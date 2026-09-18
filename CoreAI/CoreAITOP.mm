// CoreAI TOP — Apple Core AI(macOS 27+)の .aimodel を TouchDesigner で回す汎用推論 TOP
//
// CoreML TOP の Core AI 版。任意の .aimodel / .aimodelc をロードし、入力 TOP を
// 最初の画像入力(rank 3〜5 のテンソル)へ流し込み、選んだ出力を Mono/RGBA32Float で出す。
// モデルの入出力は関数ディスクリプタが自己記述(shape / dtype)なので、モデルごとの
// 特別扱いはしない(深度・超解像・セグメンテーション等がそのまま通る)。
//
// Core AI は Swift 専用なので実体は Swiftヘルパ(CoreAIHelper・C ABI ai_*)。
// ロード・推論は helper 内で非同期。cook は非ブロックで、ダウンロード(getData)だけ
// ワーカースレッドで行う(家族の型)。macOS 26 では helper が「requires macOS 27+」を
// status に返すだけでクラッシュしない(-weak_framework CoreAI)。
#import <Foundation/Foundation.h>
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

extern "C" {
    void* ai_create(void);
    void  ai_destroy(void*);
    void  ai_load(void*, const char* path, const char* fn, int units);
    int   ai_submit(void*, const unsigned char* bgra, int w, int h, int normalize);
    char* ai_status_json(void*);
    int   ai_image_info(void*, const char* name, int channel, int* w, int* h, int* c, unsigned long long* serial);
    int   ai_copy_image(void*, const char* name, float* dst, int mode, float lo, float hi, int invert, int channel, int flip);
    void  ai_stats(void*, double* v);
    char* ai_info_tsv(void*);
    char* ai_output_names(void*);
}

namespace {

struct Job
{
    OP_SmartRef<OP_TOPDownloadResult> image;
    int normalize = 0;
    bool valid = false;
};

class CoreAITOP final : public TOP_CPlusPlusBase
{
public:
    CoreAITOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c)
    {
        myState = ai_create();
        myThread = std::thread([this] { worker(); });
    }

    ~CoreAITOP() override
    {
        {
            std::lock_guard<std::mutex> l(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myThread.joinable())
            myThread.join();
        if (myState)
            ai_destroy(myState);
    }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
    }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        if (!myState)
            return;

        // モデルのロード(パス / 関数 / 計算ユニットが変わったとき、または Reload)
        std::string model = in->getParString("Model") ?: "";
        std::string fn = in->getParString("Function") ?: "main";
        const int units = unitsIndex(in->getParString("Computeunits"));
        std::string loadSig = model + "|" + fn + "|" + std::to_string(units);
        if (loadSig != myLoadSig || myWantReload) {
            myLoadSig = loadSig;
            myWantReload = false;
            ai_load(myState, model.c_str(), fn.c_str(), units);
            mySig.clear();          // 新モデルで必ず再投入
            myUploaded = 0;
            refreshOutputMenu();
        }
        double st[11];
        ai_stats(myState, st);
        const bool loaded = st[0] > 0.5;
        if (loaded != myLoadedShown) {
            myLoadedShown = loaded;
            refreshOutputMenu();    // 非同期ロードの完了時にメニューへ出力名を入れる
        }
        // 出力範囲の手動値は auto/raw では意味が無いので寝かせる(CoreML TOP と同じ)
        const std::string range = in->getParString("Outputrange") ?: "auto";
        const bool manual = range == "manual";
        if (manual != myManualShown) {
            in->enablePar("Rangemin", manual);
            in->enablePar("Rangemax", manual);
            myManualShown = manual;
        }

        if (!in->getParInt("Active") || !loaded)
            return;

        const OP_TOPInput* top = in->getInputTOP(0);
        if (!top)
            return;

