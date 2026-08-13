// AVF Camera TOP — AVFoundation でカメラを開き、**フォーマットを明示的に選んで**映像を出す。
//
// TD 標準の Video Device In TOP との違い(2026-08-13 に実機で確認):
//
//   * **フォーマットを一覧から選べる。** TD は「解像度」と「fps 上限」を別々に指定する形なので、
//     どの組み合わせが実在するのか分からない。実測(Logicool BRIO): 35フォーマット =
//     212通りのうち **60fps が出るのは 1280x720/420v の1通りだけ**で、1920x1080 は 30fps 頭打ち。
//     TD で 1080p を選ぶと 60fps に到達する道が塞がれるが、それに気づけない
//   * **露出 / フォーカスをロックできる。** TD の exposure / analoggain 等は SDI 用で、
//     UVC カメラを選ぶと**すべてグレーアウト**する(実測)。展示では自動露出が動くと
//     キーイングやトラッキングが崩れるので、止められること自体に価値がある
//   * **Center Stage / Portrait / Studio Light** を切り替えられる(macOS のビデオエフェクト)
//   * デスクビューカメラなど、TD の一覧に出ないデバイスも扱える(実測: TD 5台 / AVF 6台)
//   * デバイスは **uniqueID** で保持し、抜き差しに追従する
//
// 映像は AVCaptureVideoDataOutput → BGRA の CPU バッファ → TOP へアップロード
// (ScreenCapture TOP と同じ型)。受信は専用キューで、cook は最新フレームを上げるだけ。
#include "TOP_CPlusPlusBase.h"
#include "../common/NonCommercialLimit.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

using namespace TD;

namespace {

struct Format {
    int width = 0, height = 0;
    double minFps = 0, maxFps = 0;
    std::string pixel;      // FourCC
    int index = 0;          // device.formats 内の位置
    int range = 0;          // その format 内の videoSupportedFrameRateRanges の位置
};

struct Camera {
    std::string uid, name, model, manufacturer;
};

std::string fourCC(FourCharCode c)
{
    char b[5] = {(char)((c >> 24) & 0xFF), (char)((c >> 16) & 0xFF),
                 (char)((c >> 8) & 0xFF), (char)(c & 0xFF), 0};
    return b;
}

std::string toStr(NSString* s) { return s ? std::string(s.UTF8String) : std::string(); }

} // namespace

// 受信デリゲート。フレームは BGRA でコピーして最新値だけ持つ
@interface AVFCamSink : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, assign) void* owner;
@end

class AVFCameraTOP;
static void avfPushFrame(void* owner, const uint8_t* src, size_t rowBytes, uint32_t w, uint32_t h);

@implementation AVFCamSink
- (void)captureOutput:(AVCaptureOutput*)o
    didOutputSampleBuffer:(CMSampleBufferRef)sb
           fromConnection:(AVCaptureConnection*)c
{
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb || !self.owner) return;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    avfPushFrame(self.owner, (const uint8_t*)CVPixelBufferGetBaseAddress(pb),
                 CVPixelBufferGetBytesPerRow(pb),
                 (uint32_t)CVPixelBufferGetWidth(pb), (uint32_t)CVPixelBufferGetHeight(pb));
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}
@end

