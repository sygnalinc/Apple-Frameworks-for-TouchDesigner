// MapKit Live TOP — 常駐 MKMapView を ScreenCaptureKit で取り込み、3D地図の中を
// リアルタイムに飛び回れるようにする。
//
// **なぜこの構成か(実測の結論)**:
// - MKMapSnapshotter は1回あたり約0.9秒の固定費(32x32でも885ms)。並列にしても
//   約1.4枚/秒で頭打ち = ライブの飛行は不可能
// - マップ.app が滑らかなのは**レンダラーを常駐させている**から。同じことをするには
//   MKMapView のインスタンスを生かしっぱなしにする必要がある
// - ただし MKMapView は CAMetalLayer のスワップチェーンで表示するため、プロセス内の
//   取り込みは全滅(cacheDisplayInRect / renderInContext / CARenderer とも真っ白を実測)。
//   完成した絵の所有者はウインドウサーバーなので、**ScreenCaptureKit の
//   initWithDesktopIndependentWindow: で自分のウインドウを取り込む**のが唯一の公式ルート
// - 帰属表示は MKMapView 自身が描く(Apple ロゴ + Legal)ので焼き込み不要
//
// 制約: 実ウインドウが1枚必要(既定では最背面・デスクトップレベルに隠す)。
// 画面収録の TCC 許可が要る(Screen Capture TOP と同じ)。
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <MapKit/MapKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "../common/NonCommercialLimit.h"
using namespace TD;

namespace { class MapKitLiveTOP; }

@interface TDMapLiveOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, assign) void* owner;
@end

namespace {

struct Frame {
    std::vector<uint8_t> bgra;
    uint32_t w = 0, h = 0;
    uint64_t serial = 0;
};

class MapKitLiveTOP final : public TOP_CPlusPlusBase {
public:
    MapKitLiveTOP(const OP_NodeInfo*, TOP_Context* c)
        : myContext(c), myAlive(std::make_shared<std::atomic<bool>>(true))
    {
        myOutput = [TDMapLiveOutput new];
        myOutput.owner = this;
    }

    ~MapKitLiveTOP() override
    {
        *myAlive = false;
        myOutput.owner = nullptr;
        SCStream* st = myStream; myStream = nil;
        NSWindow* w = myWindow; myWindow = nil;
        myMapView = nil;
        if (st) [st stopCaptureWithCompletionHandler:^(NSError*) {}];
        // ウインドウは AppKit の所有物なのでメインスレッドで閉じる
        dispatch_async(dispatch_get_main_queue(), ^{ [w close]; });
    }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrame = true;   // ストリームは cook と無関係に流れてくるので常に回す
    }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        const bool active = in->getParInt("Active") != 0;

        // 出力解像度は Common ページから(入力なしの生成系と同じ扱い)
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

        // --- ウインドウ+MKMapView(メインスレッドで一度だけ作る) ---
        if (active && !myWindowRequested.exchange(true)) createWindow(w, h);