        const int normalize = normIndex(in->getParString("Normalize"));
        // 静止画でも 前処理の変更で再投入する(シグネチャ検知・家族の型)
        char sig[128];
        snprintf(sig, sizeof(sig), "%d|%lld|%s", normalize, (long long)top->totalCooks, myLoadSig.c_str());
        if (mySig != sig) {
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myJob.valid && st[2] < 0.5 /*busy*/) {
                OP_TOPInputDownloadOptions opts;
                opts.pixelFormat = OP_PixelFormat::BGRA8Fixed;
                opts.verticalFlip = true;   // ML意味処理系: 正立(top-down)画像を渡す
                Job j;
                j.image = top->downloadTexture(opts, nullptr);
                j.normalize = normalize;
                j.valid = (bool)j.image;
                if (j.valid) {
                    myJob = std::move(j);
                    mySig = sig;
                    l.unlock();
                    myCond.notify_one();
                }
            }
        }

        // 最新結果を毎cookアップロード(bypass 復帰で黒にならないように・家族の型)
        std::string outName = in->getParString("Output") ?: "";
        if (outName == "auto") outName.clear();
        const int channel = (int)in->getParInt("Channel") - 1;   // UI は 0=all, 1..=index
        int w = 0, h = 0, c = 0;
        unsigned long long serial = 0;
        if (!ai_image_info(myState, outName.c_str(), channel, &w, &h, &c, &serial) || w <= 0 || h <= 0) {
            myNotImage = st[7] > 0.5;   // 結果はあるのに画像として解釈できない(serial は結果があるときだけ >0)
            return;
        }
        myNotImage = false;
        myLastW = w; myLastH = h; myLastC = c;
        const bool mono = (channel >= 0) || (c == 1);
        const int mode = range == "raw" ? 1 : (manual ? 2 : 0);
        const float lo = (float)in->getParDouble("Rangemin");
        const float hi = (float)in->getParDouble("Rangemax");
        const int invert = in->getParInt("Invert") ? 1 : 0;
        const int flip = in->getParInt("Flip") ? 1 : 0;

        // helper は常に RGBA32F で書く。Mono 出力は R だけ詰め直す
        if (myRGBA.size() < (size_t)w * h * 4)
            myRGBA.resize((size_t)w * h * 4);
        if (serial != myUploaded || myMode != mode || myLo != lo || myHi != hi ||
            myInvert != invert || myFlip != flip || myChannel != channel || myOutName != outName) {
            ai_copy_image(myState, outName.c_str(), myRGBA.data(), mode, lo, hi, invert, channel, flip);
            myUploaded = serial; myMode = mode; myLo = lo; myHi = hi;
            myInvert = invert; myFlip = flip; myChannel = channel; myOutName = outName;
        }
        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = w;
        ui.textureDesc.height = h;
        ui.textureDesc.pixelFormat = mono ? OP_PixelFormat::Mono32Float : OP_PixelFormat::RGBA32Float;
        const size_t sz = (size_t)w * h * (mono ? 1 : 4) * sizeof(float);
        auto b = myContext->createOutputBuffer(sz, TOP_BufferFlags::None, nullptr);
        if (!b)
            return;
        if (mono) {
            float* d = (float*)b->data;
            for (size_t i = 0; i < (size_t)w * h; i++)
                d[i] = myRGBA[i * 4];
        } else {
            memcpy(b->data, myRGBA.data(), sz);
        }
        out->uploadBuffer(&b, ui, nullptr);
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* PAGE = "CoreAI";
        {
            OP_NumericParameter p("Active");
            p.label = "Active"; p.page = PAGE; p.defaultValues[0] = 1;
            m->appendToggle(p);
        }
        {
            OP_StringParameter p("Model");
            p.label = "Model (.aimodel)"; p.page = PAGE; p.defaultValue = "";
            m->appendFolder(p);     // .aimodel はパッケージ(フォルダ)。ファイル選択だと中に入ってしまう
        }
        {
            OP_StringParameter p("Function");
            p.label = "Function"; p.page = PAGE; p.defaultValue = "main";
            m->appendString(p);
        }
        {
            OP_StringParameter p("Computeunits");
            p.label = "Compute Units"; p.page = PAGE; p.defaultValue = "auto";
            const char* names[] = {"auto", "cpu", "gpu", "ane"};
            const char* labels[] = {"Auto", "CPU Only", "Prefer GPU", "Prefer Neural Engine"};
            m->appendMenu(p, 4, names, labels);
        }
        {
            OP_NumericParameter p("Reload");
            p.label = "Reload Model"; p.page = PAGE;
            m->appendPulse(p);
        }
        {
            OP_StringParameter p("Normalize");
            p.label = "Input Normalize"; p.page = PAGE; p.defaultValue = "zeroone";
            const char* names[] = {"zeroone", "negoneone", "imagenet", "raw255"};
            const char* labels[] = {"0 to 1", "-1 to 1", "ImageNet Mean/Std", "0 to 255"};
            m->appendMenu(p, 4, names, labels);
        }
        {
            // 動的メニューは非空の既定値が必須(空だとパラメータ自体が生成されない・既知の罠)
            OP_StringParameter p("Output");
            p.label = "Output"; p.page = PAGE; p.defaultValue = "auto";
            m->appendDynamicStringMenu(p);
        }
        {
            OP_NumericParameter p("Channel");
            p.label = "Channel (0=All)"; p.page = PAGE; p.defaultValues[0] = 0;
            p.minSliders[0] = 0; p.maxSliders[0] = 8; p.minValues[0] = 0; p.clampMins[0] = true;
            m->appendInt(p);
        }
        {
            OP_StringParameter p("Outputrange");
            p.label = "Output Range"; p.page = PAGE; p.defaultValue = "auto";
            const char* names[] = {"auto", "raw", "manual"};
            const char* labels[] = {"Auto (Min-Max per frame)", "Raw", "Manual"};
            m->appendMenu(p, 3, names, labels);
        }
        {
            OP_NumericParameter p("Rangemin");
            p.label = "Range Min"; p.page = PAGE; p.defaultValues[0] = 0;
            p.minSliders[0] = -10; p.maxSliders[0] = 10;
            m->appendFloat(p);
        }
        {
            OP_NumericParameter p("Rangemax");
            p.label = "Range Max"; p.page = PAGE; p.defaultValues[0] = 1;
            p.minSliders[0] = -10; p.maxSliders[0] = 10;
            m->appendFloat(p);
        }
        {
            OP_NumericParameter p("Invert");
            p.label = "Invert"; p.page = PAGE; p.defaultValues[0] = 0;
            m->appendToggle(p);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Vertically"; p.page = PAGE; p.defaultValues[0] = 1;
            m->appendToggle(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Reload") == 0)
            myWantReload = true;
    }

    void buildDynamicMenu(const OP_Inputs*, OP_BuildDynamicMenuInfo* info, void*) override
    {
        if (strcmp(info->name, "Output"))
            return;
        info->addMenuEntry("auto", "Auto (first output)");
        std::lock_guard<std::mutex> l(myMenuMutex);
        for (auto& n : myOutputNames)
            info->addMenuEntry(n.c_str(), n.c_str());
    }

    int32_t getNumInfoCHOPChans(void*) override { return 15; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        double st[11] = {0};
        if (myState) ai_stats(myState, st);
        const char* n[] = {"executes", "submits", "results", "busy", "loaded", "loading",
                           "inference_ms", "load_ms", "width", "height", "channels", "serial",
                           "pre_ms", "run_ms", "post_ms"};
        float v[] = {(float)myExec.load(), (float)st[3], (float)st[4], (float)st[2], (float)st[0],
                     (float)st[1], (float)st[5], (float)st[6], (float)myLastW, (float)myLastH,
                     (float)myLastC, (float)st[7], (float)st[8], (float)st[9], (float)st[10]};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    bool getInfoDATSize(OP_InfoDATSize* s, void*) override
    {
        refreshInfoRows();
        if (myInfoRows.empty()) return false;
        s->rows = (int32_t)myInfoRows.size() + 1;   // ヘッダ行
        s->cols = 5;
        s->byColumn = false;
        return true;
    }
    void getInfoDATEntries(int32_t index, int32_t nEntries, OP_InfoDATEntries* e, void*) override
    {
        static const char* hdr[] = {"key", "name", "kind", "dtype", "shape"};
        if (index == 0) {
            for (int j = 0; j < nEntries && j < 5; j++) e->values[j]->setString(hdr[j]);
            return;
        }
        index--;
        if (index < 0 || index >= (int)myInfoRows.size()) return;
        const auto& row = myInfoRows[index];
        for (int j = 0; j < nEntries; j++)
            e->values[j]->setString(j < (int)row.size() ? row[j].c_str() : "");
    }

    void getWarningString(OP_String* s, void*) override
    {
        if (!myState) { s->setString("helper unavailable"); return; }
        double st[11] = {0};
        ai_stats(myState, st);
        if (st[0] > 0.5 && myNotImage) {
            s->setString("selected output is not image-shaped ([H,W] / [C,H,W] / [H,W,C] with C<=4). Pick another Output, or use the CoreAI CHOP for tensors");
            return;
        }
        char* j = ai_status_json(myState);
        if (!j) return;
        std::string js(j);
        free(j);
        if (js.find("\"status\":\"error") != std::string::npos ||
            js.find("requires macOS") != std::string::npos ||
            js.find("\"status\":\"no model\"") != std::string::npos) {
            size_t p = js.find("\"status\":\"");
            if (p != std::string::npos) {
                p += 10;
                size_t q = js.find('"', p);
                s->setString(js.substr(p, q == std::string::npos ? std::string::npos : q - p).c_str());
            }
        }
    }

private:
    static int unitsIndex(const char* s)
    {
        if (!s) return 0;
        if (!strcmp(s, "cpu")) return 1;
        if (!strcmp(s, "gpu")) return 2;
        if (!strcmp(s, "ane")) return 3;
        return 0;
    }
    static int normIndex(const char* s)
    {
        if (!s) return 0;
        if (!strcmp(s, "negoneone")) return 1;
        if (!strcmp(s, "imagenet")) return 2;
        if (!strcmp(s, "raw255")) return 3;
        return 0;
    }

    void refreshOutputMenu()
    {
        char* names = ai_output_names(myState);
        if (!names) return;
        std::vector<std::string> v;
        std::string cur;
        for (const char* p = names; ; p++) {
            if (*p == '\n' || *p == 0) {
                if (!cur.empty()) v.push_back(cur);
                cur.clear();
                if (*p == 0) break;
            } else cur += *p;
        }
        free(names);
        std::lock_guard<std::mutex> l(myMenuMutex);
        myOutputNames = std::move(v);
    }

    void refreshInfoRows()
    {
        char* tsv = ai_info_tsv(myState);
        if (!tsv) return;
        std::vector<std::vector<std::string>> rows;
        std::vector<std::string> row;
        std::string cur;
        for (const char* p = tsv; ; p++) {
            if (*p == '\t') { row.push_back(cur); cur.clear(); }
            else if (*p == '\n' || *p == 0) {
                row.push_back(cur); cur.clear();
                rows.push_back(row); row.clear();
                if (*p == 0) break;
            } else cur += *p;
        }
        free(tsv);
        myInfoRows = std::move(rows);
    }

    void worker()
    {
        for (;;) {
            Job j;
            {
                std::unique_lock<std::mutex> l(myMutex);
                myCond.wait(l, [this] { return myJob.valid || myQuit; });
                if (myQuit)
                    return;
                j = std::move(myJob);
                myJob = Job();
            }
            // getData() はブロックするのでワーカーで呼ぶ
            const uint8_t* img = (const uint8_t*)j.image->getData();
            int w = (int)j.image->textureDesc.width;
            int h = (int)j.image->textureDesc.height;
            if (!img || w <= 0 || h <= 0)
                continue;
            ai_submit(myState, img, w, h, j.normalize);
        }
    }

    TOP_Context* myContext;
    void* myState = nullptr;
    std::string myLoadSig, mySig, myOutName;
    unsigned long long myUploaded = 0;
    int myMode = -1, myInvert = -1, myFlip = -1, myChannel = -2;
    float myLo = 0, myHi = 0;
    int myLastW = 0, myLastH = 0, myLastC = 0;
    bool myManualShown = true, myNotImage = false, myLoadedShown = false;
    std::vector<float> myRGBA;
    std::atomic<uint64_t> myExec{0};
    std::atomic<bool> myWantReload{false};

    std::mutex myMenuMutex;
    std::vector<std::string> myOutputNames;
    std::vector<std::vector<std::string>> myInfoRows;

    std::thread myThread;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    Job myJob;
};

}   // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i)
{
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion))
        return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Coreai");
    i->customOPInfo.opLabel->setString("CoreAI");
    i->customOPInfo.opIcon->setString("CAI");
    if (i->customOPInfo.opHelpURL)
        i->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/CoreAI/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 1;
    i->customOPInfo.maxInputs = 1;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c)
{
    return new CoreAITOP(i, c);
}
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*)
{
    delete static_cast<CoreAITOP*>(i);
}
}
