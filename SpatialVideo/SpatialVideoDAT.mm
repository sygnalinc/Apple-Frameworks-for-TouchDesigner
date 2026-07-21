// Spatial Video DAT — MV-HEVC の空間ビデオ(Apple Spatial Video / 立体視)の
// メタデータを読み出す。左右眼の有無・ヒーローアイ・カメラ基線・水平視野角・水平視差調整・
// 解像度・尺・fps・コーデックを key/value テーブルに出力する。
//
// これらは映像トラックのフォーマット記述(CMFormatDescription)拡張から取得する
// (kCMFormatDescriptionExtension_HasLeft/RightStereoEyeView / HeroEye /
//  StereoCameraBaseline / HorizontalFieldOfView / HorizontalDisparityAdjustment)。
// 実デコードは Spatial Video TOP 側で行う。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {

static std::string fourcc(uint32_t c)
{
    char b[5] = {(char)((c >> 24) & 0xff), (char)((c >> 16) & 0xff),
                 (char)((c >> 8) & 0xff), (char)(c & 0xff), 0};
    return b;
}

class SpatialVideoDAT final : public DAT_CPlusPlusBase
{
public:
    explicit SpatialVideoDAT(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }
    ~SpatialVideoDAT() override
    {
        {
            std::lock_guard<std::mutex> l(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myWorker.joinable())
            myWorker.join();
    }

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExec++;
        const char* pathC = inputs->getParFilePath("File");
        std::string path = pathC ? pathC : "";
        if (path != myLastPath) {
            myLastPath = path;
            std::lock_guard<std::mutex> l(myMutex);
            myPendingPath = path;
            myHasPending = true;
            myCond.notify_one();
        }

        std::vector<std::pair<std::string, std::string>> rows;
        {
            std::lock_guard<std::mutex> l(myMutex);
            rows = myRows;
        }
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize((int)rows.size() + 1, 2);
        output->setCellString(0, 0, "key");
        output->setCellString(0, 1, "value");
        for (int i = 0; i < (int)rows.size(); i++) {
            output->setCellString(i + 1, 0, rows[i].first.c_str());
            output->setCellString(i + 1, 1, rows[i].second.c_str());
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        OP_StringParameter p("File");
        p.label = "Spatial Video File (MV-HEVC)";
        p.page = "Spatial Video";
        m->appendFile(p);
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[5] = {"executes", "is_spatial", "width", "height", "baseline_mm"};
        float v[5] = {(float)myExec.load(), (float)myIsSpatial.load(),
                      (float)myW.load(), (float)myH.load(), myBaselineMm.load()};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    void getWarningString(OP_String* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (!myWarn.empty())
            s->setString(myWarn.c_str());
    }

private:
    void workerLoop()
    {
        for (;;) {
            std::string path;
            {
                std::unique_lock<std::mutex> l(myMutex);
                myCond.wait(l, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                path = myPendingPath;
                myHasPending = false;
            }
            std::vector<std::pair<std::string, std::string>> rows;
            std::string warn;
            analyze(path, rows, warn);
            {
                std::lock_guard<std::mutex> l(myMutex);
                myRows = std::move(rows);
                myWarn = std::move(warn);
            }
        }
    }

    void analyze(const std::string& path,
                 std::vector<std::pair<std::string, std::string>>& rows, std::string& warn)
    {
        if (path.empty()) {
            warn = "Set a Spatial Video file (MV-HEVC .MOV/.MP4).";
            myIsSpatial = 0;
            return;
        }
        @autoreleasepool {
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
            AVURLAsset* asset = [AVURLAsset assetWithURL:url];
            AVAssetTrack* vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            if (!vt) {
                warn = "No video track in file.";
                myIsSpatial = 0;
                return;
            }
            CMFormatDescriptionRef fmt =
                (__bridge CMFormatDescriptionRef)vt.formatDescriptions.firstObject;
            if (!fmt) {
                warn = "No format description.";
                return;
            }
            CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fmt);
            uint32_t codec = CMFormatDescriptionGetMediaSubType(fmt);
            double dur = CMTimeGetSeconds(asset.duration);
            float fps = vt.nominalFrameRate;

            auto ext = [&](CFStringRef key) -> CFTypeRef {
                return CMFormatDescriptionGetExtension(fmt, key);
            };
            bool hasLeft = boolExt(ext(kCMFormatDescriptionExtension_HasLeftStereoEyeView));
            bool hasRight = boolExt(ext(kCMFormatDescriptionExtension_HasRightStereoEyeView));
            bool spatial = hasLeft && hasRight;

            rows.push_back({"codec", fourcc(codec)});
            rows.push_back({"width", std::to_string(dim.width)});
            rows.push_back({"height", std::to_string(dim.height)});
            char b[64];
            snprintf(b, sizeof(b), "%.3f", dur);
            rows.push_back({"duration", b});
            snprintf(b, sizeof(b), "%.3f", fps);
            rows.push_back({"fps", b});
            rows.push_back({"is_spatial", spatial ? "1" : "0"});
            rows.push_back({"has_left_eye", hasLeft ? "1" : "0"});
            rows.push_back({"has_right_eye", hasRight ? "1" : "0"});

            CFStringRef hero = (CFStringRef)ext(kCMFormatDescriptionExtension_HeroEye);
            std::string heroStr = "none";
            if (hero) {
                if (CFEqual(hero, kCMFormatDescriptionHeroEye_Left))
                    heroStr = "left";
                else if (CFEqual(hero, kCMFormatDescriptionHeroEye_Right))
                    heroStr = "right";
            }
            rows.push_back({"hero_eye", heroStr});

            // 基線: micrometers → mm
            double baselineMm = 0;
            if (CFNumberRef n = (CFNumberRef)ext(kCMFormatDescriptionExtension_StereoCameraBaseline)) {
                uint32_t micrometers = 0;
                CFNumberGetValue(n, kCFNumberSInt32Type, &micrometers);
                baselineMm = micrometers / 1000.0;
                snprintf(b, sizeof(b), "%.3f", baselineMm);
                rows.push_back({"baseline_mm", b});
            }
            // 水平視野角: thousandths of a degree → degree
            if (CFNumberRef n = (CFNumberRef)ext(kCMFormatDescriptionExtension_HorizontalFieldOfView)) {
                uint32_t thou = 0;
                CFNumberGetValue(n, kCFNumberSInt32Type, &thou);
                snprintf(b, sizeof(b), "%.3f", thou / 1000.0);
                rows.push_back({"horizontal_fov_deg", b});
            }
            // 水平視差調整(正規化値・符号付き)
            if (CFNumberRef n = (CFNumberRef)ext(kCMFormatDescriptionExtension_HorizontalDisparityAdjustment)) {
                int32_t v = 0;
                CFNumberGetValue(n, kCFNumberSInt32Type, &v);
                rows.push_back({"horizontal_disparity_adjustment", std::to_string(v)});
            }

            myW = dim.width;
            myH = dim.height;
            myIsSpatial = spatial ? 1 : 0;
            myBaselineMm = (float)baselineMm;
            if (!spatial)
                warn = "Not a stereo/spatial (MV-HEVC) video; only basic info shown.";
        }
    }

    static bool boolExt(CFTypeRef v)
    {
        return v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v);
    }

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false, myHasPending = false;
    std::string myPendingPath, myLastPath = "\x01", myWarn;
    std::vector<std::pair<std::string, std::string>> myRows;
    std::atomic<int> myExec{0}, myIsSpatial{0}, myW{0}, myH{0};
    std::atomic<float> myBaselineMm{0.0f};
};

}   // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Spatialvideo");
    info->customOPInfo.opLabel->setString("Spatial Video");
    info->customOPInfo.opIcon->setString("SPV");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* info)
{
    return new SpatialVideoDAT(info);
}
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<SpatialVideoDAT*>(instance);
}
}
