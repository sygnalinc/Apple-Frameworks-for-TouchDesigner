// MapKit MapView TOP — 常駐 MKMapView を ScreenCaptureKit で取り込み、3D地図の中を
// リアルタイムに飛び回れるようにする。街並みの実写は MapKit LookAround TOP(別op)。
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
//
// 制約: 実ウインドウが1枚必要(既定では画面右下に 1pt だけ残して隠す)。
// 画面収録の TCC 許可が要る(Screen Capture TOP と同じ)。
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

namespace { class MapKitMapViewTOP; }

// ボーダーレスウインドウは既定で key になれず、マウスドラッグ系の操作が届かない。
// クラス名はバンドル固有(MapKitShared.h 冒頭の注意を参照)
@interface TDMapWindow : NSWindow
@end
@implementation TDMapWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

// バーの閉じるボタン: 実際には閉じず、フラグを立てて cook 側が Show Window をオフにする
// (ウインドウは使い回すので破棄しない。AppKit コールバックから TD には触らない —
//  CoreText のフォントパネルで踏んだ THREAD CONFLICT と同じ理由でフラグ渡し)
@interface TDMapBarDelegate : NSObject <NSWindowDelegate>
{
@public
    std::shared_ptr<std::atomic<bool>> closeReq;
    void (^onClose)(void);
}
@end
@implementation TDMapBarDelegate
- (BOOL)windowShouldClose:(NSWindow*)w
{
    // **cook を待たずにその場で畳む**。cook が止まっているとフラグを読む人が
    // いないので、ボタンが効かないまま固まって見える(実際に踏んだ)
    if (onClose) onClose();
    if (closeReq) closeReq->store(true);
    return NO;
}
@end

@interface TDMapStreamOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, assign) void* owner;
@end

namespace {

// Markers DAT の1行。u/v は MKMapView 自身の射影(convertCoordinate:toPointToView:)なので
// 3D のパース・ピッチ・ヘディングに完全一致する
struct Marker {
    std::string name;
    double lat = 0, lon = 0;
    float u = 0, v = 0;
    bool visible = false;
};

class MapKitMapViewTOP final : public TOP_CPlusPlusBase {
public:
    MapKitMapViewTOP(const OP_NodeInfo* ni, TOP_Context* c)
        : myNode(ni), myContext(c), myAlive(std::make_shared<std::atomic<bool>>(true))
    {
        myOutput = [TDMapStreamOutput new];
        myOutput.owner = this;
    }

    ~MapKitMapViewTOP() override
    {
        *myAlive = false;
        if (myWatchdog) { dispatch_source_cancel(myWatchdog); myWatchdog = nil; }
        myOutput.owner = nullptr;
        SCStream* st = myStream; myStream = nil;
        NSWindow* w = myWindow; myWindow = nil;
        NSWindow* bw = myBarWindow; myBarWindow = nil;
        myBarDelegate = nil;
        id obs = myMoveObserver; myMoveObserver = nil;
        if (obs) [[NSNotificationCenter defaultCenter] removeObserver:obs];
        myMapView = nil;
        if (st) [st stopCaptureWithCompletionHandler:^(NSError*) {}];
        // ウインドウは AppKit の所有物なのでメインスレッドで閉じる
        // TD 終了時はメインスレッドから破棄されるので、非同期にすると
        // 実行される前にプロセスが畳まれてウインドウが残って見える
        void (^closeAll)(void) = ^{
            bw.delegate = nil;   // NSWindow.delegate は weak でない(assign)ので明示的に切る
            [bw orderOut:nil]; [w orderOut:nil];
            [bw close]; [w close];
        };
        if ([NSThread isMainThread]) closeAll();
        else dispatch_async(dispatch_get_main_queue(), closeAll);
    }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrame = true;   // ストリームは cook と無関係に流れてくるので常に回す
    }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        myLastCook = CFAbsoluteTimeGetCurrent();
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
        bool show = in->getParInt("Showwindow") != 0;
        // ウインドウを畳んだ後(cook 停止・Active オフ・閉じるボタン)と**ロード直後**は、
        // Show Window を 0 に戻して閉じたままにする。cook が戻っても勝手に開かない /
        // 次回 TD 起動時も必ず閉じた状態で始まる
        if (myNeedParamOff.exchange(false)) {
            if (show) tdpycb::setFloatPars(myNode, {{"Showwindow", 0.0}});
            show = false;
            myStreamSig.clear();
        }
        // バーの閉じるボタン → Show Window をオフ(ウインドウは次 cook で隠れる)
        if (myCloseReq->exchange(false) && show)
            tdpycb::setFloatPars(myNode, {{"Showwindow", 0.0}});

