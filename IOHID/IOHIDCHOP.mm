// HID CHOP — IOHIDManager で任意のUSB/Bluetooth HIDデバイス(ゲームパッド/ペダル/ノブ/センサ等)の
// raw入力を読み、各要素(usage)の値をCHOPチャンネルとして出力する。バックグラウンドスレッドの
// run loop で値変化コールバックを受け、cook は最新値をスナップショットして出力する(非ブロック)。
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#include <string>
#include <vector>
#include <map>
#include <atomic>
#include <mutex>
#include <thread>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
static const int kMax = 256;
struct Elem { uint32_t cookie, page, usage; std::atomic<double> value{0}; };

class IOHIDCHOP final : public CHOP_CPlusPlusBase {
public:
    IOHIDCHOP(const OP_NodeInfo*) {}
    ~IOHIDCHOP() override { stop(); }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; g->timeslice=false; }
    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* in, void*) override {
        ensure(in);
        std::lock_guard<std::mutex> l(myMutex);
        int n=(int)myElems.size();
        info->numChannels = n>0?n:1; info->numSamples=1; info->sampleRate=60; return true;
    }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override {
        std::lock_guard<std::mutex> l(myMutex);
        if (i<(int)myElems.size()){ char b[48]; snprintf(b,sizeof b,"p%u_u%u_c%u",myElems[i]->page,myElems[i]->usage,myElems[i]->cookie); name->setString(b); }
        else name->setString("connected");
    }
    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        ensure(in);
        std::lock_guard<std::mutex> l(myMutex);
        int n=(int)myElems.size();
        if (n==0){ if(out->numChannels>0) out->channels[0][0]=(float)(myOpen?1:0); return; }
        for (int i=0;i<n && i<out->numChannels;i++) out->channels[i][0]=(float)myElems[i]->value.load();
    }
    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="IOHID";
        { OP_NumericParameter p("Active"); p.label="Active"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Usagepage"); p.label="Usage Page (0=any)"; p.page=P; p.defaultValues[0]=0; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Usage"); p.label="Usage (0=any)"; p.page=P; p.defaultValues[0]=0; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Vendorid"); p.label="Vendor ID (0=any)"; p.page=P; p.defaultValues[0]=0; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Productid"); p.label="Product ID (0=any)"; p.page=P; p.defaultValues[0]=0; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
    }
    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","elements","open"}; float v[]={(float)myExec.load(),(float)myElemCount.load(),(float)(myOpen?1:0)};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(myOpen && myElemCount.load()==0) s->setString("HID manager open but no matching device/elements. Check Usage Page/Usage or grant Input Monitoring permission."); }

