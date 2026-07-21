// CreateML DAT — Apple の CreateML 各種学習タスクを1つのオペレータに統合する汎用トレーナ。
// Task メニューで Image / Hand Pose / Action(body) / Hand Action / Sound / Activity(CHOP時系列) /
// Tabular Classifier / Tabular Regressor を切り替え、オンデバイス学習して .mlmodel を書き出す。
// 出力モデルは既存の CoreML TOP / CoreML Motion CHOP / SoundClass 等がそのまま推論する。
// 学習は Swift ヘルパ(ml_)で非同期実行し、cook は進捗を poll するだけでブロックしない。
#import <Foundation/Foundation.h>
#include <string>
#include <atomic>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void* ml_create(void); void ml_destroy(void*);
    void  ml_train(void*, int task, const char* trainPath, const char* out, const char* features,
                   const char* label, const char* rec, const char* target, int maxIter, int window, int augMask);
    void  ml_cancel(void*);
    const char* ml_status(void*);
}

namespace {
// Task メニューの並び(ヘルパの task ID と一致)
enum { T_IMAGE=0, T_HANDPOSE, T_ACTION, T_HANDACTION, T_SOUND, T_ACTIVITY, T_TABCLS, T_TABREG };

class CreateMLDAT final : public DAT_CPlusPlusBase {
public:
    CreateMLDAT(const OP_NodeInfo*) { myState = ml_create(); }
    ~CreateMLDAT() override { if (myState) ml_destroy(myState); }

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; }

    void execute(DAT_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        if (!myState) return;
        if (myTrainReq.exchange(false)) {
            int task = taskIndex(in);
            std::string train = in->getParFilePath("Trainingpath") ? in->getParFilePath("Trainingpath") : "";
            std::string model = in->getParFilePath("Outputmodel") ? in->getParFilePath("Outputmodel") : "";
            std::string feats = in->getParString("Featurecolumns") ? in->getParString("Featurecolumns") : "";
            std::string label = in->getParString("Labelcolumn") ? in->getParString("Labelcolumn") : "label";
            std::string rec = in->getParString("Recordingcolumn") ? in->getParString("Recordingcolumn") : "recording";
            std::string target = in->getParString("Targetcolumn") ? in->getParString("Targetcolumn") : "target";
            int maxIter = (int)in->getParInt("Maxiterations");
            int window = (int)in->getParInt("Predictionwindow");
            int augMask = 0;
            if (in->getParInt("Augflip")) augMask |= 1;
            if (in->getParInt("Augcrop")) augMask |= 2;
            if (in->getParInt("Augrotation")) augMask |= 4;
            if (in->getParInt("Augblur")) augMask |= 8;
            if (in->getParInt("Augexposure")) augMask |= 16;
            if (in->getParInt("Augnoise")) augMask |= 32;
            if (!train.empty() && !model.empty())
                { ml_train(myState, task, train.c_str(), model.c_str(), feats.c_str(), label.c_str(), rec.c_str(), target.c_str(), maxIter, window, augMask); myTrains++; }
        }
        if (myCancelReq.exchange(false)) ml_cancel(myState);

        const char* j = ml_status(myState); std::string js = j ? j : "{}"; if (j) free((void*)j);
        parse(js);

        out->setOutputDataType(DAT_OutDataType::Table);
        const char* accKey = (myMetric == "rmse") ? "train_rmse" : "train_accuracy";
        const char* valKey = (myMetric == "rmse") ? "val_rmse" : "validation_accuracy";
        out->setTableSize(8, 2);
        const char* keys[] = {"status","progress",accKey,valKey,"classes","features","model","error"};
        char b[64];
        for (int i=0;i<8;i++) out->setCellString(i,0,keys[i]);
        out->setCellString(0,1,myStatus.c_str());
        snprintf(b,sizeof b,"%.3f",myProgress); out->setCellString(1,1,b);
        snprintf(b,sizeof b,"%.4f",myTrainAcc); out->setCellString(2,1,b);
        snprintf(b,sizeof b,"%.4f",myValAcc); out->setCellString(3,1,b);
        out->setCellString(4,1,myClasses.c_str());
        out->setCellString(5,1,myFeatures.c_str());
        out->setCellString(6,1,myModel.c_str());
        out->setCellString(7,1,myError.c_str());
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "CreateML";
        {
            OP_StringParameter p("Task"); p.label="Task"; p.page=PAGE; p.defaultValue="Image";
            const char* names[] = {"Image","Handpose","Action","Handaction","Sound","Activity","Tabularcls","Tabularreg"};
            const char* labels[] = {"Image Classifier","Hand Pose Classifier","Action Classifier (body)",
                                    "Hand Action Classifier","Sound Classifier","Activity Classifier (CHOP series)",
                                    "Tabular Classifier","Tabular Regressor"};
            m->appendMenu(p, 8, names, labels);
        }
        { OP_StringParameter p("Trainingpath"); p.label="Training Path (folder or CSV)"; p.page=PAGE; m->appendFolder(p); }
        { OP_StringParameter p("Outputmodel"); p.label="Output Model (.mlmodel)"; p.page=PAGE; p.defaultValue="model.mlmodel"; m->appendFile(p); }
        { OP_NumericParameter p("Train"); p.label="Train"; p.page=PAGE; m->appendPulse(p); }
        { OP_NumericParameter p("Cancel"); p.label="Cancel"; p.page=PAGE; m->appendPulse(p); }

        const char* DATA = "Data";
        { OP_StringParameter p("Labelcolumn"); p.label="Label Column (Activity)"; p.page=DATA; p.defaultValue="label"; m->appendString(p); }
        { OP_StringParameter p("Recordingcolumn"); p.label="Recording ID Column (Activity)"; p.page=DATA; p.defaultValue="recording"; m->appendString(p); }
        { OP_StringParameter p("Targetcolumn"); p.label="Target Column (Tabular)"; p.page=DATA; p.defaultValue="target"; m->appendString(p); }
        { OP_StringParameter p("Featurecolumns"); p.label="Feature Columns (comma, empty=auto)"; p.page=DATA; m->appendString(p); }

        const char* TRAIN = "Training";
        { OP_NumericParameter p("Maxiterations"); p.label="Max Iterations"; p.page=TRAIN; p.defaultValues[0]=25; p.minSliders[0]=1; p.maxSliders[0]=200; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Predictionwindow"); p.label="Prediction Window (Action/Activity)"; p.page=TRAIN; p.defaultValues[0]=30; p.minSliders[0]=5; p.maxSliders[0]=150; p.minValues[0]=2; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Augflip"); p.label="Augment: Flip (Image)"; p.page=TRAIN; m->appendToggle(p); }
        { OP_NumericParameter p("Augcrop"); p.label="Augment: Crop (Image)"; p.page=TRAIN; m->appendToggle(p); }
        { OP_NumericParameter p("Augrotation"); p.label="Augment: Rotation (Image)"; p.page=TRAIN; m->appendToggle(p); }
        { OP_NumericParameter p("Augblur"); p.label="Augment: Blur (Image)"; p.page=TRAIN; m->appendToggle(p); }
        { OP_NumericParameter p("Augexposure"); p.label="Augment: Exposure (Image)"; p.page=TRAIN; m->appendToggle(p); }
        { OP_NumericParameter p("Augnoise"); p.label="Augment: Noise (Image)"; p.page=TRAIN; m->appendToggle(p); }
    }

    void pulsePressed(const char* name, void*) override {
        if (strcmp(name,"Train")==0) myTrainReq = true;
        else if (strcmp(name,"Cancel")==0) myCancelReq = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        int training = (myStatus=="training")?1:0, done=(myStatus=="done")?1:0;
        const char* n[] = {"executes","progress","train_metric","val_metric","training","done"};
        float v[] = {(float)myExec.load(),(float)myProgress,(float)myTrainAcc,(float)myValAcc,(float)training,(float)done};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if (myStatus=="error" && !myError.empty()) s->setString(("CreateML: "+myError).c_str()); }

