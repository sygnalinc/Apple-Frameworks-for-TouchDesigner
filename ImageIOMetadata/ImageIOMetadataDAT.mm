// ImageMetadata DAT — TouchDesigner カスタムオペレータ(macOS / ImageIO)
//
// 画像ファイルのメタデータ(EXIF・GPS・TIFF・IPTC 等)を key/value テーブルで出力する。
// TOP パイプラインを通るとメタデータは失われるため、**ファイルパス指定**で直接読む。
// 撮影日時・GPS座標・カメラ機種・露出などを演出パラメータとして使える。
//
// 出力: 基本情報(width/height/dpi/colormodel)+ 各辞書を "exif:FNumber" 形式の
// フラットな key で列挙。GPS は緯度経度を十進度に変換した "gps:latitude_deg" 等も出す。
//
// 実装: 読み取りはワーカースレッドで非同期。ファイルパス/更新時刻の変化で自動再読込。

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <utility>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

static std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }

class ImageMetadataDAT final : public DAT_CPlusPlusBase
{
public:
    explicit ImageMetadataDAT(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~ImageMetadataDAT() override
    {
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myWorker.joinable())
            myWorker.join();
    }

    void getGeneralInfo(DAT_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        std::string path;
        if (const char* p = inputs->getParString("File"))
            path = p;

        // パスまたはファイル更新時刻が変わったら再読込
        double mtime = 0;
        if (!path.empty()) {
            struct stat st;
            if (stat(path.c_str(), &st) == 0)
                mtime = (double)st.st_mtime;
        }
        if (active) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myBusy &&
                (path != myLastPath || mtime != myLastMtime)) {
                myLastPath = path;
                myLastMtime = mtime;
                myPendingPath = path;
                myHasPending = true;
                lock.unlock();
                myCond.notify_one();
            }
        }

        std::vector<std::pair<std::string, std::string>> rows;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            rows = myRows;
        }
        if (!active)
            rows.clear();

        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize((int32_t)rows.size() + 1, 2);
        output->setCellString(0, 0, "key");
        output->setCellString(0, 1, "value");
        for (int i = 0; i < (int)rows.size(); i++) {
            output->setCellString(i + 1, 0, rows[i].first.c_str());
            output->setCellString(i + 1, 1, rows[i].second.c_str());
        }
        myKeyCount = (int)rows.size();
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Image Metadata";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("File");
            p.label = "Image File";
            p.page = "Image Metadata";
            manager->appendFile(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "reads", "keys"};
        float values[3] = {(float)myExecCount, (float)myReadCount, (float)myKeyCount};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myWarning.empty())
            warning->setString(myWarning.c_str());
    }

private:
    void workerLoop()
    {
        while (true) {
            std::string path;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                path = std::move(myPendingPath);
                myHasPending = false;
                myBusy = true;
            }
            std::vector<std::pair<std::string, std::string>> rows;
            std::string warning;
            read(path, rows, warning);
            myReadCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myRows = std::move(rows);
                myWarning = std::move(warning);
                myBusy = false;
            }
        }
    }

    // NSDictionary の値を文字列化(配列は ; 区切り)
    static std::string valueToString(id v)
    {
        if ([v isKindOfClass:[NSArray class]]) {
            NSMutableArray* parts = [NSMutableArray array];
            for (id e in (NSArray*)v)
                [parts addObject:[NSString stringWithFormat:@"%@", e]];
            return nsstr([parts componentsJoinedByString:@";"]);
        }
        return nsstr([NSString stringWithFormat:@"%@", v]);
    }

    static void flattenDict(NSDictionary* dict, const std::string& prefix,
                            std::vector<std::pair<std::string, std::string>>& rows)
    {
        NSArray* keys = [dict.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString* key in keys) {
            id v = dict[key];
            const std::string k =
                prefix.empty() ? nsstr(key) : prefix + ":" + nsstr(key);
            if ([v isKindOfClass:[NSDictionary class]])
                flattenDict((NSDictionary*)v, k, rows);
            else
                rows.push_back({k, valueToString(v)});
        }
    }

    static void read(const std::string& path,
                     std::vector<std::pair<std::string, std::string>>& rows,
                     std::string& warning)
    {
        if (path.empty())
            return;
        @autoreleasepool {
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
            CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
            if (!src) {
                warning = "Cannot read image file";
                return;
            }
            NSDictionary* props = (__bridge_transfer NSDictionary*)
                CGImageSourceCopyPropertiesAtIndex(src, 0, nullptr);
            CFRelease(src);
            if (!props) {
                warning = "No metadata found";
                return;
            }

            // 基本情報を先頭に
            for (NSString* key in @[(NSString*)kCGImagePropertyPixelWidth,
                                    (NSString*)kCGImagePropertyPixelHeight,
                                    (NSString*)kCGImagePropertyDPIWidth,
                                    (NSString*)kCGImagePropertyColorModel,
                                    (NSString*)kCGImagePropertyDepth]) {
                if (props[key])
                    rows.push_back({nsstr(key.lowercaseString), valueToString(props[key])});
            }

            // GPS は十進度の緯度経度を計算して先に出す(演出で一番使う値)
            NSDictionary* gps = props[(NSString*)kCGImagePropertyGPSDictionary];
            if (gps) {
                NSNumber* lat = gps[(NSString*)kCGImagePropertyGPSLatitude];
                NSNumber* lon = gps[(NSString*)kCGImagePropertyGPSLongitude];
                NSString* latRef = gps[(NSString*)kCGImagePropertyGPSLatitudeRef];
                NSString* lonRef = gps[(NSString*)kCGImagePropertyGPSLongitudeRef];
                if (lat && lon) {
                    double la = lat.doubleValue * ([latRef isEqualToString:@"S"] ? -1 : 1);
                    double lo = lon.doubleValue * ([lonRef isEqualToString:@"W"] ? -1 : 1);
                    char buf[64];
                    snprintf(buf, sizeof(buf), "%.7f", la);
                    rows.push_back({"gps:latitude_deg", buf});
                    snprintf(buf, sizeof(buf), "%.7f", lo);
                    rows.push_back({"gps:longitude_deg", buf});
                }
            }

            // 辞書ごとにフラット化
            struct { NSString* key; const char* prefix; } dicts[] = {
                {(NSString*)kCGImagePropertyExifDictionary, "exif"},
                {(NSString*)kCGImagePropertyTIFFDictionary, "tiff"},
                {(NSString*)kCGImagePropertyGPSDictionary, "gps"},
                {(NSString*)kCGImagePropertyIPTCDictionary, "iptc"},
                {(NSString*)kCGImagePropertyPNGDictionary, "png"},
            };
            for (auto& d : dicts) {
                NSDictionary* sub = props[d.key];
                if (sub)
                    flattenDict(sub, d.prefix, rows);
            }
        }
    }

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    std::string myPendingPath, myLastPath, myWarning;
    double myLastMtime = -1;
    std::vector<std::pair<std::string, std::string>> myRows;

    std::atomic<int> myExecCount{0}, myReadCount{0}, myKeyCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Imageiometadata");
    info->customOPInfo.opLabel->setString("ImageIO Metadata");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("IMD");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/ImageIOMetadata/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new ImageMetadataDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<ImageMetadataDAT*>(instance);
}

}   // extern "C"