private:
    void ensure(const OP_Inputs* in) {
        bool active=in->getParInt("Active")!=0;
        int up=(int)in->getParInt("Usagepage"), us=(int)in->getParInt("Usage"), vid=(int)in->getParInt("Vendorid"), pid=(int)in->getParInt("Productid");
        std::string sig=std::to_string(active)+"|"+std::to_string(up)+"|"+std::to_string(us)+"|"+std::to_string(vid)+"|"+std::to_string(pid);
        if (sig==mySig) return; mySig=sig;
        stop();
        if (active) start(up,us,vid,pid);
    }
    static void valueCB(void* ctx, IOReturn, void*, IOHIDValueRef v) {
        IOHIDCHOP* self=(IOHIDCHOP*)ctx;
        IOHIDElementRef e=IOHIDValueGetElement(v); if(!e) return;
        uint32_t cookie=(uint32_t)IOHIDElementGetCookie(e);
        CFIndex iv=IOHIDValueGetIntegerValue(v);
        std::lock_guard<std::mutex> l(self->myMutex);
        auto it=self->myByCookie.find(cookie);
        if (it!=self->myByCookie.end()) it->second->value.store((double)iv);
    }
    void start(int up, int us, int vid, int pid) {
        myMgr=IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        NSMutableDictionary* match=[NSMutableDictionary dictionary];
        if (up>0) match[@kIOHIDDeviceUsagePageKey]=@(up);
        if (us>0) match[@kIOHIDDeviceUsageKey]=@(us);
        if (vid>0) match[@kIOHIDVendorIDKey]=@(vid);
        if (pid>0) match[@kIOHIDProductIDKey]=@(pid);
        IOHIDManagerSetDeviceMatching(myMgr, match.count?(__bridge CFDictionaryRef)match:NULL);
        IOReturn r=IOHIDManagerOpen(myMgr, kIOHIDOptionsTypeNone);
        myOpen=(r==kIOReturnSuccess);
        if (!myOpen) return;
        // マッチしたデバイスの要素を列挙してチャンネル確定
        CFSetRef devs=IOHIDManagerCopyDevices(myMgr);
        if (devs) {
            CFIndex nd=CFSetGetCount(devs);
            std::vector<const void*> arr(nd); CFSetGetValues(devs, arr.data());
            std::lock_guard<std::mutex> l(myMutex);
            for (CFIndex d=0; d<nd; d++) {
                IOHIDDeviceRef dev=(IOHIDDeviceRef)arr[d];
                CFArrayRef els=IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
                if (!els) continue;
                CFIndex ne=CFArrayGetCount(els);
                for (CFIndex k=0; k<ne && (int)myElems.size()<kMax; k++) {
                    IOHIDElementRef e=(IOHIDElementRef)CFArrayGetValueAtIndex(els,k);
                    IOHIDElementType t=IOHIDElementGetType(e);
                    if (t==kIOHIDElementTypeInput_Misc||t==kIOHIDElementTypeInput_Button||t==kIOHIDElementTypeInput_Axis) {
                        auto el=std::make_shared<Elem>();
                        el->cookie=(uint32_t)IOHIDElementGetCookie(e); el->page=IOHIDElementGetUsagePage(e); el->usage=IOHIDElementGetUsage(e);
                        if (myByCookie.find(el->cookie)==myByCookie.end()) { myElems.push_back(el); myByCookie[el->cookie]=el; }
                    }
                }
                CFRelease(els);
            }
            CFRelease(devs);
            myElemCount.store((uint64_t)myElems.size());
        }
        IOHIDManagerRegisterInputValueCallback(myMgr, valueCB, this);
        // 専用スレッドのrun loopでコールバックを回す
        myRun=true;
        myThread=std::thread([this]{
            myLoop=CFRunLoopGetCurrent();
            IOHIDManagerScheduleWithRunLoop(myMgr, myLoop, kCFRunLoopDefaultMode);
            while (myRun) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true); }
            IOHIDManagerUnscheduleFromRunLoop(myMgr, myLoop, kCFRunLoopDefaultMode);
        });
    }
    void stop() {
        myRun=false; if (myLoop) CFRunLoopWakeUp(myLoop);
        if (myThread.joinable()) myThread.join();
        if (myMgr) { IOHIDManagerClose(myMgr, kIOHIDOptionsTypeNone); CFRelease(myMgr); myMgr=NULL; }
        std::lock_guard<std::mutex> l(myMutex); myElems.clear(); myByCookie.clear(); myElemCount.store(0); myOpen=false; myLoop=NULL;
    }
    IOHIDManagerRef myMgr=NULL; CFRunLoopRef myLoop=NULL; std::thread myThread; std::atomic<bool> myRun{false};
    std::mutex myMutex; std::vector<std::shared_ptr<Elem>> myElems; std::map<uint32_t,std::shared_ptr<Elem>> myByCookie;
    bool myOpen=false; std::string mySig; std::atomic<uint64_t> myExec{0}, myElemCount{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Iohid");
    i->customOPInfo.opLabel->setString("IOHID");
    i->customOPInfo.opIcon->setString("IOH");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new IOHIDCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<IOHIDCHOP*>(i); }
}
