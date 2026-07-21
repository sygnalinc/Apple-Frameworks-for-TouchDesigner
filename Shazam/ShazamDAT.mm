// Shazam DAT — TouchDesigner カスタムオペレータ(macOS / ShazamKit)
//
// **自作音源のオフライン照合**。Reference Folder の音声ファイル群からカスタムカタログを
// 構築し、Audio CHOP のライブ音声がどの曲の何秒目かを判定する。
// 「会場に流れている音源にショー進行を同期する」「どの曲がかかったかで演出切替」に使える。
// カスタムカタログ照合は完全オンデバイス(ネットワーク不要・エンタイトルメント不要)。
//
// 出力テーブル: status / matched / title / offset(曲頭からの秒)/ skew / tracks
// 数値は Info CHOP(matched / offset)からも取れる。
//
// 実装: ShazamKit は Swift 中心のため helper dylib(sh_ プレフィックス)で包む。
// カタログ構築は非同期(数秒/曲)。マッチはストリーミング(数秒ぶん聞くと確定)。

#import <Foundation/Foundation.h>

#include <atomic>
#include <cstring>
#include <string>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

extern "C" {
void* sh_create(void);
void sh_build_catalog(void* h, const char* folder);
void sh_feed(void* h, const float* samples, int32_t count, double rate);
void sh_poll(void* h, char* buf, int32_t n);
void sh_reset(void* h);
void sh_destroy(void* h);
}

namespace {

class ShazamDAT final : public DAT_CPlusPlusBase
{
public:
    explicit ShazamDAT(const OP_NodeInfo*) { mySession = sh_create(); }

    ~ShazamDAT() override
    {
        if (mySession)
            sh_destroy(mySession);
    }

    void getGeneralInfo(DAT_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;

        // カタログ構築要求
        if (myBuildRequested && mySession) {
            myBuildRequested = false;
            if (const char* f = inputs->getParString("Referencefolder"))
                sh_build_catalog(mySession, f);
        }

        // 音声を流し込む(モノラル ch0)
        const OP_CHOPInput* audio = inputs->getParCHOP("Audio");
        if (active && mySession && audio && audio->numChannels > 0 &&
            audio->numSamples > 0) {
            sh_feed(mySession, audio->getChannelData(0), audio->numSamples,
                    audio->sampleRate);
        }

        // 状態JSONをポーリング
        char buf[2048] = {0};
        if (mySession)
            sh_poll(mySession, buf, sizeof(buf));
        parsePoll(buf);

        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize(7, 2);
        output->setCellString(0, 0, "key");
        output->setCellString(0, 1, "value");
        const char* keys[6] = {"status", "matched", "title", "offset", "skew", "tracks"};
        std::string* vals[6] = {&myStatus, &myMatchedStr, &myTitle, &myOffsetStr,
                                &mySkewStr, &myTracksStr};
        for (int i = 0; i < 6; i++) {
            output->setCellString(i + 1, 0, keys[i]);
            output->setCellString(i + 1, 1, vals[i]->c_str());
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Audio");
            p.label = "Audio CHOP";
            p.page = "Shazam";
            manager->appendCHOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Shazam";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Referencefolder");
            p.label = "Reference Folder";
            p.page = "Shazam";
            manager->appendFolder(p);
        }
        {
            OP_NumericParameter p("Buildcatalog");
            p.label = "Build Catalog";
            p.page = "Shazam";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Reset");
            p.label = "Reset Match";
            p.page = "Shazam";
            manager->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Buildcatalog") == 0)
            myBuildRequested = true;
        else if (strcmp(name, "Reset") == 0 && mySession)
            sh_reset(mySession);
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[4] = {"executes", "matched", "offset", "tracks"};
        float values[4] = {(float)myExecCount, myMatched ? 1.0f : 0.0f, myOffset,
                           (float)myTracks};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        if (!mySession)
            warning->setString("ShazamKit requires macOS 12+");
        else if (myTracks == 0)
            warning->setString("Set Reference Folder and pulse Build Catalog");
    }

private:
    // 依存を増やさない超簡易JSONパース(ヘルパの固定形式前提)
    void parsePoll(const char* json)
    {
        auto findStr = [&](const char* key, std::string& out) {
            std::string pat = std::string("\"") + key + "\":\"";
            const char* p = strstr(json, pat.c_str());
            if (!p) {
                out.clear();
                return;
            }
            p += pat.size();
            const char* e = strchr(p, '"');
            out = e ? std::string(p, e - p) : "";
        };
        auto findNum = [&](const char* key) -> double {
            std::string pat = std::string("\"") + key + "\":";
            const char* p = strstr(json, pat.c_str());
            return p ? atof(p + pat.size()) : 0.0;
        };
        findStr("status", myStatus);
        findStr("title", myTitle);
        myMatched = strstr(json, "\"matched\":true") != nullptr;
        myOffset = (float)findNum("offset");
        const double skew = findNum("skew");
        const int tracks = (int)findNum("tracks");
        myTracks = tracks;
        char buf[32];
        snprintf(buf, sizeof(buf), "%d", myMatched ? 1 : 0);
        myMatchedStr = buf;
        snprintf(buf, sizeof(buf), "%.2f", myOffset);
        myOffsetStr = buf;
        snprintf(buf, sizeof(buf), "%.4f", skew);
        mySkewStr = buf;
        snprintf(buf, sizeof(buf), "%d", tracks);
        myTracksStr = buf;
    }

    void* mySession = nullptr;
    bool myBuildRequested = false;
    bool myMatched = false;
    float myOffset = 0;
    int myTracks = 0;
    std::string myStatus, myTitle, myMatchedStr, myOffsetStr, mySkewStr, myTracksStr;
    std::atomic<int> myExecCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Shazam");
    info->customOPInfo.opLabel->setString("Shazam");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("SHZ");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new ShazamDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<ShazamDAT*>(instance);
}

}   // extern "C"