        // --- カメラ。毎 cook 送る(TD 側で lat/heading をアニメーションさせる前提) ---
        if (active && myWindowReady.load()) {
            const double lat = in->getParDouble("Latitude");
            const double lon = in->getParDouble("Longitude");
            const double dist = std::max(50.0, in->getParDouble("Distance"));
            const double pitch = in->getParDouble("Pitch");
            const double heading = in->getParDouble("Heading");
            char cam[160];
            snprintf(cam, sizeof cam, "%.7f|%.7f|%.2f|%.2f|%.2f", lat, lon, dist, pitch, heading);
            if (myCamSig != cam) {
                myCamSig = cam;
                MKMapView* mv = myMapView;
                auto alive = myAlive;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!alive->load() || !mv) return;
                    @try {
                        mv.camera = [MKMapCamera cameraLookingAtCenterCoordinate:
                                        CLLocationCoordinate2DMake(lat, lon)
                                     fromDistance:dist pitch:pitch heading:heading];
                    } @catch (NSException*) {}
                });
            }

            // --- 地図のスタイル(変わったときだけ) ---
            std::string style = str(in, "Style", "standard");
            std::string elev  = str(in, "Elevation", "realistic");
            const bool poi = in->getParInt("Poi") != 0;
            const bool dark = in->getParInt("Dark") != 0;
            const std::string cfgSig = style + "|" + elev + (poi ? "|1" : "|0") + (dark ? "|1" : "|0");
            if (myCfgSig != cfgSig) {
                myCfgSig = cfgSig;
                applyConfig(style, elev, poi, dark);
            }

            // --- ウインドウの見せ方 / サイズ / ストリーム ---
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
        Frame f;
        {
            std::lock_guard<std::mutex> l(myMutex);
            if (myFrame.bgra.empty()) return;
            f = myFrame;
        }
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
        const char* P = "MapKit Live";
        { OP_NumericParameter p("Active"); p.label = "Active"; p.page = P;
          p.defaultValues[0] = 1; m->appendToggle(p); }
        addF(m, P, "Latitude",  "Latitude",  35.6595, -90, 90);
        addF(m, P, "Longitude", "Longitude", 139.7005, -180, 180);
        addF(m, P, "Distance",  "Distance (m)", 800, 50, 200000);
        addF(m, P, "Pitch",     "Pitch",     60, 0, 80);
        addF(m, P, "Heading",   "Heading",   0, 0, 360);
        {
            OP_StringParameter p("Style");
            p.label = "Style"; p.page = P; p.defaultValue = "standard";
            const char* n[] = {"standard", "muted", "satellite", "hybrid"};
            const char* l[] = {"Standard", "Muted", "Satellite", "Hybrid"};
            m->appendMenu(p, 4, n, l);
        }
        {
            OP_StringParameter p("Elevation");
            p.label = "Elevation"; p.page = P; p.defaultValue = "realistic";
            const char* n[] = {"flat", "realistic"};
            const char* l[] = {"Flat", "Realistic (3D)"};
            m->appendMenu(p, 2, n, l);
        }
        { OP_NumericParameter p("Poi");  p.label = "Show Points Of Interest"; p.page = P;
          p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Dark"); p.label = "Dark Appearance"; p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Fps");  p.label = "Capture FPS"; p.page = P;
          p.defaultValues[0] = 60; p.minSliders[0] = 1; p.maxSliders[0] = 120;
          p.minValues[0] = 1; p.maxValues[0] = 120; p.clampMins[0] = p.clampMaxes[0] = true;
          m->appendInt(p); }
        // 既定は最背面(デスクトップレベル)に隠す。確認したいときだけ前へ出す
        { OP_NumericParameter p("Showwindow"); p.label = "Show Window"; p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Restart"); p.label = "Restart"; p.page = P; m->appendPulse(p); }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Restart")) { myStreamSig.clear(); myCamSig.clear(); myCfgSig.clear(); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 7; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        static const char* n[7] = {"executes", "frames", "running", "window_ready",
                                   "width", "height", "capture_fps"};
        // capture_fps: 直近1秒に受け取ったフレーム数
        const float v[7] = {(float)myExec.load(), (float)myFrames.load(),
                            myRunning.load() ? 1.f : 0.f, myWindowReady.load() ? 1.f : 0.f,
                            (float)myLastW.load(), (float)myLastH.load(), myFps.load()};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    void getWarningString(OP_String* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (!myWarning.empty()) s->setString(myWarning.c_str());
    }

    // --- ストリーム受信(SCK のキューから呼ばれる) ---
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
            Frame f;
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
            // 実効fps(1秒窓)
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

private:
    static std::string str(const OP_Inputs* in, const char* k, const char* d)
    {
        const char* v = in->getParString(k);
        return v && *v ? v : d;
    }
    static void addF(OP_ParameterManager* m, const char* pg, const char* n, const char* l,
                     double def, double lo, double hi)
    {
        OP_NumericParameter p(n);
        p.label = l; p.page = pg;
        p.defaultValues[0] = def;
        p.minSliders[0] = lo; p.maxSliders[0] = hi;
        p.minValues[0] = lo;  p.maxValues[0] = hi;
        p.clampMins[0] = p.clampMaxes[0] = true;
        m->appendFloat(p);
    }

    void createWindow(int w, int h)
    {
        auto alive = myAlive;
        auto* self = this;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load()) return;
            const CGFloat scale = NSScreen.mainScreen.backingScaleFactor ?: 2.0;
            NSRect r = NSMakeRect(0, 0, w / scale, h / scale);
            NSWindow* win = [[NSWindow alloc] initWithContentRect:r
                                                        styleMask:NSWindowStyleMaskBorderless
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
            win.releasedWhenClosed = NO;
            // Mission Control やスペース移動に巻き込まれないように
            win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorStationary |
                                     NSWindowCollectionBehaviorIgnoresCycle;
            MKMapView* mv = [[MKMapView alloc] initWithFrame:r];
            mv.showsCompass = NO;
            mv.showsZoomControls = NO;
            win.contentView = mv;
            self->myMapView = mv;
            self->myWindow = win;
            [win orderBack:nil];
            self->myWindowReady = true;
        });
    }

    void applyConfig(std::string style, std::string elev, bool poi, bool dark)
    {
        MKMapView* mv = myMapView;
        NSWindow* win = myWindow;
        auto alive = myAlive;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load() || !mv) return;
            @try {
                MKMapConfiguration* cfg = nil;
                if (style == "satellite") {
                    cfg = [[MKImageryMapConfiguration alloc] init];
                } else if (style == "hybrid") {
                    MKHybridMapConfiguration* hc = [[MKHybridMapConfiguration alloc] init];
                    if (!poi) hc.pointOfInterestFilter =
                        [MKPointOfInterestFilter filterExcludingAllCategories];
                    cfg = hc;
                } else {
                    MKStandardMapConfiguration* st = [[MKStandardMapConfiguration alloc] init];
                    st.emphasisStyle = (style == "muted") ? MKStandardMapEmphasisStyleMuted
                                                          : MKStandardMapEmphasisStyleDefault;
                    if (!poi) st.pointOfInterestFilter =
                        [MKPointOfInterestFilter filterExcludingAllCategories];
                    cfg = st;
                }
                cfg.elevationStyle = (elev == "realistic") ? MKMapElevationStyleRealistic
                                                           : MKMapElevationStyleFlat;
                mv.preferredConfiguration = cfg;
                win.appearance = [NSAppearance appearanceNamed:
                    dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
            } @catch (NSException*) {}
        });
    }

    // ウインドウのサイズ・見せ方を合わせ、ストリームを張り直す
    void reconfigure(int w, int h, int fps, bool show)
    {
        myStarting = true;
        NSWindow* win = myWindow;
        MKMapView* mv = myMapView;
        SCStream* old = myStream; myStream = nil;
        if (old) [old stopCaptureWithCompletionHandler:^(NSError*) {}];
        myRunning = false;
        auto alive = myAlive;
        auto* self = this;
        __weak TDMapLiveOutput* weakOut = myOutput;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load() || !win) { self->myStarting = false; return; }
            const CGFloat scale = win.screen.backingScaleFactor ?: 2.0;
            NSRect r = win.frame;
            r.size = NSMakeSize(w / scale, h / scale);
            [win setFrame:r display:YES];
            mv.frame = NSMakeRect(0, 0, r.size.width, r.size.height);
            if (show) {
                win.level = NSNormalWindowLevel;
                [win orderFront:nil];
            } else {
                // デスクトップレベル = 壁紙の上・アイコンの下。ユーザーの操作に一切割り込まない
                win.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey);
                [win orderBack:nil];
            }
            const CGWindowID wid = (CGWindowID)win.windowNumber;

            // ウインドウサーバーに載った自分のウインドウを SCK で探して取り込む
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                       onScreenWindowsOnly:NO
                completionHandler:^(SCShareableContent* c, NSError* e) {
                TDMapLiveOutput* o = weakOut;
                if (!o || !o.owner || !alive->load()) return;
                auto* owner = static_cast<MapKitLiveTOP*>(o.owner);
                if (e || !c) { owner->streamError(e); owner->myStarting = false; return; }
                SCWindow* target = nil;
                for (SCWindow* x in c.windows)
                    if (x.windowID == wid) { target = x; break; }
                if (!target) {
                    // まだ載っていない。sig を空にして次の cook でやり直す
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
                SCStream* st = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:o];
                NSError* add = nil;
                [st addStreamOutput:o type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                               error:&add];
                if (add) { owner->streamError(add); owner->myStarting = false; return; }
                owner->myStream = st;
                [st startCaptureWithCompletionHandler:^(NSError* se) {
                    TDMapLiveOutput* o2 = weakOut;
                    if (!o2 || !o2.owner) return;
                    auto* ow = static_cast<MapKitLiveTOP*>(o2.owner);
                    ow->myStarting = false;
                    if (se) ow->streamError(se);
                    else ow->myRunning = true;
                }];
            }];
        });
    }

    TOP_Context* myContext;
    std::shared_ptr<std::atomic<bool>> myAlive;
    TDMapLiveOutput* myOutput = nil;
    SCStream* myStream = nil;
    NSWindow* myWindow = nil;
    MKMapView* myMapView = nil;
    std::mutex myMutex;
    Frame myFrame;
    std::string myWarning, myCamSig, myCfgSig, myStreamSig;
    uint64_t mySerial = 0;
    double myFpsT0 = 0;
    int myFpsN = 0;
    std::atomic<uint64_t> myExec{0}, myFrames{0};
    std::atomic<uint32_t> myLastW{0}, myLastH{0};
    std::atomic<float> myFps{0};
    std::atomic<bool> myWindowRequested{false}, myWindowReady{false};
    std::atomic<bool> myStarting{false}, myRunning{false};
};

}  // namespace

@implementation TDMapLiveOutput
- (void)stream:(SCStream*)s didOutputSampleBuffer:(CMSampleBufferRef)b ofType:(SCStreamOutputType)t
{
    if (t == SCStreamOutputTypeScreen && self.owner)
        static_cast<MapKitLiveTOP*>(self.owner)->receive(b);
}
- (void)stream:(SCStream*)s didStopWithError:(NSError*)e
{
    if (self.owner) static_cast<MapKitLiveTOP*>(self.owner)->streamError(e);
}
@end

extern "C" {

DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i)
{
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Mapkitlive");
    i->customOPInfo.opLabel->setString("MapKit Live");
    i->customOPInfo.opIcon->setString("MKL");
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
    return new MapKitLiveTOP(i, c);
}

DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*)
{
    delete static_cast<MapKitLiveTOP*>(i);
}

}
