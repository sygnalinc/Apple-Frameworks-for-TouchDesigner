// Vision IterSeg TOP — Apple純正の対話的セグメンテーション(macOS 27+)
//
// Vision の GenerateIterativeSegmentationRequest で、プロンプト(点/矩形/なぞり書き)から
// 任意物体のソフトマスクを生成する。外部モデル不要(CoreML SAM2 の純正代替)。
// 入力0=画像、入力1=scribbleマスク(Prompt Mode=Scribble のとき使用・Rチャンネル)。
// 出力は Mono32Float のソフトマスク。
//
// 処理は Swiftヘルパ(VisionIterSegHelper)が async で実行。cook は非ブロックで、
// ダウンロード(getData)だけワーカースレッドで行う(家族の型)。
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
    void* vi_create(void);
    void  vi_destroy(void*);
    void  vi_download_assets(void*);
    bool  vi_submit(void*, const unsigned char* bgra, int w, int h,
                    int mode, double px, double py,
                    double bx, double by, double bw, double bh,
                    const unsigned char* scribble, int sw, int sh, int quality);
    int   vi_latest_info(void*, int* w, int* h, unsigned long long* serial);
    void  vi_copy_latest(void*, void* dst, int flip);
    const char* vi_status_json(void*);
}

namespace {

struct Job
{
    OP_SmartRef<OP_TOPDownloadResult> image;
    OP_SmartRef<OP_TOPDownloadResult> scribble;   // mode==2 のときのみ
    int mode = 0;
    double px = 0.5, py = 0.5;
    double bx = 0.25, by = 0.25, bw = 0.5, bh = 0.5;
    int quality = 1;
    bool valid = false;
};

class VisionIterSegTOP final : public TOP_CPlusPlusBase
{
public:
    VisionIterSegTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c)
    {
        myState = vi_create();
        myThread = std::thread([this] { worker(); });
    }

