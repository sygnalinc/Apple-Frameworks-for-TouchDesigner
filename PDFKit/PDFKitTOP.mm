// PDFKit TOP — PDFKit で PDF の指定ページを BGRA8 TOP に描画する。DPI/ページ指定。
// cook はブロックせずワーカーで描画する。
//
// 文書構造(旧 PDFKit DAT を統合): Info DAT Mode(Info / Outline / Text / Annotations)で
// 選んだテーブルを Info DAT に出す。Info DAT をこのノードに向けるだけで旧DATと同じ情報が
// 得られる(Text/Annotations は Page パラメータのページを対象にする)。
#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "../common/NonCommercialLimit.h"
#include "../common/PyCallbacksBootstrap.h"
using namespace TD;

// Callbacks DAT 雛形(配置時に自動生成・ドックチップ接続)。
// Info DAT トグル ON で隣に文書構造の Info DAT を自動生成する(二重生成ガード付き)。
static const char* PythonCallbacksDATStubs =
"# PDFKit TOP callbacks\n"
"#\n"
"# onInfoDAT: 'Info DAT' トグルを on にした瞬間に呼ばれる。\n"
"# 隣に文書構造表示用の Info DAT を自動生成する(既にあれば何もしない)。\n"
"# 表示内容は本体の 'Info DAT Mode'(Info/Outline/Text/Annotations)で切り替える。\n"
"def onInfoDAT(op, enabled):\n"
"\tif not enabled:\n"
"\t\treturn\n"
"\tp = op.parent()\n"
"\tname = op.name + '_info'\n"
"\tif p.op(name):\n"
"\t\treturn\n"
"\td = p.create(infoDAT, name)\n"
"\td.par.op = op.name\n"
"\td.nodeX = op.nodeX + 200\n"
"\td.nodeY = op.nodeY\n"
"\td.viewer = True\n"
"\treturn\n";

