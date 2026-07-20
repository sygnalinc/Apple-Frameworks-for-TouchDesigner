// CreateML Motion DAT — 録画した時系列CHOP系列(VisionPose 等のチャンネル + label列 + recording列)の
// CSV から、動き/ジェスチャ分類モデルを CreateML(MLActivityClassifier)でオンデバイス学習し
// .mlmodel を書き出す。出力モデルは CoreML Motion CHOP でライブ推論する。
#import <Foundation/Foundation.h>
#include <string>
#include <atomic>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void* cma_create(void); void cma_destroy(void*);
    void  cma_train(void*, const char* csv, const char* out, const char* features, const char* label, const char* rec, int window, int maxIter);
    void  cma_cancel(void*);
    const char* cma_status(void*);
}

namespace {
class CreateMLMotionDAT final : public DAT_CPlusPlusBase {
public:
    CreateMLMotionDAT(const OP_NodeInfo*) { myState = cma_create(); }
    ~CreateMLMotionDAT() override { if (myState) cma_destroy(myState); }

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; }

    void execute(DAT_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        if (!myState) return;
        if (myTrainReq.exchange(false)) {
            std::string csv = in->getParFilePath("Trainingcsv") ? in->getParFilePath("Trainingcsv") : "";
            std::string model = in->getParFilePath("Outputmodel") ? in->getParFilePath("Outputmodel") : "";
            std::string feats = in->getParString("Featurecolumns") ? in->getParString("Featurecolumns") : "";
            std::string label = in->getParString("Labelcolumn") ? in->getParString("Labelcolumn") : "label";
            std::string rec = in->getParString("Recordingcolumn") ? in->getParString("Recordingcolumn") : "recording";
            int window = (int)in->getParInt("Predictionwindow");
            int maxIter = (int)in->getParInt("Maxiterations");
            if (!csv.empty() && !model.empty()) { cma_train(myState, csv.c_str(), model.c_str(), feats.c_str(), label.c_str(), rec.c_str(), window, maxIter); myTrains++; }
        }
        if (myCancelReq.exchange(false)) cma_cancel(myState);

        const char* j = cma_status(myState); std::string js = j ? j : "{}"; if (j) free((void*)j);
        parse(js);

        out->setOutputDataType(DAT_OutDataType::Table);
        out->setTableSize(7, 2);
        const char* keys[] = {"status","progress","train_accuracy","validation_accuracy","features","model","error"};
        char b[64];
        for (int i=0;i<7;i++) out->setCellString(i,0,keys[i]);
        out->setCellString(0,1,myStatus.c_str());
        snprintf(b,sizeof b,"%.3f",myProgress); out->setCellString(1,1,b);
        snprintf(b,sizeof b,"%.4f",myTrainAcc); out->setCellString(2,1,b);
        snprintf(b,sizeof b,"%.4f",myValAcc); out->setCellString(3,1,b);
        out->setCellString(4,1,myFeatures.c_str());
        out->setCellString(5,1,myModel.c_str());
        out->setCellString(6,1,myError.c_str());
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "CreateML Motion";
        { OP_StringParameter p("Trainingcsv"); p.label="Training CSV (recorded CHOP sequences)"; p.page=PAGE; m->appendFile(p); }
        { OP_StringParameter p("Outputmodel"); p.label="Output Model (.mlmodel)"; p.page=PAGE; p.defaultValue="motion.mlmodel"; m->appendFile(p); }
        { OP_StringParameter p("Featurecolumns"); p.label="Feature Columns (comma, empty=auto)"; p.page=PAGE; m->appendString(p); }
        { OP_StringParameter p("Labelcolumn"); p.label="Label Column"; p.page=PAGE; p.defaultValue="label"; m->appendString(p); }
        { OP_StringParameter p("Recordingcolumn"); p.label="Recording ID Column"; p.page=PAGE; p.defaultValue="recording"; m->appendString(p); }
        { OP_NumericParameter p("Predictionwindow"); p.label="Prediction Window (frames)"; p.page=PAGE; p.defaultValues[0]=30; p.minSliders[0]=5; p.maxSliders[0]=150; p.minValues[0]=2; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Maxiterations"); p.label="Max Iterations"; p.page=PAGE; p.defaultValues[0]=25; p.minSliders[0]=1; p.maxSliders[0]=200; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Train"); p.label="Train"; p.page=PAGE; m->appendPulse(p); }
        { OP_NumericParameter p("Cancel"); p.label="Cancel"; p.page=PAGE; m->appendPulse(p); }
    }

    void pulsePressed(const char* name, void*) override {
        if (strcmp(name,"Train")==0) myTrainReq = true;
        else if (strcmp(name,"Cancel")==0) myCancelReq = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        int training = (myStatus=="training")?1:0, done=(myStatus=="done")?1:0;
        const char* n[] = {"executes","progress","train_accuracy","validation_accuracy","training","done"};
        float v[] = {(float)myExec.load(),(float)myProgress,(float)myTrainAcc,(float)myValAcc,(float)training,(float)done};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if (myStatus=="error" && !myError.empty()) s->setString(("CreateML: "+myError).c_str()); }

private:
    void parse(const std::string& js) {
        @autoreleasepool {
            NSData* d = [NSData dataWithBytes:js.data() length:js.size()];
            NSDictionary* m = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if (![m isKindOfClass:[NSDictionary class]]) return;
            myStatus = m[@"status"] ? [[m[@"status"] description] UTF8String] : "";
            myProgress = [m[@"progress"] doubleValue];
            myTrainAcc = [m[@"train_acc"] doubleValue];
            myValAcc = [m[@"val_acc"] doubleValue];
            myModel = m[@"model"] ? [[m[@"model"] description] UTF8String] : "";
            myError = m[@"error"] ? [[m[@"error"] description] UTF8String] : "";
            NSArray* fs = m[@"features"]; myFeatures.clear();
            if ([fs isKindOfClass:[NSArray class]]) { int n=0; for (NSString* c in fs) { if (n++) myFeatures+=", "; myFeatures += [[c description] UTF8String]; } }
        }
    }
    void* myState = nullptr;
    std::string myStatus, myFeatures, myModel, myError; double myProgress=0, myTrainAcc=0, myValAcc=0;
    std::atomic<bool> myTrainReq{false}, myCancelReq{false};
    std::atomic<uint64_t> myExec{0}, myTrains{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i) {
    if (!i->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Createmlmotion");
    i->customOPInfo.opLabel->setString("CreateML Motion");
    i->customOPInfo.opIcon->setString("CMM");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i) { return new CreateMLMotionDAT(i); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i) { delete static_cast<CreateMLMotionDAT*>(i); }
}
