// Vision Document DAT — 新Vision APIの RecognizeDocumentsRequest(macOS 26+)で
// 文書の段落・表・行・セル・リスト構造を認識し、テーブルDATへ出力する。
// 解析は Swift ヘルパ(dv_)で非同期。cook は poll するだけでブロックしない。
#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <atomic>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void* dv_create(void);
    void  dv_destroy(void*);
    void  dv_analyze(void*, const char*);
    const char* dv_status(void*);
    const char* dv_result(void*);
}

namespace {
class VisionDocumentDAT final : public DAT_CPlusPlusBase {
public:
    VisionDocumentDAT(const OP_NodeInfo*) { myState = dv_create(); }
    ~VisionDocumentDAT() override { if (myState) dv_destroy(myState); }

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }

    void execute(DAT_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        if (!myState) return;
        std::string file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        if (file != myFile) { myFile = file; if (!file.empty()) { dv_analyze(myState, file.c_str()); mySubmit++; } }

        // status: "status|p,t,l,c|error"
        std::string status, counts, err;
        { const char* s = dv_status(myState); if (s) { std::string all(s); free((void*)s);
            size_t a = all.find('|'), b = all.rfind('|');
            if (a != std::string::npos && b != std::string::npos && b > a) { status = all.substr(0, a); counts = all.substr(a+1, b-a-1); err = all.substr(b+1); } } }
        myStatus = status; myCounts = counts; myErr = err;

        // done になったら結果を取り込んでテーブル化(取り込み済みなら再構築しない)
        if (status == "done" && myLastBuilt != file + "#done") { myLastBuilt = file + "#done"; buildTable(out); myBuilt = true; }
        else if (myBuilt && !myRows.empty()) { emitTable(out); }
        else { out->setOutputDataType(DAT_OutDataType::Table); out->setTableSize(1, 6);
               const char* h[6] = {"type","page","index","row","col","text"}; for (int c = 0; c < 6; c++) out->setCellString(0, c, h[c]); }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "Vision Document";
        { OP_StringParameter p("File"); p.label = "Document Image (photo/scan)"; p.page = PAGE; m->appendFile(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        int p = 0, t = 0, l = 0, ce = 0; sscanf(myCounts.c_str(), "%d,%d,%d,%d", &p, &t, &l, &ce);
        int analyzing = (myStatus == "analyzing") ? 1 : 0;
        const char* n[] = {"executes","paragraphs","tables","lists","cells","analyzing"};
        float v[] = {(float)myExec.load(), (float)p, (float)t, (float)l, (float)ce, (float)analyzing};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override { if (myStatus == "error" && !myErr.empty()) s->setString(("Vision Document: " + myErr).c_str()); }

private:
    void buildTable(DAT_Output* out) {
        myRows.clear();
        const char* j = dv_result(myState); if (!j) return; std::string js(j); free((void*)j);
        @autoreleasepool {
            NSData* d = [NSData dataWithBytes:js.data() length:js.size()];
            NSArray* arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if (![arr isKindOfClass:[NSArray class]]) return;
            for (NSDictionary* e in arr) {
                Row r;
                r.type = [[e[@"type"] description] UTF8String] ?: "";
                r.page = [e[@"page"] intValue]; r.index = [e[@"index"] intValue];
                r.row = [e[@"row"] intValue]; r.col = [e[@"col"] intValue];
                r.text = [[e[@"text"] description] UTF8String] ?: "";
                myRows.push_back(r);
            }
        }
        emitTable(out);
    }
    void emitTable(DAT_Output* out) {
        out->setOutputDataType(DAT_OutDataType::Table);
        out->setTableSize((int32_t)myRows.size() + 1, 6);
        const char* h[6] = {"type","page","index","row","col","text"}; for (int c = 0; c < 6; c++) out->setCellString(0, c, h[c]);
        char b[16];
        for (int i = 0; i < (int)myRows.size(); i++) {
            const Row& r = myRows[i];
            out->setCellString(i+1, 0, r.type.c_str());
            snprintf(b, sizeof b, "%d", r.page); out->setCellString(i+1, 1, b);
            snprintf(b, sizeof b, "%d", r.index); out->setCellString(i+1, 2, b);
            snprintf(b, sizeof b, "%d", r.row); out->setCellString(i+1, 3, b);
            snprintf(b, sizeof b, "%d", r.col); out->setCellString(i+1, 4, b);
            out->setCellString(i+1, 5, r.text.c_str());
        }
    }
    struct Row { std::string type, text; int page = 0, index = 0, row = 0, col = 0; };
    void* myState = nullptr;
    std::string myFile, myStatus, myCounts, myErr, myLastBuilt;
    std::vector<Row> myRows; bool myBuilt = false;
    std::atomic<uint64_t> myExec{0}, mySubmit{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i) {
    if (!i->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Visiondocument");
    i->customOPInfo.opLabel->setString("Vision Document");
    i->customOPInfo.opIcon->setString("VDC");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/VisionDocument/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i) { return new VisionDocumentDAT(i); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i) { delete static_cast<VisionDocumentDAT*>(i); }
}