namespace {
struct Result { std::vector<uint8_t> bgra; uint32_t w=0,h=0; uint64_t serial=0; bool ok=false; };

class PDFKitTOP final : public TOP_CPlusPlusBase {
public:
    PDFKitTOP(const OP_NodeInfo* ni, TOP_Context* c) : myNode(ni), myContext(c) { myThread=std::thread([this]{ worker(); }); }
    ~PDFKitTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit=true; } myCond.notify_all(); if(myThread.joinable()) myThread.join(); }
    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked=true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        // 配置後の cook で雛形入り Callbacks DAT を自動生成・ドック接続(成功するまでリトライ)
        if (!myBootstrapped) myBootstrapped = tdpycb::bootstrapCallbacksDAT(myNode, PythonCallbacksDATStubs);
        // Info DAT トグル off→on で隣に Info DAT を自動生成
        bool infoDat = in->getParInt("Infodat") != 0;
        if (infoDat && !myPrevInfoDat) {
            tdpycb::bootstrapCallbacksDAT(myNode, PythonCallbacksDATStubs);   // 消されていたら再生成
            tdpycb::firePythonCallback(myNode, "onInfoDAT", true);
        }
        myPrevInfoDat = infoDat;
        std::string file=in->getParFilePath("File")?in->getParFilePath("File"):"";
        int page=(int)in->getParInt("Page"); float dpi=(float)in->getParDouble("Dpi");
        std::string imode=in->getParString("Infomode")?in->getParString("Infomode"):"Info";
        std::string sig=file+"|"+std::to_string(page)+"|"+std::to_string((int)dpi)+"|"+imode;
        if (sig!=mySig){ mySig=sig; std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy){ myFile=file; myPage=page; myDpi=dpi; myInfoMode=imode; myPending=true; mySubmit++; l.unlock(); myCond.notify_one(); } else mySig.clear(); }
        Result r; { std::lock_guard<std::mutex> l(myMutex); if(!myResult.ok||myResult.bgra.empty()) return; r=myResult; myUploaded=r.serial; }
        // NC の 1280x1280 上限に収めてから宣言する（超えたまま渡すと TD が
        // クランプ後の幅でバッファを読み、絵が斜めに崩れる）
        if (tdnc::fit(r.bgra, r.w, r.h, OP_PixelFormat::BGRA8Fixed)) myWarn = tdnc::kWarning;
        TOP_UploadInfo ui; ui.textureDesc.texDim=OP_TexDim::e2D; ui.textureDesc.width=r.w; ui.textureDesc.height=r.h; ui.textureDesc.pixelFormat=OP_PixelFormat::BGRA8Fixed;
        auto b=myContext->createOutputBuffer((size_t)r.w*r.h*4, TOP_BufferFlags::None, nullptr); if(!b) return;
        memcpy(b->data, r.bgra.data(), r.bgra.size()); out->uploadBuffer(&b, ui, nullptr);
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="PDFKit";
        { OP_StringParameter p("File"); p.label="PDF File"; p.page=P; m->appendFile(p); }
        { OP_NumericParameter p("Page"); p.label="Page (0-based)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=100; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Dpi"); p.label="DPI"; p.page=P; p.defaultValues[0]=150; p.minSliders[0]=36; p.maxSliders[0]=600; p.minValues[0]=1; p.clampMins[0]=true; m->appendFloat(p); }
        { OP_StringParameter p("Infomode"); p.label="Info DAT Mode"; p.page=P; p.defaultValue="Info";
          const char* n[]={"Info","Outline","Text","Annotations"}; const char* l[]={"Info / Metadata","Outline (bookmarks)","Page Text","Page Annotations"};
          m->appendMenu(p,4,n,l); }
        { OP_NumericParameter p("Infodat"); p.label="Info DAT"; p.page=P; p.defaultValues[0]=0; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","width","height","pages"}; float v[]={(float)myExec.load(),(float)myOutW,(float)myOutH,(float)myPages.load()};
        c->name->setString(n[i]); c->value=v[i];
    }

    // Info DAT: 旧 PDFKit DAT のテーブル(Infomode で切替・workerが構築したキャッシュを返す)
    bool getInfoDATSize(OP_InfoDATSize* s, void*) override {
        std::lock_guard<std::mutex> l(myMutex);
        if (myInfoRows.empty()) return false;
        s->rows=(int32_t)myInfoRows.size(); s->cols=(int32_t)myInfoCols; s->byColumn=false;
        return true;
    }
    void getInfoDATEntries(int32_t index, int32_t nEntries, OP_InfoDATEntries* e, void*) override {
        std::lock_guard<std::mutex> l(myMutex);
        if (index<0 || index>=(int)myInfoRows.size()) return;
        const auto& row=myInfoRows[index];
        for (int j=0;j<nEntries;j++) e->values[j]->setString(j<(int)row.size()?row[j].c_str():"");
    }
    void getWarningString(OP_String* s, void*) override { if(!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    void worker() {
        for(;;){
            std::string file, imode; int page; float dpi;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l,[this]{return myPending||myQuit;}); if(myQuit) return; myBusy=true; myPending=false; file=myFile; page=myPage; dpi=myDpi; imode=myInfoMode; }
            Result r; r.serial=++mySerial;
            @autoreleasepool {
                if(!file.empty()){
                    NSURL* url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:file.c_str()]];
                    PDFDocument* doc=[[PDFDocument alloc] initWithURL:url];
                    if (doc) { myPages=(int)doc.pageCount; buildInfo(doc, imode, page); }
                    if (!doc){ std::lock_guard<std::mutex> l(myMutex); myWarn="failed to open PDF"; }
                    else if (page<0||page>=(int)doc.pageCount){ std::lock_guard<std::mutex> l(myMutex); myWarn="page out of range"; }
                    else {
                        PDFPage* p=[doc pageAtIndex:page];
                        CGRect box=[p boundsForBox:kPDFDisplayBoxMediaBox];
                        float sc=dpi/72.f;
                        int iw=(int)ceilf(box.size.width*sc), ih=(int)ceilf(box.size.height*sc);
                        if (iw>0 && ih>0 && (long)iw*ih<=64L*1024*1024){
                            r.bgra.assign((size_t)iw*ih*4, 0);
                            CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
                            CGContextRef ctx=CGBitmapContextCreate(r.bgra.data(), iw, ih, 8, iw*4, cs, kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
                            CGContextSetRGBFillColor(ctx,1,1,1,1); CGContextFillRect(ctx, CGRectMake(0,0,iw,ih)); // 白背景
                            CGContextScaleCTM(ctx, sc, sc);
                            CGContextTranslateCTM(ctx, -box.origin.x, -box.origin.y);
                            [p drawWithBox:kPDFDisplayBoxMediaBox toContext:ctx];
                            CGContextRelease(ctx); CGColorSpaceRelease(cs);
                            // PDF描画は bottom-up(PDF座標は左下原点)。TD表示に合わせて上下反転する
                            {
                                std::vector<uint8_t> fl((size_t)iw*ih*4);
                                for (int y=0;y<ih;y++)
                                    memcpy(fl.data()+(size_t)(ih-1-y)*iw*4, r.bgra.data()+(size_t)y*iw*4, (size_t)iw*4);
                                r.bgra.swap(fl);
                            }
                            r.w=iw; r.h=ih; r.ok=true;
                        }
                    }
                }
            }
            { std::lock_guard<std::mutex> l(myMutex); myResult=r; if(r.ok){ myOutW=r.w; myOutH=r.h; myWarn.clear(); } myBusy=false; }
        }
    }
    // 旧 PDFKit DAT のテーブル群を Info DAT 用キャッシュ(myInfoRows)へ構築する(worker上)
    static const char* cstr(NSString* s){ return s?[s UTF8String]:""; }
    void buildInfo(PDFDocument* doc, const std::string& mode, int page) {
        std::vector<std::vector<std::string>> rows; size_t cols=2;
        if (mode=="Outline") {
            cols=3; rows.push_back({"level","title","page"});
            if (doc.outlineRoot) walkOutline(doc.outlineRoot, 0, doc, rows);
            if (rows.size()==1) rows.push_back({"0","(no outline)",""});
        } else if (mode=="Text") {
            cols=2; rows.push_back({"line","text"});
            if (page>=0 && page<(int)doc.pageCount) {
                NSString* txt=[doc pageAtIndex:page].string ?: @"";
                int ln=0;
                for (NSString* line in [txt componentsSeparatedByString:@"\n"])
                    rows.push_back({std::to_string(ln++), cstr(line)});
            } else rows.push_back({"0","(page out of range)"});
        } else if (mode=="Annotations") {
            cols=6; rows.push_back({"type","x","y","w","h","contents"});
            if (page>=0 && page<(int)doc.pageCount) {
                char b[32];
                for (PDFAnnotation* an in [doc pageAtIndex:page].annotations) {
                    CGRect r=an.bounds; std::vector<std::string> row;
                    row.push_back(cstr(an.type?:@""));
                    snprintf(b,sizeof b,"%.1f",r.origin.x); row.push_back(b);
                    snprintf(b,sizeof b,"%.1f",r.origin.y); row.push_back(b);
                    snprintf(b,sizeof b,"%.1f",r.size.width); row.push_back(b);
                    snprintf(b,sizeof b,"%.1f",r.size.height); row.push_back(b);
                    row.push_back(cstr(an.contents?:@""));
                    rows.push_back(std::move(row));
                }
            }
            if (rows.size()==1) rows.push_back({"(none)","","","","",""});
        } else {   // Info / Metadata
            cols=2; rows.push_back({"key","value"});
            NSDictionary* a=doc.documentAttributes;
            rows.push_back({"pages", std::to_string((unsigned long)doc.pageCount)});
            rows.push_back({"title", cstr([a[PDFDocumentTitleAttribute] description])});
            rows.push_back({"author", cstr([a[PDFDocumentAuthorAttribute] description])});
            rows.push_back({"subject", cstr([a[PDFDocumentSubjectAttribute] description])});
            rows.push_back({"creator", cstr([a[PDFDocumentCreatorAttribute] description])});
            rows.push_back({"producer", cstr([a[PDFDocumentProducerAttribute] description])});
            rows.push_back({"encrypted", doc.isEncrypted?"1":"0"});
            rows.push_back({"locked", doc.isLocked?"1":"0"});
            if (PDFPage* p0=[doc pageAtIndex:0]) {
                CGRect r=[p0 boundsForBox:kPDFDisplayBoxMediaBox]; char b[32];
                snprintf(b,sizeof b,"%.1f",r.size.width);  rows.push_back({"page0_width",b});
                snprintf(b,sizeof b,"%.1f",r.size.height); rows.push_back({"page0_height",b});
            }
        }
        std::lock_guard<std::mutex> l(myMutex);
        myInfoRows=std::move(rows); myInfoCols=cols;
    }
    void walkOutline(PDFOutline* node, int level, PDFDocument* doc, std::vector<std::vector<std::string>>& rows) {
        for (NSInteger i=0;i<node.numberOfChildren;i++){
            PDFOutline* c=[node childAtIndex:i];
            NSInteger pg = c.destination.page ? [doc indexForPage:c.destination.page] : -1;
            rows.push_back({std::to_string(level), cstr(c.label?:@""), std::to_string((long)pg)});
            walkOutline(c, level+1, doc, rows);
        }
    }

    const OP_NodeInfo* myNode = nullptr;   // Python コールバック用
    bool myBootstrapped = false, myPrevInfoDat = false;
    TOP_Context* myContext=nullptr; std::thread myThread; std::mutex myMutex; std::condition_variable myCond;
    bool myPending=false,myBusy=false,myQuit=false;
    std::string myFile,mySig,myWarn,myInfoMode="Info"; int myPage=0; float myDpi=150; int myOutW=0,myOutH=0;
    std::vector<std::vector<std::string>> myInfoRows; size_t myInfoCols=2;   // myMutex 保護
    Result myResult; uint64_t myUploaded=0; std::atomic<uint64_t> mySerial{0},myExec{0},mySubmit{0};
    std::atomic<int> myPages{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode=TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Pdfkit");
    i->customOPInfo.opLabel->setString("PDFKit");
    i->customOPInfo.opIcon->setString("PDF");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/PDFKit/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
    i->customOPInfo.pythonCallbacksDAT = PythonCallbacksDATStubs;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new PDFKitTOP(i,c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<PDFKitTOP*>(i); }
}
