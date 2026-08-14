// MapKit LookAround TOP — Apple マップの Look Around(街並みの実写)をライブで TOP に出す。
// MapKit TOP(地図)と同じ土台: 常駐ビューをプラグイン所有のウインドウに置き、
// ScreenCaptureKit の initWithDesktopIndependentWindow: で取り込む(理由は MapKitTOP.mm 冒頭)。
//
// 視線制御は**私有 API**(公開 API には存在しない):
// MKLookAroundView の setPresentationYaw:pitch:animated: を呼ぶ(ドラッグと同じ内部経路)。
// 現在の方位は MKLookAroundView.presentationYaw で読める(pitch の読み出し口は無い)。
// 実測(画素検証): yaw 20.1→90→225 と回り、画像は保たれる(輝度 148→143→141)。
// pitch は**正=下**(+30 で路面 / -30 でビル上層と空。実測)。
// ※シーンを initWithMapItem:cameraFrameOverride: で作り直す方式は**常に真っ黒**
//   (実測: 状態は drawn=1/yaw 適用済みと返るが、実際の合成は黒。使わないこと)
// **OS 更新で壊れうる**ことは README に明記(このプラグインは experimental)
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <MapKit/MapKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreText/CoreText.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "../common/NonCommercialLimit.h"
#include "../common/PyCallbacksBootstrap.h"
#include "MapKitShared.h"
using namespace TD;

namespace { class MapKitLookAroundTOP; }

// ボーダーレスウインドウは既定で key になれず、マウスドラッグ系の操作が届かない。
// クラス名はバンドル固有(MapKitShared.h 冒頭の注意を参照)
@interface TDMKLAWindow : NSWindow
@end
@implementation TDMKLAWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

// バーの閉じるボタン: 実際には閉じず、フラグを立てて cook 側が Show Window をオフにする
@interface TDMKLABarDelegate : NSObject <NSWindowDelegate>
{
@public
    std::shared_ptr<std::atomic<bool>> closeReq;
}
@end
@implementation TDMKLABarDelegate
- (BOOL)windowShouldClose:(NSWindow*)w
{
    if (closeReq) closeReq->store(true);
    return NO;
}
@end

@interface TDMKLAStreamOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, assign) void* owner;
@end

namespace {

class MapKitLookAroundTOP final : public TOP_CPlusPlusBase {
public:
    MapKitLookAroundTOP(const OP_NodeInfo* ni, TOP_Context* c)
        : myNode(ni), myContext(c), myAlive(std::make_shared<std::atomic<bool>>(true))
    {
        myOutput = [TDMKLAStreamOutput new];
        myOutput.owner = this;
    }

    ~MapKitLookAroundTOP() override
    {
        *myAlive = false;
        myOutput.owner = nullptr;
        SCStream* st = myStream; myStream = nil;
        NSWindow* w = myWindow; myWindow = nil;
        NSWindow* bw = myBarWindow; myBarWindow = nil;
        myBarDelegate = nil;
        id obs = myMoveObserver; myMoveObserver = nil;
        if (obs) [[NSNotificationCenter defaultCenter] removeObserver:obs];
        myLookVC = nil;
        if (st) [st stopCaptureWithCompletionHandler:^(NSError*) {}];
        dispatch_async(dispatch_get_main_queue(), ^{
            bw.delegate = nil;   // NSWindow.delegate は weak でない(assign)ので明示的に切る
            [bw close]; [w close];
        });
    }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrame = true;
    }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        const bool active = in->getParInt("Active") != 0;
        int w = 1280, h = 720;
        {
            const char* om = in->getParString("outputresolution");
            if (om && strcmp(om, "useinput")) {
                OP_TextureDesc sug{}; out->getSuggestedOutputDesc(&sug, nullptr);
                if (sug.width > 15 && sug.height > 15) { w = (int)sug.width; h = (int)sug.height; }
            }
            if (w > 8192) w = 8192;
            if (h > 8192) h = 8192;
        }
        const int fps = std::max(1, std::min(120, (int)in->getParInt("Fps")));
        const bool show = in->getParInt("Showwindow") != 0;
        if (myCloseReq->exchange(false) && show)
            tdpycb::setFloatPars(myNode, {{"Showwindow", 0.0}});

