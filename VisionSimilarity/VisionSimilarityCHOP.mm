// VisionSimilarity CHOP — Vision Feature Printによる2画像の距離。
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;
namespace {
struct Result{float valid=0,distance=0,similarity=0,match=0;};
class VisionSimilarityCHOP final:public CHOP_CPlusPlusBase{
public:
 VisionSimilarityCHOP(const OP_NodeInfo*){myThread=std::thread([this]{worker();});}
 ~VisionSimilarityCHOP()override{{std::lock_guard<std::mutex>l(myMutex);myQuit=true;}myCond.notify_all();if(myThread.joinable())myThread.join();}
 void getGeneralInfo(CHOP_GeneralInfo*g,const OP_Inputs*,void*)override{g->cookEveryFrameIfAsked=true;g->timeslice=false;}
 bool getOutputInfo(CHOP_OutputInfo*i,const OP_Inputs*,void*)override{i->numChannels=4;i->numSamples=1;i->startIndex=0;return true;}
 void getChannelName(int32_t i,OP_String*n,const OP_Inputs*,void*)override{const char*x[]={"valid","distance","similarity","match"};n->setString(x[i]);}
 void execute(CHOP_Output*out,const OP_Inputs*in,void*)override{myExec++;bool active=in->getParInt("Active")!=0,flip=in->getParInt("Flip")!=0;float threshold=std::max(0.f,(float)in->getParDouble("Threshold"));std::string sig=std::to_string(threshold)+(flip?":1":":0");if(sig!=mySig){mySig=sig;myLastA=myLastB=-1;}const OP_TOPInput*a=in->getParTOP("Top"),*b=in->getParTOP("Reference");if(active&&a&&b&&((int64_t)a->totalCooks!=myLastA||(int64_t)b->totalCooks!=myLastB)){std::unique_lock<std::mutex>l(myMutex,std::try_to_lock);if(l.owns_lock()&&!myPending&&!myBusy){OP_TOPInputDownloadOptions o;o.pixelFormat=OP_PixelFormat::BGRA8Fixed;o.verticalFlip=flip;myA=a->downloadTexture(o,nullptr);myB=b->downloadTexture(o,nullptr);if(myA&&myB){myThreshold=threshold;myPending=true;myLastA=a->totalCooks;myLastB=b->totalCooks;mySubmit++;l.unlock();myCond.notify_one();}}}Result r;{std::lock_guard<std::mutex>l(myMutex);r=myResult;}out->channels[0][0]=active?r.valid:0;out->channels[1][0]=active?r.distance:0;out->channels[2][0]=active?r.similarity:0;out->channels[3][0]=active?r.match:0;}
 void setupParameters(OP_ParameterManager*m,void*)override{OP_StringParameter a("Top");a.label="TOP";a.page="Vision Similarity";m->appendTOP(a);OP_StringParameter b("Reference");b.label="Reference TOP";b.page="Vision Similarity";m->appendTOP(b);OP_NumericParameter on("Active");on.label="Active";on.page="Vision Similarity";on.defaultValues[0]=1;m->appendToggle(on);OP_NumericParameter t("Threshold");t.label="Distance Threshold";t.page="Vision Similarity";t.defaultValues[0]=10;t.minSliders[0]=0;t.maxSliders[0]=30;t.minValues[0]=0;t.clampMins[0]=true;m->appendFloat(t);OP_NumericParameter f("Flip");f.label="Flip Image Vertically";f.page="Vision Similarity";f.defaultValues[0]=1;m->appendToggle(f);}
 int32_t getNumInfoCHOPChans(void*)override{return 4;}void getInfoCHOPChan(int32_t i,OP_InfoCHOPChan*c,void*)override{const char*n[]={"executes","submits","analyzes","analyze_ms"};float v[]={(float)myExec.load(),(float)mySubmit.load(),(float)myAnalyze.load(),myMs.load()};c->name->setString(n[i]);c->value=v[i];}void getWarningString(OP_String*s,void*)override{std::lock_guard<std::mutex>l(myMutex);if(!myWarning.empty())s->setString(myWarning.c_str());}
private:
 void worker(){while(true){OP_SmartRef<OP_TOPDownloadResult>a,b;float threshold;{std::unique_lock<std::mutex>l(myMutex);myCond.wait(l,[this]{return myQuit||myPending;});if(myQuit)return;a=std::move(myA);b=std::move(myB);threshold=myThreshold;myPending=false;myBusy=true;}Result r;std::string w;auto t=std::chrono::steady_clock::now();bool ok=analyze(a,b,threshold,r,w);myMs=std::chrono::duration<float,std::milli>(std::chrono::steady_clock::now()-t).count();myAnalyze++;{std::lock_guard<std::mutex>l(myMutex);if(ok)myResult=r;else myResult={};myWarning=std::move(w);myBusy=false;}}}
 static VNFeaturePrintObservation*feature(OP_SmartRef<OP_TOPDownloadResult>&d,NSError**error){void*data=d->getData();uint32_t w=d->textureDesc.width,h=d->textureDesc.height;if(!data||!w||!h)return nil;CVPixelBufferRef p=nullptr;CVPixelBufferCreateWithBytes(nullptr,w,h,kCVPixelFormatType_32BGRA,data,w*4,nullptr,nullptr,nullptr,&p);if(!p)return nil;VNGenerateImageFeaturePrintRequest*r=[VNGenerateImageFeaturePrintRequest new];VNImageRequestHandler*handler=[[VNImageRequestHandler alloc]initWithCVPixelBuffer:p options:@{}];BOOL ok=[handler performRequests:@[r] error:error];CVPixelBufferRelease(p);return ok?(VNFeaturePrintObservation*)r.results.firstObject:nil;}
 static bool analyze(OP_SmartRef<OP_TOPDownloadResult>&a,OP_SmartRef<OP_TOPDownloadResult>&b,float threshold,Result&r,std::string&w){@autoreleasepool{NSError*e=nil;VNFeaturePrintObservation*fa=feature(a,&e);if(!fa){w=e.localizedDescription.UTF8String?:"Could not generate input feature print";return false;}e=nil;VNFeaturePrintObservation*fb=feature(b,&e);if(!fb){w=e.localizedDescription.UTF8String?:"Could not generate reference feature print";return false;}float d=0;if(![fa computeDistance:&d toFeaturePrintObservation:fb error:&e]){w=e.localizedDescription.UTF8String?:"Feature print comparison failed";return false;}r.valid=1;r.distance=d;r.similarity=expf(-d/10.f);r.match=d<=threshold?1:0;return true;}}
 std::thread myThread;std::condition_variable myCond;std::mutex myMutex;bool myQuit=false,myPending=false,myBusy=false;OP_SmartRef<OP_TOPDownloadResult>myA,myB;float myThreshold=10;Result myResult;std::string myWarning,mySig;int64_t myLastA=-1,myLastB=-1;std::atomic<uint64_t>myExec{0},mySubmit{0},myAnalyze{0};std::atomic<float>myMs{0};
};}
extern "C"{DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo*i){if(!i->setAPIVersion(CHOPCPlusPlusAPIVersion))return;i->customOPInfo.opType->setString("Visionsimilarity");i->customOPInfo.opLabel->setString("Vision Similarity");i->customOPInfo.opIcon->setString("VSM");if(i->customOPInfo.opHelpURL)i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/VisionSimilarity/README.md");i->customOPInfo.authorName->setString("SYGNAL Inc.");i->customOPInfo.minInputs=0;i->customOPInfo.maxInputs=0;}DLLEXPORT CHOP_CPlusPlusBase*CreateCHOPInstance(const OP_NodeInfo*i){return new VisionSimilarityCHOP(i);}DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase*i){delete static_cast<VisionSimilarityCHOP*>(i);}}
