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
#include "../common/PyCallbacksBootstrap.h"
using namespace TD;

namespace { class MapKitLiveTOP; }

// ボーダーレスウインドウは既定で key になれず、マウスドラッグ系の操作が届かない
@interface TDMapLiveWindow : NSWindow
@end
@implementation TDMapLiveWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface TDMapLiveOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, assign) void* owner;
@end

namespace {

struct Frame {
    std::vector<uint8_t> bgra;
    uint32_t w = 0, h = 0;
    uint64_t serial = 0;
};

// MKMapView の帰属表示(Legal リンク)をビュー階層から探して隠す。
// 公開 API には表示/非表示の口が無い。Apple のガイドライン上、人に見せる地図には
// 帰属表示が求められる点は README に明記(消す判断は利用者のもの)
static void setLegalHidden(NSView* v, bool hidden)
{
    for (NSView* sub in v.subviews) {
        NSString* cls = NSStringFromClass(sub.class);
        if ([cls containsString:@"Attribution"] || [cls containsString:@"Legal"])
            sub.hidden = hidden;
        else
            setLegalHidden(sub, hidden);
    }
}

class MapKitLiveTOP final : public TOP_CPlusPlusBase {
public:
    MapKitLiveTOP(const OP_NodeInfo* ni, TOP_Context* c)
        : myNode(ni), myContext(c), myAlive(std::make_shared<std::atomic<bool>>(true))
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
        NSWindow* bw = myBarWindow; myBarWindow = nil;
        id obs = myMoveObserver; myMoveObserver = nil;
        if (obs) [[NSNotificationCenter defaultCenter] removeObserver:obs];
        myMapView = nil;
        if (st) [st stopCaptureWithCompletionHandler:^(NSError*) {}];
        // ウインドウは AppKit の所有物なのでメインスレッドで閉じる
        dispatch_async(dispatch_get_main_queue(), ^{ [bw close]; [w close]; });
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
        // 初期カメラをパラメータから入れる。入れないと地図既定の全景で開き、
        // Show Window オン(=ウインドウがマスター)だとその値がパラメータへ逆流する
        if (active && !myWindowRequested.exchange(true))
            createWindow(w, h,
                         in->getParDouble("Latitude"), in->getParDouble("Longitude"),
                         std::max(50.0, in->getParDouble("Distance")),
                         in->getParDouble("Pitch"), in->getParDouble("Heading"));