        if (active && !myWindowRequested.exchange(true))
            createWindow(w, h);

        if (active && myWindowReady.load()) {
            // 座標が変わったらシーンを取り直す
            const double lat = in->getParDouble("Latitude");
            const double lon = in->getParDouble("Longitude");
            char sig[64];
            snprintf(sig, sizeof sig, "%.7f|%.7f", lat, lon);
            if (myLaSig != sig && !myLaBusy.exchange(true)) {
                myLaSig = sig;
                requestScene(lat, lon);
            }

            // --- 視線(Heading / Look Pitch)。私有 API 経由(冒頭コメント参照) ---
            if (show) {
                // ウインドウがマスター: ドラッグした視線を Heading へ書き戻す(yaw のみ)
                NSWindow* win2 = myWindow;
                auto alive2 = myAlive;
                auto* self2 = this;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!alive2->load() || !win2.contentView) return;
                    NSView* lav = tdmk::findLookAroundView(win2.contentView);
                    if (!lav) return;
                    @try {
                        const double y = [[lav valueForKey:@"presentationYaw"] doubleValue];
                        std::lock_guard<std::mutex> l(self2->myMutex);
                        self2->myLaYaw = y;
                        self2->myLaYawSerial++;
                    } @catch (NSException*) {}
                });
                double y; uint64_t serial;
                {
                    std::lock_guard<std::mutex> l(myMutex);
                    y = myLaYaw; serial = myLaYawSerial;
                }
                if (serial && serial != myLaYawApplied) {
                    double norm = fmod(y, 360.0); if (norm < 0) norm += 360.0;
                    if (fabs(norm - in->getParDouble("Heading")) > 0.05)
                        tdpycb::setFloatPars(myNode, {{"Heading", norm}});
                    myLaYawApplied = serial;
                    char c2[64]; snprintf(c2, sizeof c2, "%.2f|%.2f",
                                          norm, in->getParDouble("Lookpitch"));
                    myLaCamSig = c2;
                }
            } else {
                // パラメータがマスター: setPresentationYaw:pitch:animated: で適用。
                // API の pitch は**正=下**(実測)なので、パラメータは正=上に反転して渡す。
                // pitch の読み戻し口は無いため書き戻しは yaw のみ
                if (myLaRetry.exchange(false)) myLaCamSig.clear();
                const double hd = in->getParDouble("Heading");
                const double lp = in->getParDouble("Lookpitch");
                char c2[64]; snprintf(c2, sizeof c2, "%.2f|%.2f", hd, lp);
                if (myLaSyncSig.exchange(false)) {
                    myLaCamSig = c2;   // シーン本来の向きを尊重(勝手に適用しない)
                } else if (myLaCamSig != c2) {
                    myLaCamSig = c2;
                    NSWindow* win3 = myWindow;
                    auto alive2 = myAlive;
                    auto* self2 = this;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!alive2->load() || !win3.contentView) return;
                        NSView* lav = tdmk::findLookAroundView(win3.contentView);
                        if (!lav) { self2->myLaRetry = true; return; }  // 読込前 → 再適用
                        @try {
                            ((void (*)(id, SEL, double, double, BOOL))objc_msgSend)(lav,
                                sel_registerName("setPresentationYaw:pitch:animated:"),
                                hd, -lp, YES);
                        } @catch (NSException*) {}
                    });
                }
            }

            myAttrOn = in->getParInt("Attribution") != 0;
            {
                const std::string ap = tdmk::str(in, "Attributionpos", "bottomleft");
                myAttrPos = (ap == "bottomright") ? 1 : (ap == "topleft") ? 2
                          : (ap == "topright") ? 3 : 0;
            }
            // 毎 cook の抑え込み2件: 内蔵 Legal は常に隠す / レコグナイザは常に有効化
            {
                NSWindow* win2 = myWindow;
                auto alive2 = myAlive;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!alive2->load() || !win2.contentView) return;
                    tdmk::setLegalHidden(win2.contentView, true);
                    tdmk::enableAllGestures(win2.contentView);
                });
            }

            char ss[64];
            snprintf(ss, sizeof ss, "%d|%d|%d|%d", w, h, fps, show ? 1 : 0);
            if (myStreamSig != ss && !myStarting.load()) {
                myStreamSig = ss;
                reconfigure(w, h, fps, show);
            }
        }
        if (!active && myStream) {
            SCStream* st = myStream; myStream = nil;
            [st stopCaptureWithCompletionHandler:^(NSError*) {}];
            myRunning = false;
            myStreamSig.clear();
        }

        // --- 最新フレームをアップロード(bypass 復帰のため毎回) ---
        tdmk::Frame f;
        {
            std::lock_guard<std::mutex> l(myMutex);
            if (myFrame.bgra.empty()) return;
            f = myFrame;
        }
        if (myAttrOn.load()) myAttr.burn(f, myAttrPos.load());
        if (tdnc::fit(f.bgra, f.w, f.h, OP_PixelFormat::BGRA8Fixed)) {
            std::lock_guard<std::mutex> l(myMutex);
            myWarning = tdnc::kWarning;
        }
        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = f.w;
        ui.textureDesc.height = f.h;
        ui.textureDesc.pixelFormat = OP_PixelFormat::BGRA8Fixed;
        auto b = myContext->createOutputBuffer(f.bgra.size(), TOP_BufferFlags::None, nullptr);
        if (!b) return;
        memcpy(b->data, f.bgra.data(), f.bgra.size());
        out->uploadBuffer(&b, ui, nullptr);
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "Look Around";
        { OP_NumericParameter p("Active"); p.label = "Active"; p.page = P;
          p.defaultValues[0] = 1; m->appendToggle(p); }
        tdmk::addF(m, P, "Latitude",  "Latitude",  35.6595, -90, 90);
        tdmk::addF(m, P, "Longitude", "Longitude", 139.7005, -180, 180);
        tdmk::addF(m, P, "Heading",   "Heading",   0, 0, 360);
        // 見上げ(+)/見下ろし(-)。読み出し口が無いのでドラッグの書き戻しは無し
        tdmk::addF(m, P, "Lookpitch", "Look Pitch", 0, -90, 90);
        { OP_NumericParameter p("Attribution"); p.label = "Show Attribution"; p.page = P;
          p.defaultValues[0] = 1; m->appendToggle(p); }
        {
            OP_StringParameter p("Attributionpos");
            p.label = "Attribution Position"; p.page = P; p.defaultValue = "bottomleft";
            const char* n[] = {"bottomleft", "bottomright", "topleft", "topright"};
            const char* l[] = {"Bottom Left", "Bottom Right", "Top Left", "Top Right"};
            m->appendMenu(p, 4, n, l);
        }
        { OP_NumericParameter p("Fps");  p.label = "Capture FPS"; p.page = P;
          p.defaultValues[0] = 60; p.minSliders[0] = 1; p.maxSliders[0] = 120;
          p.minValues[0] = 1; p.maxValues[0] = 120; p.clampMins[0] = p.clampMaxes[0] = true;
          m->appendInt(p); }
        { OP_NumericParameter p("Showwindow"); p.label = "Show Window"; p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Restart"); p.label = "Restart"; p.page = P; m->appendPulse(p); }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Restart")) {
            myStreamSig.clear(); myLaSig.clear(); myLaCamSig.clear();
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 8; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        static const char* n[8] = {"executes", "frames", "running", "window_ready",
                                   "available", "width", "height", "capture_fps"};
        const float v[8] = {(float)myExec.load(), (float)myFrames.load(),
                            myRunning.load() ? 1.f : 0.f, myWindowReady.load() ? 1.f : 0.f,
                            myAvailable.load() ? 1.f : 0.f,
                            (float)myLastW.load(), (float)myLastH.load(), myFps.load()};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    void getWarningString(OP_String* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (!myWarning.empty()) s->setString(myWarning.c_str());
    }

    void receive(CMSampleBufferRef sample)
    {
        CVImageBufferRef px = CMSampleBufferGetImageBuffer(sample);
        if (!px) return;
        CVPixelBufferLockBaseAddress(px, kCVPixelBufferLock_ReadOnly);
        const uint32_t w = (uint32_t)CVPixelBufferGetWidth(px);
        const uint32_t h = (uint32_t)CVPixelBufferGetHeight(px);
        const size_t stride = CVPixelBufferGetBytesPerRow(px);
        const uint8_t* src = (const uint8_t*)CVPixelBufferGetBaseAddress(px);
        if (src && w && h) {
            tdmk::Frame f;
            f.w = w; f.h = h;
            f.bgra.resize((size_t)w * h * 4);
            for (uint32_t y = 0; y < h; y++)   // TD は bottom-up
                memcpy(f.bgra.data() + (size_t)(h - 1 - y) * w * 4, src + (size_t)y * stride, w * 4);
            {
                std::lock_guard<std::mutex> l(myMutex);
                f.serial = ++mySerial;
                myFrame = std::move(f);
            }
            myFrames++;
            myLastW = w; myLastH = h;
            const double now = CFAbsoluteTimeGetCurrent();
            if (now - myFpsT0 >= 1.0) {
                myFps = (float)(myFpsN / (now - myFpsT0));
                myFpsT0 = now; myFpsN = 0;
            }
            myFpsN++;
        }
        CVPixelBufferUnlockBaseAddress(px, kCVPixelBufferLock_ReadOnly);
    }

    void streamError(NSError* e)
    {
        myRunning = false;
        std::lock_guard<std::mutex> l(myMutex);
        myWarning = e ? (e.localizedDescription.UTF8String ?: "stream error") : "stream stopped";
    }

    std::atomic<bool> myStarting{false};
    SCStream* myStream = nil;
    std::atomic<bool> myRunning{false};
    std::string myStreamSig;

private:
    void createWindow(int w, int h)
    {
        auto alive = myAlive;
        auto* self = this;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load()) return;
            const CGFloat scale = NSScreen.mainScreen.backingScaleFactor ?: 2.0;
            NSRect r = NSMakeRect(0, 0, w / scale, h / scale);
            NSWindow* win = [[TDMKLAWindow alloc]
                initWithContentRect:r
                          styleMask:NSWindowStyleMaskBorderless
                            backing:NSBackingStoreBuffered
                              defer:NO];
            win.releasedWhenClosed = NO;
            win.title = @"MapKit LookAround";
            // ドラッグ用のバーは**別ウインドウ**(親子接続もしない)。タイトル付き・
            // 親子接続のウインドウは macOS 26 が角を丸め、丸角が取り込みに写る(実測)
            NSWindow* bar = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(0, 0, r.size.width, 0)
                          styleMask:(NSWindowStyleMaskTitled |
                                     NSWindowStyleMaskClosable)  // Closable が無いと閉じるボタンが出ない
                            backing:NSBackingStoreBuffered
                              defer:NO];
            bar.releasedWhenClosed = NO;
            bar.title = @"MapKit LookAround";
            [[bar standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
            [[bar standardWindowButton:NSWindowZoomButton] setHidden:YES];
            TDMKLABarDelegate* del = [TDMKLABarDelegate new];
            del->closeReq = self->myCloseReq;
            bar.delegate = del;
            self->myBarDelegate = del;
            self->myBarWindow = bar;
            NSWindow* mapWin = win;
            self->myMoveObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:NSWindowDidMoveNotification
                            object:bar
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification*) {
                const NSRect bf = bar.frame;
                [mapWin setFrameOrigin:NSMakePoint(bf.origin.x,
                                                   bf.origin.y - mapWin.frame.size.height)];
            }];
            win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorStationary |
                                     NSWindowCollectionBehaviorIgnoresCycle;
            // macOS では NSViewController(実測)。view だけ抜き取るとレスポンダチェーンが
            // 繋がらず操作が全滅する → contentViewController として正しく載せる
            self->myLookVC = [[MKLookAroundViewController alloc] init];
            self->myLookVC.navigationEnabled = YES;
            const NSRect keep = win.frame;   // contentViewController がサイズを変えることがある
            win.contentViewController = self->myLookVC;
            [win setFrame:keep display:YES];
            [win makeFirstResponder:self->myLookVC.view];
            self->myWindow = win;
            [win orderBack:nil];
            self->myWindowReady = true;
        });
    }

    void requestScene(double lat, double lon)
    {
        auto alive = myAlive;
        auto* self = this;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load()) { self->myLaBusy = false; return; }
            MKLookAroundSceneRequest* req = [[MKLookAroundSceneRequest alloc]
                initWithCoordinate:CLLocationCoordinate2DMake(lat, lon)];
            [req getSceneWithCompletionHandler:^(MKLookAroundScene* scene, NSError* e) {
                if (!alive->load()) return;
                self->myAvailable = (scene != nil);
                self->myLaSyncSig = true;   // 読込直後は適用せず、シグネチャの基準だけ合わせる
                if (self->myLookVC) self->myLookVC.scene = scene;
                {
                    std::lock_guard<std::mutex> l(self->myMutex);
                    self->myWarning = scene ? "" :
                        (e ? (e.localizedDescription.UTF8String ?: "no Look Around scene")
                           : "No Look Around imagery at this coordinate. Coverage is patchy.");
                }
                self->myLaBusy = false;
            }];
        });
    }

    // ウインドウのサイズ・見せ方を合わせ、ストリームを張り直す(仕組みは MapKitTOP.mm と同じ)
    void reconfigure(int w, int h, int fps, bool show)
    {
        myStarting = true;
        NSWindow* win = myWindow;
        SCStream* old = myStream; myStream = nil;
        if (old) [old stopCaptureWithCompletionHandler:^(NSError*) {}];
        myRunning = false;
        auto alive = myAlive;
        auto* self = this;
        __weak TDMKLAStreamOutput* weakOut = myOutput;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load() || !win) { self->myStarting = false; return; }
            const CGFloat scale = win.screen.backingScaleFactor ?: 2.0;
            NSRect r = win.frame;
            r.size = NSMakeSize(w / scale, h / scale);
            NSWindow* bar = self->myBarWindow;
            if (show) {
                [win setFrame:r display:NO];
                if (self->myShownOrigin.x != 0 || self->myShownOrigin.y != 0) {
                    [win setFrameOrigin:self->myShownOrigin];
                } else {
                    NSWindow* host = NSApp.mainWindow ?: NSApp.keyWindow;
                    const NSRect hf = host ? host.frame
                        : (win.screen ?: NSScreen.mainScreen).visibleFrame;
                    [win setFrameOrigin:NSMakePoint(NSMidX(hf) - r.size.width / 2,
                                                    NSMidY(hf) - r.size.height / 2)];
                }
                win.alphaValue = 1.0;
                win.ignoresMouseEvents = NO;
                win.level = NSFloatingWindowLevel;
                [win makeKeyAndOrderFront:nil];
                [bar setContentSize:NSMakeSize(win.frame.size.width, 0)];
                [bar setFrameOrigin:NSMakePoint(win.frame.origin.x, NSMaxY(win.frame))];
                bar.level = NSFloatingWindowLevel;
                [bar orderFront:nil];
                self->myWasShown = true;
            } else {
                // 隠し方の実測は MapKitTOP.mm を参照(画面外=凍結 / デスクトップレベル=灰色 /
                // アルファ=取り込みが暗くなる → 右下に kSliver pt だけ残す)
                if (self->myWasShown) {
                    self->myShownOrigin = win.frame.origin;
                    self->myWasShown = false;
                }
                [bar orderOut:nil];
                [win setFrame:r display:NO];
                win.alphaValue = 1.0;
                win.ignoresMouseEvents = YES;
                win.level = NSFloatingWindowLevel;
                NSScreen* scr = win.screen ?: NSScreen.mainScreen;
                const NSRect sf = scr.frame;
                [win setFrameOrigin:NSMakePoint(NSMaxX(sf) - tdmk::kSliver,
                                                NSMinY(sf) - r.size.height + tdmk::kSliver)];
                [win orderFront:nil];
            }
            const CGWindowID wid = (CGWindowID)win.windowNumber;

            [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                       onScreenWindowsOnly:NO
                completionHandler:^(SCShareableContent* c, NSError* e) {
                TDMKLAStreamOutput* o = weakOut;
                if (!o || !o.owner || !alive->load()) return;
                auto* owner = static_cast<MapKitLookAroundTOP*>(o.owner);
                if (e || !c) { owner->streamError(e); owner->myStarting = false; return; }
                SCWindow* target = nil;
                for (SCWindow* x in c.windows)
                    if (x.windowID == wid) { target = x; break; }
                if (!target) {
                    owner->myStreamSig.clear();
                    owner->myStarting = false;
                    return;
                }
                SCContentFilter* filter =
                    [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];
                SCStreamConfiguration* cfg = [SCStreamConfiguration new];
                cfg.width = w; cfg.height = h;
                cfg.minimumFrameInterval = CMTimeMake(1, fps);
                cfg.pixelFormat = kCVPixelFormatType_32BGRA;
                cfg.showsCursor = NO;
                cfg.queueDepth = 3;
                if (@available(macOS 14.0, *)) cfg.ignoreShadowsSingleWindow = YES;

                SCStream* st = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:o];
                NSError* add = nil;
                [st addStreamOutput:o type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                               error:&add];
                if (add) { owner->streamError(add); owner->myStarting = false; return; }
                owner->myStream = st;
                [st startCaptureWithCompletionHandler:^(NSError* se) {
                    TDMKLAStreamOutput* o2 = weakOut;
                    if (!o2 || !o2.owner) return;
                    auto* ow = static_cast<MapKitLookAroundTOP*>(o2.owner);
                    ow->myStarting = false;
                    if (se) ow->streamError(se);
                    else ow->myRunning = true;
                }];
            }];
        });
    }

    TOP_Context* myContext;
    std::shared_ptr<std::atomic<bool>> myAlive;
    TDMKLAStreamOutput* myOutput = nil;
    NSWindow* myWindow = nil;
    MKLookAroundViewController* myLookVC = nil;
    std::string myLaCamSig, myLaSig, myWarning;
    double myLaYaw = 0;
    uint64_t myLaYawSerial = 0, myLaYawApplied = 0;
    std::atomic<bool> myLaSyncSig{false}, myLaRetry{false};
    std::mutex myMutex;
    tdmk::Frame myFrame;
    tdmk::Attribution myAttr;
    uint64_t mySerial = 0;
    double myFpsT0 = 0;
    int myFpsN = 0;
    std::atomic<uint64_t> myExec{0}, myFrames{0};
    std::atomic<uint32_t> myLastW{0}, myLastH{0};
    std::atomic<float> myFps{0};
    std::atomic<bool> myWindowRequested{false}, myWindowReady{false};
    std::atomic<bool> myAttrOn{true};
    std::atomic<int> myAttrPos{0};
    std::atomic<bool> myAvailable{true}, myLaBusy{false};
    const OP_NodeInfo* myNode;
    NSPoint myShownOrigin = {0, 0};
    NSWindow* myBarWindow = nil;
    TDMKLABarDelegate* myBarDelegate = nil;
    std::shared_ptr<std::atomic<bool>> myCloseReq =
        std::make_shared<std::atomic<bool>>(false);
    id myMoveObserver = nil;
    bool myWasShown = false;
};

}  // namespace

@implementation TDMKLAStreamOutput
- (void)stream:(SCStream*)s didOutputSampleBuffer:(CMSampleBufferRef)b ofType:(SCStreamOutputType)t
{
    if (t == SCStreamOutputTypeScreen && self.owner)
        static_cast<MapKitLookAroundTOP*>(self.owner)->receive(b);
}
- (void)stream:(SCStream*)s didStopWithError:(NSError*)e
{
    if (self.owner) static_cast<MapKitLookAroundTOP*>(self.owner)->streamError(e);
}
@end

extern "C" {

DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i)
{
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Mapkitlookaround");
    i->customOPInfo.opLabel->setString("MapKit LookAround");
    i->customOPInfo.opIcon->setString("MLA");
    if (i->customOPInfo.opHelpURL)
        i->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/MapKit/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
    i->customOPInfo.cookOnStart = true;   // 出力を見られていなくてもストリームを維持する
}

DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c)
{
    return new MapKitLookAroundTOP(i, c);
}

DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*)
{
    delete static_cast<MapKitLookAroundTOP*>(i);
}

}
