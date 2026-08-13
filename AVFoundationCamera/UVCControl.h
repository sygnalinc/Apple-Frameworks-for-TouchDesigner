// USB Video Class のコントロールを、USB のコントロール転送で直接読み書きする。
//
// **なぜ必要か**: macOS の AVFoundation には手動露出が無い(`exposureDuration` / `iso` /
// `setExposureModeCustom` / `setExposureTargetBias` はいずれも iOS 専用でコンパイルが通らない)。
// 明るさ・コントラスト・彩度・ゲイン・色温度・フォーカス距離・ズームも同様。
// AVFoundation でできるのは露出とフォーカスの auto / locked だけ。
//
// **開きっぱなしにしてはいけない(実測で踏んだ)**: `USBDeviceOpen` は排他アクセスなので、
// 保持したままにすると macOS のビデオドライバと取り合いになり、
// **カメラが USB バスから落ちて AVFoundation の一覧からも消えた**(抜き差しで復帰)。
// 転送のあいだだけ開いて必ず閉じること(`Session` を使う)。
// ディスクリプタは開かずに読めるので、ユニットIDの取得に open は不要。
//
// **もうひとつの実測**: コントロール転送はカメラが**実際にストリーミングしていないと**
// `kIOReturnNotResponding`(0xe00002ed)になる。プローブは最初のフレームが届いてから行う。
//
// **実測(2026-08-13 / Logicool BRIO)**: `USBDeviceOpen` は**特別な権限も root も不要で通る**。
// カメラが AppleUSBVideo に掴まれていてもコントロール転送は別扱いで、
// 露出時間を GET_CUR=312 / MIN=3 / MAX=2047(100us単位)で読み、AEモードを手動にして
// 100(10.0ms)を書き込み、読み戻しで一致することを確認した。
#pragma once
#import <Foundation/Foundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <string>
#include <vector>

namespace tduvc {

// リクエストの形:
//   GET: bmRequestType=0xA1 / bRequest=0x81(GET_CUR) 0x82(MIN) 0x83(MAX) 0x84(RES) 0x86(INFO)
//   SET: bmRequestType=0x21 / bRequest=0x01(SET_CUR)
//   wValue = コントロールセレクタ << 8
//   wIndex = (unitID << 8) | インターフェイス番号
enum : uint8_t { kGetCur = 0x81, kGetMin = 0x82, kGetMax = 0x83, kGetRes = 0x84, kGetInfo = 0x86,
                 kSetCur = 0x01 };

// Camera Terminal(unit 1)
enum : uint8_t { kCT_AE_MODE = 0x02, kCT_EXPOSURE_ABS = 0x04, kCT_FOCUS_ABS = 0x06,
                 kCT_FOCUS_AUTO = 0x08, kCT_ZOOM_ABS = 0x0B, kCT_PANTILT_ABS = 0x0D };
// Processing Unit(unit 2 が多い)
enum : uint8_t { kPU_BRIGHTNESS = 0x02, kPU_CONTRAST = 0x03, kPU_GAIN = 0x04, kPU_SATURATION = 0x07,
                 kPU_SHARPNESS = 0x08, kPU_WB_TEMP = 0x0A, kPU_WB_AUTO = 0x0B,
                 kPU_BACKLIGHT = 0x01, kPU_POWER_LINE = 0x05 };

// ユニットは番号を決め打ちできない。**ディスクリプタから読む**(機種により 2 / 3 / 5 など)
enum class Unit { Camera, Processing };

// 値の性質。**AE モードのようなビットマップ型は GET_MIN/MAX を返さない**ので、
// 対応判定に MIN/MAX を使ってはいけない(実際にそれで Auto Exposure が無効判定になった)
enum class Kind { Range, Boolean, AEMode };

struct Control {
    const char* name;     // パラメータ名(先頭大文字)
    const char* label;
    uint8_t selector;
    Unit unit;
    uint8_t length;       // バイト数
    bool isSigned;
    Kind kind = Kind::Range;
    bool supported = false, canSet = false;
    int32_t minV = 0, maxV = 0, cur = 0;
};

// 扱うコントロール一覧。**対応可否は機種ごとに実測して決める**(GET_MIN/MAX が通るかで判定)
inline std::vector<Control> defaultControls()
{
    using U = Unit; using K = Kind;
    return {
        {"Exposureauto",  "Auto Exposure",          kCT_AE_MODE,      U::Camera,     1, false, K::AEMode},
        {"Exposuretime",  "Exposure Time (0.1ms)",  kCT_EXPOSURE_ABS, U::Camera,     4, false, K::Range},
        {"Focusauto",     "Auto Focus",             kCT_FOCUS_AUTO,   U::Camera,     1, false, K::Boolean},
        {"Focusdistance", "Focus Distance",         kCT_FOCUS_ABS,    U::Camera,     2, false, K::Range},
        {"Zoom",          "Zoom",                   kCT_ZOOM_ABS,     U::Camera,     2, false, K::Range},
        {"Brightness",    "Brightness",             kPU_BRIGHTNESS,   U::Processing, 2, true,  K::Range},
        {"Contrast",      "Contrast",               kPU_CONTRAST,     U::Processing, 2, false, K::Range},
        {"Saturation",    "Saturation",             kPU_SATURATION,   U::Processing, 2, false, K::Range},
        {"Sharpness",     "Sharpness",              kPU_SHARPNESS,    U::Processing, 2, false, K::Range},
        {"Gain",          "Gain",                   kPU_GAIN,         U::Processing, 2, false, K::Range},
        {"Whitebalauto",  "Auto White Balance",     kPU_WB_AUTO,      U::Processing, 1, false, K::Boolean},
        {"Whitebaltemp",  "White Balance (K)",      kPU_WB_TEMP,      U::Processing, 2, false, K::Range},
        {"Backlight",     "Backlight Compensation", kPU_BACKLIGHT,    U::Processing, 2, false, K::Range},
    };
}

class Device {
public:
    ~Device() { detach(); }

