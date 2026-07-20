#import <Foundation/Foundation.h>
#include <atomic>
#include <cstring>
#include <string>
#include <vector>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
void* gm_create();
bool gm_submit(void*, const char*, const char*, const char*, const char*, double, int32_t, bool);
bool gm_start_server(void*, const char*, const char*, int32_t, int32_t, int32_t);
void gm_stop_server(void*); void gm_cancel(void*); void gm_clear(void*);
int32_t gm_poll(void*, char*, int32_t); void gm_destroy(void*);
}

namespace {
struct Turn { std::string role, text; };
class GemmaDAT : public DAT_CPlusPlusBase {
public:
    explicit GemmaDAT(const OP_NodeInfo*) : session(gm_create()) {}
    ~GemmaDAT() override { if (session) gm_destroy(session); }
    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }
    void execute(DAT_Output* out, const OP_Inputs* in, void*) override {
        executes++;
        if (wantSubmit.exchange(false)) gm_submit(session, str(in,"Endpoint"), str(in,"Model"), str(in,"Instructions"), str(in,"Prompt"), in->getParDouble("Temperature"), in->getParInt("Maxtokens"), in->getParInt("Keepcontext") != 0);
        if (wantStart.exchange(false)) gm_start_server(session, str(in,"Serverbinary"), str(in,"Modelfile"), in->getParInt("Port"), in->getParInt("Context"), in->getParInt("Gpulayers"));
        if (wantStop.exchange(false)) gm_stop_server(session);
        if (wantCancel.exchange(false)) gm_cancel(session);
        if (wantClear.exchange(false)) gm_clear(session);
        poll();
        int maxRows = std::max(1, (int)in->getParInt("Maxrows")); int begin = std::max(0, (int)history.size()-maxRows);
        out->setOutputDataType(DAT_OutDataType::Table); out->setTableSize(1+(int)history.size()-begin,3);
        out->setCellString(0,0,"index"); out->setCellString(0,1,"role"); out->setCellString(0,2,"text");
        for (int i=begin,row=1;i<(int)history.size();++i,++row) { auto n=std::to_string(i); out->setCellString(row,0,n.c_str()); out->setCellString(row,1,history[i].role.c_str()); out->setCellString(row,2,history[i].text.c_str()); }
    }
    void setupParameters(OP_ParameterManager* m, void*) override {
        stringPar(m,"Instructions","Instructions (System)","Gemma",""); stringPar(m,"Prompt","Prompt","Gemma","");
        numPar(m,"Temperature","Temperature","Gemma",0.7,0,2,false); numPar(m,"Maxtokens","Max Tokens","Gemma",512,1,8192,true);
        toggle(m,"Keepcontext","Keep Context","Gemma",1); numPar(m,"Maxrows","Max Rows","Gemma",50,1,200,true);
        pulse(m,"Submit","Submit","Gemma"); pulse(m,"Cancel","Cancel","Gemma"); pulse(m,"Clear","Clear Conversation","Gemma");
        stringPar(m,"Endpoint","Endpoint","Server","http://127.0.0.1:8080/v1/chat/completions"); stringPar(m,"Model","API Model Name","Server","gemma-4");
        stringPar(m,"Serverbinary","llama-server Path","Server","/opt/homebrew/bin/llama-server"); stringPar(m,"Modelfile","GGUF Model Path","Server","");
        numPar(m,"Port","Port","Server",8080,1,65535,true); numPar(m,"Context","Context Size","Server",8192,512,32768,true); numPar(m,"Gpulayers","GPU Layers","Server",99,0,999,true);
        pulse(m,"Startserver","Start Local Server","Server"); pulse(m,"Stopserver","Stop Local Server","Server");
    }
    void pulsePressed(const char* n, void*) override { if(!strcmp(n,"Submit"))wantSubmit=true; else if(!strcmp(n,"Cancel"))wantCancel=true; else if(!strcmp(n,"Clear"))wantClear=true; else if(!strcmp(n,"Startserver"))wantStart=true; else if(!strcmp(n,"Stopserver"))wantStop=true; }
    int32_t getNumInfoCHOPChans(void*) override{return 4;}
    void getInfoCHOPChan(int32_t i,OP_InfoCHOPChan* c,void*) override { const char* n[]={"executes","busy","turns","server"}; float v[]={(float)executes.load(),(float)busy,(float)history.size(),(float)serverRunning}; c->name->setString(n[i]);c->value=v[i]; }
    bool getInfoDATSize(OP_InfoDATSize* s,void*) override{s->rows=1;s->cols=2;s->byColumn=false;return true;}
    void getInfoDATEntries(int32_t,int32_t,OP_InfoDATEntries* e,void*) override{e->values[0]->setString("status");e->values[1]->setString(status.c_str());}
private:
    static const char* str(const OP_Inputs* i,const char* n){const char* s=i->getParString(n);return s?s:"";}
    static void stringPar(OP_ParameterManager*m,const char*n,const char*l,const char*p,const char*d){OP_StringParameter x(n);x.label=l;x.page=p;x.defaultValue=d;m->appendString(x);}
    static void pulse(OP_ParameterManager*m,const char*n,const char*l,const char*p){OP_NumericParameter x(n);x.label=l;x.page=p;m->appendPulse(x);}
    static void toggle(OP_ParameterManager*m,const char*n,const char*l,const char*p,double d){OP_NumericParameter x(n);x.label=l;x.page=p;x.defaultValues[0]=d;m->appendToggle(x);}
    static void numPar(OP_ParameterManager*m,const char*n,const char*l,const char*p,double d,double lo,double hi,bool integer){OP_NumericParameter x(n);x.label=l;x.page=p;x.defaultValues[0]=d;x.minSliders[0]=lo;x.maxSliders[0]=hi;x.minValues[0]=lo;x.clampMins[0]=true;if(integer)m->appendInt(x);else m->appendFloat(x);}
    void poll(){ static thread_local std::vector<char>b(1048576);gm_poll(session,b.data(),(int32_t)b.size());@autoreleasepool{NSData*d=[NSData dataWithBytes:b.data() length:strlen(b.data())];NSDictionary*j=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];if(![j isKindOfClass:NSDictionary.class])return;NSString*s=j[@"status"];if([s isKindOfClass:NSString.class])status=s.UTF8String?:"";busy=[j[@"busy"] boolValue];serverRunning=[j[@"server"] boolValue];history.clear();for(NSDictionary*t in j[@"history"]){if(![t isKindOfClass:NSDictionary.class])continue;NSString*r=t[@"role"],*x=t[@"text"];history.push_back({r.UTF8String?:"",x.UTF8String?:""});}}}
    void* session=nullptr; std::vector<Turn>history; std::string status="idle"; int busy=0,serverRunning=0; std::atomic<int>executes{0}; std::atomic<bool>wantSubmit{false},wantStart{false},wantStop{false},wantCancel{false},wantClear{false};
};}
extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo*i){if(!i->setAPIVersion(DATCPlusPlusAPIVersion))return;i->customOPInfo.opType->setString("Gemma");i->customOPInfo.opLabel->setString("Gemma");i->customOPInfo.authorName->setString("sygnal");i->customOPInfo.opIcon->setString("GEM");i->customOPInfo.minInputs=0;i->customOPInfo.maxInputs=0;}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo*i){return new GemmaDAT(i);} DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase*i){delete(GemmaDAT*)i;}
}
