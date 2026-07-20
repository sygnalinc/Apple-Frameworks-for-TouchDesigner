// Caption Author DAT — 文字起こし/字幕テーブルを SRT / WebVTT の字幕テキストへ整形し、
// ファイルにも書き出す。SpeechText DAT(index/text/final)や、start/end/text 列を持つ
// 任意の入力DATを字幕に変換できる。
//
//   ・入力DATに start/end 列があればその時刻を使う(秒 / ミリ秒 / タイムコードを選択)
//   ・start が無ければ Default Duration で 0 から連番タイミングを自動付与
//     (SpeechText の index/text/final をそのまま字幕化できる)
//   ・end が無ければ start + Default Duration、または次キャプションの start までを使う
//
// 出力: DAT本体には整形済みの SRT / VTT テキスト(setText)。Write でファイルへ保存。
// TDの File Out DAT でも保存できるが、拡張子・改行込みで完成形を扱えるよう自前書き出しも用意。
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using namespace TD;

namespace {

struct Cue
{
    double start = 0;   // 秒
    double end = 0;     // 秒
    std::string text;
};

// "HH:MM:SS,mmm" / "HH:MM:SS.mmm" / "MM:SS" / 秒数 を秒へ
static double parseTime(const std::string& s, const std::string& unit)
{
    if (s.empty())
        return -1;
    if (unit == "seconds")
        return atof(s.c_str());
    if (unit == "milliseconds")
        return atof(s.c_str()) / 1000.0;
    // timecode: コロン区切り。最後の要素は SS[.,mmm]
    std::vector<std::string> parts;
    std::string cur;
    for (char c : s) {
        if (c == ':') {
            parts.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(c == ',' ? '.' : c);
        }
    }
    parts.push_back(cur);
    double t = 0;
    for (const auto& p : parts)
        t = t * 60.0 + atof(p.c_str());
    return t;
}

// 秒 → "HH:MM:SS,mmm"(sep=","=SRT) / "HH:MM:SS.mmm"(sep="."=VTT)
static std::string fmtTime(double sec, char sep)
{
    if (sec < 0)
        sec = 0;
    long ms = (long)(sec * 1000.0 + 0.5);
    int h = (int)(ms / 3600000);
    ms %= 3600000;
    int m = (int)(ms / 60000);
    ms %= 60000;
    int s = (int)(ms / 1000);
    int milli = (int)(ms % 1000);
    char buf[32];
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d%c%03d", h, m, s, sep, milli);
    return buf;
}

class CaptionAuthorDAT final : public DAT_CPlusPlusBase
{
public:
    explicit CaptionAuthorDAT(const OP_NodeInfo*) {}
    ~CaptionAuthorDAT() override {}

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExec++;
        const char* fmtC = inputs->getParString("Format");
        const std::string fmt = fmtC ? fmtC : "srt";
        const char* unitC = inputs->getParString("Timeunit");
        const std::string unit = unitC ? unitC : "seconds";
        const std::string textCol = getStr(inputs, "Textcol", "text");
        const std::string startCol = getStr(inputs, "Startcol", "start");
        const std::string endCol = getStr(inputs, "Endcol", "end");
        const double defDur = inputs->getParDouble("Defaultduration");
        const bool skipFinal = inputs->getParInt("Onlyfinal") != 0;

        std::vector<Cue> cues;
        buildCues(inputs, textCol, startCol, endCol, unit, defDur, skipFinal, cues);

        const std::string content = (fmt == "vtt") ? toVTT(cues) : toSRT(cues);
        myCueCount = (int)cues.size();

        output->setOutputDataType(DAT_OutDataType::Text);
        output->setText(content.c_str());

