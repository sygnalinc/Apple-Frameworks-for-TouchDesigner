// Training Recorder CHOP — 入力CHOP(VisionPose / VisionHand / SoundFeatures など)の
// 時系列を、CreateML DAT(Activity task)がそのまま学習できるCSVデータセットへ収録する。
//
//   CSV形式: recording,label,<feat0>,<feat1>,...   (1行=1フレーム)
//   ・feature列 = 入力CHOPのチャンネル名(カンマは _ に置換)
//   ・recording列 = 1収録=1系列のID(Save/Record停止ごとに採番)
//   ・label列 = そのジェスチャ/動作のラベル(パラメータ)
//   CreateML DAT の Activity task はこの recording 列で系列化し、featureColumns で学習する。
//
// 使い方: VisionPose CHOP 等 → Training Recorder(Label="wave", Record On で収録 → Off で確定)。
// 複数ラベル・複数テイクを1つのCSVに追記していく。集まったCSVを CreateML DAT の Training Path に。
//
// 収録は cook 内で入力CHOPの現在サンプルをメモリへ追記(軽量)。確定時にCSVへ追記書き込みする。
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include <atomic>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <string>
#include <vector>

using namespace TD;

namespace {

static std::string sanitize(const char* s)
{
    std::string out = s ? s : "";
    for (char& c : out)
        if (c == ',' || c == '\n' || c == '\r')
            c = '_';
    return out;
}

// CSVフィールド: カンマ/引用符/改行を含むなら二重引用符で囲む
static std::string csvField(const std::string& s)
{
    bool need = s.find_first_of(",\"\n\r") != std::string::npos;
    if (!need)
        return s;
    std::string out = "\"";
    for (char c : s) {
        if (c == '"')
            out += "\"\"";
        else
            out += c;
    }
    out += "\"";
    return out;
}

static bool fileHasContent(const std::string& path)
{
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    return f.good() && f.tellg() > 0;
}

class CreateMLTrainingRecorderCHOP final : public CHOP_CPlusPlusBase
{
public:
    explicit CreateMLTrainingRecorderCHOP(const OP_NodeInfo*)
    {
        mySessionTag = "r" + std::to_string((long)time(nullptr));
    }
    ~CreateMLTrainingRecorderCHOP() override {}

