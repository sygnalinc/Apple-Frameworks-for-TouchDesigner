// MapKit の地図画像と Look Around(街並み)を TOP に出す。
//
// **実測でわかった要点(2026-08-14 / macOS 26.6)**:
// - API キーは要らない。地図・検索・経路とも Apple のサービスへ直接繋がる
// - `MKMapSnapshotter` は好きなキューで完了を受け取れるが、**Look Around の完了ハンドラは
//   メインキューに来る**。単体CLIでメインスレッドをセマフォで塞ぐと全部タイムアウトする。
//   TD はメインランループを回すので、**要求もメインキューから出す**のが確実
// - Look Around のカバー範囲は飛び飛び(東京駅=無し / 渋谷スクランブル=有り)。
//   無い座標では画像が来ないので `available` で判別できるようにしてある
// - 要求した pt サイズの2倍の画素が返る(Retina)。出力解像度は返ってきた画素数に合わせる
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <MapKit/MapKit.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "../common/NonCommercialLimit.h"
using namespace TD;

namespace {

struct Settings {
    std::string mode = "map", style = "standard", elevation = "flat";
    double lat = 35.6595, lon = 139.7005;   // 既定は渋谷スクランブル(Look Around のカバー内)
    double span = 1200.0, pitch = 0.0, heading = 0.0;
    bool traffic = false, poi = true, dark = false;
    int w = 1280, h = 720;

    std::string signature() const
    {
        char b[256];
        snprintf(b, sizeof b, "%s|%s|%s|%.7f|%.7f|%.1f|%.1f|%.1f|%d%d%d|%d|%d",
                 mode.c_str(), style.c_str(), elevation.c_str(), lat, lon, span, pitch, heading,
                 traffic, poi, dark, w, h);
        return b;
    }
};

struct Result {
    std::vector<uint8_t> bgra;
    uint32_t w = 0, h = 0;
    uint64_t serial = 0;
    bool available = false;      // Look Around のカバー内か
};

// NSImage → BGRA。**素直に描くと TD の表示で上下が逆になる**(実機で確認)ので、
// CTM を反転させてから描き、バッファを TD が期待する並びで作る
static bool imageToBGRA(NSImage* img, Result& r)
{
    if (!img) return false;
    CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) return false;
    const size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return false;
    r.w = (uint32_t)w; r.h = (uint32_t)h;
    r.bgra.assign(w * h * 4, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(r.bgra.data(), w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedFirst |
                                             kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) { r.bgra.clear(); return false; }
    CGContextTranslateCTM(ctx, 0, (CGFloat)h);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
    CGContextRelease(ctx);
    return true;
}

class MapKitTOP final : public TOP_CPlusPlusBase {
public:
    MapKitTOP(const OP_NodeInfo*, TOP_Context* c)
        : myContext(c), myAlive(std::make_shared<std::atomic<bool>>(true)) {}

    ~MapKitTOP() override { *myAlive = false; }   // 飛んでいる要求が破棄後に触らないように

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
    }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        Settings s = readSettings(out, in);

        const std::string sig = s.signature();
        if (sig != mySig || myReload.exchange(false)) {
            mySig = sig;
            request(s);
        }

        Result r;
        {
            std::lock_guard<std::mutex> l(myMutex);
            // bypass / 無効化から戻ると TD が保持テクスチャを捨てるので**毎回アップロードする**
            if (myResult.bgra.empty()) return;
            r = myResult;
        }
        if (tdnc::fit(r.bgra, r.w, r.h, OP_PixelFormat::BGRA8Fixed)) {
            std::lock_guard<std::mutex> l(myMutex);
            myWarning = tdnc::kWarning;
        }
        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = r.w;
        ui.textureDesc.height = r.h;
        ui.textureDesc.pixelFormat = OP_PixelFormat::BGRA8Fixed;
        auto b = myContext->createOutputBuffer(r.bgra.size(), TOP_BufferFlags::None, nullptr);
        if (!b) return;
        memcpy(b->data, r.bgra.data(), r.bgra.size());
        out->uploadBuffer(&b, ui, nullptr);
        myOutW = r.w; myOutH = r.h;
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "MapKit";
        {
            OP_StringParameter p("Mode");
            p.label = "Mode"; p.page = P; p.defaultValue = "map";
            const char* n[] = {"map", "lookaround"};
            const char* l[] = {"Map", "Look Around"};
            m->appendMenu(p, 2, n, l);
        }
        addFloat(m, P, "Latitude",  "Latitude",  35.6595, -90,  90);
        addFloat(m, P, "Longitude", "Longitude", 139.7005, -180, 180);
        addFloat(m, P, "Span",      "Span (m)",  1200, 50, 200000);
        {
            OP_StringParameter p("Style");
            p.label = "Style"; p.page = P; p.defaultValue = "standard";
            const char* n[] = {"standard", "muted", "satellite", "hybrid"};
            const char* l[] = {"Standard", "Muted", "Satellite", "Hybrid"};
            m->appendMenu(p, 4, n, l);
        }
        {
            OP_StringParameter p("Elevation");
            p.label = "Elevation"; p.page = P; p.defaultValue = "flat";
            const char* n[] = {"flat", "realistic"};
            const char* l[] = {"Flat", "Realistic (3D)"};
            m->appendMenu(p, 2, n, l);
        }
        addFloat(m, P, "Pitch",   "Pitch",   0, 0, 80);
        addFloat(m, P, "Heading", "Heading", 0, 0, 360);
        { OP_NumericParameter p("Traffic"); p.label = "Show Traffic";           p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Poi");     p.label = "Show Points Of Interest"; p.page = P; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Dark");    p.label = "Dark Appearance";        p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Reload");  p.label = "Reload";                 p.page = P; m->appendPulse(p); }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Reload")) myReload = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 8; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        static const char* n[8] = {"executes", "requests", "renders", "busy",
                                   "available", "width", "height", "request_ms"};
        const float v[8] = {(float)myExec.load(), (float)myRequests.load(), (float)myRenders.load(),
                            myBusy.load() ? 1.f : 0.f, myAvailable.load() ? 1.f : 0.f,
                            (float)myOutW, (float)myOutH, myMs.load()};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    void getWarningString(OP_String* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (!myWarning.empty()) s->setString(myWarning.c_str());
    }