        // Write パルス / Auto Write でファイル保存
        const bool autoWrite = inputs->getParInt("Autowrite") != 0;
        if (myWritePulse || (autoWrite && content != myLastWritten)) {
            myWritePulse = false;
            const char* pathC = inputs->getParFilePath("Outputpath");
            std::string path = pathC ? pathC : "";
            if (!path.empty()) {
                std::ofstream ofs(path, std::ios::trunc | std::ios::binary);
                if (ofs.good()) {
                    ofs << content;
                    myLastWritten = content;
                    myWrites++;
                    myWarn.clear();
                } else {
                    myWarn = "Cannot write caption file: " + path;
                }
            } else {
                myWarn = "Set an Output File path to write.";
            }
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "Caption Author";
        {
            OP_StringParameter p("Format");
            p.label = "Format";
            p.page = P;
            p.defaultValue = "srt";
            const char* n[] = {"srt", "vtt"};
            const char* l[] = {"SubRip (.srt)", "WebVTT (.vtt)"};
            m->appendMenu(p, 2, n, l);
        }
        {
            OP_StringParameter p("Textcol");
            p.label = "Text Column";
            p.page = P;
            p.defaultValue = "text";
            m->appendString(p);
        }
        {
            OP_StringParameter p("Startcol");
            p.label = "Start Column";
            p.page = P;
            p.defaultValue = "start";
            m->appendString(p);
        }
        {
            OP_StringParameter p("Endcol");
            p.label = "End Column";
            p.page = P;
            p.defaultValue = "end";
            m->appendString(p);
        }
        {
            OP_StringParameter p("Timeunit");
            p.label = "Time Unit";
            p.page = P;
            p.defaultValue = "seconds";
            const char* n[] = {"seconds", "milliseconds", "timecode"};
            const char* l[] = {"Seconds", "Milliseconds", "Timecode (HH:MM:SS,mmm)"};
            m->appendMenu(p, 3, n, l);
        }
        {
            OP_NumericParameter p("Defaultduration");
            p.label = "Default Duration (s)";
            p.page = P;
            p.defaultValues[0] = 2.0;
            p.minValues[0] = 0.1;
            p.minSliders[0] = 0.5;
            p.maxSliders[0] = 8.0;
            p.clampMins[0] = true;
            m->appendFloat(p);
        }
        {
            OP_NumericParameter p("Onlyfinal");
            p.label = "Only Finalized Rows";
            p.page = P;
            p.defaultValues[0] = 1;
            m->appendToggle(p);
        }
        {
            OP_StringParameter p("Outputpath");
            p.label = "Output File";
            p.page = P;
            m->appendFile(p);
        }
        {
            OP_NumericParameter p("Autowrite");
            p.label = "Auto Write";
            p.page = P;
            p.defaultValues[0] = 0;
            m->appendToggle(p);
        }
        {
            OP_NumericParameter p("Write");
            p.label = "Write File";
            p.page = P;
            m->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Write") == 0)
            myWritePulse = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[3] = {"executes", "cues", "writes"};
        float v[3] = {(float)myExec, (float)myCueCount, (float)myWrites};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    void getWarningString(OP_String* s, void*) override
    {
        if (!myWarn.empty())
            s->setString(myWarn.c_str());
    }

private:
    static std::string getStr(const OP_Inputs* in, const char* p, const char* def)
    {
        const char* v = in->getParString(p);
        return (v && *v) ? std::string(v) : std::string(def);
    }

    void buildCues(const OP_Inputs* in, const std::string& textCol,
                   const std::string& startCol, const std::string& endCol,
                   const std::string& unit, double defDur, bool skipFinal,
                   std::vector<Cue>& cues)
    {
        const OP_DATInput* dat = in->getInputDAT(0);
        if (!dat || dat->numRows == 0 || dat->numCols == 0)
            return;

        // 列名 → index(ヘッダがある前提。無ければ text=最終列)
        int cText = -1, cStart = -1, cEnd = -1, cFinal = -1;
        const bool hasHeader = dat->isTable && dat->numRows > 1;
        if (hasHeader) {
            for (int c = 0; c < dat->numCols; c++) {
                const char* h = dat->getCell(0, c);
                if (!h)
                    continue;
                if (textCol == h) cText = c;
                else if (startCol == h) cStart = c;
                else if (endCol == h) cEnd = c;
                else if (strcmp(h, "final") == 0) cFinal = c;
            }
        }
        if (cText < 0)
            cText = dat->numCols - 1;   // ヘッダ無し/未一致は最終列をテキストに

        const int startRow = hasHeader ? 1 : 0;
        double cursor = 0;
        for (int r = startRow; r < dat->numRows; r++) {
            const char* tx = dat->getCell(r, cText);
            if (!tx || !*tx)
                continue;
            if (skipFinal && cFinal >= 0) {
                const char* f = dat->getCell(r, cFinal);
                if (f && (strcmp(f, "0") == 0 || strcmp(f, "") == 0))
                    continue;   // 未確定行(volatile)は除外
            }
            Cue cue;
            cue.text = tx;
            double st = -1, en = -1;
            if (cStart >= 0)
                st = parseTime(dat->getCell(r, cStart) ? dat->getCell(r, cStart) : "", unit);
            if (cEnd >= 0)
                en = parseTime(dat->getCell(r, cEnd) ? dat->getCell(r, cEnd) : "", unit);
            if (st < 0)
                st = cursor;             // start 無し → 連番
            if (en < 0)
                en = st + defDur;        // end 無し → start + 既定長
            cue.start = st;
            cue.end = en;
            cursor = en;                 // 次の連番開始
            cues.push_back(std::move(cue));
        }
        // end が次の start を越える場合は次の start までにクランプ(連番の重なり防止)
        for (size_t i = 0; i + 1 < cues.size(); i++)
            if (cues[i].end > cues[i + 1].start && cues[i + 1].start > cues[i].start)
                cues[i].end = cues[i + 1].start;
    }

    static std::string toSRT(const std::vector<Cue>& cues)
    {
        std::string out;
        for (size_t i = 0; i < cues.size(); i++) {
            out += std::to_string(i + 1) + "\n";
            out += fmtTime(cues[i].start, ',') + " --> " + fmtTime(cues[i].end, ',') + "\n";
            out += cues[i].text + "\n\n";
        }
        return out;
    }

    static std::string toVTT(const std::vector<Cue>& cues)
    {
        std::string out = "WEBVTT\n\n";
        for (size_t i = 0; i < cues.size(); i++) {
            out += fmtTime(cues[i].start, '.') + " --> " + fmtTime(cues[i].end, '.') + "\n";
            out += cues[i].text + "\n\n";
        }
        return out;
    }

    int myExec = 0, myCueCount = 0, myWrites = 0;
    bool myWritePulse = false;
    std::string myLastWritten, myWarn;
};

}   // namespace

extern "C" {

DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Captionauthor");
    info->customOPInfo.opLabel->setString("Caption Author");
    info->customOPInfo.opIcon->setString("CAP");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* info)
{
    return new CaptionAuthorDAT(info);
}

DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<CaptionAuthorDAT*>(instance);
}

}   // extern "C"