    void getGeneralInfo(CHOP_GeneralInfo* info, const OP_Inputs* in, void*) override
    {
        // 収録中は必ず毎フレーム cook させる(出力未使用でもフレームを取りこぼさない)
        const bool rec = in && in->getParInt("Record") != 0;
        info->cookEveryFrame = rec;
        info->cookEveryFrameIfAsked = true;
        info->timeslice = false;
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override
    {
        info->numChannels = 6;   // recording / frames / channels / recordings / rows / label_id
        info->numSamples = 1;
        info->sampleRate = 60;
        return true;
    }

    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override
    {
        const char* n[6] = {"recording", "frames", "channels",
                            "recordings", "rows", "buffered"};
        name->setString(n[i]);
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        const char* pathC = in->getParFilePath("Outputpath");
        std::string path = pathC ? pathC : "";
        const char* labelC = in->getParString("Label");
        std::string label = labelC ? labelC : "";
        const bool record = in->getParInt("Record") != 0;
        const bool autosave = in->getParInt("Autosave") != 0;
        int stride = in->getParInt("Stride");
        if (stride < 1)
            stride = 1;
        const char* sampleC = in->getParString("Sample");
        const bool lastSample = !(sampleC && strcmp(sampleC, "first") == 0);

        const OP_CHOPInput* ci = in->getInputCHOP(0);
        const int nch = ci ? ci->numChannels : 0;

        // 立ち上がり: 新規収録の開始(バッファとfeature名スナップショット)
        if (record && !myPrevRecord) {
            myBuffer.clear();
            myRecFeatNames.clear();
            if (ci)
                for (int c = 0; c < nch; c++)
                    myRecFeatNames.push_back(sanitize(ci->getChannelName(c)));
            myFrameCtr = 0;
        }

        // 収録中: 現在サンプルを1行として追記
        if (record && ci && nch > 0) {
            if (myFrameCtr % stride == 0) {
                int s = lastSample ? (ci->numSamples - 1) : 0;
                if (s < 0)
                    s = 0;
                std::vector<float> row;
                row.reserve(nch);
                for (int c = 0; c < nch; c++)
                    row.push_back(ci->getChannelData(c)[s]);
                myBuffer.push_back(std::move(row));
            }
            myFrameCtr++;
        }

        // 確定: Save パルス、または Record 立ち下がり + Autosave
        bool doSave = mySavePulse.exchange(false) ||
                      (myPrevRecord && !record && autosave);
        if (doSave && !myBuffer.empty())
            flushRecording(path, label);

        // Clear File パルス: ヘッダのみに初期化
        if (myClearPulse.exchange(false))
            clearFile(path);

        myPrevRecord = record;

        // 出力(ステータス)
        out->channels[0][0] = record ? 1.0f : 0.0f;
        out->channels[1][0] = (float)myFrameCtr;
        out->channels[2][0] = (float)nch;
        out->channels[3][0] = (float)myRecordings.load();
        out->channels[4][0] = (float)myRows.load();
        out->channels[5][0] = (float)myBuffer.size();
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "CreateML Training Recorder";
        {
            OP_StringParameter p("Outputpath");
            p.label = "Output CSV";
            p.page = P;
            m->appendFile(p);
        }
        {
            OP_StringParameter p("Label");
            p.label = "Label";
            p.page = P;
            p.defaultValue = "gesture";
            m->appendString(p);
        }
        {
            OP_NumericParameter p("Record");
            p.label = "Record";
            p.page = P;
            p.defaultValues[0] = 0;
            m->appendToggle(p);
        }
        {
            OP_NumericParameter p("Autosave");
            p.label = "Auto Save On Stop";
            p.page = P;
            p.defaultValues[0] = 1;
            m->appendToggle(p);
        }
        {
            OP_NumericParameter p("Save");
            p.label = "Save Recording";
            p.page = P;
            m->appendPulse(p);
        }
        {
            OP_NumericParameter p("Clearfile");
            p.label = "Clear File";
            p.page = P;
            m->appendPulse(p);
        }
        {
            OP_NumericParameter p("Stride");
            p.label = "Frame Stride";
            p.page = P;
            p.defaultValues[0] = 1;
            p.minValues[0] = 1;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 10;
            p.clampMins[0] = true;
            m->appendInt(p);
        }
        {
            OP_StringParameter p("Sample");
            p.label = "Sample";
            p.page = P;
            p.defaultValue = "last";
            const char* n[] = {"last", "first"};
            const char* l[] = {"Last Sample", "First Sample"};
            m->appendMenu(p, 2, n, l);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Save") == 0)
            mySavePulse = true;
        else if (strcmp(name, "Clearfile") == 0)
            myClearPulse = true;
    }

    void getWarningString(OP_String* s, void*) override
    {
        if (!myWarn.empty())
            s->setString(myWarn.c_str());
    }

private:
    void flushRecording(const std::string& path, const std::string& label)
    {
        if (path.empty()) {
            myWarn = "Set an Output CSV path first.";
            return;
        }
        const bool needHeader = !fileHasContent(path);
        std::ofstream ofs(path, std::ios::app | std::ios::binary);
        if (!ofs.good()) {
            myWarn = "Cannot open output CSV for writing: " + path;
            return;
        }
        if (needHeader) {
            ofs << "recording,label";
            for (const auto& f : myRecFeatNames)
                ofs << "," << csvField(f);
            ofs << "\n";
            myHeaderFeatCount = (int)myRecFeatNames.size();
        } else if (myHeaderFeatCount > 0 &&
                   myHeaderFeatCount != (int)myRecFeatNames.size()) {
            myWarn = "Feature count changed vs existing CSV (" +
                     std::to_string((int)myRecFeatNames.size()) + " vs " +
                     std::to_string(myHeaderFeatCount) +
                     "). Use Clear File to start a fresh dataset.";
        }
        const std::string rid = mySessionTag + "_" + std::to_string(myRecCounter);
        const std::string lab = csvField(label);
        char num[32];
        for (const auto& row : myBuffer) {
            ofs << rid << "," << lab;
            for (float v : row) {
                snprintf(num, sizeof(num), "%.6g", v);
                ofs << "," << num;
            }
            ofs << "\n";
        }
        myRows += (int)myBuffer.size();
        myRecCounter++;
        myRecordings++;
        myBuffer.clear();
        myWarn.clear();
    }

    void clearFile(const std::string& path)
    {
        if (path.empty())
            return;
        std::ofstream ofs(path, std::ios::trunc | std::ios::binary);
        // ヘッダは次の flush 時に現在の入力チャンネルで書き直す
        myHeaderFeatCount = 0;
        myRecCounter = 0;
        myRecordings = 0;
        myRows = 0;
        myWarn.clear();
    }

    std::string mySessionTag;
    std::vector<std::vector<float>> myBuffer;
    std::vector<std::string> myRecFeatNames;
    std::string myWarn;
    bool myPrevRecord = false;
    int myFrameCtr = 0;
    int myRecCounter = 0;
    int myHeaderFeatCount = 0;
    std::atomic<bool> mySavePulse{false}, myClearPulse{false};
    std::atomic<int> myExec{0}, myRecordings{0}, myRows{0};
};

}   // namespace

extern "C" {

DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Createmltrainingrecorder");
    info->customOPInfo.opLabel->setString("CreateML Training Recorder");
    info->customOPInfo.opIcon->setString("CTR");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/CreateMLTrainingRecorder/README.md");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new CreateMLTrainingRecorderCHOP(info);
}

DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete static_cast<CreateMLTrainingRecorderCHOP*>(instance);
}

}   // extern "C"
