// Spatial Video TOP — MV-HEVC の空間ビデオから左右眼のフレームを取り出して TOP に出す。
// AVAssetReader + AVAssetReaderTrackOutput に MV-HEVC の両レイヤー(VideoLayerID 0/1)を
// 要求してデコードし、CMTaggedBufferGroup から左眼/右眼の CVPixelBuffer を分離する。
//
//   Eye = Left / Right / Side-by-Side(左右連結)を選べる。
//   Time(0..1)でスクラブ。デコードはワーカースレッド(cook 非ブロック)。
//
// これで空間ビデオの各眼を TD の映像として扱える(立体視の分解・視差合成の素材)。
//
// メタデータ(旧 Spatial Video DAT を統合): CMFormatDescription 拡張から
// baseline / FOV / hero eye 等を読み、数値は Info CHOP、全項目は Info DAT(key/value)に出す。
// Info CHOP / Info DAT をこのノードに向けるだけで旧DATと同じ情報が得られる。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {

struct Frame
{
    std::vector<uint8_t> bgra;
    uint32_t w = 0, h = 0;
    uint64_t serial = 0;
    bool ok = false;
    bool spatial = false;
};

static std::string fourcc(uint32_t c)
{
    char b[5] = {(char)((c >> 24) & 0xff), (char)((c >> 16) & 0xff),
                 (char)((c >> 8) & 0xff), (char)(c & 0xff), 0};
    return b;
}

