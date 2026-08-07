// VisionRect CHOP — multi-rectangle detection with bbox and four corners.
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
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;
namespace {
constexpr int kMaxRects=100;
struct Rect{float confidence=0,bbox[4]={},corners[8]={};};
struct Settings{int max=10;float minAspect=.5f,maxAspect=1,minSize=.2f,minConfidence=0,tolerance=30;};
class VisionRectCHOP final:public CHOP_CPlusPlusBase{
public:
 VisionRectCHOP(const OP_NodeInfo*){myThread=std::thread([this]{worker();});}
 ~VisionRectCHOP()override{{std::lock_guard<std::mutex>l(myMutex);myQuit=true;}myCond.notify_all();if(myThread.joinable())myThread.join();}
 void getGeneralInfo(CHOP_GeneralInfo*g,const OP_Inputs*,void*)override{g->cookEveryFrameIfAsked=true;g->timeslice=false;}
 bool getOutputInfo(CHOP_OutputInfo*i,const OP_Inputs*in,void*)override{myMax=std::clamp(in->getParInt("Maxrects"),1,kMaxRects);i->numChannels=myMax*14;i->numSamples=1;i->startIndex=0;return true;}
 void getChannelName(int32_t index,OP_String*n,const OP_Inputs*,void*)override{int r=index/14+1,l=index%14;char b[64];if(l==0)snprintf(b,sizeof(b),"rect%d:valid",r);else{const char*f[]={"confidence","bbox:u","bbox:v","bbox:w","bbox:h","tl:u","tl:v","tr:u","tr:v","br:u","br:v","bl:u","bl:v"};snprintf(b,sizeof(b),"rect%d/%s",r,f[l-1]);}n->setString(b);}
 void execute(CHOP_Output*out,const OP_Inputs*in,void*)override{myExec++;bool active=in->getParInt("Active")!=0,flip=in->getParInt("Flip")!=0;Settings s;s.max=myMax;s.minAspect=std::clamp((float)in->getParDouble("Minaspect"),0.f,1.f);s.maxAspect=std::clamp((float)in->getParDouble("Maxaspect"),s.minAspect,1.f);s.minSize=std::clamp((float)in->getParDouble("Minsize"),0.f,1.f);s.minConfidence=std::clamp((float)in->getParDouble("Minconfidence"),0.f,1.f);s.tolerance=std::clamp((float)in->getParDouble("Tolerance"),0.f,45.f);
  std::string sig=std::to_string(s.max)+":"+std::to_string(s.minAspect)+":"+std::to_string(s.maxAspect)+":"+std::to_string(s.minSize)+":"+std::to_string(s.minConfidence)+":"+std::to_string(s.tolerance)+(flip?":1":":0");if(sig!=mySig){mySig=sig;myLast=-1;}
  const OP_TOPInput*top=in->getParTOP("Top");if(active&&top&&(int64_t)top->totalCooks!=myLast){std::unique_lock<std::mutex>l(myMutex,std::try_to_lock);if(l.owns_lock()&&!myPending&&!myBusy){OP_TOPInputDownloadOptions o;o.pixelFormat=OP_PixelFormat::BGRA8Fixed;o.verticalFlip=flip;myDownload=top->downloadTexture(o,nullptr);if(myDownload){mySettings=s;myPending=true;myLast=top->totalCooks;mySubmit++;l.unlock();myCond.notify_one();}}}
  std::vector<Rect>rows;{std::lock_guard<std::mutex>l(myMutex);rows=myRows;}for(int i=0;i<myMax*14;i++)out->channels[i][0]=0;for(int r=0;r<myMax&&active&&r<(int)rows.size();r++){int b=r*14;out->channels[b][0]=1;out->channels[b+1][0]=rows[r].confidence;for(int i=0;i<4;i++)out->channels[b+2+i][0]=rows[r].bbox[i];for(int i=0;i<8;i++)out->channels[b+6+i][0]=rows[r].corners[i];}}
 void setupParameters(OP_ParameterManager*m,void*)override{OP_StringParameter top("Top");top.label="TOP";top.page="Vision Rect";m->appendTOP(top);OP_NumericParameter a("Active");a.label="Active";a.page="Vision Rect";a.defaultValues[0]=1;m->appendToggle(a);OP_NumericParameter n("Maxrects");n.label="Max Rectangles";n.page="Vision Rect";n.defaultValues[0]=10;n.minSliders[0]=1;n.maxSliders[0]=10;n.minValues[0]=1;n.maxValues[0]=100;n.clampMins[0]=n.clampMaxes[0]=true;m->appendInt(n);
  addFloat(m,"Minaspect","Minimum Aspect Ratio",.5,0,1);addFloat(m,"Maxaspect","Maximum Aspect Ratio",1,0,1);addFloat(m,"Minsize","Minimum Size",.2,0,1);addFloat(m,"Minconfidence","Minimum Confidence",0,0,1);addFloat(m,"Tolerance","Quadrature Tolerance",30,0,45);OP_NumericParameter f("Flip");f.label="Flip Image Vertically";f.page="Vision Rect";f.defaultValues[0]=1;m->appendToggle(f);}
 int32_t getNumInfoCHOPChans(void*)override{return 5;}void getInfoCHOPChan(int32_t i,OP_InfoCHOPChan*c,void*)override{const char*n[]={"executes","submits","analyzes","analyze_ms","rects"};int count;{std::lock_guard<std::mutex>l(myMutex);count=(int)myRows.size();}float v[]={(float)myExec.load(),(float)mySubmit.load(),(float)myAnalyze.load(),myMs.load(),(float)count};c->name->setString(n[i]);c->value=v[i];}
 void getWarningString(OP_String*s,void*)override{std::lock_guard<std::mutex>l(myMutex);if(!myWarning.empty())s->setString(myWarning.c_str());}
private:
 static void addFloat(OP_ParameterManager*m,const char*name,const char*label,double def,double lo,double hi){OP_NumericParameter p(name);p.label=label;p.page="Vision Rect";p.defaultValues[0]=def;p.minSliders[0]=lo;p.maxSliders[0]=hi;p.minValues[0]=lo;p.maxValues[0]=hi;p.clampMins[0]=p.clampMaxes[0]=true;m->appendFloat(p);}
 void worker(){while(true){OP_SmartRef<OP_TOPDownloadResult>d;Settings s;{std::unique_lock<std::mutex>l(myMutex);myCond.wait(l,[this]{return myQuit||myPending;});if(myQuit)return;d=std::move(myDownload);s=mySettings;myPending=false;myBusy=true;}std::vector<Rect>r;std::string w;auto t=std::chrono::steady_clock::now();analyze(d,s,r,w);myMs=std::chrono::duration<float,std::milli>(std::chrono::steady_clock::now()-t).count();myAnalyze++;{std::lock_guard<std::mutex>l(myMutex);myRows=std::move(r);myWarning=std::move(w);myBusy=false;}}}
 static void analyze(OP_SmartRef<OP_TOPDownloadResult>&d,const Settings&s,std::vector<Rect>&rows,std::string&warning){if(!d)return;void*data=d->getData();uint32_t w=d->textureDesc.width,h=d->textureDesc.height;if(!data||!w||!h)return;@autoreleasepool{CVPixelBufferRef p=nullptr;CVPixelBufferCreateWithBytes(nullptr,w,h,kCVPixelFormatType_32BGRA,data,(size_t)w*4,nullptr,nullptr,nullptr,&p);if(!p)return;VNDetectRectanglesRequest*r=[VNDetectRectanglesRequest new];r.revision=VNDetectRectanglesRequestRevision1;r.maximumObservations=s.max;r.minimumAspectRatio=s.minAspect;r.maximumAspectRatio=s.maxAspect;r.minimumSize=s.minSize;r.minimumConfidence=s.minConfidence;r.quadratureTolerance=s.tolerance;VNImageRequestHandler*handler=[[VNImageRequestHandler alloc]initWithCVPixelBuffer:p options:@{}];NSError*e=nil;if([handler performRequests:@[r]error:&e])for(VNRectangleObservation*o in r.results){Rect x;x.confidence=o.confidence;CGRect b=o.boundingBox;x.bbox[0]=b.origin.x+b.size.width*.5;x.bbox[1]=b.origin.y+b.size.height*.5;x.bbox[2]=b.size.width;x.bbox[3]=b.size.height;CGPoint cs[]={o.topLeft,o.topRight,o.bottomRight,o.bottomLeft};for(int i=0;i<4;i++){x.corners[i*2]=cs[i].x;x.corners[i*2+1]=cs[i].y;}rows.push_back(x);}else if(e)warning=e.localizedDescription.UTF8String?:"Rectangle detection failed";CVPixelBufferRelease(p);}std::stable_sort(rows.begin(),rows.end(),[](const Rect&a,const Rect&b){return a.bbox[0]<b.bbox[0];});}
 std::thread myThread;std::condition_variable myCond;std::mutex myMutex;bool myQuit=false,myPending=false,myBusy=false;OP_SmartRef<OP_TOPDownloadResult>myDownload;Settings mySettings;int myMax=10;int64_t myLast=-1;std::string mySig,myWarning;std::vector<Rect>myRows;std::atomic<uint64_t>myExec{0},mySubmit{0},myAnalyze{0};std::atomic<float>myMs{0};
};}
extern "C"{DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo*i){if(!i->setAPIVersion(CHOPCPlusPlusAPIVersion))return;i->customOPInfo.opType->setString("Visionrect");i->customOPInfo.opLabel->setString("Vision Rect");i->customOPInfo.opIcon->setString("VRC");if(i->customOPInfo.opHelpURL)i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/VisionRect/README.md");i->customOPInfo.authorName->setString("SYGNAL Inc.");
i->customOPInfo.majorVersion = 0;
i->customOPInfo.minorVersion = 9;i->customOPInfo.minInputs=0;i->customOPInfo.maxInputs=0;}DLLEXPORT CHOP_CPlusPlusBase*CreateCHOPInstance(const OP_NodeInfo*i){return new VisionRectCHOP(i);}DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase*i){delete static_cast<VisionRectCHOP*>(i);}}