        // --- ウインドウ+MKMapView(メインスレッドで一度だけ作る) ---
        // 初期カメラをパラメータから入れる。入れないと地図既定の全景で開き、
        // Show Window オン(=ウインドウがマスター)だとその値がパラメータへ逆流する
        if (active && !myWindowRequested.exchange(true))
            createWindow(w, h,
                         in->getParDouble("Latitude"), in->getParDouble("Longitude"),
                         std::max(50.0, in->getParDouble("Distance")),
                         in->getParDouble("Pitch"), in->getParDouble("Heading"));

        // --- カメラは双方向 ---
        // Window Drives Camera をオフにすると、ウインドウを表示したまま
        // パラメータがマスターのままになる(スクリプト駆動の飛行を見せながら
        // 衛星タイルを読み込ませる用途。imagery はウインドウが見えていないと
        // ロードされない — 実測)
        if (active && myWindowReady.load()) {
            const bool winMaster = show && in->getParInt("Windowcamera") != 0;
            if (winMaster) {
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
            std::string style = tdmk::str(in, "Style", "standard");
            std::string elev  = tdmk::str(in, "Elevation", "realistic");
            const bool traffic = in->getParInt("Traffic") != 0;
            const bool poi = in->getParInt("Poi") != 0;
            const bool dark = in->getParInt("Dark") != 0;
            myAttrOn = in->getParInt("Attribution") != 0;
            {
                const std::string ap = tdmk::str(in, "Attributionpos", "bottomleft");
                myAttrPos = (ap == "bottomright") ? 1 : (ap == "topleft") ? 2
                          : (ap == "topright") ? 3 : 0;
            }
            const std::string cfgSig = style + "|" + elev + (traffic ? "|1" : "|0") +
                                       (poi ? "|1" : "|0") + (dark ? "|1" : "|0");
            if (myCfgSig != cfgSig) {
                myCfgSig = cfgSig;
                applyConfig(style, elev, traffic, poi, dark);
            }
            // 内蔵 Legal はタイル読込後に再出現する → 常に隠す(焼き込みの帰属表示に置き換え)
            {
                NSWindow* win2 = myWindow;
                auto alive2 = myAlive;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!alive2->load() || !win2.contentView) return;
                    tdmk::setLegalHidden(win2.contentView, true);
                });
            }

            // --- マーカーの射影(毎 cook) ---
            projectMarkers(in);

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
            parkWindow();   // Active を切ったらウインドウも画面から下ろす
        }

        // --- 最新フレームをアップロード(bypass 復帰のため毎回) ---
        tdmk::Frame f;
        {
            std::lock_guard<std::mutex> l(myMutex);
            if (myFrame.bgra.empty()) return;
            f = myFrame;
        }
        // 帰属表示はアップロード直前に焼く(理由は MapKitShared.h)
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
        const char* P = "MapKit";
        { OP_NumericParameter p("Active"); p.label = "Active"; p.page = P;
          p.defaultValues[0] = 1; m->appendToggle(p); }
        tdmk::addF(m, P, "Latitude",  "Latitude",  35.6595, -90, 90);
        tdmk::addF(m, P, "Longitude", "Longitude", 139.7005, -180, 180);
        {
            // ウインドウ側で大きくズームアウトした値も受けるため、上限はクランプしない
            OP_NumericParameter p("Distance");
            p.label = "Distance (m)"; p.page = P;
            p.defaultValues[0] = 800;
            p.minSliders[0] = 50; p.maxSliders[0] = 2000000;
            p.minValues[0] = 1; p.clampMins[0] = true; p.clampMaxes[0] = false;
            m->appendFloat(p);
        }
        tdmk::addF(m, P, "Pitch",     "Pitch",     60, 0, 80);
        tdmk::addF(m, P, "Heading",   "Heading",   0, 0, 360);
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
        { OP_NumericParameter p("Traffic"); p.label = "Show Traffic"; p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Poi");  p.label = "Show Points Of Interest"; p.page = P;
          p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Dark"); p.label = "Dark Appearance"; p.page = P; m->appendToggle(p); }
        // 帰属表示。ビュー内蔵の Legal は TOP 上ではリンクとして機能しないので常に隠し、
        // 代わりに「(Appleロゴ) Apple Maps」を出力へ焼き込む(Apple の規約上、既定オン)
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
        {
            // 緯度経度の表(列: name,lat,lon または lat,lon)。各点の画面位置 u/v を
            // Info DAT に出す = SOP や TOP を地図のパースに正確に重ねられる
            OP_StringParameter p("Markers");
            p.label = "Markers DAT"; p.page = P;
            m->appendDAT(p);
        }
        { OP_NumericParameter p("Showwindow"); p.label = "Show Window"; p.page = P; m->appendToggle(p); }
        // オン(既定): Show Window 中は手で決めたカメラがパラメータへ書き戻る。
        // オフ: ウインドウは表示するがカメラはパラメータが決める(式/CHOP駆動の飛行用)
        { OP_NumericParameter p("Windowcamera"); p.label = "Window Drives Camera"; p.page = P;
          p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Restart"); p.label = "Restart"; p.page = P; m->appendPulse(p); }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Restart")) {
            myStreamSig.clear(); myCamSig.clear(); myCfgSig.clear();
        }
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

    // Markers DAT を読み、メインスレッドで MKMapView に射影させる。
    // cook は前回の結果(myMarkers)を Info DAT に出すだけ
    void projectMarkers(const OP_Inputs* in)
    {
        const OP_DATInput* d = in->getParDAT("Markers");
        std::vector<Marker> req;
        if (d && d->numRows > 0) {
            for (int r = 0; r < d->numRows; r++) {
                const int nc = d->numCols;
                const char* c0 = d->getCell(r, 0);
                Marker mk;
                if (nc >= 3) {
                    const char* c1 = d->getCell(r, 1);
                    const char* c2 = d->getCell(r, 2);
                    char* e1 = nullptr; char* e2 = nullptr;
                    const double la = c1 ? strtod(c1, &e1) : 0;
                    const double lo = c2 ? strtod(c2, &e2) : 0;
                    if (e1 == c1 || e2 == c2) continue;   // ヘッダ行(数値でない)は読み飛ばす
                    mk.name = c0 ? c0 : "";
                    mk.lat = la; mk.lon = lo;
                } else if (nc == 2) {
                    const char* c1 = d->getCell(r, 1);
                    char* e0 = nullptr; char* e1 = nullptr;
                    const double la = c0 ? strtod(c0, &e0) : 0;
                    const double lo = c1 ? strtod(c1, &e1) : 0;
                    if (e0 == c0 || e1 == c1) continue;
                    mk.name = std::to_string(r);
                    mk.lat = la; mk.lon = lo;
                } else {
                    continue;
                }
                req.push_back(mk);
            }
        }
        {
            std::lock_guard<std::mutex> l(myMutex);
            myMarkerReq = req;
        }
        if (req.empty()) {
            std::lock_guard<std::mutex> l(myMutex);
            myMarkers.clear();
            return;
        }
        MKMapView* mv = myMapView;
        auto alive = myAlive;
        auto* self = this;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load() || !mv) return;
            std::vector<Marker> ms;
            {
                std::lock_guard<std::mutex> l(self->myMutex);
                ms = self->myMarkerReq;
            }
            const CGFloat vw = mv.bounds.size.width, vh = mv.bounds.size.height;
            if (vw < 1 || vh < 1) return;
            for (Marker& mk : ms) {
                const CGPoint pt = [mv convertCoordinate:CLLocationCoordinate2DMake(mk.lat, mk.lon)
                                           toPointToView:mv];
                if (isfinite(pt.x) && isfinite(pt.y)) {
                    mk.u = (float)(pt.x / vw);
                    mk.v = 1.0f - (float)(pt.y / vh);
                    mk.visible = mk.u >= 0.f && mk.u <= 1.f && mk.v >= 0.f && mk.v <= 1.f;
                }
            }
            std::lock_guard<std::mutex> l(self->myMutex);
            self->myMarkers = std::move(ms);
        });
    }

    bool getInfoDATSize(OP_InfoDATSize* sz, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        sz->rows = (int32_t)myMarkers.size() + 1;
        sz->cols = 6;
        sz->byColumn = false;
        return true;
    }

    void getInfoDATEntries(int32_t row, int32_t nCols, OP_InfoDATEntries* e, void*) override
    {
        static const char* hdr[6] = {"name", "lat", "lon", "u", "v", "visible"};
        if (row == 0) {
            for (int i = 0; i < nCols && i < 6; i++) e->values[i]->setString(hdr[i]);
            return;
        }
        std::lock_guard<std::mutex> l(myMutex);
        const int i = row - 1;
        if (i < 0 || i >= (int)myMarkers.size()) return;
        const Marker& mk = myMarkers[i];
        char b[5][32];
        snprintf(b[0], 32, "%.7f", mk.lat);
        snprintf(b[1], 32, "%.7f", mk.lon);
        snprintf(b[2], 32, "%.5f", mk.u);
        snprintf(b[3], 32, "%.5f", mk.v);
        snprintf(b[4], 32, "%d", mk.visible ? 1 : 0);
        const char* v[6] = {mk.name.c_str(), b[0], b[1], b[2], b[3], b[4]};
        for (int c = 0; c < nCols && c < 6; c++) e->values[c]->setString(v[c]);
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
    // cook が止まった / Active が切れたときに、ウインドウを画面から下ろす。
    // **破棄はしない**(再開時に張り直すため)。ここは cook スレッドからも呼ばれる
    // **メインスレッド専用**。ウインドウを画面から下ろす(破棄はしない)。
    // cook が再開しても勝手に開かないよう、Show Window パラメータを 0 に戻す予約もする
    void parkNow()
    {
        if (!myWindow || !myOnScreen) return;
        if (myWasShown) {   // 表示位置を覚えてから下ろす(次に開いたとき同じ場所へ)
            myShownOrigin = myWindow.frame.origin;
            myWasShown = false;
        }
        [myBarWindow orderOut:nil];
        [myWindow orderOut:nil];
        myOnScreen = false;
        myNeedParamOff = true;   // 次の cook で Show Window を 0 に戻す
    }

    void parkWindow()   // cook スレッドなど、どこからでも
    {
        auto alive = myAlive;
        auto* self = this;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (alive->load()) self->parkNow();
        });
    }

    // cook が止まったことを見張る。**cook が止まると main queue への dispatch も止まる**ので、
    // cook から独立したタイマーでしか検出できない(コンテナの allowCooking=False や
    // バイパスでウインドウだけ画面に残るのを防ぐ)
    void startWatchdog()
    {
        if (myWatchdog) return;
        auto alive = myAlive;
        auto* self = this;
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
        dispatch_source_set_timer(t,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
            (uint64_t)(0.25 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(t, ^{
            if (!alive->load()) return;
            const double last = self->myLastCook.load();
            if (last > 0 && CFAbsoluteTimeGetCurrent() - last > kCookStallSec)
                self->parkWindow();
        });
        dispatch_resume(t);
        myWatchdog = t;
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
            NSWindow* win = [[TDMapWindow alloc]
                initWithContentRect:r
                          styleMask:NSWindowStyleMaskBorderless
                            backing:NSBackingStoreBuffered
                              defer:NO];
            win.releasedWhenClosed = NO;
            win.title = @"MapKit MapView";
            // ドラッグ用のバーは**別ウインドウ**(親子接続もしない)。タイトル付き・
            // 親子接続のウインドウは macOS 26 が角を丸め、丸角が取り込みに写る(実測)
            NSWindow* bar = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(0, 0, r.size.width, 0)
                          styleMask:(NSWindowStyleMaskTitled |
                                     NSWindowStyleMaskClosable)  // Closable が無いと閉じるボタンが出ない
                            backing:NSBackingStoreBuffered
                              defer:NO];
            bar.releasedWhenClosed = NO;
            bar.title = @"MapKit MapView";
            // 閉じるボタンは出す(押すと Show Window がオフになる。delegate 参照)
            [[bar standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
            [[bar standardWindowButton:NSWindowZoomButton] setHidden:YES];
            TDMapBarDelegate* del = [TDMapBarDelegate new];
            del->closeReq = self->myCloseReq;
            del->onClose = ^{ self->parkNow(); };   // ボタンで即座に畳む(メインスレッド)
            bar.delegate = del;
            self->myBarDelegate = del;
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
            // Option+スクロール=チルト)。コントロール類は取り込みに写るので常に出さない
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
            self->myOnScreen = true;   // orderBack も「画面に載っている」状態
            self->myWindowReady = true;
            self->startWatchdog();
        });
    }

    void applyConfig(std::string style, std::string elev, bool traffic, bool poi, bool dark)
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
                    hc.showsTraffic = traffic;
                    cfg = hc;
                } else {
                    MKStandardMapConfiguration* st = [[MKStandardMapConfiguration alloc] init];
                    st.emphasisStyle = (style == "muted") ? MKStandardMapEmphasisStyleMuted
                                                          : MKStandardMapEmphasisStyleDefault;
                    if (!poi) st.pointOfInterestFilter =
                        [MKPointOfInterestFilter filterExcludingAllCategories];
                    st.showsTraffic = traffic;
                    cfg = st;
                }
                cfg.elevationStyle = (elev == "realistic") ? MKMapElevationStyleRealistic
                                                           : MKMapElevationStyleFlat;
                mv.preferredConfiguration = cfg;
                win.appearance = [NSAppearance appearanceNamed:
                    dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
                if (win.contentView) tdmk::setLegalHidden(win.contentView, true);
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
        __weak TDMapStreamOutput* weakOut = myOutput;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load() || !win) { self->myStarting = false; return; }
            const CGFloat scale = win.screen.backingScaleFactor ?: 2.0;
            NSRect r = win.frame;
            r.size = NSMakeSize(w / scale, h / scale);
            [win setFrame:r display:YES];
            mv.frame = NSMakeRect(0, 0, r.size.width, r.size.height);
            NSWindow* bar = self->myBarWindow;
            if (show) {
                // 地図ウインドウは**常にボーダーレス**(角が四角のまま取り込まれる)。
                // ドラッグはバー(独立ウインドウ)が担う
                [win setFrame:r display:NO];
                if (self->myShownOrigin.x != 0 || self->myShownOrigin.y != 0) {
                    [win setFrameOrigin:self->myShownOrigin];   // 前回表示していた場所へ戻す
                } else {
                    // 初回は退避位置(右下ほぼ画面外)のままにせず、
                    // TD のメインウインドウ(無ければ画面)の中央に出す
                    NSWindow* host = NSApp.mainWindow ?: NSApp.keyWindow;
                    const NSRect hf = host ? host.frame
                        : (win.screen ?: NSScreen.mainScreen).visibleFrame;
                    [win setFrameOrigin:NSMakePoint(NSMidX(hf) - r.size.width / 2,
                                                    NSMidY(hf) - r.size.height / 2)];
                }
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
                self->myWasShown = true;
            } else {
                // 隠すときはボーダーレス(角が四角)。**2つの罠を実測で踏んだ**:
                // ①デスクトップレベルに置くと遮蔽扱いになり MapKit が描画を止めて灰色になる
                // ②アルファを下げると SCK の取り込みまで暗くなる(合成後の見た目が返る)
                // → アルファ 1.0 のまま、**大部分を画面外へ出して 1pt だけ画面内に残す**。
                //   完全に画面外だと描画が止まるので端を残す(Translate の極小ウインドウと同じ発想)。
                //   取り込みは desktopIndependent なので画面外の部分も丸ごと取れる
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
            self->myOnScreen = true;
            mv.showsCompass = NO;   // コントロール類は TOP に写るので常に出さない
            mv.showsZoomControls = NO;
            if (@available(macOS 11.0, *)) mv.showsPitchControl = NO;
            const CGWindowID wid = (CGWindowID)win.windowNumber;

            // ウインドウサーバーに載った自分のウインドウを SCK で探して取り込む
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                       onScreenWindowsOnly:NO
                completionHandler:^(SCShareableContent* c, NSError* e) {
                TDMapStreamOutput* o = weakOut;
                if (!o || !o.owner || !alive->load()) return;
                auto* owner = static_cast<MapKitMapViewTOP*>(o.owner);
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
                    TDMapStreamOutput* o2 = weakOut;
                    if (!o2 || !o2.owner) return;
                    auto* ow = static_cast<MapKitMapViewTOP*>(o2.owner);
                    ow->myStarting = false;
                    if (se) ow->streamError(se);
                    else ow->myRunning = true;
                }];
            }];
        });
    }

    TOP_Context* myContext;
    std::shared_ptr<std::atomic<bool>> myAlive;
    TDMapStreamOutput* myOutput = nil;
    NSWindow* myWindow = nil;
    MKMapView* myMapView = nil;
    std::mutex myMutex;
    tdmk::Frame myFrame;
    tdmk::Attribution myAttr;
    std::string myWarning, myCamSig, myCfgSig;
    uint64_t mySerial = 0;
    double myFpsT0 = 0;
    int myFpsN = 0;
    std::atomic<uint64_t> myExec{0}, myFrames{0};
    std::atomic<uint32_t> myLastW{0}, myLastH{0};
    std::atomic<float> myFps{0};
    std::atomic<bool> myWindowRequested{false}, myWindowReady{false};
    std::atomic<bool> myAttrOn{true};
    std::atomic<int> myAttrPos{0};
    std::vector<Marker> myMarkers, myMarkerReq;
    const OP_NodeInfo* myNode;
    double myPulled[5] = {};
    uint64_t myPulledSerial = 0, myAppliedPull = 0;
    NSPoint myShownOrigin = {0, 0};
    std::atomic<double> myLastCook{0};
    // ロード直後も true = **起動時は必ず閉じた状態から**
    std::atomic<bool> myNeedParamOff{true};
    dispatch_source_t myWatchdog = nil;
    bool myOnScreen = false;   // メインスレッドのみが触る
    // これだけ cook が来なければ「止まった」と見なす(ヒッチで畳まない程度に長く)
    static constexpr double kCookStallSec = 1.0;
    NSWindow* myBarWindow = nil;
    TDMapBarDelegate* myBarDelegate = nil;
    std::shared_ptr<std::atomic<bool>> myCloseReq =
        std::make_shared<std::atomic<bool>>(false);
    id myMoveObserver = nil;
    bool myWasShown = false;
};

}  // namespace

@implementation TDMapStreamOutput
- (void)stream:(SCStream*)s didOutputSampleBuffer:(CMSampleBufferRef)b ofType:(SCStreamOutputType)t
{
    if (t == SCStreamOutputTypeScreen && self.owner)
        static_cast<MapKitMapViewTOP*>(self.owner)->receive(b);
}
- (void)stream:(SCStream*)s didStopWithError:(NSError*)e
{
    if (self.owner) static_cast<MapKitMapViewTOP*>(self.owner)->streamError(e);
}
@end

extern "C" {

DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i)
{
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Mapkitmapview");
    i->customOPInfo.opLabel->setString("MapKit MapView");
    i->customOPInfo.opIcon->setString("MPK");
    if (i->customOPInfo.opHelpURL)
        i->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/MapKit/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 1;   // Mode/Look Around を別opへ分離(破壊的変更)
    i->customOPInfo.minorVersion = 0;
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
    i->customOPInfo.cookOnStart = true;   // 出力を見られていなくてもストリームを維持する
}

DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c)
{
    return new MapKitMapViewTOP(i, c);
}

DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*)
{
    delete static_cast<MapKitMapViewTOP*>(i);
}

}
