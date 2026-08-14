// Music Understanding DAT — 音楽ファイルのオンデバイス楽曲解析(macOS 27+)
//
// Apple MusicUnderstanding framework で、音楽ファイルから演出制御に直結する構造データを
// テーブル出力する: ビート/小節/BPM・調(キー)・楽曲構造(セクション)・ペース・
// ラウドネス・楽器アクティビティ(vocal/drum/bass/other)。
// File 変更で自動解析(Reanalyze パルスで手動再実行)。解析はSwiftヘルパが非同期実行。
// Mode メニューで出力テーブルを切り替える。数値の要約は Info CHOP に出る。
#import <Foundation/Foundation.h>
#include <atomic>
#include <cstring>
#include <string>
#include <vector>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void* mu_create(void);
    void  mu_destroy(void*);
    bool  mu_analyze(void*, const char* path, int flags);
    const char* mu_status_json(void*);
    const char* mu_result_json(void*);
}

namespace {

class MusicUnderstandingDAT final : public DAT_CPlusPlusBase
{
public:
    explicit MusicUnderstandingDAT(const OP_NodeInfo*) { myState = mu_create(); }
    ~MusicUnderstandingDAT() override { if (myState) mu_destroy(myState); }

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        if (!myState)
            return;

        const char* fp = in->getParFilePath("File");
        std::string file = fp ? fp : "";
        int flags = 0;
        if (in->getParInt("Rhythm")) flags |= 1;
        if (in->getParInt("Key")) flags |= 2;
        if (in->getParInt("Structure")) flags |= 4;
        if (in->getParInt("Pace")) flags |= 8;
        if (in->getParInt("Loudness")) flags |= 16;
        if (in->getParInt("Instruments")) flags |= 32;

        // File/解析セット変更 or Reanalyze で自動解析
        char sig[1200];
        snprintf(sig, sizeof(sig), "%s|%d", file.c_str(), flags);
        if ((mySig != sig || myWantAnalyze) && !file.empty() && flags != 0) {
            if (mu_analyze(myState, file.c_str(), flags)) {
                mySig = sig;
                myWantAnalyze = false;
            }
        }

        // ステータス取得+結果が更新されていたらパース
        int busy = 0;
        unsigned long long serial = 0;
        {
            const char* j = mu_status_json(myState);
            if (j) {
                parseStatus(j, busy, serial);
                free((void*)j);
            }
        }
        myBusy = busy;
        if (serial != myParsedSerial) {
            const char* rj = mu_result_json(myState);
            if (rj) {
                parseResult(rj);
                free((void*)rj);
                myParsedSerial = serial;
            }
        }