private:
    int taskIndex(const OP_Inputs* in) {
        const char* t = in->getParString("Task");
        std::string s = t ? t : "Image";
        if (s=="Handpose") return T_HANDPOSE; if (s=="Action") return T_ACTION;
        if (s=="Handaction") return T_HANDACTION; if (s=="Sound") return T_SOUND;
        if (s=="Activity") return T_ACTIVITY; if (s=="Tabularcls") return T_TABCLS;
        if (s=="Tabularreg") return T_TABREG; return T_IMAGE;
    }
    void joinArr(NSArray* a, std::string& dst) { dst.clear(); if (![a isKindOfClass:[NSArray class]]) return; int n=0; for (id v in a) { if (n++) dst+=", "; dst += [[v description] UTF8String]; } }
    void parse(const std::string& js) {
        @autoreleasepool {
            NSData* d = [NSData dataWithBytes:js.data() length:js.size()];
            NSDictionary* m = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if (![m isKindOfClass:[NSDictionary class]]) return;
            myStatus = m[@"status"] ? [[m[@"status"] description] UTF8String] : "";
            myProgress = [m[@"progress"] doubleValue];
            myTrainAcc = [m[@"train_acc"] doubleValue];
            myValAcc = [m[@"val_acc"] doubleValue];
            myMetric = m[@"metric"] ? [[m[@"metric"] description] UTF8String] : "";
            myModel = m[@"model"] ? [[m[@"model"] description] UTF8String] : "";
            myError = m[@"error"] ? [[m[@"error"] description] UTF8String] : "";
            joinArr(m[@"classes"], myClasses);
            joinArr(m[@"features"], myFeatures);
        }
    }
    void* myState = nullptr;
    std::string myStatus, myMetric, myClasses, myFeatures, myModel, myError;
    double myProgress=0, myTrainAcc=0, myValAcc=0;
    std::atomic<bool> myTrainReq{false}, myCancelReq{false};
    std::atomic<uint64_t> myExec{0}, myTrains{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i) {
    if (!i->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Createml");
    i->customOPInfo.opLabel->setString("CreateML");
    i->customOPInfo.opIcon->setString("CML");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i) { return new CreateMLDAT(i); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i) { delete static_cast<CreateMLDAT*>(i); }
}
