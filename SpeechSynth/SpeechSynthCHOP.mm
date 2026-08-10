#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include <algorithm>
#include <atomic>
#include <mutex>
#include <memory>
#include <string>
#include <vector>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;
namespace {class SpeechSynthCHOP final:public CHOP_CPlusPlusBase{
public:SpeechSynthCHOP(const OP_NodeInfo*){mySynth=[AVSpeechSynthesizer new];}~SpeechSynthCHOP()override{myAlive->store(false);[mySynth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];mySynth=nil;}
 void getGeneralInfo(CHOP_GeneralInfo*g,const OP_Inputs*,void*)override{g->cookEveryFrameIfAsked=true;g->timeslice=true;}bool getOutputInfo(CHOP_OutputInfo*i,const OP_Inputs*in,void*)override{myBlock=std::clamp(in->getParInt("Blocksamples"),64,8192);i->numChannels=2;i->numSamples=myBlock;i->startIndex=0;i->sampleRate=myRate.load();return true;}void getChannelName(int32_t i,OP_String*n,const OP_Inputs*,void*)override{n->setString(i?"right":"left");}
 // Voice プルダウン。AVSpeechSynthesisVoice.speechVoices() から実行時に組む
 // (端末にどの音声が入っているかは環境依存。この Mac では 180音声 / 49言語)。
 // ラベルに言語を出しているので **別途 Locale パラメータは要らない** —
 // 識別子が言語を内包している(com.apple.voice.compact.ja-JP.Kyoko は日本語)。
 // 文字列パラメータなので、一覧に無い識別子を直接打ち込むこともできる。
 void buildDynamicMenu(const OP_Inputs*,OP_BuildDynamicMenuInfo*info,void*)override{
  if(strcmp(info->name,"Voice")!=0)return;
  if(myVoiceIds.empty()){
   myVoiceIds.push_back("default");myVoiceLabels.push_back("System Default");
   NSArray<AVSpeechSynthesisVoice*>*vs=[AVSpeechSynthesisVoice speechVoices];
   NSArray<AVSpeechSynthesisVoice*>*sorted=[vs sortedArrayUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice*a,AVSpeechSynthesisVoice*b){
    NSComparisonResult r=[a.language compare:b.language];return r!=NSOrderedSame?r:[a.name compare:b.name];}];
   for(AVSpeechSynthesisVoice*v in sorted){
    const char*q=v.quality==AVSpeechSynthesisVoiceQualityPremium?"Premium":
                 v.quality==AVSpeechSynthesisVoiceQualityEnhanced?"Enhanced":"Default";
    myVoiceIds.push_back(v.identifier.UTF8String);
    myVoiceLabels.push_back(std::string(v.language.UTF8String)+"  "+v.name.UTF8String+"  ("+q+")");}}
  for(size_t i=0;i<myVoiceIds.size();i++)info->addMenuEntry(myVoiceIds[i].c_str(),myVoiceLabels[i].c_str());}
 void execute(CHOP_Output*out,const OP_Inputs*in,void*)override{myExec++;bool active=in->getParInt("Active")!=0,autotrigger=in->getParInt("Autotrigger")!=0;std::string text=in->getParString("Text")?:"";bool pulse=myPulse.load();if(active&&!text.empty()&&(pulse||(autotrigger&&text!=myLastText))){myLastText=text;mySpokenText.clear();speak(in,text);}std::lock_guard<std::mutex>l(myMutex);for(int s=0;s<out->numSamples;s++){float v=myRead<myAudio.size()?myAudio[myRead++]:0;out->channels[0][s]=active?v:0;out->channels[1][s]=active?v:0;}if(myRead>=myAudio.size()&&!mySpeaking)myAudio.clear();}
 void setupParameters(OP_ParameterManager*m,void*)override{addToggle(m,"Active","Active",1);OP_StringParameter t("Text");t.label="Text";t.page="Speech Synth";t.defaultValue="Hello from TouchDesigner";m->appendString(t);OP_StringParameter v("Voice");v.label="Voice";v.page="Speech Synth";v.defaultValue="default";m->appendDynamicStringMenu(v);addFloat(m,"Rate","Rate",.5,.01,1);addFloat(m,"Pitch","Pitch",1,.5,2);addFloat(m,"Volume","Volume",1,0,1);addInt(m,"Blocksamples","Block Samples",1024,64,8192);addToggle(m,"Autotrigger","Speak When Text Changes",0);OP_NumericParameter p("Speak");p.label="Speak";p.page="Speech Synth";m->appendPulse(p);OP_NumericParameter stop("Stop");stop.label="Stop";stop.page="Speech Synth";m->appendPulse(stop);}
 void pulsePressed(const char*n,void*)override{if(!strcmp(n,"Stop")){[mySynth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];std::lock_guard<std::mutex>l(myMutex);myAudio.clear();myRead=0;mySpeaking=false;}else if(!strcmp(n,"Speak"))myPulse=true;}
 int32_t getNumInfoCHOPChans(void*)override{return 6;}void getInfoCHOPChan(int32_t i,OP_InfoCHOPChan*c,void*)override{const char*n[]={"executes","utterances","buffers","speaking","queued_samples","sample_rate"};size_t q;{std::lock_guard<std::mutex>l(myMutex);q=myAudio.size()>myRead?myAudio.size()-myRead:0;}float v[]={(float)myExec.load(),(float)myUtterances.load(),(float)myBuffers.load(),mySpeaking?1.f:0.f,(float)q,myRate.load()};c->name->setString(n[i]);c->value=v[i];}bool getInfoDATSize(OP_InfoDATSize*i,void*)override{i->rows=1;i->cols=2;i->byColumn=false;return true;}void getInfoDATEntries(int32_t,int32_t,OP_InfoDATEntries*e,void*)override{e->values[0]->setString("status");e->values[1]->setString(myStatus.c_str());}
private:static void addToggle(OP_ParameterManager*m,const char*n,const char*l,int d){OP_NumericParameter p(n);p.label=l;p.page="Speech Synth";p.defaultValues[0]=d;m->appendToggle(p);}static void addInt(OP_ParameterManager*m,const char*n,const char*l,int d,int lo,int hi){OP_NumericParameter p(n);p.label=l;p.page="Speech Synth";p.defaultValues[0]=d;p.minSliders[0]=lo;p.maxSliders[0]=hi;p.minValues[0]=lo;p.maxValues[0]=hi;p.clampMins[0]=p.clampMaxes[0]=true;m->appendInt(p);}static void addFloat(OP_ParameterManager*m,const char*n,const char*l,double d,double lo,double hi){OP_NumericParameter p(n);p.label=l;p.page="Speech Synth";p.defaultValues[0]=d;p.minSliders[0]=lo;p.maxSliders[0]=hi;p.minValues[0]=lo;p.maxValues[0]=hi;p.clampMins[0]=p.clampMaxes[0]=true;m->appendFloat(p);}
 void speak(const OP_Inputs*in,const std::string&text){if(!myPulse.exchange(false)&&text==mySpokenText)return;mySpokenText=text;AVSpeechUtterance*u=[AVSpeechUtterance speechUtteranceWithString:[NSString stringWithUTF8String:text.c_str()]];const char*voice=in->getParString("Voice");if(voice&&*voice&&strcmp(voice,"default")!=0){AVSpeechSynthesisVoice*v=[AVSpeechSynthesisVoice voiceWithIdentifier:[NSString stringWithUTF8String:voice]];if(v)u.voice=v;}u.rate=std::clamp((float)in->getParDouble("Rate"),.01f,1.f);u.pitchMultiplier=std::clamp((float)in->getParDouble("Pitch"),.5f,2.f);u.volume=std::clamp((float)in->getParDouble("Volume"),0.f,1.f);{std::lock_guard<std::mutex>l(myMutex);myAudio.clear();myRead=0;}mySpeaking=true;myStatus="synthesizing";myUtterances++;__block SpeechSynthCHOP*self=this;auto alive=myAlive;[mySynth writeUtterance:u toBufferCallback:^(AVAudioBuffer*b){if(!alive->load())return;AVAudioPCMBuffer*p=[b isKindOfClass:[AVAudioPCMBuffer class]]?(AVAudioPCMBuffer*)b:nil;if(!p||p.frameLength==0){self->mySpeaking=false;self->myStatus="ready";return;}AVAudioFormat*f=p.format;self->myRate=f.sampleRate;AVAudioFrameCount count=p.frameLength;std::lock_guard<std::mutex>l(self->myMutex);if(p.floatChannelData){float*src=p.floatChannelData[0];self->myAudio.insert(self->myAudio.end(),src,src+count);}else if(p.int16ChannelData){int16_t*src=p.int16ChannelData[0];for(AVAudioFrameCount i=0;i<count;i++)self->myAudio.push_back(src[i]/32768.f);}self->myBuffers++;}];}
 std::vector<std::string> myVoiceIds,myVoiceLabels;
 AVSpeechSynthesizer*mySynth=nil;std::shared_ptr<std::atomic<bool>>myAlive=std::make_shared<std::atomic<bool>>(true);std::mutex myMutex;std::vector<float>myAudio;size_t myRead=0;int myBlock=1024;std::string myLastText,mySpokenText,myStatus="idle";std::atomic<bool>myPulse{false},mySpeaking{false};std::atomic<float>myRate{22050};std::atomic<uint64_t>myExec{0},myUtterances{0},myBuffers{0};};}
extern "C"{DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo*i){if(!i->setAPIVersion(CHOPCPlusPlusAPIVersion))return;i->customOPInfo.opType->setString("Speechsynth");i->customOPInfo.opLabel->setString("Speech Synth");i->customOPInfo.opIcon->setString("SYN");if(i->customOPInfo.opHelpURL)i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/SpeechSynth/README.md");i->customOPInfo.authorName->setString("SYGNAL Inc.");
i->customOPInfo.majorVersion = 0;
i->customOPInfo.minorVersion = 9;i->customOPInfo.minInputs=0;i->customOPInfo.maxInputs=0;}DLLEXPORT CHOP_CPlusPlusBase*CreateCHOPInstance(const OP_NodeInfo*i){return new SpeechSynthCHOP(i);}DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase*i){delete static_cast<SpeechSynthCHOP*>(i);}}