class AVFCameraTOP final : public TOP_CPlusPlusBase {
public:
    AVFCameraTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c)
    {
        myQueue = dispatch_queue_create("tdappleops.avfcamera", DISPATCH_QUEUE_SERIAL);
        mySink = [[AVFCamSink alloc] init];
        mySink.owner = this;
        rescan();
    }

    ~AVFCameraTOP() override
    {
        stopSession();
        mySink.owner = nullptr;
        mySink = nil;
    }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrame = true;   // 受信は別スレッド。見られていなくても回しておく
    }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        if (myDevicesChanged.exchange(false)) rescan();

        const bool active = in->getParInt("Active") != 0;
        const char* sel = in->getParString("Device");
        const std::string uid = sel ? sel : "";
        // **動的文字列メニューは getParString で読む。** getParInt だと常に 0 になり、
        // フォーマットの変更が検知できず既定のまま開き続ける(実際に踏んだ)
        const char* fmtStr = in->getParString("Format");
        const int fmtIdx = fmtStr ? (int)strtol(fmtStr, nullptr, 10) : 0;

        if (!active) { stopSession(); }
        else if (uid != myOpenUID || fmtIdx != myOpenFormat) { startSession(uid, fmtIdx); }

        if (myDevice) applyControls(in);

        // 最新フレームをアップロード。
        // **1080p60 は 1フレーム 8MB。中間バッファを挟むとコピーが倍になる**ので、
        // 通常経路ではロックしたまま TD のバッファへ直接書く
        uint32_t w = 0, h = 0;
        { std::lock_guard<std::mutex> l(myMutex); w = myWidth; h = myHeight; if (myPixels.empty()) return; }

        if (tdnc::active() && (w > 1280 || h > 1280)) {
            // NC の上限を超えるときだけ縮小経路(コピーが増えるが滅多に通らない)
            std::vector<uint8_t> px;
            { std::lock_guard<std::mutex> l(myMutex); px = myPixels; w = myWidth; h = myHeight; }
            tdnc::fit(px, w, h, OP_PixelFormat::BGRA8Fixed);
            myWarning = tdnc::kWarning;
            TOP_UploadInfo ui;
            ui.textureDesc.texDim = OP_TexDim::e2D;
            ui.textureDesc.width = w; ui.textureDesc.height = h;
            ui.textureDesc.pixelFormat = OP_PixelFormat::BGRA8Fixed;
            auto b2 = myContext->createOutputBuffer(px.size(), TOP_BufferFlags::None, nullptr);
            if (!b2) return;
            memcpy(b2->data, px.data(), px.size());
            out->uploadBuffer(&b2, ui, nullptr);
            return;
        }

        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = w;
        ui.textureDesc.height = h;
        ui.textureDesc.pixelFormat = OP_PixelFormat::BGRA8Fixed;
        auto buf = myContext->createOutputBuffer((size_t)w * h * 4, TOP_BufferFlags::None, nullptr);
        if (!buf) return;
        {
            std::lock_guard<std::mutex> l(myMutex);
            if (myWidth != w || myHeight != h || myPixels.empty()) return;   // 途中でフォーマットが変わった
            memcpy(buf->data, myPixels.data(), myPixels.size());
        }
        out->uploadBuffer(&buf, ui, nullptr);
    }

    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Refreshdevices")) myDevicesChanged = true;
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* PAGE = "AVF Camera";
        { OP_NumericParameter p("Active"); p.label = "Active"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
        {
            OP_StringParameter p("Device");
            p.label = "Device"; p.page = PAGE; p.defaultValue = "none";
            m->appendDynamicStringMenu(p);
        }
        { OP_NumericParameter p("Refreshdevices"); p.label = "Refresh Devices"; p.page = PAGE; m->appendPulse(p); }
        {
            // **ここが本 OP の主目的**。実在する組み合わせだけを並べる
            OP_StringParameter p("Format");
            p.label = "Format"; p.page = PAGE; p.defaultValue = "0";
            m->appendDynamicStringMenu(p);
        }

        const char* CTRL = "Control";
        {
            OP_StringParameter p("Exposure");
            p.label = "Exposure"; p.page = CTRL; p.defaultValue = "auto";
            const char* n[] = {"auto", "locked"};
            const char* l[] = {"Continuous Auto", "Locked"};
            m->appendMenu(p, 2, n, l);
        }
        {
            OP_StringParameter p("Focus");
            p.label = "Focus"; p.page = CTRL; p.defaultValue = "auto";
            const char* n[] = {"auto", "locked"};
            const char* l[] = {"Continuous Auto", "Locked"};
            m->appendMenu(p, 2, n, l);
        }
        // **Center Stage だけがアプリから設定できる**(実測)。Portrait / Studio Light は
        // setter が無く、コントロールセンター側でユーザーが決める。状態は Info CHOP に出す
        { OP_NumericParameter p("Centerstage"); p.label = "Center Stage"; p.page = CTRL; m->appendToggle(p); }
    }

    void buildDynamicMenu(const OP_Inputs* in, OP_BuildDynamicMenuInfo* info, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (!strcmp(info->name, "Device")) {
            info->addMenuEntry("none", "(none)");
            for (const Camera& c : myCameras)
                info->addMenuEntry(c.uid.c_str(), c.name.c_str());
        } else if (!strcmp(info->name, "Format")) {
            if (myFormats.empty()) { info->addMenuEntry("0", "(select a device)"); return; }
            for (size_t i = 0; i < myFormats.size(); i++) {
                const Format& f = myFormats[i];
                char val[16]; snprintf(val, sizeof val, "%d", (int)i);
                char lab[128];
                if (f.minFps == f.maxFps)
                    snprintf(lab, sizeof lab, "%dx%d  %s  %.0f fps", f.width, f.height, f.pixel.c_str(), f.maxFps);
                else
                    snprintf(lab, sizeof lab, "%dx%d  %s  %.0f-%.0f fps", f.width, f.height,
                             f.pixel.c_str(), f.minFps, f.maxFps);
                info->addMenuEntry(val, lab);
            }
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 14; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        // width/height は**届いたフレーム**、active_* は**デバイスが今持っているフォーマット**。
        // 両者を分けて出すと「指定が効いていない」のか「フレームがまだ古い」のか判別できる
        const char* n[14] = {"executes", "frames", "running", "width", "height", "formats", "cameras",
                             "center_stage", "portrait_effect", "studio_light", "active_w", "active_h",
                             "preset_path", "fmt_locked"};
        // preset_path: 1=プリセットを設定 / 2=プリセット非対応で activeFormat へ / 3=該当プリセット無し
        // fmt_locked : applyFormat で lockForConfiguration が通ったか
        std::lock_guard<std::mutex> l(myMutex);
        CMVideoDimensions ad = {0, 0};
        if (myDevice && myDevice.activeFormat)
            ad = CMVideoFormatDescriptionGetDimensions(myDevice.activeFormat.formatDescription);
        float v[14] = {(float)myExec.load(), (float)myFrames.load(), myRunning ? 1.f : 0.f,
                      (float)myWidth, (float)myHeight, (float)myFormats.size(), (float)myCameras.size(),
                      AVCaptureDevice.centerStageEnabled ? 1.f : 0.f,
                      AVCaptureDevice.portraitEffectEnabled ? 1.f : 0.f,
                      AVCaptureDevice.studioLightEnabled ? 1.f : 0.f,
                      (float)ad.width, (float)ad.height,
                      (float)myPresetPath, (float)myFmtLocked};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    // 実在するフォーマットの一覧を表として出す(選択の根拠を見せる)
    bool getInfoDATSize(OP_InfoDATSize* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        s->rows = (int32_t)myFormats.size() + 1;
        s->cols = 5;
        s->byColumn = false;
        return true;
    }

    void getInfoDATEntries(int32_t row, int32_t nCols, OP_InfoDATEntries* e, void*) override
    {
        static const char* hdr[5] = {"index", "width", "height", "pixel", "max_fps"};
        std::lock_guard<std::mutex> l(myMutex);
        if (row == 0) {
            for (int i = 0; i < nCols && i < 5; i++) e->values[i]->setString(hdr[i]);
            return;
        }
        const int idx = row - 1;
        if (idx < 0 || idx >= (int)myFormats.size()) return;
        const Format& f = myFormats[idx];
        char a[16], b[16], c[16], d[16];
        snprintf(a, sizeof a, "%d", idx);
        snprintf(b, sizeof b, "%d", f.width);
        snprintf(c, sizeof c, "%d", f.height);
        snprintf(d, sizeof d, "%.2f", f.maxFps);
        const char* vals[5] = {a, b, c, f.pixel.c_str(), d};
        for (int i = 0; i < nCols && i < 5; i++) e->values[i]->setString(vals[i]);
    }

    void getWarningString(OP_String* w, void*) override
    {
        if (!myWarning.empty()) { w->setString(myWarning.c_str()); return; }
        std::lock_guard<std::mutex> l(myMutex);
        if (myCameras.empty()) w->setString("No camera found.");
        else if (!myRunning && myOpenUID != "none" && !myOpenUID.empty())
            w->setString("Camera is not running. Check the camera permission for TouchDesigner "
                         "in System Settings > Privacy & Security > Camera.");
    }

    // 受信スレッドから呼ばれる
    void pushFrame(const uint8_t* src, size_t rowBytes, uint32_t w, uint32_t h)
    {
        std::lock_guard<std::mutex> l(myMutex);
        myWidth = w; myHeight = h;
        myPixels.resize((size_t)w * h * 4);
        // **TD は下から上。CoreVideo は上から下**なので行を反転して詰める
        for (uint32_t y = 0; y < h; y++)
            memcpy(myPixels.data() + (size_t)(h - 1 - y) * w * 4, src + y * rowBytes, (size_t)w * 4);
        myFrames++;
    }

private:
    void setWarning(const std::string& w) { std::lock_guard<std::mutex> l(myMutex); myWarning = w; }

    void rescan()
    {
        @autoreleasepool {
            NSArray* types = @[AVCaptureDeviceTypeExternal, AVCaptureDeviceTypeBuiltInWideAngleCamera,
                               AVCaptureDeviceTypeContinuityCamera, AVCaptureDeviceTypeDeskViewCamera];
            AVCaptureDeviceDiscoverySession* ds =
                [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                                      mediaType:AVMediaTypeVideo
                                                                       position:AVCaptureDevicePositionUnspecified];
            std::vector<Camera> cams;
            for (AVCaptureDevice* d in ds.devices) {
                Camera c;
                c.uid = toStr(d.uniqueID);
                c.name = toStr(d.localizedName);
                c.model = toStr(d.modelID);
                c.manufacturer = toStr(d.manufacturer);
                cams.push_back(c);
            }
            std::lock_guard<std::mutex> l(myMutex);
            myCameras.swap(cams);
        }
    }

    // そのデバイスで実在する (フォーマット × fpsレンジ) を並べる
    void buildFormats(AVCaptureDevice* d)
    {
        std::vector<Format> fs;
        int i = 0;
        for (AVCaptureDeviceFormat* f in d.formats) {
            CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
            const std::string px = fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription));
            int ri = 0;
            for (AVFrameRateRange* r in f.videoSupportedFrameRateRanges) {
                Format o;
                o.width = dim.width; o.height = dim.height;
                o.minFps = r.minFrameRate; o.maxFps = r.maxFrameRate;
                o.pixel = px; o.index = i; o.range = ri++;
                fs.push_back(o);
            }
            i++;
        }
        std::lock_guard<std::mutex> l(myMutex);
        myFormats.swap(fs);
    }

    void startSession(const std::string& uid, int fmtIdx)
    {
        stopSession();
        myOpenUID = uid;
        myOpenFormat = fmtIdx;
        if (uid.empty() || uid == "none") return;

        @autoreleasepool {
            AVCaptureDevice* d = [AVCaptureDevice deviceWithUniqueID:
                                  [NSString stringWithUTF8String:uid.c_str()]];
            if (!d) return;
            myDevice = d;
            buildFormats(d);

            @try {
            AVCaptureSession* s = [[AVCaptureSession alloc] init];
            [s beginConfiguration];
            NSError* err = nil;
            AVCaptureDeviceInput* in = [AVCaptureDeviceInput deviceInputWithDevice:d error:&err];
            if (!in || ![s canAddInput:in]) { [s commitConfiguration]; return; }
            [s addInput:in];

            AVCaptureVideoDataOutput* o = [[AVCaptureVideoDataOutput alloc] init];
            o.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey :
                                 @(kCVPixelFormatType_32BGRA) };   // 変換は AVF に任せる
            o.alwaysDiscardsLateVideoFrames = YES;
            [o setSampleBufferDelegate:mySink queue:myQueue];
            if ([s canAddOutput:o]) [s addOutput:o];
            // **フォーマット指定はセッションの設定ブロックの中で行う。**
            // (iOS の AVCaptureSessionPresetInputPriority は macOS に存在しない)
            // **UVC(DAL)デバイスは activeFormat を無視する**(実測: 指定しても 1920x1080 のまま)。
            // macOS で解像度を選ぶ道は sessionPreset。該当するプリセットがあればそちらを使い、
            // 無ければ activeFormat を試す
            {
                Format want;
                { std::lock_guard<std::mutex> l(myMutex);
                  if (fmtIdx >= 0 && fmtIdx < (int)myFormats.size()) want = myFormats[fmtIdx]; }
                NSString* preset = nil;
                if (want.width == 3840 && want.height == 2160) preset = AVCaptureSessionPreset3840x2160;
                else if (want.width == 1920 && want.height == 1080) preset = AVCaptureSessionPreset1920x1080;
                else if (want.width == 1280 && want.height == 720) preset = AVCaptureSessionPreset1280x720;
                else if (want.width == 960 && want.height == 540) preset = AVCaptureSessionPreset960x540;
                else if (want.width == 640 && want.height == 480) preset = AVCaptureSessionPreset640x480;
                else if (want.width == 352 && want.height == 288) preset = AVCaptureSessionPreset352x288;
                myPresetPath = preset ? ([s canSetSessionPreset:preset] ? 1 : 2) : 3;
                if (myPresetPath == 1) s.sessionPreset = preset;
                else applyFormat(d, fmtIdx);
            }
            [s commitConfiguration];

            mySession = s;
            [s startRunning];
            { std::lock_guard<std::mutex> l(myMutex); myRunning = s.isRunning; }
            } @catch (NSException* ex) {
                setWarning(std::string("Could not open the camera: ") +
                           (ex.reason ? ex.reason.UTF8String : "unknown"));
            }
        }
    }

    void applyFormat(AVCaptureDevice* d, int idx)
    {
        Format want;
        {
            std::lock_guard<std::mutex> l(myMutex);
            if (idx < 0 || idx >= (int)myFormats.size()) return;
            want = myFormats[idx];
        }
        NSArray<AVCaptureDeviceFormat*>* fmts = d.formats;
        if (want.index < 0 || want.index >= (int)fmts.count) return;
        NSError* e = nil;
        if (![d lockForConfiguration:&e]) {
            myFmtLocked = 0;
            setWarning("Could not lock the camera for configuration.");
            return;
        }
        myFmtLocked = 1;
        // **AVFoundation は不正な値で NSError ではなく ObjC 例外を投げる。**
        // fps から自分で CMTime を作って渡したら -[AVCaptureDALDevice
        // setActiveVideoMinFrameDuration:] が投げて TD ごと落ちた(実際に踏んだ)。
        // フレーム持続時間は**システムが返すレンジの値をそのまま使う**。
        @try {
            AVCaptureDeviceFormat* f = fmts[want.index];
            d.activeFormat = f;
            NSArray<AVFrameRateRange*>* rs = f.videoSupportedFrameRateRanges;
            if (want.range >= 0 && want.range < (int)rs.count) {
                AVFrameRateRange* r = rs[want.range];
                d.activeVideoMinFrameDuration = r.minFrameDuration;   // 最短 = 最高fps
                d.activeVideoMaxFrameDuration = r.minFrameDuration;
            }
        } @catch (NSException* ex) {
            setWarning(std::string("This camera refused the format: ") +
                       (ex.reason ? ex.reason.UTF8String : "unknown"));
        }
        [d unlockForConfiguration];
    }

    void applyControls(const OP_Inputs* in)
    {
        AVCaptureDevice* d = myDevice;
        if (!d) return;
        const char* ex = in->getParString("Exposure");
        const char* fo = in->getParString("Focus");
        const bool cs = in->getParInt("Centerstage") != 0;

        const std::string exs = ex ? ex : "auto", fos = fo ? fo : "auto";
        if (exs == myExposure && fos == myFocus && cs == myCS) return;
        myExposure = exs; myFocus = fos; myCS = cs;

        NSError* e = nil;
        if ([d lockForConfiguration:&e]) {
          @try {
            const AVCaptureExposureMode em = (exs == "locked")
                ? AVCaptureExposureModeLocked : AVCaptureExposureModeContinuousAutoExposure;
            if ([d isExposureModeSupported:em]) d.exposureMode = em;
            const AVCaptureFocusMode fm = (fos == "locked")
                ? AVCaptureFocusModeLocked : AVCaptureFocusModeContinuousAutoFocus;
            if ([d isFocusModeSupported:fm]) d.focusMode = fm;
          } @catch (NSException* ex) {
            setWarning(std::string("Camera control failed: ") +
                       (ex.reason ? ex.reason.UTF8String : "unknown"));
          }
          [d unlockForConfiguration];
        }
        @try { AVCaptureDevice.centerStageControlMode = AVCaptureCenterStageControlModeApp; }
        @catch (NSException*) {}
        // ビデオエフェクトはデバイスではなくクラス側の設定(Control Center と共有)
        @try { AVCaptureDevice.centerStageEnabled = cs; } @catch (NSException*) {}
    }

    void stopSession()
    {
        if (mySession) { [mySession stopRunning]; mySession = nil; }
        myDevice = nil;
        std::lock_guard<std::mutex> l(myMutex);
        myRunning = false;
    }

    TOP_Context* myContext;
    dispatch_queue_t myQueue = nullptr;
    AVFCamSink* mySink = nil;
    AVCaptureSession* mySession = nil;
    AVCaptureDevice* myDevice = nil;

    std::mutex myMutex;
    std::vector<Camera> myCameras;
    std::vector<Format> myFormats;
    std::vector<uint8_t> myPixels;
    uint32_t myWidth = 0, myHeight = 0;
    bool myRunning = false;
    std::string myOpenUID, myWarning;
    int myOpenFormat = -1;
    std::string myExposure = "?", myFocus = "?";
    bool myCS = false;
    int myPresetPath = 0, myFmtLocked = -1;

    std::atomic<uint64_t> myExec{0}, myFrames{0};
    std::atomic<bool> myDevicesChanged{false};
};

static void avfPushFrame(void* owner, const uint8_t* src, size_t rowBytes, uint32_t w, uint32_t h)
{
    if (owner) ((AVFCameraTOP*)owner)->pushFrame(src, rowBytes, w, h);
}

extern "C" {

DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* info)
{
    if (!info->setAPIVersion(TOPCPlusPlusAPIVersion))
        return;
    info->executeMode = TOP_ExecuteMode::CPUMem;
    OP_CustomOPInfo& x = info->customOPInfo;
    x.opType->setString("Avfcamera");
    x.opLabel->setString("AVF Camera");
    x.opIcon->setString("AVF");
    x.authorName->setString("SYGNAL Inc.");
    x.authorEmail->setString("info@sygnal.tokyo");
    x.minInputs = 0;
    x.maxInputs = 0;
    x.majorVersion = 0;
    x.minorVersion = 9;
    if (x.opHelpURL)
        x.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/AVFoundationCamera/README.md");
}

DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new AVFCameraTOP(info, context);
}

DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (AVFCameraTOP*)instance;
}

}