    // AVFoundation の modelID にある "VendorID_1133 ProductID_2142" から VID/PID を取り出す
    static bool parseModelID(const std::string& model, int& vid, int& pid)
    {
        const size_t v = model.find("VendorID_");
        const size_t p = model.find("ProductID_");
        if (v == std::string::npos || p == std::string::npos) return false;
        vid = atoi(model.c_str() + v + 9);
        pid = atoi(model.c_str() + p + 10);
        return vid != 0;
    }

    // デバイスを見つけてディスクリプタだけ読む(**開かない**)
    bool attach(int vid, int pid)
    {
        detach();
        myStatus = "no matching USB device";
        io_iterator_t it = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching(kIOUSBDeviceClassName), &it) != kIOReturnSuccess) return false;
        io_service_t dev;
        while ((dev = IOIteratorNext(it))) {
            if (idOf(dev, CFSTR("idVendor")) != vid || idOf(dev, CFSTR("idProduct")) != pid) {
                IOObjectRelease(dev); continue;
            }
            IOCFPlugInInterface** plug = nullptr; SInt32 score = 0;
            if (IOCreatePlugInInterfaceForService(dev, kIOUSBDeviceUserClientTypeID,
                    kIOCFPlugInInterfaceID, &plug, &score) == kIOReturnSuccess && plug) {
                (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                        (LPVOID*)&myUSB);
                (*plug)->Release(plug);
            }
            if (myUSB) {
                myService = dev;
                readDescriptors();          // open 不要。ユニットIDとインターフェイス番号を実物から取る
                myStatus = (myCameraUnit || myProcessingUnit) ? "ok" : "no UVC control units";
                IOObjectRelease(it);
                return true;
            }
            myStatus = "cannot create USB interface";
            if (myUSB) { (*myUSB)->Release(myUSB); myUSB = nullptr; }
            IOObjectRelease(dev);
        }
        IOObjectRelease(it);
        return false;
    }

    void detach()
    {
        endSession();
        if (myUSB) { (*myUSB)->Release(myUSB); myUSB = nullptr; }
        if (myService) { IOObjectRelease(myService); myService = 0; }
    }

    // **転送のあいだだけ開く**。開きっぱなしにするとカメラがバスから落ちる
    bool beginSession()
    {
        if (!myUSB) return false;
        if (myOpen) return true;
        const IOReturn r = (*myUSB)->USBDeviceOpen(myUSB);
        if (r != kIOReturnSuccess) {
            char b[64]; snprintf(b, sizeof b, "USBDeviceOpen 0x%x", r);
            myLastErr = b;
            return false;
        }
        myOpen = true;
        return true;
    }

    void endSession()
    {
        if (myUSB && myOpen) (*myUSB)->USBDeviceClose(myUSB);
        myOpen = false;
    }

    // スコープを抜けたら必ず閉じる
    struct Session {
        Device& d; const bool ok;
        explicit Session(Device& dev) : d(dev), ok(dev.beginSession()) {}
        ~Session() { d.endSession(); }
    };

    bool isOpen() const { return myUSB != nullptr; }
    const std::string& status() const { return myStatus; }
    const std::string& lastError() const { return myLastErr; }
    int vcInterface() const { return myVCInterface; }

    int cameraUnit() const { return myCameraUnit; }
    int processingUnit() const { return myProcessingUnit; }

    bool get(const Control& c, uint8_t request, int32_t& out) const
    {
        if (!myUSB) return false;
        uint8_t buf[8] = {};
        const uint8_t len = (request == kGetInfo) ? 1 : c.length;   // GET_INFO は必ず1バイト
        if (!request3(0xA1, request, c, buf, len)) return false;
        out = decode(buf, len, request == kGetInfo ? false : c.isSigned);
        return true;
    }

    bool set(const Control& c, int32_t value) const
    {
        if (!myUSB || !c.canSet) return false;
        int32_t v = value;
        if (c.kind == Kind::AEMode) v = value ? myAutoAE : 0x01;   // 自動 / 手動
        uint8_t buf[8] = {};
        for (int i = 0; i < c.length; i++) buf[i] = (uint8_t)((v >> (8 * i)) & 0xFF);
        return request3(0x21, kSetCur, c, buf, c.length);
    }

    // 対応判定は **GET_INFO**(bit0=GET可 / bit1=SET可)。MIN/MAX は範囲型にしか無いので、
    // これを判定に使うとビットマップ型(AEモード)やブール型が落ちる
    void probe(std::vector<Control>& list)
    {
        Session s(*this);
        if (!s.ok) { for (Control& c : list) c.supported = false; return; }
        for (Control& c : list) {
            if (unitID(c) == 0) { c.supported = false; continue; }
            // **GET_CUR を先に出す**。対応していないリクエストは EP0 を stall させるので、
            // 先に GET_INFO を投げると以降の転送まで巻き添えで失敗する(実際に全滅した)
            int32_t info = 0, cur = 0;
            const bool hasCur = get(c, kGetCur, cur);
            c.supported = hasCur;
            c.canSet = hasCur;
            if (!c.supported) continue;
            if (get(c, kGetInfo, info) && info) c.canSet = (info & 0x02) != 0;
            c.cur = cur;
            if (c.kind == Kind::Range) {
                int32_t lo = 0, hi = 0;
                if (get(c, kGetMin, lo) && get(c, kGetMax, hi)) { c.minV = lo; c.maxV = hi; }
            } else {
                c.minV = 0; c.maxV = 1;
                // AE モードはビットマップ(1=手動 / 2=自動 / 4=シャッター優先 / 8=絞り優先)。
                // TD 側はトグルにしたいので、手動(1)以外を「自動」とみなす
                if (c.kind == Kind::AEMode) {
                    // GET_RES が対応モードのビットマップを返す。自動側は
                    // 絞り優先(8) > 自動(2) の順で使えるものを選ぶ
                    int32_t res = 0;
                    if (get(c, kGetRes, res) && res) {
                        if (res & 0x08) myAutoAE = 0x08;
                        else if (res & 0x02) myAutoAE = 0x02;
                        else if (res & 0x04) myAutoAE = 0x04;
                    }
                    c.cur = (cur == 0x01) ? 0 : 1;
                }
            }
        }
    }

