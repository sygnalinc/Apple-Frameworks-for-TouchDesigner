// SoundFeatures CHOP — Accelerate/vDSPによるリアルタイム音響特徴量。
#import <Accelerate/Accelerate.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;
namespace {
constexpr int kBands=16,kFeatures=13+kBands;
const char*kNames[kFeatures]={"rms","peak","db","zcr","centroid","rolloff","flux","onset","beat","bpm","bass","mid","high","band0","band1","band2","band3","band4","band5","band6","band7","band8","band9","band10","band11","band12","band13","band14","band15"};
struct Result{float v[kFeatures]={};};
class SoundFeaturesCHOP final:public CHOP_CPlusPlusBase{
public:
 SoundFeaturesCHOP(const OP_NodeInfo*){myThread=std::thread([this]{worker();});}
 ~SoundFeaturesCHOP()override{{std::lock_guard<std::mutex>l(myMutex);myQuit=true;}myCond.notify_all();if(myThread.joinable())myThread.join();}
 void getGeneralInfo(CHOP_GeneralInfo*g,const OP_Inputs*,void*)override{g->cookEveryFrameIfAsked=true;g->timeslice=false;}
 bool getOutputInfo(CHOP_OutputInfo*i,const OP_Inputs*,void*)override{i->numChannels=kFeatures;i->numSamples=1;i->startIndex=0;return true;}
 void getChannelName(int32_t i,OP_String*n,const OP_Inputs*,void*)override{n->setString(kNames[i]);}
 void execute(CHOP_Output*out,const OP_Inputs*in,void*)override{myExec++;bool active=in->getParInt("Active")!=0;int size=1<<std::clamp(in->getParInt("Fftsize"),8,15);float threshold=std::max(0.f,(float)in->getParDouble("Onsetthreshold"));const OP_CHOPInput*a=in->getInputCHOP(0);if(active&&a&&a->numChannels&&a->numSamples){std::lock_guard<std::mutex>l(myMutex);myFftSize=size;myThreshold=threshold;mySampleRate=a->sampleRate;const float*src=a->getChannelData(0);myAudio.insert(myAudio.end(),src,src+a->numSamples);size_t cap=(size_t)size*4;if(myAudio.size()>cap)myAudio.erase(myAudio.begin(),myAudio.end()-cap);if(myAudio.size()>=(size_t)size&&!myPending){myPending=true;myCond.notify_one();}}Result r;{std::lock_guard<std::mutex>l(myMutex);r=myResult;}for(int i=0;i<kFeatures;i++)out->channels[i][0]=active?r.v[i]:0;}
 void setupParameters(OP_ParameterManager*m,void*)override{OP_NumericParameter a("Active");a.label="Active";a.page="Sound Features";a.defaultValues[0]=1;m->appendToggle(a);OP_NumericParameter f("Fftsize");f.label="FFT Size (Power of 2)";f.page="Sound Features";f.defaultValues[0]=11;f.minSliders[0]=8;f.maxSliders[0]=13;f.minValues[0]=8;f.maxValues[0]=15;f.clampMins[0]=f.clampMaxes[0]=true;m->appendInt(f);OP_NumericParameter t("Onsetthreshold");t.label="Onset Threshold";t.page="Sound Features";t.defaultValues[0]=0.12;t.minSliders[0]=0;t.maxSliders[0]=1;t.minValues[0]=0;t.clampMins[0]=true;m->appendFloat(t);}
 int32_t getNumInfoCHOPChans(void*)override{return 5;}void getInfoCHOPChan(int32_t i,OP_InfoCHOPChan*c,void*)override{const char*n[]={"executes","analyzes","analyze_ms","samplerate","fft_size"};float v[]={(float)myExec.load(),(float)myAnalyze.load(),myMs.load(),(float)mySampleRate.load(),(float)myFftSize.load()};c->name->setString(n[i]);c->value=v[i];}
private:
 void worker(){while(true){std::vector<float>x;int n;float sr,threshold;{std::unique_lock<std::mutex>l(myMutex);myCond.wait(l,[this]{return myQuit||myPending;});if(myQuit)return;n=myFftSize;sr=mySampleRate;threshold=myThreshold;if(myAudio.size()<(size_t)n){myPending=false;continue;}x.assign(myAudio.end()-n,myAudio.end());myPending=false;}auto t=std::chrono::steady_clock::now();Result r;analyze(x,sr,threshold,r);myMs=std::chrono::duration<float,std::milli>(std::chrono::steady_clock::now()-t).count();myAnalyze++;{std::lock_guard<std::mutex>l(myMutex);myResult=r;}}
 }
 void analyze(std::vector<float>&x,float sr,float threshold,Result&r){int n=(int)x.size(),half=n/2;vDSP_rmsqv(x.data(),1,&r.v[0],n);vDSP_maxmgv(x.data(),1,&r.v[1],n);r.v[2]=20.f*log10f(std::max(r.v[0],1e-8f));int crosses=0;for(int i=1;i<n;i++)if((x[i-1]>=0)!=(x[i]>=0))crosses++;r.v[3]=(float)crosses/(n-1);
  std::vector<float>w(n);vDSP_hann_window(w.data(),n,vDSP_HANN_NORM);vDSP_vmul(x.data(),1,w.data(),1,x.data(),1,n);std::vector<float>real(half),imag(half),mag(half);DSPSplitComplex z{real.data(),imag.data()};vDSP_ctoz((DSPComplex*)x.data(),2,&z,1,half);vDSP_Length log2n=(vDSP_Length)lrint(log2(n));FFTSetup setup=vDSP_create_fftsetup(log2n,kFFTRadix2);vDSP_fft_zrip(setup,&z,1,log2n,kFFTDirection_Forward);vDSP_zvmags(&z,1,mag.data(),1,half);vDSP_destroy_fftsetup(setup);for(float&v:mag)v=sqrtf(std::max(0.f,v))/n;
  double sum=0,weighted=0;for(int i=1;i<half;i++){sum+=mag[i];weighted+=mag[i]*(i*sr/n);}r.v[4]=sum>0?weighted/sum:0;double acc=0;for(int i=1;i<half;i++){acc+=mag[i];if(acc>=sum*.85){r.v[5]=i*sr/n;break;}}
  if(myPrevMag.size()!=mag.size())myPrevMag.assign(mag.size(),0);double flux=0;for(int i=1;i<half;i++)flux+=std::max(0.f,mag[i]-myPrevMag[i]);r.v[6]=(float)(flux/std::max(1,half-1));myPrevMag=mag;bool onset=r.v[6]>threshold&&r.v[0]>.003f;r.v[7]=onset?1:0;auto now=std::chrono::steady_clock::now();r.v[8]=0;if(onset&&(!myHaveOnset||std::chrono::duration<double>(now-myLastOnset).count()>.18)){if(myHaveOnset){double dt=std::chrono::duration<double>(now-myLastOnset).count();if(dt<2){float bpm=60.f/dt;while(bpm<60)bpm*=2;while(bpm>200)bpm*=.5f;myBpm=myBpm==0?bpm:myBpm*.8f+bpm*.2f;r.v[8]=1;}}myLastOnset=now;myHaveOnset=true;}r.v[9]=myBpm;
  auto energy=[&](float lo,float hi){int a=std::clamp((int)(lo*n/sr),1,half-1),b=std::clamp((int)(hi*n/sr),a+1,half);double s=0;for(int i=a;i<b;i++)s+=mag[i];return(float)(s/(b-a));};r.v[10]=energy(20,250);r.v[11]=energy(250,4000);r.v[12]=energy(4000,std::min(20000.f,sr*.5f));float minF=20,maxF=std::min(20000.f,sr*.5f);for(int b=0;b<kBands;b++){float lo=minF*powf(maxF/minF,(float)b/kBands),hi=minF*powf(maxF/minF,(float)(b+1)/kBands);r.v[13+b]=energy(lo,hi);}}
 std::thread myThread;std::condition_variable myCond;std::mutex myMutex;bool myQuit=false,myPending=false;std::vector<float>myAudio,myPrevMag;Result myResult;std::atomic<int>myFftSize{2048};float myThreshold=.12f;std::atomic<float>mySampleRate{0},myMs{0};std::atomic<uint64_t>myExec{0},myAnalyze{0};bool myHaveOnset=false;float myBpm=0;std::chrono::steady_clock::time_point myLastOnset;
};}
extern "C"{DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo*i){if(!i->setAPIVersion(CHOPCPlusPlusAPIVersion))return;i->customOPInfo.opType->setString("Soundfeatures");i->customOPInfo.opLabel->setString("Sound Features");i->customOPInfo.opIcon->setString("SFT");i->customOPInfo.authorName->setString("SYGNAL Inc.");i->customOPInfo.minInputs=1;i->customOPInfo.maxInputs=1;}DLLEXPORT CHOP_CPlusPlusBase*CreateCHOPInstance(const OP_NodeInfo*i){return new SoundFeaturesCHOP(i);}DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase*i){delete static_cast<SoundFeaturesCHOP*>(i);}}