        // --- カメラは双方向 ---
        // Show Window オン = **ウインドウがマスター**。トラックパッド/マウスで動かした
        // カメラを読み取り、パラメータへ書き戻す(結果が TOP のプロパティに残る)。
        // オフ = 従来どおりパラメータがマスターで、式や CHOP から飛ばせる
        if (active && myWindowReady.load()) {
            if (show) {
                // メインスレッドにカメラを読ませ、cook はその写しを見る
                MKMapView* mv = myMapView;
                auto alive = myAlive;
                auto* self = this;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!alive->load() || !mv) return;
                    MKMapCamera* c = mv.camera;
                    std::lock_guard<std::mutex> l(self->myMutex);
                    self->myPulled[0] = c.centerCoordinate.latitude;
                    self->myPulled[1] = c.centerCoordinate.longitude;
                    self->myPulled[2] = c.centerCoordinateDistance;
                    self->myPulled[3] = c.pitch;
                    self->myPulled[4] = c.heading;
                    self->myPulledSerial++;
                });
                double v[5]; uint64_t serial;
                {
                    std::lock_guard<std::mutex> l(myMutex);
                    memcpy(v, myPulled, sizeof v);
                    serial = myPulledSerial;
                }
                if (serial && serial != myAppliedPull) {
                    const bool moved =
                        fabs(v[0] - in->getParDouble("Latitude"))  > 1e-7 ||
                        fabs(v[1] - in->getParDouble("Longitude")) > 1e-7 ||
                        fabs(v[2] - in->getParDouble("Distance"))  > 0.01 ||
                        fabs(v[3] - in->getParDouble("Pitch"))     > 0.01 ||
                        fabs(v[4] - in->getParDouble("Heading"))   > 0.01;
                    if (moved) {
                        tdpycb::setFloatPars(myNode, {{"Latitude", v[0]}, {"Longitude", v[1]},
                                                      {"Distance", v[2]}, {"Pitch", v[3]},
                                                      {"Heading", v[4]}});
                    }
                    myAppliedPull = serial;
                    // 書き戻した値を push 側の基準にもして、オフに戻した瞬間に飛ばないようにする
                    char cam[160];
                    snprintf(cam, sizeof cam, "%.7f|%.7f|%.2f|%.2f|%.2f",
                             v[0], v[1], v[2], v[3], v[4]);
                    myCamSig = cam;
                }
            } else {
                const double lat = in->getParDouble("Latitude");
                const double lon = in->getParDouble("Longitude");
                const double dist = std::max(50.0, in->getParDouble("Distance"));
                const double pitch = in->getParDouble("Pitch");
                const double heading = in->getParDouble("Heading");
                char cam[160];
                snprintf(cam, sizeof cam, "%.7f|%.7f|%.2f|%.2f|%.2f",
                         lat, lon, dist, pitch, heading);
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
            }

            // --- 地図のスタイル(変わったときだけ) ---
            std::string style = str(in, "Style", "standard");
            std::string elev  = str(in, "Elevation", "realistic");
            const bool poi = in->getParInt("Poi") != 0;
            const bool dark = in->getParInt("Dark") != 0;
            const bool legal = in->getParInt("Legallink") != 0;
            myLegalHidden = !legal;
            const std::string cfgSig = style + "|" + elev + (poi ? "|1" : "|0") +
                                       (dark ? "|1" : "|0") + (legal ? "|1" : "|0");
            if (myCfgSig != cfgSig) {
                myCfgSig = cfgSig;
                applyConfig(style, elev, poi, dark);
            }
            // ラベルはタイル読込後に再出現することがあるので、隠す指定のあいだは毎 cook 抑え込む
            if (myLegalHidden.load()) {
                MKMapView* mv2 = myMapView;
                auto alive2 = myAlive;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (alive2->load() && mv2) setLegalHidden(mv2, true);
                });
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
        {
            // ウインドウ側で大きくズームアウトした値も受けるため、上限はクランプしない
            OP_NumericParameter p("Distance");
            p.label = "Distance (m)"; p.page = P;
            p.defaultValues[0] = 800;
            p.minSliders[0] = 50; p.maxSliders[0] = 2000000;
            p.minValues[0] = 1; p.clampMins[0] = true; p.clampMaxes[0] = false;
            m->appendFloat(p);
        }
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
        // 帰属表示。Apple の規約上は表示が求められるので既定オン
        { OP_NumericParameter p("Legallink"); p.label = "Show Legal Link"; p.page = P;
          p.defaultValues[0] = 1; m->appendToggle(p); }
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

    void createWindow(int w, int h, double lat, double lon, double dist,
                      double pitch, double heading)
    {
        auto alive = myAlive;
        auto* self = this;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load()) return;
            const CGFloat scale = NSScreen.mainScreen.backingScaleFactor ?: 2.0;
            NSRect r = NSMakeRect(0, 0, w / scale, h / scale);
            NSWindow* win = [[TDMapLiveWindow alloc]
                initWithContentRect:r
                          styleMask:NSWindowStyleMaskBorderless
                            backing:NSBackingStoreBuffered
                              defer:NO];
            win.releasedWhenClosed = NO;
            win.title = @"MapKit Live";
            // ドラッグ用のバーは**別ウインドウ**にして親にする。地図ウインドウを
            // タイトル付きにすると下角まで丸くなり、丸角が TOP に写ってしまう
            // (実際にユーザーに指摘された)。バーを掴めば子の地図がついてくる
            NSWindow* bar = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(0, 0, r.size.width, 0)
                          styleMask:NSWindowStyleMaskTitled
                            backing:NSBackingStoreBuffered
                              defer:NO];
            bar.releasedWhenClosed = NO;
            bar.title = @"MapKit Live";
            [[bar standardWindowButton:NSWindowCloseButton] setHidden:YES];
            [[bar standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
            [[bar standardWindowButton:NSWindowZoomButton] setHidden:YES];
            self->myBarWindow = bar;
            // バーをドラッグしたら地図をその真下へ追従させる
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
            // Mission Control やスペース移動に巻き込まれないように
            win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorStationary |
                                     NSWindowCollectionBehaviorIgnoresCycle;
            MKMapView* mv = [[MKMapView alloc] initWithFrame:win.contentView.bounds];
            mv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            @try {
                mv.camera = [MKMapCamera cameraLookingAtCenterCoordinate:
                                CLLocationCoordinate2DMake(lat, lon)
                             fromDistance:dist pitch:pitch heading:heading];
            } @catch (NSException*) {}
            // 標準のマップと同じ操作(スクロール=パン / ピンチ=ズーム / 2本指回転 /
            // Option+スクロール=チルト)。コントロール類は Show Window 時だけ出す
            mv.zoomEnabled = YES;
            mv.scrollEnabled = YES;
            mv.rotateEnabled = YES;
            mv.pitchEnabled = YES;
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
        auto* self2 = this;
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
                setLegalHidden(mv, self2->myLegalHidden.load());
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
            NSWindow* bar = myBarWindow;
            if (show) {
                // 地図ウインドウは**常にボーダーレス**(角が四角のまま取り込まれる)。
                // ドラッグはバー(親ウインドウ)が担う
                [win setFrame:r display:NO];
                if (myShownOrigin.x != 0 || myShownOrigin.y != 0)
                    [win setFrameOrigin:myShownOrigin];   // 前回表示していた場所へ戻す
                win.alphaValue = 1.0;
                win.ignoresMouseEvents = NO;
                // TD のウインドウをクリックしても隠れないように浮かせる
                win.level = NSFloatingWindowLevel;
                [win makeKeyAndOrderFront:nil];
                [bar setContentSize:NSMakeSize(win.frame.size.width, 0)];
                [bar setFrameOrigin:NSMakePoint(win.frame.origin.x, NSMaxY(win.frame))];
                bar.level = NSFloatingWindowLevel;
                // **親子接続はしない**。macOS 26 は接続したウインドウ群をまとめて
                // 角丸にするため、地図の角まで丸くなって取り込みに写った(実測)。
                // バーの移動は通知(NSWindowDidMoveNotification)で追従させる
                [bar orderFront:nil];
                myWasShown = true;
            } else {
                // 隠すときはボーダーレス(角が四角)。**2つの罠を実測で踏んだ**:
                // ①デスクトップレベルに置くと遮蔽扱いになり MapKit が描画を止めて灰色になる
                // ②アルファを下げると SCK の取り込みまで暗くなる(合成後の見た目が返る)
                // → アルファ 1.0 のまま、**大部分を画面外へ出して 8pt だけ画面内に残す**。
                //   完全に画面外だと描画が止まるので端を残す(Translate の極小ウインドウと同じ発想)。
                //   取り込みは desktopIndependent なので画面外の部分も丸ごと取れる
                if (myWasShown) { myShownOrigin = win.frame.origin; myWasShown = false; }
                [bar orderOut:nil];
                [win setFrame:r display:NO];
                win.alphaValue = 1.0;
                win.ignoresMouseEvents = YES;
                win.level = NSFloatingWindowLevel;
                NSScreen* scr = win.screen ?: NSScreen.mainScreen;
                const NSRect sf = scr.frame;
                [win setFrameOrigin:NSMakePoint(NSMaxX(sf) - 8, NSMinY(sf) - r.size.height + 8)];
                [win orderFront:nil];
            }
            mv.showsCompass = NO;   // コントロール類は TOP に写るので常に出さない
            mv.showsZoomControls = NO;
            if (@available(macOS 11.0, *)) mv.showsPitchControl = NO;
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
                if (@available(macOS 14.0, *)) cfg.ignoreShadowsSingleWindow = YES;

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
    std::atomic<bool> myLegalHidden{false};
    std::atomic<bool> myStarting{false}, myRunning{false};
    const OP_NodeInfo* myNode;
    double myPulled[5] = {};
    uint64_t myPulledSerial = 0, myAppliedPull = 0;
    NSPoint myShownOrigin = {0, 0};
    NSWindow* myBarWindow = nil;
    id myMoveObserver = nil;
    bool myWasShown = false;
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