private:
    static int idOf(io_service_t s, CFStringRef key)
    {
        CFNumberRef n = (CFNumberRef)IORegistryEntryCreateCFProperty(s, key, nullptr, 0);
        int v = 0;
        if (n) { CFNumberGetValue(n, kCFNumberIntType, &v); CFRelease(n); }
        return v;
    }

    uint8_t unitID(const Control& c) const
    {
        return c.unit == Unit::Camera ? (uint8_t)myCameraUnit : (uint8_t)myProcessingUnit;
    }

    bool request3(uint8_t type, uint8_t req, const Control& c, void* data, uint8_t len) const
    {
        const uint8_t unit = unitID(c);
        if (!unit) return false;
        IOUSBDevRequest q = {};
        q.bmRequestType = type;
        q.bRequest = req;
        q.wValue = (uint16_t)(c.selector << 8);
        q.wIndex = (uint16_t)((unit << 8) | myVCInterface);
        q.wLength = len;
        q.pData = data;
        const IOReturn r = (*myUSB)->DeviceRequest(myUSB, &q);
        if (r != kIOReturnSuccess) {
            char b[96];
            snprintf(b, sizeof b, "req=0x%02x sel=0x%02x unit=%u if=%d len=%u -> 0x%x",
                     req, c.selector, unit, myVCInterface, len, r);
            myLastErr = b;
        }
        return r == kIOReturnSuccess;
    }

    // コンフィグレーションディスクリプタを歩いて、VideoControl インターフェイス番号と
    // Camera Terminal / Processing Unit のユニットIDを拾う
    void readDescriptors()
    {
        myCameraUnit = myProcessingUnit = 0;
        myVCInterface = 0;
        IOUSBConfigurationDescriptorPtr cfg = nullptr;
        if (!myUSB || (*myUSB)->GetConfigurationDescriptorPtr(myUSB, 0, &cfg) != kIOReturnSuccess || !cfg)
            return;
        const uint8_t* p = (const uint8_t*)cfg;
        const uint16_t total = (uint16_t)(p[2] | (p[3] << 8));
        bool inVC = false;
        for (uint16_t i = 0; i + 1 < total; ) {
            const uint8_t len = p[i], type = p[i + 1];
            if (len < 2) break;
            if (type == 0x04 && i + 6 < total) {                 // INTERFACE
                const uint8_t cls = p[i + 5], sub = p[i + 6];
                inVC = (cls == 0x0E && sub == 0x01);             // Video / VideoControl
                if (inVC) myVCInterface = p[i + 2];
            } else if (type == 0x24 && inVC && len >= 4) {       // CS_INTERFACE
                const uint8_t subtype = p[i + 2];
                if (subtype == 0x02 && len >= 6) {               // INPUT_TERMINAL
                    const uint16_t tt = (uint16_t)(p[i + 4] | (p[i + 5] << 8));
                    if (tt == 0x0201) myCameraUnit = p[i + 3];   // ITT_CAMERA
                } else if (subtype == 0x05) {                    // PROCESSING_UNIT
                    myProcessingUnit = p[i + 3];
                }
            }
            i += len;
        }
    }

    static int32_t decode(const uint8_t* b, int len, bool sign)
    {
        int32_t v = 0;
        for (int i = 0; i < len; i++) v |= ((int32_t)b[i]) << (8 * i);
        if (sign && len == 2 && (v & 0x8000)) v -= 0x10000;
        return v;
    }

    IOUSBDeviceInterface** myUSB = nullptr;
    io_service_t myService = 0;
    int myCameraUnit = 0, myProcessingUnit = 0, myVCInterface = 0;
    int myAutoAE = 0x08;
    bool myOpen = false;
    std::string myStatus = "not opened";
    mutable std::string myLastErr;
};

} // namespace tduvc