    ~VisionIterSegTOP() override
    {
        {
            std::lock_guard<std::mutex> l(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myThread.joinable())
            myThread.join();
        if (myState)
            vi_destroy(myState);
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
        if (myWantDownload) {
            myWantDownload = false;
            vi_download_assets(myState);
        }
        if (!in->getParInt("Active"))
            return;

        const OP_TOPInput* top = in->getInputTOP(0);
        if (!top)
            return;

        const int mode = (int)in->getParInt("Promptmode");
        double px, py, bpx, bpy, bsx, bsy;
        in->getParDouble2("Point", px, py);
        in->getParDouble2("Boxpos", bpx, bpy);
        in->getParDouble2("Boxsize", bsx, bsy);
        const int quality = (int)in->getParInt("Quality");

        // 静止画でも プロンプト/画質 変更で再解析する(シグネチャ検知・家族の型)
        char sig[256];
        snprintf(sig, sizeof(sig), "%d|%.4f,%.4f|%.4f,%.4f,%.4f,%.4f|%d|%lld",
                 mode, px, py, bpx, bpy, bsx, bsy, quality,
                 (long long)top->totalCooks);
        const OP_TOPInput* scr = in->getInputTOP(1);
        long long scrCooks = scr ? (long long)scr->totalCooks : -1;
        char sig2[300];
        snprintf(sig2, sizeof(sig2), "%s|%lld", sig, scrCooks);

        if (mySig != sig2) {
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myJob.valid) {
                // 入力をノンブロッキングで確保(getData はワーカーで呼ぶ)
                OP_TOPInputDownloadOptions opts;
                opts.pixelFormat = OP_PixelFormat::BGRA8Fixed;
                opts.verticalFlip = true;   // Vision意味処理系: 正立画像を渡す
                Job j;
                j.image = top->downloadTexture(opts, nullptr);
                if (mode == 2 && scr)
                    j.scribble = scr->downloadTexture(opts, nullptr);
                j.mode = mode;
                j.px = px; j.py = py;
                j.bx = bpx; j.by = bpy; j.bw = bsx; j.bh = bsy;
                j.quality = quality;
                j.valid = (bool)j.image;
                if (j.valid) {
                    myJob = std::move(j);
                    mySig = sig2;
                    l.unlock();
                    myCond.notify_one();
                }
            }
        }

        // 最新マスクをアップロード(Mono32Float)
        int lw = 0, lh = 0;
        unsigned long long serial = 0;
        if (vi_latest_info(myState, &lw, &lh, &serial) && serial != myUploaded &&
            lw > 0 && lh > 0) {
            size_t sz = (size_t)lw * lh * 4;
            TOP_UploadInfo ui;
            ui.textureDesc.texDim = OP_TexDim::e2D;
            ui.textureDesc.width = lw;
            ui.textureDesc.height = lh;
            ui.textureDesc.pixelFormat = OP_PixelFormat::Mono32Float;
            auto b = myContext->createOutputBuffer(sz, TOP_BufferFlags::None, nullptr);
            if (!b)
                return;
            vi_copy_latest(myState, b->data, in->getParInt("Flip") ? 1 : 0);
            out->uploadBuffer(&b, ui, nullptr);
            myUploaded = serial;
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* PAGE = "Vision IterSeg";
        {
            OP_NumericParameter p("Active");
            p.label = "Active"; p.page = PAGE; p.defaultValues[0] = 1;
            m->appendToggle(p);
        }
        {
            OP_StringParameter p("Promptmode");
            p.label = "Prompt Mode"; p.page = PAGE; p.defaultValue = "point";
            const char* names[] = {"point", "box", "scribble"};
            const char* labels[] = {"Seed Point", "Seed Box", "Scribble (Input 1)"};
            m->appendMenu(p, 3, names, labels);
        }
        {
            OP_NumericParameter p("Point");
            p.label = "Seed Point (uv)"; p.page = PAGE;
            p.defaultValues[0] = 0.5; p.defaultValues[1] = 0.5;
            for (int i = 0; i < 2; i++) { p.minSliders[i] = 0; p.maxSliders[i] = 1; }
            m->appendXY(p);
        }
        {
            OP_NumericParameter p("Boxpos");
            p.label = "Box Position (uv)"; p.page = PAGE;
            p.defaultValues[0] = 0.25; p.defaultValues[1] = 0.25;
            for (int i = 0; i < 2; i++) { p.minSliders[i] = 0; p.maxSliders[i] = 1; }
            m->appendXY(p);
        }
        {
            OP_NumericParameter p("Boxsize");
            p.label = "Box Size (uv)"; p.page = PAGE;
            p.defaultValues[0] = 0.5; p.defaultValues[1] = 0.5;
            for (int i = 0; i < 2; i++) { p.minSliders[i] = 0; p.maxSliders[i] = 1; }
            m->appendXY(p);
        }
        {
            OP_StringParameter p("Quality");
            p.label = "Quality"; p.page = PAGE; p.defaultValue = "balanced";
            const char* names[] = {"fast", "balanced", "accurate"};
            const char* labels[] = {"Fast", "Balanced", "Accurate"};
            m->appendMenu(p, 3, names, labels);
        }
        {
            OP_NumericParameter p("Downloadassets");
            p.label = "Download Assets"; p.page = PAGE;
            m->appendPulse(p);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Vertically"; p.page = PAGE; p.defaultValues[0] = 1;
            m->appendToggle(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Downloadassets") == 0)
            myWantDownload = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        // ステータスJSONから busy / asset_ready / submits / results を毎回読む
        int busy = 0, assetReady = 0;
        long long submits = 0, results = 0;
        if (myState) {
            const char* j = vi_status_json(myState);
            if (j) {
                parseStatus(j, busy, assetReady, submits, results);
                free((void*)j);
            }
        }
        const char* n[] = {"executes", "submits", "results", "busy", "asset_ready"};
        float v[] = {(float)myExec.load(), (float)submits, (float)results,
                     (float)busy, (float)assetReady};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    void getWarningString(OP_String* s, void*) override
    {
        if (!myState) {
            s->setString("helper unavailable");
            return;
        }
        const char* j = vi_status_json(myState);
        if (!j)
            return;
        std::string js(j);
        free((void*)j);
        if (js.find("error") != std::string::npos ||
            js.find("requires macOS") != std::string::npos ||
            js.find("not downloaded") != std::string::npos)
            s->setString(js.c_str());
    }

private:
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
            std::vector<uint8_t> scribbleGray;
            const uint8_t* scr = nullptr;
            int sw = 0, sh = 0;
            if (j.mode == 2 && j.scribble) {
                const uint8_t* sb = (const uint8_t*)j.scribble->getData();
                sw = (int)j.scribble->textureDesc.width;
                sh = (int)j.scribble->textureDesc.height;
                if (sb && sw > 0 && sh > 0) {
                    // BGRA の R チャンネル → 8bitグレー
                    scribbleGray.resize((size_t)sw * sh);
                    for (int i = 0; i < sw * sh; i++)
                        scribbleGray[i] = sb[i * 4 + 2];
                    scr = scribbleGray.data();
                }
            }
            vi_submit(myState, img, w, h, j.mode, j.px, j.py,
                      j.bx, j.by, j.bw, j.bh, scr, sw, sh, j.quality);
        }
    }

    static void parseStatus(const char* json, int& busy, int& assetReady,
                            long long& submits, long long& results)
    {
        // 小さな固定JSONなので文字列走査で十分
        std::string js(json);
        busy = js.find("\"busy\":true") != std::string::npos ? 1 : 0;
        size_t p = js.find("\"asset_ready\":");
        if (p != std::string::npos) assetReady = atoi(js.c_str() + p + 14);
        p = js.find("\"submits\":");
        if (p != std::string::npos) submits = atoll(js.c_str() + p + 10);
        p = js.find("\"results\":");
        if (p != std::string::npos) results = atoll(js.c_str() + p + 10);
    }

    TOP_Context* myContext;
    void* myState = nullptr;
    unsigned long long myUploaded = 0;
    std::string mySig;
    std::atomic<uint64_t> myExec{0};
    std::atomic<bool> myWantDownload{false};

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
    i->customOPInfo.opType->setString("Visioniterseg");
    i->customOPInfo.opLabel->setString("Vision IterSeg");
    i->customOPInfo.opIcon->setString("VIS");
    if (i->customOPInfo.opHelpURL)
        i->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/TDAppleOps/blob/main/VisionIterSeg/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 1;
    i->customOPInfo.maxInputs = 2;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c)
{
    return new VisionIterSegTOP(i, c);
}
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*)
{
    delete static_cast<VisionIterSegTOP*>(i);
}
}