        // Mode に応じたテーブル出力
        const int mode = (int)in->getParInt("Mode");
        out->setOutputDataType(DAT_OutDataType::Table);
        const std::vector<std::vector<std::string>>* rows = &mySummary;
        switch (mode) {
            case 1: rows = &myRhythm; break;
            case 2: rows = &myKey; break;
            case 3: rows = &myStructure; break;
            case 4: rows = &myPace; break;
            case 5: rows = &myLoudness; break;
            case 6: rows = &myInstruments; break;
            default: rows = &mySummary; break;
        }
        int nrows = (int)rows->size();
        int ncols = nrows > 0 ? (int)(*rows)[0].size() : 2;
        out->setTableSize(std::max(1, nrows), ncols);
        if (nrows == 0) {
            out->setCellString(0, 0, "status");
            out->setCellString(0, 1, myStatus.c_str());
        } else {
            for (int r = 0; r < nrows; r++)
                for (int c = 0; c < (int)(*rows)[r].size(); c++)
                    out->setCellString(r, c, (*rows)[r][c].c_str());
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* PAGE = "Music Understanding";
        {
            OP_StringParameter p("File");
            p.label = "Audio File"; p.page = PAGE;
            m->appendFile(p);
        }
        {
            OP_StringParameter p("Mode");
            p.label = "Output Table"; p.page = PAGE; p.defaultValue = "summary";
            const char* names[] = {"summary", "rhythm", "key", "structure", "pace", "loudness", "instruments"};
            const char* labels[] = {"Summary", "Rhythm (beats/bars)", "Key", "Structure", "Pace", "Loudness", "Instruments"};
            m->appendMenu(p, 7, names, labels);
        }
        auto toggle = [&](const char* name, const char* label, double def) {
            OP_NumericParameter p(name);
            p.label = label; p.page = PAGE; p.defaultValues[0] = def;
            m->appendToggle(p);
        };
        toggle("Rhythm", "Analyze Rhythm", 1);
        toggle("Key", "Analyze Key", 1);
        toggle("Structure", "Analyze Structure", 1);
        toggle("Pace", "Analyze Pace", 1);
        toggle("Loudness", "Analyze Loudness", 1);
        toggle("Instruments", "Analyze Instruments", 1);
        {
            OP_NumericParameter p("Reanalyze");
            p.label = "Reanalyze"; p.page = PAGE;
            m->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Reanalyze") == 0)
            myWantAnalyze = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 7; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[] = {"executes", "busy", "done", "bpm", "beats", "bars", "sections"};
        float v[] = {(float)myExec.load(), (float)myBusy,
                     (float)(myParsedSerial > 0 ? 1 : 0), myBPM,
                     (float)myBeatCount, (float)myBarCount, (float)mySectionCount};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    bool getInfoDATSize(OP_InfoDATSize* sz, void*) override
    {
        sz->rows = 1; sz->cols = 2; sz->byColumn = false;
        return true;
    }
    void getInfoDATEntries(int32_t, int32_t, OP_InfoDATEntries* e, void*) override
    {
        e->values[0]->setString("status");
        e->values[1]->setString(myStatus.c_str());
    }

    void getWarningString(OP_String* s, void*) override
    {
        if (myStatus.find("error") != std::string::npos ||
            myStatus.find("requires macOS") != std::string::npos)
            s->setString(myStatus.c_str());
    }

private:
    static std::string fmt(double v)
    {
        char b[32];
        snprintf(b, sizeof(b), "%.3f", v);
        return b;
    }

    void parseStatus(const char* json, int& busy, unsigned long long& serial)
    {
        std::string js(json);
        busy = js.find("\"busy\":true") != std::string::npos ? 1 : 0;
        size_t p = js.find("\"serial\":");
        if (p != std::string::npos) serial = strtoull(js.c_str() + p + 9, nullptr, 10);
        p = js.find("\"status\":\"");
        if (p != std::string::npos) {
            size_t e = js.find('"', p + 10);
            if (e != std::string::npos) myStatus = js.substr(p + 10, e - p - 10);
        }
    }

    void parseResult(const char* json)
    {
        @autoreleasepool {
            NSData* data = [NSData dataWithBytes:json length:strlen(json)];
            NSDictionary* d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![d isKindOfClass:[NSDictionary class]])
                return;
            myRhythm = {{"index", "time", "type"}};
            myKey = {{"index", "start", "end", "tonic", "mode"}};
            myStructure = {{"index", "type", "start", "end"}};
            myPace = {{"index", "start", "end", "value"}};
            myLoudness = {{"index", "type", "time", "value"}};
            myInstruments = {{"index", "instrument", "type", "start_or_time", "end_or_value"}};
            myBPM = 0; myBeatCount = 0; myBarCount = 0; mySectionCount = 0;

            NSDictionary* rhythm = d[@"rhythm"];
            if ([rhythm isKindOfClass:[NSDictionary class]]) {
                myBPM = [rhythm[@"bpm"] floatValue];
                int idx = 0;
                for (NSNumber* t in rhythm[@"beats"])
                    myRhythm.push_back({std::to_string(idx++), fmt(t.doubleValue), "beat"});
                myBeatCount = idx;
                for (NSNumber* t in rhythm[@"bars"])
                    myRhythm.push_back({std::to_string(idx++), fmt(t.doubleValue), "bar"});
                myBarCount = idx - myBeatCount;
            }
            NSArray* key = d[@"key"];
            if ([key isKindOfClass:[NSArray class]]) {
                int idx = 0;
                for (NSDictionary* r in key)
                    myKey.push_back({std::to_string(idx++), fmt([r[@"start"] doubleValue]),
                                     fmt([r[@"end"] doubleValue]),
                                     [r[@"tonic"] isKindOfClass:[NSString class]] ? [r[@"tonic"] UTF8String] : "",
                                     [r[@"mode"] isKindOfClass:[NSString class]] ? [r[@"mode"] UTF8String] : ""});
            }
            NSDictionary* st = d[@"structure"];
            if ([st isKindOfClass:[NSDictionary class]]) {
                int idx = 0;
                for (NSString* kind in @[@"sections", @"segments", @"phrases"]) {
                    for (NSDictionary* r in st[kind]) {
                        myStructure.push_back({std::to_string(idx++),
                                               [[kind substringToIndex:kind.length - 1] UTF8String],
                                               fmt([r[@"start"] doubleValue]),
                                               fmt([r[@"end"] doubleValue])});
                        if ([kind isEqualToString:@"sections"]) mySectionCount++;
                    }
                }
            }
            NSArray* pace = d[@"pace"];
            if ([pace isKindOfClass:[NSArray class]]) {
                int idx = 0;
                for (NSDictionary* r in pace)
                    myPace.push_back({std::to_string(idx++), fmt([r[@"start"] doubleValue]),
                                      fmt([r[@"end"] doubleValue]), fmt([r[@"value"] doubleValue])});
            }
            NSDictionary* loud = d[@"loudness"];
            if ([loud isKindOfClass:[NSDictionary class]]) {
                int idx = 0;
                for (NSString* kind in @[@"integrated", @"peak"]) {
                    NSDictionary* r = loud[kind];
                    if ([r isKindOfClass:[NSDictionary class]])
                        myLoudness.push_back({std::to_string(idx++), kind.UTF8String,
                                              fmt([r[@"time"] doubleValue]), fmt([r[@"value"] doubleValue])});
                }
                for (NSString* kind in @[@"momentary", @"short_term"]) {
                    for (NSDictionary* r in loud[kind])
                        myLoudness.push_back({std::to_string(idx++), kind.UTF8String,
                                              fmt([r[@"time"] doubleValue]), fmt([r[@"value"] doubleValue])});
                }
            }
            NSDictionary* inst = d[@"instruments"];
            if ([inst isKindOfClass:[NSDictionary class]]) {
                int idx = 0;
                NSDictionary* ranges = inst[@"ranges"];
                for (NSString* name in [[ranges allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                    for (NSDictionary* r in ranges[name])
                        myInstruments.push_back({std::to_string(idx++), name.UTF8String, "range",
                                                 fmt([r[@"start"] doubleValue]), fmt([r[@"end"] doubleValue])});
                }
                NSDictionary* act = inst[@"activity"];
                for (NSString* name in [[act allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                    for (NSDictionary* r in act[name])
                        myInstruments.push_back({std::to_string(idx++), name.UTF8String, "activity",
                                                 fmt([r[@"time"] doubleValue]), fmt([r[@"value"] doubleValue])});
                }
            }
            // Summary
            mySummary = {{"key", "value"}};
            mySummary.push_back({"status", myStatus});
            mySummary.push_back({"bpm", fmt(myBPM)});
            mySummary.push_back({"beats", std::to_string(myBeatCount)});
            mySummary.push_back({"bars", std::to_string(myBarCount)});
            mySummary.push_back({"sections", std::to_string(mySectionCount)});
            if (myKey.size() > 1)
                mySummary.push_back({"key", myKey[1][3] + " " + myKey[1][4]});
        }
    }

    void* myState = nullptr;
    std::string mySig, myStatus = "ready";
    std::atomic<uint64_t> myExec{0};
    std::atomic<bool> myWantAnalyze{false};
    unsigned long long myParsedSerial = 0;
    int myBusy = 0;
    float myBPM = 0;
    int myBeatCount = 0, myBarCount = 0, mySectionCount = 0;
    std::vector<std::vector<std::string>> mySummary{{"key", "value"}};
    std::vector<std::vector<std::string>> myRhythm, myKey, myStructure, myPace, myLoudness, myInstruments;
};

}   // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Musicunderstanding");
    info->customOPInfo.opLabel->setString("Music Understanding");
    info->customOPInfo.opIcon->setString("MUN");
    if (info->customOPInfo.opHelpURL)
        info->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/TDAppleOps/blob/main/MusicUnderstanding/README.md");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* info)
{
    return new MusicUnderstandingDAT(info);
}
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete (MusicUnderstandingDAT*)instance;
}
}
