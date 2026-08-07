// VisionTrajectory CHOP — parabolic small-object trajectory detection.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Vision/Vision.h>
#include "../common/AspectCoords.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;
namespace {
constexpr int kMaxTrajectories=100,kMaxLength=30;
struct Trajectory{float a=0,b=0,c=0,radius=0;std::vector<simd_float2>detected,projected;};
struct Settings{int length=5,maxTrajectories=4;float minRadius=.005f,maxRadius=.1f,targetFps=60;};
class VisionTrajectoryCHOP final:public CHOP_CPlusPlusBase{
public:
 VisionTrajectoryCHOP(const OP_NodeInfo*){myThread=std::thread([this]{worker();});}
 ~VisionTrajectoryCHOP()override{{std::lock_guard<std::mutex>l(myMutex);myQuit=true;}myCond.notify_all();if(myThread.joinable())myThread.join();}
 void getGeneralInfo(CHOP_GeneralInfo*g,const OP_Inputs*,void*)override{g->cookEveryFrameIfAsked=true;g->timeslice=false;}
 bool getOutputInfo(CHOP_OutputInfo*i,const OP_Inputs*in,void*)override{myMax=std::clamp(in->getParInt("Maxtrajectories"),1,kMaxTrajectories);myLength=std::clamp(in->getParInt("Length"),5,kMaxLength);i->numChannels=myMax*(6+myLength*4);i->numSamples=1;i->startIndex=0;return true;}
 void getChannelName(int32_t index,OP_String*name,const OP_Inputs*,void*)override{int per=6+myLength*4,t=index/per+1,l=index%per;char b[96];
  if(l==0)snprintf(b,sizeof(b),"trajectory%d:valid",t);else if(l<6){const char*f[]={"a","b","c","radius","points"};snprintf(b,sizeof(b),"trajectory%d/%s",t,f[l-1]);}
  else{int q=(l-6)/4,field=(l-6)%4;const char*f[]={"detected_u","detected_v","projected_u","projected_v"};snprintf(b,sizeof(b),"trajectory%d/point%d:%s",t,q+1,f[field]);}name->setString(b);}
 void execute(CHOP_Output*out,const OP_Inputs*in,void*)override{myExec++;bool active=in->getParInt("Active")!=0,flip=in->getParInt("Flip")!=0;
  Settings s;s.length=myLength;s.maxTrajectories=myMax;s.minRadius=std::max(0.f,(float)in->getParDouble("Minradius"));s.maxRadius=std::max(s.minRadius,(float)in->getParDouble("Maxradius"));s.targetFps=std::max(1.f,(float)in->getParDouble("Targetfps"));
  std::string sig=std::to_string(s.length)+":"+std::to_string(s.minRadius)+":"+std::to_string(s.maxRadius)+":"+std::to_string(s.targetFps)+(flip?":1":":0");if(sig!=mySig){mySig=sig;myLast=-1;myReset=true;}
  const OP_TOPInput*top=in->getParTOP("Top");if(active&&top&&(int64_t)top->totalCooks!=myLast){std::unique_lock<std::mutex>l(myMutex,std::try_to_lock);if(l.owns_lock()&&!myPending&&!myBusy){OP_TOPInputDownloadOptions o;o.pixelFormat=OP_PixelFormat::BGRA8Fixed;o.verticalFlip=flip;myDownload=top->downloadTexture(o,nullptr);if(myDownload){mySettings=s;myPending=true;myLast=top->totalCooks;mySubmit++;l.unlock();myCond.notify_one();}}}
  std::vector<Trajectory>r;{std::lock_guard<std::mutex>l(myMutex);r=myRows;}int per=6+myLength*4;
  const tdaspect::Mapper map{in->getParInt("Aspectcorrectuv")!=0,top?(float)top->textureDesc.width:0.f,top?(float)top->textureDesc.height:0.f};for(int t=0;t<myMax;t++){bool valid=active&&t<(int)r.size();int base=t*per;for(int q=0;q<per;q++)out->channels[base+q][0]=0;if(!valid)continue;const auto&x=r[t];out->channels[base][0]=1;out->channels[base+1][0]=map.dy(x.a);out->channels[base+2][0]=map.dy(x.b);out->channels[base+3][0]=map.y(x.c);out->channels[base+4][0]=x.radius;out->channels[base+5][0]=(float)x.detected.size();
   for(int p=0;p<myLength;p++){if(p<(int)x.detected.size()){out->channels[base+6+p*4][0]=map.x(x.detected[p].x);out->channels[base+7+p*4][0]=map.y(x.detected[p].y);}if(p<(int)x.projected.size()){out->channels[base+8+p*4][0]=map.x(x.projected[p].x);out->channels[base+9+p*4][0]=map.y(x.projected[p].y);}}}}
 void setupParameters(OP_ParameterManager*m,void*)override{OP_StringParameter top("Top");top.label="TOP";top.page="Vision Trajectory";m->appendTOP(top);tdaspect::appendAspectCorrect<OP_ParameterManager,OP_NumericParameter>(m,"Vision Trajectory");OP_NumericParameter a("Active");a.label="Active";a.page="Vision Trajectory";a.defaultValues[0]=1;m->appendToggle(a);
  OP_NumericParameter n("Maxtrajectories");n.label="Max Trajectories";n.page="Vision Trajectory";n.defaultValues[0]=4;n.minSliders[0]=1;n.maxSliders[0]=10;n.minValues[0]=1;n.maxValues[0]=100;n.clampMins[0]=n.clampMaxes[0]=true;m->appendInt(n);
  OP_NumericParameter len("Length");len.label="Trajectory Length";len.page="Vision Trajectory";len.defaultValues[0]=5;len.minSliders[0]=5;len.maxSliders[0]=30;len.minValues[0]=5;len.maxValues[0]=30;len.clampMins[0]=len.clampMaxes[0]=true;m->appendInt(len);
  OP_NumericParameter mi("Minradius");mi.label="Minimum Object Radius";mi.page="Vision Trajectory";mi.defaultValues[0]=.005;mi.minSliders[0]=0;mi.maxSliders[0]=.1;mi.minValues[0]=0;mi.clampMins[0]=true;m->appendFloat(mi);
  OP_NumericParameter ma("Maxradius");ma.label="Maximum Object Radius";ma.page="Vision Trajectory";ma.defaultValues[0]=.1;ma.minSliders[0]=.01;ma.maxSliders[0]=.5;ma.minValues[0]=0;ma.clampMins[0]=true;m->appendFloat(ma);
  OP_NumericParameter fps("Targetfps");fps.label="Target FPS";fps.page="Vision Trajectory";fps.defaultValues[0]=60;fps.minSliders[0]=1;fps.maxSliders[0]=120;fps.minValues[0]=1;fps.clampMins[0]=true;m->appendFloat(fps);
  OP_NumericParameter reset("Reset");reset.label="Reset Tracking";reset.page="Vision Trajectory";m->appendPulse(reset);
  OP_NumericParameter f("Flip");f.label="Flip Image Vertically";f.page="Vision Trajectory";f.defaultValues[0]=1;m->appendToggle(f);}
 void pulsePressed(const char*n,void*)override{if(!strcmp(n,"Reset")){myReset=true;myResets++;}}
 int32_t getNumInfoCHOPChans(void*)override{return 7;}void getInfoCHOPChan(int32_t i,OP_InfoCHOPChan*c,void*)override{const char*n[]={"executes","submits","analyzes","analyze_ms","trajectories","frames","resets"};int count;{std::lock_guard<std::mutex>l(myMutex);count=(int)myRows.size();}float v[]={(float)myExec.load(),(float)mySubmit.load(),(float)myAnalyze.load(),myMs.load(),(float)count,(float)myFrames.load(),(float)myResets.load()};c->name->setString(n[i]);c->value=v[i];}
 void getWarningString(OP_String*s,void*)override{std::lock_guard<std::mutex>l(myMutex);if(!myWarning.empty())s->setString(myWarning.c_str());}
private:
 void resetRequest(const Settings&s){mySequence=[VNSequenceRequestHandler new];myRequest=[[VNDetectTrajectoriesRequest alloc]initWithFrameAnalysisSpacing:kCMTimeZero trajectoryLength:s.length completionHandler:nil];myRequest.revision=VNDetectTrajectoriesRequestRevision1;myRequest.objectMinimumNormalizedRadius=s.minRadius;myRequest.objectMaximumNormalizedRadius=s.maxRadius;if(@available(macOS 12.0,*))myRequest.targetFrameTime=CMTimeMake(1,(int32_t)s.targetFps);myFrameIndex=0;}
 void worker(){@autoreleasepool{while(true){OP_SmartRef<OP_TOPDownloadResult>d;Settings s;{std::unique_lock<std::mutex>l(myMutex);myCond.wait(l,[this]{return myQuit||myPending;});if(myQuit)return;d=std::move(myDownload);s=mySettings;myPending=false;myBusy=true;}std::vector<Trajectory>r;std::string w;auto t=std::chrono::steady_clock::now();if(myReset.exchange(false)||!myRequest)resetRequest(s);analyze(d,s,r,w);myMs=std::chrono::duration<float,std::milli>(std::chrono::steady_clock::now()-t).count();myAnalyze++;{std::lock_guard<std::mutex>l(myMutex);myRows=std::move(r);myWarning=std::move(w);myBusy=false;}}}}
 void analyze(OP_SmartRef<OP_TOPDownloadResult>&d,const Settings&s,std::vector<Trajectory>&rows,std::string&warning){if(!d)return;void*data=d->getData();uint32_t w=d->textureDesc.width,h=d->textureDesc.height;if(!data||!w||!h)return;@autoreleasepool{CVPixelBufferRef p=nullptr;CVPixelBufferCreateWithBytes(nullptr,w,h,kCVPixelFormatType_32BGRA,data,(size_t)w*4,nullptr,nullptr,nullptr,&p);if(!p)return;CMVideoFormatDescriptionRef fmt=nullptr;CMSampleBufferRef sample=nullptr;CMVideoFormatDescriptionCreateForImageBuffer(nullptr,p,&fmt);CMSampleTimingInfo timing={CMTimeMake(1,(int32_t)s.targetFps),CMTimeMake(myFrameIndex++,(int32_t)s.targetFps),kCMTimeInvalid};CMSampleBufferCreateForImageBuffer(nullptr,p,true,nullptr,nullptr,fmt,&timing,&sample);NSError*e=nil;
   if(sample&&[mySequence performRequests:@[myRequest] onCMSampleBuffer:sample error:&e]){myFrames++;for(VNTrajectoryObservation*o in myRequest.results){if((int)rows.size()>=s.maxTrajectories)break;Trajectory x;simd_float3 q=o.equationCoefficients;x.a=q.x;x.b=q.y;x.c=q.z;if(@available(macOS 12.0,*))x.radius=o.movingAverageRadius;for(VNPoint*p in o.detectedPoints)x.detected.push_back(simd_make_float2((float)p.x,(float)p.y));for(VNPoint*p in o.projectedPoints)x.projected.push_back(simd_make_float2((float)p.x,(float)p.y));rows.push_back(std::move(x));}}
   else if(e)warning=e.localizedDescription.UTF8String?:"Trajectory detection failed";if(sample)CFRelease(sample);if(fmt)CFRelease(fmt);CVPixelBufferRelease(p);}}
 std::thread myThread;std::condition_variable myCond;std::mutex myMutex;bool myQuit=false,myPending=false,myBusy=false;OP_SmartRef<OP_TOPDownloadResult>myDownload;Settings mySettings;int myMax=4,myLength=5;int64_t myLast=-1,myFrameIndex=0;std::string mySig,myWarning;std::vector<Trajectory>myRows;VNSequenceRequestHandler*mySequence=nil;VNDetectTrajectoriesRequest*myRequest=nil;std::atomic<bool>myReset{true};std::atomic<uint64_t>myExec{0},mySubmit{0},myAnalyze{0},myFrames{0},myResets{0};std::atomic<float>myMs{0};
};}
extern "C"{DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo*i){if(!i->setAPIVersion(CHOPCPlusPlusAPIVersion))return;i->customOPInfo.opType->setString("Visiontrajectory");i->customOPInfo.opLabel->setString("Vision Trajectory");i->customOPInfo.opIcon->setString("VTJ");if(i->customOPInfo.opHelpURL)i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/VisionTrajectory/README.md");i->customOPInfo.authorName->setString("SYGNAL Inc.");
i->customOPInfo.majorVersion = 0;
i->customOPInfo.minorVersion = 9;i->customOPInfo.minInputs=0;i->customOPInfo.maxInputs=0;}DLLEXPORT CHOP_CPlusPlusBase*CreateCHOPInstance(const OP_NodeInfo*i){return new VisionTrajectoryCHOP(i);}DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase*i){delete static_cast<VisionTrajectoryCHOP*>(i);}}
