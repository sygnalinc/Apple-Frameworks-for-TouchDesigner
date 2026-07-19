// CreateML Image DAT — ラベル付きフォルダ(サブフォルダ名=クラス)から画像分類モデルを
// CreateML でオンデバイス学習し .mlmodel を書き出す。出力モデルは CoreML TOP で推論できる。
// 学習は Swift ヘルパで非同期実行、cook は進捗を poll するだけでブロックしない。
#import <Foundation/Foundation.h>
#include <string>
#include <atomic>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void* cm_create(void); void cm_destroy(void*);
    void  cm_train(void*, const char* folder, const char* out, int maxIter, int augMask);
    void  cm_cancel(void*);
    const char* cm_status(void*);
}

namespace {
class CreateMLImageDAT final : public DAT_CPlusPlusBase {
public:
    CreateMLImageDAT(const OP_NodeInfo*) { myState = cm_create(); }
    ~CreateMLImageDAT() override { if (myState) cm_destroy(myState); }

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; }

    void execute(DAT_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        if (!myState) return;

        // Train パルス処理(パラメータは execute で読む)
        if (myTrainReq.exchange(false)) {
            std::string folder = in->getParFilePath("Trainingfolder") ? in->getParFilePath("Trainingfolder") : "";
            std::string model = in->getParFilePath("Outputmodel") ? in->getParFilePath("Outputmodel") : "";
            int maxIter = (int)in->getParInt("Maxiterations");
            int aug = 0;
            if (in->getParInt("Flip")) aug |= 1;
            if (in->getParInt("Crop")) aug |= 2;
            if (in->getParInt("Rotation")) aug |= 4;
            if (in->getParInt("Blur")) aug |= 8;
            if (in->getParInt("Exposure")) aug |= 16;
            if (in->getParInt("Noise")) aug |= 32;
            if (!folder.empty() && !model.empty()) { cm_train(myState, folder.c_str(), model.c_str(), maxIter, aug); myTrains++; }
        }
        if (myCancelReq.exchange(false)) cm_cancel(myState);

        // status JSON をパースして key/value テーブル + Info CHOP 用の値を更新
        const char* j = cm_status(myState); std::string js = j ? j : "{}"; if (j) free((void*)j);
        parse(js);

        out->setOutputDataType(DAT_OutDataType::Table);
        out->setTableSize(7, 2);
        const char* keys[] = {"status","progress","train_accuracy","validation_accuracy","classes","model","error"};
        char b[64];
        out->setCellString(0,0,"key"); out->setCellString(0,1,"value"); // 1行目もデータにするなら不要だがヘッダとして
        // 実際は 7行を key/value で出す(ヘッダ無し)
        out->setTableSize(7,2);
        for (int i=0;i<7;i++) out->setCellString(i,0,keys[i]);
        out->setCellString(0,1,myStatus.c_str());
        snprintf(b,sizeof b,"%.3f",myProgress); out->setCellString(1,1,b);
        snprintf(b,sizeof b,"%.4f",myTrainAcc); out->setCellString(2,1,b);
        snprintf(b,sizeof b,"%.4f",myValAcc); out->setCellString(3,1,b);
        out->setCellString(4,1,myClasses.c_str());
        out->setCellString(5,1,myModel.c_str());
        out->setCellString(6,1,myError.c_str());
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "CreateML Image";
        { OP_StringParameter p("Trainingfolder"); p.label="Training Folder (subfolders = labels)"; p.page=PAGE; m->appendFolder(p); }
        { OP_StringParameter p("Outputmodel"); p.label="Output Model (.mlmodel)"; p.page=PAGE; p.defaultValue="classifier.mlmodel"; m->appendFile(p); }
        { OP_NumericParameter p("Maxiterations"); p.label="Max Iterations"; p.page=PAGE; p.defaultValues[0]=25; p.minSliders[0]=1; p.maxSliders[0]=100; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
        auto tog=[&](const char* n,const char* l){ OP_NumericParameter p(n); p.label=l; p.page=PAGE; p.defaultValues[0]=0; m->appendToggle(p); };
        tog("Flip","Augment: Flip"); tog("Crop","Augment: Crop"); tog("Rotation","Augment: Rotation");
        tog("Blur","Augment: Blur"); tog("Exposure","Augment: Exposure"); tog("Noise","Augment: Noise");
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
            NSArray* cs = m[@"classes"];
            myClasses.clear();
            if ([cs isKindOfClass:[NSArray class]]) { for (NSString* c in cs) { if (!myClasses.empty()) myClasses+=", "; myClasses += [[c description] UTF8String]; } }
        }
    }
    void* myState = nullptr;
    std::string myStatus, myClasses, myModel, myError; double myProgress=0, myTrainAcc=0, myValAcc=0;
    std::atomic<bool> myTrainReq{false}, myCancelReq{false};
    std::atomic<uint64_t> myExec{0}, myTrains{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i) {
    if (!i->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Createmlimage");
    i->customOPInfo.opLabel->setString("CreateML Image");
    i->customOPInfo.opIcon->setString("CMI");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i) { return new CreateMLImageDAT(i); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i) { delete static_cast<CreateMLImageDAT*>(i); }
}
