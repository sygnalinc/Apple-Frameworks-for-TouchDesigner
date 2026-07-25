// VisionBarcode DAT — QR and barcode detection with payload and quadrilateral.
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
struct Barcode { std::string symbology,payload; float confidence=0,bbox[4]={},corners[8]={}; };
class VisionBarcodeDAT final:public DAT_CPlusPlusBase {
public:
 VisionBarcodeDAT(const OP_NodeInfo*){myThread=std::thread([this]{worker();});}
 ~VisionBarcodeDAT()override{{std::lock_guard<std::mutex>l(myMutex);myQuit=true;}myCond.notify_all();if(myThread.joinable())myThread.join();}
 void getGeneralInfo(DAT_GeneralInfo*g,const OP_Inputs*,void*)override{g->cookEveryFrameIfAsked=true;}
 void execute(DAT_Output*out,const OP_Inputs*in,void*)override{
  myExec++;bool active=in->getParInt("Active")!=0,flip=in->getParInt("Flip")!=0;
  int max=std::clamp(in->getParInt("Maxcodes"),1,100);float min=std::clamp((float)in->getParDouble("Minconfidence"),0.f,1.f);
  std::string sig=std::to_string(max)+":"+std::to_string(min)+(flip?":1":":0");if(sig!=mySig){mySig=sig;myLast=-1;}
  const OP_TOPInput*top=in->getParTOP("Top");
  if(active&&top&&(int64_t)top->totalCooks!=myLast){std::unique_lock<std::mutex>l(myMutex,std::try_to_lock);
   if(l.owns_lock()&&!myPending&&!myBusy){OP_TOPInputDownloadOptions o;o.pixelFormat=OP_PixelFormat::BGRA8Fixed;o.verticalFlip=flip;
    myDownload=top->downloadTexture(o,nullptr);if(myDownload){myPending=true;myPendingMax=max;myPendingMin=min;myLast=top->totalCooks;mySubmit++;l.unlock();myCond.notify_one();}}}
  std::vector<Barcode>rows;{std::lock_guard<std::mutex>l(myMutex);rows=myRows;}if(!active)rows.clear();
  static const char*headers[]={"index","symbology","payload","confidence","u","v","width","height",
   "tl_u","tl_v","tr_u","tr_v","br_u","br_v","bl_u","bl_v"};
  out->setOutputDataType(DAT_OutDataType::Table);out->setTableSize((int32_t)rows.size()+1,16);
  for(int c=0;c<16;c++)out->setCellString(0,c,headers[c]);
  for(int r=0;r<(int)rows.size();r++){char b[32];snprintf(b,sizeof(b),"%d",r+1);out->setCellString(r+1,0,b);
   out->setCellString(r+1,1,rows[r].symbology.c_str());out->setCellString(r+1,2,rows[r].payload.c_str());
   snprintf(b,sizeof(b),"%.6f",rows[r].confidence);out->setCellString(r+1,3,b);
   for(int c=0;c<4;c++){snprintf(b,sizeof(b),"%.6f",rows[r].bbox[c]);out->setCellString(r+1,4+c,b);}
   for(int c=0;c<8;c++){snprintf(b,sizeof(b),"%.6f",rows[r].corners[c]);out->setCellString(r+1,8+c,b);}}
  myCount=(int)rows.size();
 }
 void setupParameters(OP_ParameterManager*m,void*)override{
  OP_StringParameter top("Top");top.label="TOP";top.page="Vision Barcode";m->appendTOP(top);
  OP_NumericParameter a("Active");a.label="Active";a.page="Vision Barcode";a.defaultValues[0]=1;m->appendToggle(a);
  OP_NumericParameter n("Maxcodes");n.label="Max Codes";n.page="Vision Barcode";n.defaultValues[0]=10;n.minSliders[0]=1;n.maxSliders[0]=10;n.minValues[0]=1;n.maxValues[0]=100;n.clampMins[0]=n.clampMaxes[0]=true;m->appendInt(n);
  OP_NumericParameter c("Minconfidence");c.label="Minimum Confidence";c.page="Vision Barcode";c.defaultValues[0]=0;c.minSliders[0]=0;c.maxSliders[0]=1;c.minValues[0]=0;c.maxValues[0]=1;c.clampMins[0]=c.clampMaxes[0]=true;m->appendFloat(c);
  OP_NumericParameter f("Flip");f.label="Flip Image Vertically";f.page="Vision Barcode";f.defaultValues[0]=1;m->appendToggle(f);
 }
 int32_t getNumInfoCHOPChans(void*)override{return 5;}
 void getInfoCHOPChan(int32_t i,OP_InfoCHOPChan*c,void*)override{const char*n[]={"executes","submits","analyzes","analyze_ms","codes"};float v[]={(float)myExec.load(),(float)mySubmit.load(),(float)myAnalyze.load(),myMs.load(),(float)myCount.load()};c->name->setString(n[i]);c->value=v[i];}
 void getWarningString(OP_String*s,void*)override{std::lock_guard<std::mutex>l(myMutex);if(!myWarning.empty())s->setString(myWarning.c_str());}
private:
 void worker(){while(true){OP_SmartRef<OP_TOPDownloadResult>d;int max;float min;{std::unique_lock<std::mutex>l(myMutex);myCond.wait(l,[this]{return myQuit||myPending;});if(myQuit)return;d=std::move(myDownload);max=myPendingMax;min=myPendingMin;myPending=false;myBusy=true;}
  std::vector<Barcode>r;std::string w;auto t=std::chrono::steady_clock::now();analyze(d,max,min,r,w);myMs=std::chrono::duration<float,std::milli>(std::chrono::steady_clock::now()-t).count();myAnalyze++;{std::lock_guard<std::mutex>l(myMutex);myRows=std::move(r);myWarning=std::move(w);myBusy=false;}}}
 static void analyze(OP_SmartRef<OP_TOPDownloadResult>&d,int max,float min,std::vector<Barcode>&rows,std::string&warning){if(!d)return;void*data=d->getData();uint32_t w=d->textureDesc.width,h=d->textureDesc.height;if(!data||!w||!h)return;
  @autoreleasepool{CVPixelBufferRef p=nullptr;CVPixelBufferCreateWithBytes(nullptr,w,h,kCVPixelFormatType_32BGRA,data,(size_t)w*4,nullptr,nullptr,nullptr,&p);if(!p)return;
   VNDetectBarcodesRequest*r=[VNDetectBarcodesRequest new];VNImageRequestHandler*handler=[[VNImageRequestHandler alloc]initWithCVPixelBuffer:p options:@{}];NSError*e=nil;
   if([handler performRequests:@[r] error:&e])for(VNBarcodeObservation*o in r.results){if((int)rows.size()>=max)break;if(o.confidence<min)continue;Barcode b;b.symbology=o.symbology.UTF8String?:"";b.payload=o.payloadStringValue.UTF8String?:"";b.confidence=o.confidence;CGRect q=o.boundingBox;b.bbox[0]=q.origin.x+q.size.width*.5;b.bbox[1]=q.origin.y+q.size.height*.5;b.bbox[2]=q.size.width;b.bbox[3]=q.size.height;CGPoint cs[]={o.topLeft,o.topRight,o.bottomRight,o.bottomLeft};for(int i=0;i<4;i++){b.corners[i*2]=cs[i].x;b.corners[i*2+1]=cs[i].y;}rows.push_back(std::move(b));}
   else if(e)warning=e.localizedDescription.UTF8String?:"Barcode detection failed";CVPixelBufferRelease(p);}
  std::stable_sort(rows.begin(),rows.end(),[](const Barcode&a,const Barcode&b){return a.bbox[0]<b.bbox[0];});}
 std::thread myThread;std::condition_variable myCond;std::mutex myMutex;bool myQuit=false,myPending=false,myBusy=false;OP_SmartRef<OP_TOPDownloadResult>myDownload;int myPendingMax=10;float myPendingMin=0;int64_t myLast=-1;std::string mySig,myWarning;std::vector<Barcode>myRows;std::atomic<uint64_t>myExec{0},mySubmit{0},myAnalyze{0};std::atomic<float>myMs{0};std::atomic<int>myCount{0};
};}
extern "C"{DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo*i){if(!i->setAPIVersion(DATCPlusPlusAPIVersion))return;i->customOPInfo.opType->setString("Visionbarcode");i->customOPInfo.opLabel->setString("Vision Barcode");i->customOPInfo.opIcon->setString("VBC");if(i->customOPInfo.opHelpURL)i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/VisionBarcode/README.md");i->customOPInfo.authorName->setString("SYGNAL Inc.");
i->customOPInfo.majorVersion = 0;
i->customOPInfo.minorVersion = 9;i->customOPInfo.minInputs=0;i->customOPInfo.maxInputs=0;}DLLEXPORT DAT_CPlusPlusBase*CreateDATInstance(const OP_NodeInfo*i){return new VisionBarcodeDAT(i);}DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase*i){delete static_cast<VisionBarcodeDAT*>(i);}}
