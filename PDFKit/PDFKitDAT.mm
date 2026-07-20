// PDF Document DAT — PDFKit で PDF の構造(メタデータ / アウトライン / ページテキスト / 注釈)を
// テーブル出力する。Mode で切替。座標は PDF ポイント(左下原点)。
#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>
#include <string>
#include <atomic>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
class PDFKitDAT final : public DAT_CPlusPlusBase {
public:
    PDFKitDAT(const OP_NodeInfo*) {}
    ~PDFKitDAT() override {}
    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; }

    void execute(DAT_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        std::string file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        std::string mode = in->getParString("Mode") ? in->getParString("Mode") : "Info";
        int page = (int)in->getParInt("Page");
        @autoreleasepool {
            out->setOutputDataType(DAT_OutDataType::Table);
            if (file.empty()) { out->setTableSize(1,1); out->setCellString(0,0,"(no file)"); return; }
            NSURL* url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:file.c_str()]];
            PDFDocument* doc=[[PDFDocument alloc] initWithURL:url];
            if (!doc) { out->setTableSize(1,1); out->setCellString(0,0,"(failed to open PDF)"); myWarn="failed to open PDF"; return; }
            myWarn.clear(); myPages=(int)doc.pageCount;
            if (mode=="Outline") emitOutline(out, doc);
            else if (mode=="Text") emitText(out, doc, page);
            else if (mode=="Annotations") emitAnnotations(out, doc, page);
            else emitInfo(out, doc);
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="PDFKit";
        { OP_StringParameter p("File"); p.label="PDF File"; p.page=P; m->appendFile(p); }
        { OP_StringParameter p("Mode"); p.label="Mode"; p.page=P; p.defaultValue="Info";
          const char* n[]={"Info","Outline","Text","Annotations"}; const char* l[]={"Info / Metadata","Outline (bookmarks)","Page Text","Page Annotations"};
          m->appendMenu(p,4,n,l); }
        { OP_NumericParameter p("Page"); p.label="Page (0-based, for Text/Annotations)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=100; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","pages"}; float v[]={(float)myExec.load(),(float)myPages};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    static const char* cstr(NSString* s){ return s?[s UTF8String]:""; }
    void emitInfo(DAT_Output* out, PDFDocument* doc) {
        NSDictionary* a=doc.documentAttributes;
        NSArray* keys=@[@"key",@"value"];
        NSMutableArray* rows=[NSMutableArray arrayWithObjects:@[@"pages",[NSString stringWithFormat:@"%lu",(unsigned long)doc.pageCount]],
            @[@"title",a[PDFDocumentTitleAttribute]?:@""], @[@"author",a[PDFDocumentAuthorAttribute]?:@""],
            @[@"subject",a[PDFDocumentSubjectAttribute]?:@""], @[@"creator",a[PDFDocumentCreatorAttribute]?:@""],
            @[@"producer",a[PDFDocumentProducerAttribute]?:@""], @[@"encrypted",doc.isEncrypted?@"1":@"0"],
            @[@"locked",doc.isLocked?@"1":@"0"], nil];
        PDFPage* p0=[doc pageAtIndex:0];
        if (p0){ CGRect r=[p0 boundsForBox:kPDFDisplayBoxMediaBox]; [rows addObject:@[@"page0_width",[NSString stringWithFormat:@"%.1f",r.size.width]]]; [rows addObject:@[@"page0_height",[NSString stringWithFormat:@"%.1f",r.size.height]]]; }
        out->setTableSize((int)rows.count,2);
        for (int i=0;i<(int)rows.count;i++){ out->setCellString(i,0,cstr(rows[i][0])); out->setCellString(i,1,cstr([rows[i][1] description])); }
    }
    void emitOutline(DAT_Output* out, PDFDocument* doc) {
        NSMutableArray* rows=[NSMutableArray array];
        [rows addObject:@[@"level",@"title",@"page"]];
        PDFOutline* root=doc.outlineRoot;
        if (root) walkOutline(root, 0, doc, rows);
        if (rows.count==1) [rows addObject:@[@"0",@"(no outline)",@""]];
        out->setTableSize((int)rows.count,3);
        for (int i=0;i<(int)rows.count;i++) for(int j=0;j<3;j++) out->setCellString(i,j,cstr([rows[i][j] description]));
    }
    void walkOutline(PDFOutline* node, int level, PDFDocument* doc, NSMutableArray* rows) {
        for (NSInteger i=0;i<node.numberOfChildren;i++){
            PDFOutline* c=[node childAtIndex:i];
            NSInteger pg = c.destination.page ? [doc indexForPage:c.destination.page] : -1;
            [rows addObject:@[[NSString stringWithFormat:@"%d",level],c.label?:@"",[NSString stringWithFormat:@"%ld",(long)pg]]];
            walkOutline(c, level+1, doc, rows);
        }
    }
    void emitText(DAT_Output* out, PDFDocument* doc, int page) {
        if (page<0||page>=(int)doc.pageCount){ out->setTableSize(1,1); out->setCellString(0,0,"(page out of range)"); return; }
        PDFPage* p=[doc pageAtIndex:page];
        out->setOutputDataType(DAT_OutDataType::Text);
        out->setText(cstr(p.string ?: @""));
    }
    void emitAnnotations(DAT_Output* out, PDFDocument* doc, int page) {
        if (page<0||page>=(int)doc.pageCount){ out->setTableSize(1,1); out->setCellString(0,0,"(page out of range)"); return; }
        PDFPage* p=[doc pageAtIndex:page];
        NSMutableArray* rows=[NSMutableArray arrayWithObject:@[@"type",@"x",@"y",@"w",@"h",@"contents"]];
        for (PDFAnnotation* an in p.annotations){
            CGRect b=an.bounds;
            [rows addObject:@[an.type?:@"", [NSString stringWithFormat:@"%.1f",b.origin.x],[NSString stringWithFormat:@"%.1f",b.origin.y],
                [NSString stringWithFormat:@"%.1f",b.size.width],[NSString stringWithFormat:@"%.1f",b.size.height], an.contents?:@""]];
        }
        if (rows.count==1) [rows addObject:@[@"(none)",@"",@"",@"",@"",@""]];
        out->setTableSize((int)rows.count,6);
        for (int i=0;i<(int)rows.count;i++) for(int j=0;j<6;j++) out->setCellString(i,j,cstr([rows[i][j] description]));
    }
    std::atomic<uint64_t> myExec{0}; int myPages=0; std::string myWarn;
};
} // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i) {
    if (!i->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Pdfkit");
    i->customOPInfo.opLabel->setString("PDFKit");
    i->customOPInfo.opIcon->setString("PDF");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i) { return new PDFKitDAT(i); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i) { delete static_cast<PDFKitDAT*>(i); }
}
