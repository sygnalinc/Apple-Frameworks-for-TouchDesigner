// Image Capture DAT — ImageCaptureCore の ICDeviceBrowser で、接続中のカメラ(テザー撮影対応DSLR等)/
// スキャナを列挙し、名前/種別/UDID/転送可否をテーブル出力する。デバイス発見は非同期(delegate)。
// テザー撮影・スキャン制御の足場(デバイスが接続されていれば列挙される)。
#import <Foundation/Foundation.h>
#import <ImageCaptureCore/ImageCaptureCore.h>
#include <string>
#include <vector>
#include <atomic>
#include <mutex>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

struct DevRow { std::string name, type, uuid, transport; };
static std::mutex gMutex;

@interface TDICBrowserDelegate : NSObject <ICDeviceBrowserDelegate>
@property (nonatomic, assign) std::vector<DevRow>* rows;
@end
@implementation TDICBrowserDelegate
- (void)deviceBrowser:(ICDeviceBrowser*)b didAddDevice:(ICDevice*)d moreComing:(BOOL)more {
    std::lock_guard<std::mutex> l(gMutex);
    if (!self.rows) return;
    DevRow r;
    r.name = d.name ? d.name.UTF8String : "";
    r.type = (d.type & ICDeviceTypeCamera) ? "camera" : ((d.type & ICDeviceTypeScanner) ? "scanner" : "other");
    r.uuid = d.UUIDString ? d.UUIDString.UTF8String : "";
    r.transport = d.transportType ? d.transportType.UTF8String : "";
    self.rows->push_back(r);
}
- (void)deviceBrowser:(ICDeviceBrowser*)b didRemoveDevice:(ICDevice*)d moreGoing:(BOOL)more {
    std::lock_guard<std::mutex> l(gMutex);
    if (!self.rows) return;
    for (auto it=self.rows->begin(); it!=self.rows->end(); ++it) if (it->uuid == (d.UUIDString?d.UUIDString.UTF8String:"")) { self.rows->erase(it); break; }
}
@end

namespace {
class ImageCaptureDAT final : public DAT_CPlusPlusBase {
public:
    ImageCaptureDAT(const OP_NodeInfo*) {
        @autoreleasepool {
            myDelegate=[[TDICBrowserDelegate alloc] init];
            myDelegate.rows=&myRows;
            myBrowser=[[ICDeviceBrowser alloc] init];
            myBrowser.delegate=myDelegate;
            myBrowser.browsedDeviceTypeMask=(ICDeviceTypeMask)(ICDeviceTypeMaskCamera|ICDeviceTypeMaskScanner|ICDeviceLocationTypeMaskLocal);
            [myBrowser start];
        }
    }
    ~ImageCaptureDAT() override { @autoreleasepool { if(myBrowser){ [myBrowser stop]; myBrowser.delegate=nil; } myBrowser=nil; myDelegate.rows=nullptr; myDelegate=nil; } }
    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; }

    void execute(DAT_Output* out, const OP_Inputs*, void*) override {
        myExec++;
        out->setOutputDataType(DAT_OutDataType::Table);
        std::vector<DevRow> rows; { std::lock_guard<std::mutex> l(gMutex); rows=myRows; }
        out->setTableSize((int)rows.size()+1, 4);
        const char* hdr[]={"name","type","uuid","transport"};
        for (int j=0;j<4;j++) out->setCellString(0,j,hdr[j]);
        for (int i=0;i<(int)rows.size();i++){ out->setCellString(i+1,0,rows[i].name.c_str()); out->setCellString(i+1,1,rows[i].type.c_str()); out->setCellString(i+1,2,rows[i].uuid.c_str()); out->setCellString(i+1,3,rows[i].transport.c_str()); }
        myCount=(int)rows.size();
    }
    void setupParameters(OP_ParameterManager*, void*) override {}
    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","devices"}; float v[]={(float)myExec.load(),(float)myCount};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(myCount==0) s->setString("No camera/scanner connected (needs a tethered DSLR / scanner; may require Photos/Camera TCC permission)."); }
private:
    ICDeviceBrowser* myBrowser=nil; TDICBrowserDelegate* myDelegate=nil;
    std::vector<DevRow> myRows; int myCount=0; std::atomic<uint64_t> myExec{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i) {
    if (!i->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Imagecapture");
    i->customOPInfo.opLabel->setString("Image Capture");
    i->customOPInfo.opIcon->setString("ICP");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i) { return new ImageCaptureDAT(i); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i) { delete static_cast<ImageCaptureDAT*>(i); }
}
