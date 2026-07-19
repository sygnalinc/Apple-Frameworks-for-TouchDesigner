// VisionClassify DAT — built-in Apple Vision image classification.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
struct ClassResult { std::string identifier; float confidence = 0; };

class VisionClassifyDAT final : public DAT_CPlusPlusBase {
public:
    VisionClassifyDAT(const OP_NodeInfo*) { myWorker = std::thread([this]{ worker(); }); }
    ~VisionClassifyDAT() override {
        { std::lock_guard<std::mutex> l(myMutex); myQuit = true; }
        myCond.notify_all(); if (myWorker.joinable()) myWorker.join();
    }
    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override
    { g->cookEveryFrameIfAsked = true; }
    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override {
        myExec++;
        const bool active = inputs->getParInt("Active") != 0;
        const bool flip = inputs->getParInt("Flip") != 0;
        const int topN = std::clamp(inputs->getParInt("Topn"), 1, 100);
        const float minConf = std::clamp((float)inputs->getParDouble("Minconfidence"), 0.0f, 1.0f);
        const std::string sig = std::to_string(topN)+":"+std::to_string(minConf)+(flip?":1":":0");
        if (sig != mySignature) { mySignature = sig; myLastCook = -1; }
        const OP_TOPInput* top = inputs->getParTOP("Top");
        if (active && top && (int64_t)top->totalCooks != myLastCook) {
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) {
                OP_TOPInputDownloadOptions o; o.pixelFormat=OP_PixelFormat::BGRA8Fixed; o.verticalFlip=flip;
                myDownload=top->downloadTexture(o,nullptr);
                if (myDownload) { myPending=true; myPendingTopN=topN; myPendingMin=minConf;
                    myLastCook=top->totalCooks; mySubmit++; l.unlock(); myCond.notify_one(); }
            }
        }
        std::vector<ClassResult> rows;
        { std::lock_guard<std::mutex> l(myMutex); rows=myRows; }
        if (!active) rows.clear();
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize((int32_t)rows.size()+1,3);
        output->setCellString(0,0,"rank"); output->setCellString(0,1,"identifier");
        output->setCellString(0,2,"confidence");
        for (int i=0;i<(int)rows.size();++i) {
            char rank[16], conf[32]; snprintf(rank,sizeof(rank),"%d",i+1);
            snprintf(conf,sizeof(conf),"%.6f",rows[i].confidence);
            output->setCellString(i+1,0,rank); output->setCellString(i+1,1,rows[i].identifier.c_str());
            output->setCellString(i+1,2,conf);
        }
        myCount=(int)rows.size();
    }
    void setupParameters(OP_ParameterManager* m, void*) override {
        OP_StringParameter top("Top"); top.label="TOP"; top.page="Vision Classify"; m->appendTOP(top);
        OP_NumericParameter active("Active"); active.label="Active"; active.page="Vision Classify";
        active.defaultValues[0]=1; m->appendToggle(active);
        OP_NumericParameter n("Topn"); n.label="Top Results"; n.page="Vision Classify";
        n.defaultValues[0]=10; n.minSliders[0]=1; n.maxSliders[0]=10; n.minValues[0]=1;
        n.maxValues[0]=100; n.clampMins[0]=true; n.clampMaxes[0]=true; m->appendInt(n);
        OP_NumericParameter c("Minconfidence"); c.label="Minimum Confidence"; c.page="Vision Classify";
        c.defaultValues[0]=0.01; c.minSliders[0]=0; c.maxSliders[0]=1; c.minValues[0]=0;
        c.maxValues[0]=1; c.clampMins[0]=true; c.clampMaxes[0]=true; m->appendFloat(c);
        OP_NumericParameter f("Flip"); f.label="Flip Image Vertically"; f.page="Vision Classify";
        f.defaultValues[0]=1; m->appendToggle(f);
    }
    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* names[]={"executes","submits","analyzes","analyze_ms","results"};
        float values[]={(float)myExec.load(),(float)mySubmit.load(),(float)myAnalyze.load(),
                        myMs.load(),(float)myCount.load()};
        c->name->setString(names[i]); c->value=values[i];
    }
    void getWarningString(OP_String* s, void*) override {
        std::lock_guard<std::mutex> l(myMutex); if(!myWarning.empty()) s->setString(myWarning.c_str());
    }
private:
    void worker() {
        while(true) {
            OP_SmartRef<OP_TOPDownloadResult> d; int n; float min;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l,[this]{return myQuit||myPending;});
              if(myQuit)return; d=std::move(myDownload); n=myPendingTopN; min=myPendingMin;
              myPending=false; myBusy=true; }
            std::vector<ClassResult> rows; std::string warning;
            auto start=std::chrono::steady_clock::now(); analyze(d,n,min,rows,warning);
            myMs=std::chrono::duration<float,std::milli>(std::chrono::steady_clock::now()-start).count();
            myAnalyze++;
            { std::lock_guard<std::mutex> l(myMutex); myRows=std::move(rows); myWarning=std::move(warning); myBusy=false; }
        }
    }
    static void analyze(OP_SmartRef<OP_TOPDownloadResult>& d,int topN,float min,
                        std::vector<ClassResult>& rows,std::string& warning) {
        if(!d)return; void* data=d->getData(); uint32_t w=d->textureDesc.width,h=d->textureDesc.height;
        if(!data||!w||!h)return;
        @autoreleasepool {
            CVPixelBufferRef pixel=nullptr; CVPixelBufferCreateWithBytes(nullptr,w,h,kCVPixelFormatType_32BGRA,
                data,(size_t)w*4,nullptr,nullptr,nullptr,&pixel); if(!pixel)return;
            VNClassifyImageRequest* request=[VNClassifyImageRequest new];
            VNImageRequestHandler* handler=[[VNImageRequestHandler alloc]initWithCVPixelBuffer:pixel options:@{}];
            NSError* error=nil;
            if([handler performRequests:@[request] error:&error]) {
                for(VNClassificationObservation* o in request.results) {
                    if((int)rows.size()>=topN)break; if(o.confidence<min)continue;
                    rows.push_back({o.identifier.UTF8String ?: "",(float)o.confidence});
                }
            } else if(error) warning=error.localizedDescription.UTF8String ?: "Image classification failed";
            CVPixelBufferRelease(pixel);
        }
    }
    std::thread myWorker; std::condition_variable myCond; std::mutex myMutex;
    bool myQuit=false,myPending=false,myBusy=false; OP_SmartRef<OP_TOPDownloadResult> myDownload;
    int myPendingTopN=10; float myPendingMin=.01f; int64_t myLastCook=-1;
    std::vector<ClassResult> myRows; std::string myWarning,mySignature;
    std::atomic<uint64_t> myExec{0},mySubmit{0},myAnalyze{0};
    std::atomic<float> myMs{0}; std::atomic<int> myCount{0};
};
}
extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i) { if(!i->setAPIVersion(DATCPlusPlusAPIVersion))return;
 i->customOPInfo.opType->setString("Visionclassify"); i->customOPInfo.opLabel->setString("Apple Vision Classify");
 i->customOPInfo.opIcon->setString("VCL"); i->customOPInfo.authorName->setString("TDAppleML");
 i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0; }
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i){return new VisionClassifyDAT(i);}
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i){delete static_cast<VisionClassifyDAT*>(i);}
}