class SpatialVideoTOP final : public TOP_CPlusPlusBase
{
public:
    SpatialVideoTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c)
    {
        myThread = std::thread([this] { worker(); });
    }
    ~SpatialVideoTOP() override
    {
        {
            std::lock_guard<std::mutex> l(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myThread.joinable())
            myThread.join();
    }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
    }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        std::string path = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        std::string eye = in->getParString("Eye") ? in->getParString("Eye") : "left";
        double t = in->getParDouble("Time");
        std::string sig = path + "|" + eye + "|" + std::to_string(t);
        if (sig != mySig) {
            mySig = sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) {
                myPath = path;
                myEye = eye;
                myT = t;
                myPending = true;
                mySubmit++;
                l.unlock();
                myCond.notify_one();
            } else {
                mySig.clear();   // 取りこぼしたら次cookで再投入
            }
        }

        Frame r;
        {
            std::lock_guard<std::mutex> l(myMutex);
            if (myResult.serial == myUploaded || !myResult.ok || myResult.bgra.empty())
                return;
            r = myResult;
            myUploaded = r.serial;
        }
        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = r.w;
        ui.textureDesc.height = r.h;
        ui.textureDesc.pixelFormat = OP_PixelFormat::BGRA8Fixed;
        auto b = myContext->createOutputBuffer((size_t)r.w * r.h * 4, TOP_BufferFlags::None, nullptr);
        if (!b)
            return;
        memcpy(b->data, r.bgra.data(), r.bgra.size());
        out->uploadBuffer(&b, ui, nullptr);
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "Spatial Video";
        {
            OP_StringParameter p("File");
            p.label = "Spatial Video File (MV-HEVC)";
            p.page = P;
            m->appendFile(p);
        }
        {
            OP_StringParameter p("Eye");
            p.label = "Eye";
            p.page = P;
            p.defaultValue = "left";
            const char* n[] = {"left", "right", "sbs"};
            const char* l[] = {"Left", "Right", "Side-by-Side"};
            m->appendMenu(p, 3, n, l);
        }
        {
            OP_NumericParameter p("Time");
            p.label = "Time (0..1)";
            p.page = P;
            p.defaultValues[0] = 0.0;
            p.minSliders[0] = 0;
            p.maxSliders[0] = 1;
            m->appendFloat(p);
        }
    }

    // Info CHOP: 診断 + 旧 Spatial Video DAT の数値メタデータ
    int32_t getNumInfoCHOPChans(void*) override { return 13; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[13] = {"executes", "submits", "decodes", "is_spatial",
                             "width", "height", "duration", "fps",
                             "baseline_mm", "horizontal_fov_deg", "disparity_adjustment",
                             "has_left_eye", "has_right_eye"};
        float v[13] = {(float)myExec.load(), (float)mySubmit.load(),
                       (float)myDecodes.load(), (float)mySpatial.load(),
                       (float)myMetaW.load(), (float)myMetaH.load(),
                       myMetaDur.load(), myMetaFps.load(),
                       myBaselineMm.load(), myFovDeg.load(), (float)myDispAdj.load(),
                       (float)myHasL.load(), (float)myHasR.load()};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    // Info DAT: 旧 Spatial Video DAT の key/value テーブル(codec / hero_eye 等の文字列も含む)
    bool getInfoDATSize(OP_InfoDATSize* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        s->rows = (int32_t)myMetaRows.size() + 1;
        s->cols = 2;
        s->byColumn = false;
        return true;
    }
    void getInfoDATEntries(int32_t index, int32_t nEntries, OP_InfoDATEntries* e, void*) override
    {
        if (nEntries < 2)
            return;
        if (index == 0) {
            e->values[0]->setString("key");
            e->values[1]->setString("value");
            return;
        }
        std::lock_guard<std::mutex> l(myMutex);
        int i = index - 1;
        if (i < 0 || i >= (int)myMetaRows.size())
            return;
        e->values[0]->setString(myMetaRows[i].first.c_str());
        e->values[1]->setString(myMetaRows[i].second.c_str());
    }

    void getWarningString(OP_String* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (!myWarn.empty())
            s->setString(myWarn.c_str());
    }

private:
    void worker()
    {
        for (;;) {
            std::string path, eye;
            double t;
            {
                std::unique_lock<std::mutex> l(myMutex);
                myCond.wait(l, [this] { return myPending || myQuit; });
                if (myQuit)
                    return;
                myBusy = true;
                myPending = false;
                path = myPath;
                eye = myEye;
                t = myT;
            }
            if (path != myMetaPath) {   // ファイル変更時のみメタデータ解析(worker上・cook非ブロック)
                myMetaPath = path;
                analyze(path);
            }
            Frame r;
            r.serial = ++mySerial;
            std::string warn;
            decode(path, eye, t, r, warn);
            if (r.ok)
                myDecodes++;
            {
                std::lock_guard<std::mutex> l(myMutex);
                myResult = r;
                myWarn = warn;
                myBusy = false;
            }
        }
    }

    // 旧 Spatial Video DAT のメタデータ解析。key/value 行と数値 atomics を更新する
    void analyze(const std::string& path)
    {
        std::vector<std::pair<std::string, std::string>> rows;
        myMetaW = myMetaH = myDispAdj = myHasL = myHasR = 0;
        myMetaDur = myMetaFps = myBaselineMm = myFovDeg = 0.0f;
        mySpatial = 0;
        if (path.empty()) {
            std::lock_guard<std::mutex> l(myMutex);
            myMetaRows.clear();
            return;
        }
        @autoreleasepool {
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
            AVURLAsset* asset = [AVURLAsset assetWithURL:url];
            AVAssetTrack* vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            CMFormatDescriptionRef fmt =
                vt ? (__bridge CMFormatDescriptionRef)vt.formatDescriptions.firstObject : nullptr;
            if (!fmt) {
                rows.push_back({"error", vt ? "no format description" : "no video track"});
                std::lock_guard<std::mutex> l(myMutex);
                myMetaRows = std::move(rows);
                return;
            }
            CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fmt);
            uint32_t codec = CMFormatDescriptionGetMediaSubType(fmt);
            double dur = CMTimeGetSeconds(asset.duration);
            float fps = vt.nominalFrameRate;

            auto ext = [&](CFStringRef key) -> CFTypeRef {
                return CMFormatDescriptionGetExtension(fmt, key);
            };
            auto boolExt = [](CFTypeRef v) {
                return v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v);
            };
            bool hasLeft = boolExt(ext(kCMFormatDescriptionExtension_HasLeftStereoEyeView));
            bool hasRight = boolExt(ext(kCMFormatDescriptionExtension_HasRightStereoEyeView));
            bool spatial = hasLeft && hasRight;

            char b[64];
            rows.push_back({"codec", fourcc(codec)});
            rows.push_back({"width", std::to_string(dim.width)});
            rows.push_back({"height", std::to_string(dim.height)});
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
            if (CFNumberRef n = (CFNumberRef)ext(kCMFormatDescriptionExtension_StereoCameraBaseline)) {
                uint32_t micrometers = 0;
                CFNumberGetValue(n, kCFNumberSInt32Type, &micrometers);
                myBaselineMm = (float)(micrometers / 1000.0);
                snprintf(b, sizeof(b), "%.3f", micrometers / 1000.0);
                rows.push_back({"baseline_mm", b});
            }
            // 水平視野角: thousandths of a degree → degree
            if (CFNumberRef n = (CFNumberRef)ext(kCMFormatDescriptionExtension_HorizontalFieldOfView)) {
                uint32_t thou = 0;
                CFNumberGetValue(n, kCFNumberSInt32Type, &thou);
                myFovDeg = (float)(thou / 1000.0);
                snprintf(b, sizeof(b), "%.3f", thou / 1000.0);
                rows.push_back({"horizontal_fov_deg", b});
            }
            // 水平視差調整(正規化値・符号付き)
            if (CFNumberRef n = (CFNumberRef)ext(kCMFormatDescriptionExtension_HorizontalDisparityAdjustment)) {
                int32_t v = 0;
                CFNumberGetValue(n, kCFNumberSInt32Type, &v);
                myDispAdj = v;
                rows.push_back({"horizontal_disparity_adjustment", std::to_string(v)});
            }

            myMetaW = dim.width;
            myMetaH = dim.height;
            myMetaDur = (float)dur;
            myMetaFps = fps;
            myHasL = hasLeft ? 1 : 0;
            myHasR = hasRight ? 1 : 0;
            mySpatial = spatial ? 1 : 0;
        }
        std::lock_guard<std::mutex> l(myMutex);
        myMetaRows = std::move(rows);
    }

    // CVPixelBuffer(BGRA)を行コピーで vector に
    static bool copyPB(CVPixelBufferRef pb, std::vector<uint8_t>& out, uint32_t& w, uint32_t& h)
    {
        if (!pb)
            return false;
        CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        w = (uint32_t)CVPixelBufferGetWidth(pb);
        h = (uint32_t)CVPixelBufferGetHeight(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(pb);
        bool ok = false;
        if (base && w && h) {
            out.assign((size_t)w * h * 4, 0);
            for (uint32_t y = 0; y < h; y++)
                memcpy(out.data() + (size_t)y * w * 4, base + (size_t)y * bpr, (size_t)w * 4);
            ok = true;
        }
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        return ok;
    }

    void decode(const std::string& path, const std::string& eye, double t, Frame& r,
                std::string& warn)
    {
        if (path.empty()) {
            warn = "Set a Spatial Video file (MV-HEVC).";
            return;
        }
        @autoreleasepool {
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
            AVURLAsset* asset = [AVURLAsset assetWithURL:url];
            AVAssetTrack* vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            if (!vt) {
                warn = "No video track.";
                return;
            }
            double dur = CMTimeGetSeconds(asset.duration);
            double at = std::max(0.0, std::min(1.0, t)) * (dur > 0 ? dur : 0);

            NSError* err = nil;
            AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
            if (!reader) {
                warn = err ? err.localizedDescription.UTF8String : "reader init failed";
                return;
            }
            // 指定時刻の1フレームだけ読む
            reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(at, 600),
                                               CMTimeMakeWithSeconds(1.0, 600));
            // MV-HEVC の両レイヤーを要求(0=左/1=右 が一般的)
            NSDictionary* decomp = @{
                (id)kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs : @[ @0, @1 ]
            };
            NSDictionary* settings = @{
                (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                (id)AVVideoDecompressionPropertiesKey : decomp
            };
            AVAssetReaderTrackOutput* trackOut =
                [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vt
                                                           outputSettings:settings];
            trackOut.alwaysCopiesSampleData = NO;
            if (![reader canAddOutput:trackOut]) {
                warn = "Cannot add reader output.";
                return;
            }
            [reader addOutput:trackOut];
            if (![reader startReading]) {
                warn = reader.error ? reader.error.localizedDescription.UTF8String
                                    : "startReading failed";
                return;
            }
            CMSampleBufferRef sample = [trackOut copyNextSampleBuffer];
            if (!sample) {
                [reader cancelReading];
                warn = "No frame at requested time.";
                return;
            }

            std::vector<uint8_t> left, right;
            uint32_t lw = 0, lh = 0, rw = 0, rh = 0;
            bool haveLeft = false, haveRight = false;

            CMTaggedBufferGroupRef grp = CMSampleBufferGetTaggedBufferGroup(sample);
            if (grp) {
                r.spatial = true;
                CFIndex n = CMTaggedBufferGroupGetCount(grp);
                for (CFIndex i = 0; i < n; i++) {
                    CMTagCollectionRef tags = CMTaggedBufferGroupGetTagCollectionAtIndex(grp, i);
                    int64_t layer = -1;
                    if (tags) {
                        CMTag tag;
                        CMItemCount got = 0;
                        if (CMTagCollectionGetTagsWithCategory(
                                tags, kCMTagCategory_VideoLayerID, &tag, 1, &got) == 0 &&
                            got > 0)
                            layer = CMTagGetSInt64Value(tag);
                    }
                    CVPixelBufferRef pb = CMTaggedBufferGroupGetCVPixelBufferAtIndex(grp, i);
                    if (layer == 1) {
                        haveRight = copyPB(pb, right, rw, rh);
                    } else {
                        haveLeft = copyPB(pb, left, lw, lh);   // layer 0 or unknown → left
                    }
                }
            } else {
                // 立体視でない/タグ無し → 通常のイメージバッファを左眼として扱う
                CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
                haveLeft = copyPB(pb, left, lw, lh);
                r.spatial = false;
            }
            CFRelease(sample);
            [reader cancelReading];

            if (eye == "right" && haveRight) {
                r.bgra = std::move(right);
                r.w = rw;
                r.h = rh;
                r.ok = true;
            } else if (eye == "sbs" && haveLeft && haveRight && lh == rh) {
                r.w = lw + rw;
                r.h = lh;
                r.bgra.assign((size_t)r.w * r.h * 4, 0);
                for (uint32_t y = 0; y < r.h; y++) {
                    memcpy(r.bgra.data() + (size_t)y * r.w * 4,
                           left.data() + (size_t)y * lw * 4, (size_t)lw * 4);
                    memcpy(r.bgra.data() + (size_t)y * r.w * 4 + (size_t)lw * 4,
                           right.data() + (size_t)y * rw * 4, (size_t)rw * 4);
                }
                r.ok = true;
            } else if (haveLeft) {
                r.bgra = std::move(left);
                r.w = lw;
                r.h = lh;
                r.ok = true;
                if (eye == "right" && !haveRight)
                    warn = "No right-eye layer found; showing left.";
            } else {
                warn = "Could not extract a frame.";
            }
        }
    }

    TOP_Context* myContext = nullptr;
    std::thread myThread;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myPending = false, myBusy = false, myQuit = false;
    std::string myPath, myEye, mySig, myWarn;
    double myT = 0;
    Frame myResult;
    uint64_t myUploaded = 0;
    std::atomic<uint64_t> mySerial{0};
    std::atomic<int> myExec{0}, mySubmit{0}, myDecodes{0}, mySpatial{0};
    // メタデータ(旧 Spatial Video DAT)
    std::string myMetaPath = "\x01";   // worker専用
    std::vector<std::pair<std::string, std::string>> myMetaRows;   // myMutex 保護
    std::atomic<int> myMetaW{0}, myMetaH{0}, myDispAdj{0}, myHasL{0}, myHasR{0};
    std::atomic<float> myMetaDur{0.0f}, myMetaFps{0.0f}, myBaselineMm{0.0f}, myFovDeg{0.0f};
};

}   // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* info)
{
    if (!info->setAPIVersion(TOPCPlusPlusAPIVersion))
        return;
    info->executeMode = TOP_ExecuteMode::CPUMem;
    info->customOPInfo.opType->setString("Spatialvideo");
    info->customOPInfo.opLabel->setString("Spatial Video");
    info->customOPInfo.opIcon->setString("SPV");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/SpatialVideo/README.md");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c)
{
    return new SpatialVideoTOP(i, c);
}
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*)
{
    delete static_cast<SpatialVideoTOP*>(i);
}
}
