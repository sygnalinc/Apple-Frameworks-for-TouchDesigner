// CoreML Motion CHOP — CreateML Motion で学習した動作分類モデル(MLActivityClassifier)を
// 使い、入力CHOP(VisionPose 等のチャンネル)を予測窓ぶんバッファしてライブでジェスチャ分類する。
// 出力はクラスごとの確率 + confidence + predicted(argmax index)。recurrent state を毎回更新する。
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#include <string>
#include <vector>
#include <deque>
#include <atomic>
#include <unordered_map>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
class CoreMLMotionCHOP final : public CHOP_CPlusPlusBase {
public:
    CoreMLMotionCHOP(const OP_NodeInfo*) {}
    ~CoreMLMotionCHOP() override { @autoreleasepool { myModel = nil; } }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; g->timeslice = false; }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* in, void*) override {
        ensureModel(in);
        info->numChannels = (int)myClasses.size() + 3; // classes + confidence + predicted + buffered
        if (info->numChannels < 1) info->numChannels = 1;
        info->numSamples = 1; info->sampleRate = 60;
        return true;
    }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override {
        int nc = (int)myClasses.size();
        if (i < nc) { name->setString(("prob_" + myClasses[i]).c_str()); return; }
        const char* extra[] = {"confidence","predicted","buffered"};
        int k = i - nc; if (k >= 0 && k < 3) name->setString(extra[k]); else name->setString("chan");
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        for (int c = 0; c < out->numChannels; c++) out->channels[c][0] = 0;
        if (myResetReq.exchange(false)) { for (auto& kv : myBuf) kv.second.clear(); clearState(); }
        ensureModel(in);
        if (!myModel || myClasses.empty()) return;

        // 入力CHOPの現在サンプルを各特徴のリングバッファへ
        const OP_CHOPInput* ci = in->getInputCHOP(0);
        if (ci) {
            for (const std::string& fn : myFeatures) {
                float v = 0; bool found = false;
                for (int c = 0; c < ci->numChannels; c++) { if (fn == ci->getChannelName(c)) { v = ci->getChannelData(c)[ci->numSamples-1]; found = true; break; } }
                (void)found;
                auto& dq = myBuf[fn]; dq.push_back((double)v); while ((int)dq.size() > myWindow) dq.pop_front();
            }
        }
        int buffered = myFeatures.empty() ? 0 : (int)myBuf[myFeatures[0]].size();
        out->channels[(int)myClasses.size()+2][0] = (float)buffered;
        if (buffered < myWindow) return;

        // 予測
        @autoreleasepool {
            NSMutableDictionary* feats = [NSMutableDictionary dictionary];
            NSError* err = nil;
            for (const std::string& fn : myFeatures) {
                MLMultiArray* arr = [[MLMultiArray alloc] initWithShape:@[@(myWindow)] dataType:MLMultiArrayDataTypeDouble error:&err];
                double* p = (double*)arr.dataPointer; const auto& dq = myBuf[fn];
                for (int k = 0; k < myWindow; k++) p[k] = dq[k];
                feats[[NSString stringWithUTF8String:fn.c_str()]] = [MLFeatureValue featureValueWithMultiArray:arr];
            }
            if (!myStateName.empty()) {
                MLMultiArray* st = [[MLMultiArray alloc] initWithShape:@[@(myStateSize)] dataType:MLMultiArrayDataTypeDouble error:&err];
                double* sp = (double*)st.dataPointer; for (int k = 0; k < myStateSize; k++) sp[k] = myState[k];
                feats[[NSString stringWithUTF8String:myStateName.c_str()]] = [MLFeatureValue featureValueWithMultiArray:st];
            }
            MLDictionaryFeatureProvider* prov = [[MLDictionaryFeatureProvider alloc] initWithDictionary:feats error:&err];
            id<MLFeatureProvider> res = [myModel predictionFromFeatures:prov error:&err];
            if (!res) { myWarn = err ? err.localizedDescription.UTF8String : "prediction failed"; return; }
            // 確率
            MLFeatureValue* probV = [res featureValueForName:[NSString stringWithUTF8String:myProbName.c_str()]];
            NSDictionary* probs = probV ? probV.dictionaryValue : nil;
            int best = -1; float bestP = -1;
            for (int i = 0; i < (int)myClasses.size(); i++) {
                float p = 0; if (probs) { NSNumber* n = probs[[NSString stringWithUTF8String:myClasses[i].c_str()]]; if (n) p = n.floatValue; }
                out->channels[i][0] = p; if (p > bestP) { bestP = p; best = i; }
            }
            out->channels[(int)myClasses.size()+0][0] = bestP;
            out->channels[(int)myClasses.size()+1][0] = (float)best;
            // state 更新
            if (!myStateName.empty()) {
                MLFeatureValue* sv = [res featureValueForName:@"stateOut"];
                MLMultiArray* so = sv ? sv.multiArrayValue : nil;
                if (so) { double* sp = (double*)so.dataPointer; int n = MIN(myStateSize, (int)so.count); for (int k = 0; k < n; k++) myState[k] = sp[k]; }
            }
            myPreds++;
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "CoreML Motion";
        { OP_StringParameter p("Model"); p.label = "Model (.mlmodel from CreateML Motion)"; p.page = PAGE; m->appendFile(p); }
        { OP_NumericParameter p("Reset"); p.label = "Reset"; p.page = PAGE; m->appendPulse(p); }
    }
    void pulsePressed(const char* name, void*) override { if (strcmp(name,"Reset")==0) myResetReq = true; }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[] = {"executes","predictions","window","num_classes"};
        float v[] = {(float)myExec.load(),(float)myPreds.load(),(float)myWindow,(float)myClasses.size()};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override { if (!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    void clearState() { for (auto& v : myState) v = 0; }
    void ensureModel(const OP_Inputs* in) {
        std::string path = in->getParFilePath("Model") ? in->getParFilePath("Model") : "";
        if (path == myLoadedPath) return;
        myLoadedPath = path; myModel = nil; myClasses.clear(); myFeatures.clear(); myBuf.clear(); myStateName.clear(); myWarn.clear();
        if (path.empty()) return;
        @autoreleasepool {
            NSError* err = nil;
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
            NSURL* compiled = [MLModel compileModelAtURL:url error:&err];
            if (!compiled) { myWarn = err ? err.localizedDescription.UTF8String : "compile failed"; return; }
            MLModel* model = [MLModel modelWithContentsOfURL:compiled error:&err];
            if (!model) { myWarn = err ? err.localizedDescription.UTF8String : "load failed"; return; }
            myModel = model;
            MLModelDescription* d = model.modelDescription;
            // 特徴入力(MultiArray shape[N])と state 入力を分ける
            for (NSString* name in d.inputDescriptionsByName) {
                MLFeatureDescription* fd = d.inputDescriptionsByName[name];
                if (fd.type != MLFeatureTypeMultiArray) continue;
                std::string nm = name.UTF8String;
                int len = fd.multiArrayConstraint.shape.count > 0 ? fd.multiArrayConstraint.shape[0].intValue : 0;
                if ([name.lowercaseString containsString:@"state"]) { myStateName = nm; myStateSize = len; }
                else { myFeatures.push_back(nm); myWindow = len; }
            }
            myState.assign(myStateSize > 0 ? myStateSize : 0, 0.0);
            // クラスラベル
            for (id lbl in d.classLabels) myClasses.push_back([[lbl description] UTF8String]);
            myProbName = d.predictedProbabilitiesName ? d.predictedProbabilitiesName.UTF8String : "labelProbability";
        }
    }

    MLModel* myModel = nil;
    std::string myLoadedPath, myStateName, myProbName, myWarn;
    std::vector<std::string> myFeatures, myClasses;
    std::unordered_map<std::string, std::deque<double>> myBuf;
    std::vector<double> myState; int myWindow = 30, myStateSize = 0;
    std::atomic<bool> myResetReq{false};
    std::atomic<uint64_t> myExec{0}, myPreds{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Coremlmotion");
    i->customOPInfo.opLabel->setString("CoreML Motion");
    i->customOPInfo.opIcon->setString("CMO");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/CoreMLMotion/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 1; i->customOPInfo.maxInputs = 1;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new CoreMLMotionCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<CoreMLMotionCHOP*>(i); }
}
