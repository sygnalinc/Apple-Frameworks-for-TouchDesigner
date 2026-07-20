// Live Photo TOP — Live Photo(静止画HEIC + ペア動画MOV)を PHLivePhoto として検証し、その動画
// コンポーネントの任意時刻フレームを BGRA8 TOP に出力する(Live Photo の「全フレーム」へのアクセス)。
// 高度な編集は PHLivePhotoEditingContext を使う想定。cook はブロックせずワーカーで抽出。
// 注: Live Photo の実素材(image + paired video)が必要。
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
struct Result { std::vector<uint8_t> bgra; uint32_t w=0,h=0; uint64_t serial=0; bool ok=false; bool live=false; double dur=0; };

class LivePhotoTOP final : public TOP_CPlusPlusBase {
public:
    LivePhotoTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myThread=std::thread([this]{ worker(); }); }
    ~LivePhotoTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit=true; } myCond.notify_all(); if(myThread.joinable()) myThread.join(); }
    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked=true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        std::string img=in->getParFilePath("Imagefile")?in->getParFilePath("Imagefile"):"";
        std::string vid=in->getParFilePath("Videofile")?in->getParFilePath("Videofile"):"";
        double t=in->getParDouble("Time");
        std::string sig=img+"|"+vid+"|"+std::to_string(t);
        if (sig!=mySig){ mySig=sig; std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy){ myImg=img; myVid=vid; myT=t; myPending=true; mySubmit++; l.unlock(); myCond.notify_one(); } else mySig.clear(); }
        Result r; { std::lock_guard<std::mutex> l(myMutex); if(myResult.serial==myUploaded||!myResult.ok||myResult.bgra.empty()) return; r=myResult; myUploaded=r.serial; }
        TOP_UploadInfo ui; ui.textureDesc.texDim=OP_TexDim::e2D; ui.textureDesc.width=r.w; ui.textureDesc.height=r.h; ui.textureDesc.pixelFormat=OP_PixelFormat::BGRA8Fixed;
        auto b=myContext->createOutputBuffer((size_t)r.w*r.h*4, TOP_BufferFlags::None, nullptr); if(!b) return;
        memcpy(b->data, r.bgra.data(), r.bgra.size()); out->uploadBuffer(&b, ui, nullptr);
        myLive=r.live; myDur=r.dur;
    }
    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="Live Photo";
        { OP_StringParameter p("Imagefile"); p.label="Still File (HEIC/JPG)"; p.page=P; m->appendFile(p); }
        { OP_StringParameter p("Videofile"); p.label="Paired Video (MOV)"; p.page=P; m->appendFile(p); }
        { OP_NumericParameter p("Time"); p.label="Time (0..1 of video)"; p.page=P; p.defaultValues[0]=0.5; p.minSliders[0]=0; p.maxSliders[0]=1; m->appendFloat(p); }
    }
    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","is_live_photo","duration","submits"}; float v[]={(float)myExec.load(),(float)(myLive?1:0),(float)myDur,(float)mySubmit.load()};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(!myWarn.empty()) s->setString(myWarn.c_str()); }
private:
    void worker() {
        for(;;){
            std::string img,vid; double t;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l,[this]{return myPending||myQuit;}); if(myQuit) return; myBusy=true; myPending=false; img=myImg; vid=myVid; t=myT; }
            __block Result r; r.serial=++mySerial;
            @autoreleasepool {
                // Live Photo として妥当か検証(image+video が揃えば PHLivePhoto を生成できる)
                if (!img.empty() && !vid.empty()) {
                    NSURL* iu=[NSURL fileURLWithPath:[NSString stringWithUTF8String:img.c_str()]];
                    NSURL* vu=[NSURL fileURLWithPath:[NSString stringWithUTF8String:vid.c_str()]];
                    dispatch_semaphore_t sem=dispatch_semaphore_create(0);
                    [PHLivePhoto requestLivePhotoWithResourceFileURLs:@[iu,vu] placeholderImage:nil targetSize:CGSizeZero contentMode:PHImageContentModeDefault resultHandler:^(PHLivePhoto* lp, NSDictionary* info){
                        if (lp && ![info[PHLivePhotoInfoIsDegradedKey] boolValue]) r.live=true;
                        dispatch_semaphore_signal(sem);
                    }];
                    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC));
                }
                // 動画コンポーネントの t 時刻フレームを抽出
                if (!vid.empty()) {
                    NSURL* vu=[NSURL fileURLWithPath:[NSString stringWithUTF8String:vid.c_str()]];
                    AVURLAsset* asset=[AVURLAsset assetWithURL:vu];
                    double dur=CMTimeGetSeconds(asset.duration); r.dur=dur;
                    AVAssetImageGenerator* gen=[[AVAssetImageGenerator alloc] initWithAsset:asset];
                    gen.appliesPreferredTrackTransform=YES; gen.requestedTimeToleranceBefore=kCMTimeZero; gen.requestedTimeToleranceAfter=kCMTimeZero;
                    CMTime time=CMTimeMakeWithSeconds(dur*std::max(0.0,std::min(1.0,t)), 600);
                    NSError* err=nil;
                    CGImageRef cg=[gen copyCGImageAtTime:time actualTime:NULL error:&err];
                    if (cg) {
                        int w=(int)CGImageGetWidth(cg), h=(int)CGImageGetHeight(cg);
                        r.bgra.assign((size_t)w*h*4,0);
                        CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
                        CGContextRef ctx=CGBitmapContextCreate(r.bgra.data(),w,h,8,w*4,cs,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
                        CGContextTranslateCTM(ctx,0,h); CGContextScaleCTM(ctx,1,-1);
                        CGContextDrawImage(ctx,CGRectMake(0,0,w,h),cg);
                        CGContextRelease(ctx); CGColorSpaceRelease(cs); CGImageRelease(cg);
                        r.w=w; r.h=h; r.ok=true;
                    } else { std::lock_guard<std::mutex> l(myMutex); myWarn=err?err.localizedDescription.UTF8String:"frame extract failed"; }
                }
            }
            { std::lock_guard<std::mutex> l(myMutex); myResult=r; if(r.ok) myWarn.clear(); myBusy=false; }
        }
    }
    TOP_Context* myContext=nullptr; std::thread myThread; std::mutex myMutex; std::condition_variable myCond;
    bool myPending=false,myBusy=false,myQuit=false; bool myLive=false; double myDur=0;
    std::string myImg,myVid,mySig,myWarn; double myT=0.5;
    Result myResult; uint64_t myUploaded=0; std::atomic<uint64_t> mySerial{0},myExec{0},mySubmit{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode=TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Livephoto");
    i->customOPInfo.opLabel->setString("Live Photo");
    i->customOPInfo.opIcon->setString("LVP");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new LivePhotoTOP(i,c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<LivePhotoTOP*>(i); }
}