private:
    static void addFloat(OP_ParameterManager* m, const char* page, const char* name,
                         const char* label, double def, double lo, double hi)
    {
        OP_NumericParameter p(name);
        p.label = label; p.page = page;
        p.defaultValues[0] = def;
        p.minSliders[0] = lo; p.maxSliders[0] = hi;
        p.minValues[0] = lo;  p.maxValues[0] = hi;
        p.clampMins[0] = p.clampMaxes[0] = true;
        m->appendFloat(p);
    }

    Settings readSettings(TOP_Output* out, const OP_Inputs* in) const
    {
        Settings s;
        auto str = [&](const char* k, const char* d) {
            const char* v = in->getParString(k); return std::string(v ? v : d);
        };
        s.mode = str("Mode", "map");
        s.style = str("Style", "standard");
        s.elevation = str("Elevation", "flat");
        s.lat = in->getParDouble("Latitude");
        s.lon = in->getParDouble("Longitude");
        s.span = in->getParDouble("Span");
        s.pitch = in->getParDouble("Pitch");
        s.heading = in->getParDouble("Heading");
        s.traffic = in->getParInt("Traffic") != 0;
        s.poi = in->getParInt("Poi") != 0;
        s.dark = in->getParInt("Dark") != 0;
        // 解像度は他のTOPと同じく Common ページから。入力を持たないので
        // 既定の "Use Input"(127x127)は無意味 → 1280x720 を既定にする
        const char* om = in->getParString("outputresolution");
        if (!om || !strcmp(om, "useinput")) { s.w = 1280; s.h = 720; }
        else {
            OP_TextureDesc sug{}; out->getSuggestedOutputDesc(&sug, nullptr);
            s.w = (int)sug.width; s.h = (int)sug.height;
        }
        // getSuggestedOutputDesc が埋めてくれないことがあるので**上下ともクランプする**。
        // 0 面積は MKMapSnapshotOptions が例外を投げる
        if (s.w < 16 || s.w > 8192) s.w = (s.w < 16) ? 16 : 8192;
        if (s.h < 16 || s.h > 8192) s.h = (s.h < 16) ? 16 : 8192;
        return s;
    }

    // **要求はメインキューから出す**(Look Around の完了はメインキューに来るため)。
    // 画素への変換だけ別キューへ逃がして、メインスレッドを長く止めない
    // **値で受ける。** 参照のままブロックに捕まえると、ブロックがメインキューで走る頃には
    // 呼び出し元のローカルが消えていてゴミになる(実際にサイズ 0 で例外→TDごと落ちた)
    void request(Settings s)
    {
        if (myBusy.exchange(true)) {
            std::lock_guard<std::mutex> l(myMutex);
            myQueuedSettings = s; myQueued = true; return;
        }
        myRequests++;
        myStart = CFAbsoluteTimeGetCurrent();
        auto alive = myAlive;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load()) return;
            // **Apple のフレームワークは NSError ではなく ObjC 例外を投げる**ことがある
            // (MKMapSnapshotOptions.size は 0 面積で raise する)。C++ の呼び出し元まで
            // 伝わるとプロセスごと終了するので、必ずここで受け止める
            @try {
                if (s.mode == "lookaround") startLookAround(s, alive);
                else startMap(s, alive);
            } @catch (NSException* ex) {
                finish(alive, nil, false, ex.reason ?: @"MapKit raised an exception");
            }
        });
    }

    void finish(std::shared_ptr<std::atomic<bool>> alive, NSImage* img,
                bool available, NSString* err)
    {
        if (!alive->load()) return;
        auto* self = this;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!alive->load()) return;
            Result r;
            r.available = available;
            const bool ok = imageToBGRA(img, r);
            {
                std::lock_guard<std::mutex> l(self->myMutex);
                if (ok) { r.serial = ++self->mySerial; self->myResult = std::move(r); }
                self->myWarning = err ? err.UTF8String : "";
            }
            self->myAvailable = available;
            self->myMs = (float)((CFAbsoluteTimeGetCurrent() - self->myStart) * 1000.0);
            if (ok) self->myRenders++;
            self->myBusy = false;
            // 待たせていた設定があれば続けて投げる(最新の1件だけ)
            if (self->myQueued.exchange(false)) {
                Settings next;
                { std::lock_guard<std::mutex> l(self->myMutex); next = self->myQueuedSettings; }
                self->request(next);
            }
        });
    }

    void startMap(const Settings& s, std::shared_ptr<std::atomic<bool>> alive)
    {
        MKMapSnapshotOptions* o = [[MKMapSnapshotOptions alloc] init];
        const CLLocationCoordinate2D center = CLLocationCoordinate2DMake(s.lat, s.lon);
        // pitch / heading を使うときだけカメラ。真上からのときは region の方が
        // Span が「地上で何メートル見えるか」と素直に対応する
        if (s.pitch > 0.01 || s.heading > 0.01) {
            o.camera = [MKMapCamera cameraLookingAtCenterCoordinate:center
                                                       fromDistance:s.span
                                                              pitch:s.pitch
                                                            heading:s.heading];
        } else {
            o.region = MKCoordinateRegionMakeWithDistance(center, s.span, s.span);
        }
        o.size = NSMakeSize(s.w, s.h);
        if (s.dark) o.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

        MKMapConfiguration* cfg = nil;
        if (s.style == "satellite") {
            cfg = [[MKImageryMapConfiguration alloc] init];
        } else if (s.style == "hybrid") {
            MKHybridMapConfiguration* h = [[MKHybridMapConfiguration alloc] init];
            if (!s.poi) h.pointOfInterestFilter = [MKPointOfInterestFilter filterExcludingAllCategories];
            h.showsTraffic = s.traffic;
            cfg = h;
        } else {
            MKStandardMapConfiguration* st = [[MKStandardMapConfiguration alloc] init];
            st.emphasisStyle = (s.style == "muted") ? MKStandardMapEmphasisStyleMuted
                                                    : MKStandardMapEmphasisStyleDefault;
            if (!s.poi) st.pointOfInterestFilter = [MKPointOfInterestFilter filterExcludingAllCategories];
            st.showsTraffic = s.traffic;
            cfg = st;
        }
        cfg.elevationStyle = (s.elevation == "realistic") ? MKMapElevationStyleRealistic
                                                          : MKMapElevationStyleFlat;
        o.preferredConfiguration = cfg;

        MKMapSnapshotter* snap = [[MKMapSnapshotter alloc] initWithOptions:o];
        [snap startWithQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)
           completionHandler:^(MKMapSnapshot* sn, NSError* e) {
            finish(alive, sn.image, sn != nil,
                   sn ? nil : (e ? e.localizedDescription : @"Map snapshot failed"));
        }];
    }

    void startLookAround(const Settings& s, std::shared_ptr<std::atomic<bool>> alive)
    {
        MKLookAroundSceneRequest* req = [[MKLookAroundSceneRequest alloc]
            initWithCoordinate:CLLocationCoordinate2DMake(s.lat, s.lon)];
        const int w = s.w, h = s.h;
        [req getSceneWithCompletionHandler:^(MKLookAroundScene* scene, NSError* e) {
            if (!scene) {
                // カバー範囲外。エラーではないので警告で伝える
                finish(alive, nil, false,
                       e ? e.localizedDescription
                         : @"No Look Around imagery at this coordinate. Coverage is patchy.");
                return;
            }
            MKLookAroundSnapshotOptions* o = [[MKLookAroundSnapshotOptions alloc] init];
            o.size = NSMakeSize(w, h);
            MKLookAroundSnapshotter* ss =
                [[MKLookAroundSnapshotter alloc] initWithScene:scene options:o];
            [ss getSnapshotWithCompletionHandler:^(MKLookAroundSnapshot* snap, NSError* e2) {
                finish(alive, snap.image, snap != nil,
                       snap ? nil : (e2 ? e2.localizedDescription : @"Look Around snapshot failed"));
            }];
        }];
    }

    TOP_Context* myContext;
    std::shared_ptr<std::atomic<bool>> myAlive;
    std::mutex myMutex;
    Result myResult;
    Settings myQueuedSettings;
    std::string mySig, myWarning;
    uint64_t mySerial = 0;
    uint32_t myOutW = 0, myOutH = 0;
    CFAbsoluteTime myStart = 0;
    std::atomic<uint64_t> myExec{0}, myRequests{0}, myRenders{0};
    std::atomic<bool> myBusy{false}, myQueued{false}, myAvailable{false}, myReload{false};
    std::atomic<float> myMs{0};
};

}  // namespace

extern "C" {

DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i)
{
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Mapkit");
    i->customOPInfo.opLabel->setString("MapKit");
    i->customOPInfo.opIcon->setString("MPK");
    if (i->customOPInfo.opHelpURL)
        i->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/MapKit/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
}

DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c)
{
    return new MapKitTOP(i, c);
}

DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*)
{
    delete static_cast<MapKitTOP*>(i);
}

}
