// CoreAI ImageGen TOP — Apple Core AI(macOS 27+)で拡散モデルの画像生成
//
// coreai-models が書き出す拡散バンドル(SD 1.x / 2.x・SD3・FLUX.2 = exports/<name>/)を
// 別プロセスのヘルパ(coreai-diffusion-helper・CoreAIDiffusion)で回し、生成画像を
// TOP に出す。CoreML ImageGen(ml-stable-diffusion)の Core AI 版。
//
// 構造は LLM CoreAI DAT と同じ: posix_spawn + pipe + JSON-lines。画像は一時ファイルの
// 生 RGBA8(top-down)でやり取りする(PNG エンコードを挟まない)。
// - 生成は非同期(cook はブロックしない)。done を受けたらファイルを読んでキャッシュし、
//   毎 execute アップロードする(bypass 復帰で黒にならないため・CoreML ImageGen と同じ)
// - img2img は入力0を downloadTexture(RGBA8・verticalFlip)して一時ファイルへ書き、パスを渡す
// - Continuous Generate: 前の生成が終わるたびに最新パラメータ/入力で再生成
//
// opType Coreaiimagegen / opLabel "CoreAI ImageGen" / icon CAG。experimental・minos 27.0

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

#include "CPlusPlus_Common.h"
#include "TOP_CPlusPlusBase.h"
#include "CoreAIHelperProcess.h"

using namespace TD;

namespace {

struct Result
{
    std::vector<uint8_t> pixels;   // RGBA8 top-down
    int w = 0, h = 0;
    int serial = 0;
};

class CoreAIImageGenTOP : public TOP_CPlusPlusBase
{
public:
    CoreAIImageGenTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        char tmp[64];
        snprintf(tmp, sizeof(tmp), "%s/coreaiimagegen_%d_%p", "/tmp", (int)getpid(), (void*)this);
        myTmpBase = tmp;
        myHelper.onEvent = [this](NSDictionary* d) { handleEvent(d); };
        myHelper.onExit = [this]() {
            std::lock_guard<std::mutex> l(myMutex);
            myStatus = "helper exited (model incompatible with this Core AI? see Console.app)";
            myBusy = false;
            myReady = false;
            myProgress = 0;
        };
    }

    ~CoreAIImageGenTOP() override
    {
        myHelper.stop();
        unlink((myTmpBase + "_out.rgba").c_str());
        unlink((myTmpBase + "_in.rgba").c_str());
    }

    void getGeneralInfo(TOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(TOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const char* modelPar = inputs->getParString("Model");
        const std::string model = modelPar ? modelPar : "";
        const char* decodePar = inputs->getParString("Decode");
        const std::string decode = decodePar ? decodePar : "auto";
        const bool lowmem = inputs->getParInt("Lowmemory") != 0;

        inputs->enablePar("Strength", inputs->getParInt("Img2img") != 0);

        // ---- ヘルパ起動 / モデルロード(モデル・デコード・省メモリの変化で再ロード)----
        if (!model.empty()) {
            if (!myHelper.running()) {
                if ([NSProcessInfo processInfo].operatingSystemVersion.majorVersion < 27) {
                    std::lock_guard<std::mutex> l(myMutex);
                    myStatus = "unavailable: Core AI requires macOS 27+";
                } else {
                    myLoadedModel.clear();
                    std::string exe = tdcoreai::helperPath("coreai-diffusion-helper");
                    if (exe.empty() || access(exe.c_str(), X_OK) != 0) {
                        std::lock_guard<std::mutex> l(myMutex);
                        myStatus = "helper not found";
                    } else if (!myHelper.start(exe)) {
                        std::lock_guard<std::mutex> l(myMutex);
                        myStatus = "helper start failed";
                    }
                }
            }
            const std::string key = model + "|" + decode + "|" + (lowmem ? "1" : "0");
            if (myHelper.running() && key != myLoadedModel) {
                myLoadedModel = key;
                {
                    std::lock_guard<std::mutex> l(myMutex);
                    myReady = false;
                    myBusy = false;
                    myProgress = 0;
                    myStatus = "loading model";
                    myKind.clear();
                }
                myHelper.sendLine("{\"cmd\":\"load\",\"model\":\"" + jsonEscape(model) +
                                  "\",\"decode\":\"" + jsonEscape(decode) + "\",\"lazy\":" +
                                  (lowmem ? "true" : "false") + "}");
            }
        }

        // ---- 状態スナップショット ----
        bool ready, busy;
        {
            std::lock_guard<std::mutex> l(myMutex);
            ready = myReady;
            busy = myBusy;
        }

        // ---- 生成トリガ ----
        const bool continuous = inputs->getParInt("Continuous") != 0;
        const bool trigger = (myWantGenerate || (continuous && !busy)) && ready && !busy;
        if (trigger) {
            myWantGenerate = false;
            const bool img2img = inputs->getParInt("Img2img") != 0;
            const OP_TOPInput* top = inputs->getInputTOP(0);
            std::string cmd = "{\"cmd\":\"gen\",\"prompt\":\"" +
                jsonEscape(inputs->getParString("Prompt") ?: "") + "\",\"negative\":\"" +
                jsonEscape(inputs->getParString("Negativeprompt") ?: "") + "\",\"steps\":" +
                std::to_string((int)inputs->getParInt("Steps")) + ",\"guidance\":" +
                std::to_string(inputs->getParDouble("Guidance")) + ",\"seed\":" +
                std::to_string((long long)inputs->getParInt("Seed")) + ",\"strength\":" +
                std::to_string(inputs->getParDouble("Strength")) + ",\"out\":\"" +
                jsonEscape(myTmpBase + "_out.rgba") + "\"";
            {
                std::lock_guard<std::mutex> l(myMutex);
                myBusy = true;
                myStatus = "generating";
                myStep = 0;
            }
            if (img2img && top) {
                OP_TOPInputDownloadOptions opts;
                opts.pixelFormat = OP_PixelFormat::RGBA8Fixed;
                opts.verticalFlip = true;   // TD は bottom-up → ヘルパは top-down
                OP_SmartRef<OP_TOPDownloadResult> download = top->downloadTexture(opts, nullptr);
                if (download) {
                    // getData() はブロックするので別スレッドで待ってから送る
                    const std::string inPath = myTmpBase + "_in.rgba";
                    std::thread([this, cmd, inPath, download = std::move(download)]() mutable {
                        void* data = download->getData();
                        const uint32_t w = download->textureDesc.width;
                        const uint32_t h = download->textureDesc.height;
                        std::string full = cmd;
                        if (data && w && h) {
                            FILE* f = fopen(inPath.c_str(), "wb");
                            if (f) {
                                fwrite(data, 1, (size_t)w * h * 4, f);
                                fclose(f);
                                full += ",\"image\":\"" + jsonEscape(inPath) + "\",\"imagew\":" +
                                        std::to_string(w) + ",\"imageh\":" + std::to_string(h);
                            }
                        }
                        full += "}";
                        myHelper.sendLine(full);
                    }).detach();
                } else {
                    myHelper.sendLine(cmd + "}");
                }
            } else {
                myHelper.sendLine(cmd + "}");
            }
        }

        // ---- 新しい画像の取り込み(done を受けたら一時ファイルから読む)----
        int pendingSerial = 0, pw = 0, ph = 0;
        {
            std::lock_guard<std::mutex> l(myMutex);
            if (myDoneSerial != myLoadedSerial) {
                pendingSerial = myDoneSerial;
                pw = myDoneW;
                ph = myDoneH;
            }
        }
        if (pendingSerial && pw > 0 && ph > 0) {
            const std::string outPath = myTmpBase + "_out.rgba";
            std::vector<uint8_t> px((size_t)pw * ph * 4);
            FILE* f = fopen(outPath.c_str(), "rb");
            bool ok = false;
            if (f) {
                ok = fread(px.data(), 1, px.size(), f) == px.size();
                fclose(f);
            }
            if (ok) {
                myResult.pixels = std::move(px);
                myResult.w = pw;
                myResult.h = ph;
                myResult.serial = pendingSerial;
            }
            myLoadedSerial = pendingSerial;
        }

        // ---- アップロード(毎 execute。bypass 復帰で黒にならないように)----
        if (!myResult.pixels.empty() && myResult.w > 0 && myResult.h > 0) {
            std::vector<uint8_t> px = myResult.pixels;
            int w = myResult.w, h = myResult.h;
            // 出力は最大 1024px なので Non-Commercial の上限(1280)には掛からない
            OP_SmartRef<TOP_Buffer> buf =
                myContext->createOutputBuffer(px.size(), TOP_BufferFlags::None, nullptr);
            if (buf) {
                const bool flip = inputs->getParInt("Flip") != 0;
                uint8_t* dst = (uint8_t*)buf->data;
                const size_t row = (size_t)w * 4;
                for (int y = 0; y < h; y++) {
                    const uint8_t* src = px.data() + (size_t)y * row;
                    memcpy(dst + (size_t)(flip ? (h - 1 - y) : y) * row, src, row);
                }
                TOP_UploadInfo info;
                info.textureDesc.texDim = OP_TexDim::e2D;
                info.textureDesc.width = w;
                info.textureDesc.height = h;
                info.textureDesc.pixelFormat = OP_PixelFormat::RGBA8Fixed;
                output->uploadBuffer(&buf, info, nullptr);
            }
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Model");
            p.label = "Model Bundle (exports/<name> folder)";
            p.page = "Image Gen";
            manager->appendFolder(p);
        }
        {
            OP_StringParameter p("Decode");
            p.label = "Decode Resolution";
            p.page = "Image Gen";
            p.defaultValue = "auto";
            const char* names[4] = {"auto", "full", "half", "tiled"};
            const char* labels[4] = {"Auto", "Full (1024)", "Half (512)", "Tiled (1024, low memory)"};
            manager->appendMenu(p, 4, names, labels);
        }
        {
            OP_NumericParameter p("Lowmemory");
            p.label = "Low Memory (load stages on demand)";
            p.page = "Image Gen";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Prompt");
            p.label = "Prompt";
            p.page = "Image Gen";
            p.defaultValue = "a photo of a cat";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("Negativeprompt");
            p.label = "Negative Prompt";
            p.page = "Image Gen";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Steps");
            p.label = "Steps";
            p.page = "Image Gen";
            p.defaultValues[0] = 20;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 50;
            p.minValues[0] = 1;
            p.clampMins[0] = true;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Guidance");
            p.label = "Guidance Scale";
            p.page = "Image Gen";
            p.defaultValues[0] = 5.0;
            p.minSliders[0] = 0;
            p.maxSliders[0] = 15;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Seed");
            p.label = "Seed (-1 = Random)";
            p.page = "Image Gen";
            p.defaultValues[0] = 42;
            p.minSliders[0] = -1;
            p.maxSliders[0] = 1000;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Img2img");
            p.label = "Image to Image (Input 0)";
            p.page = "Image Gen";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Strength");
            p.label = "Img2img Strength";
            p.page = "Image Gen";
            p.defaultValues[0] = 0.85;
            p.minSliders[0] = 0;
            p.maxSliders[0] = 1;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Generate");
            p.label = "Generate";
            p.page = "Image Gen";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Continuous");
            p.label = "Continuous Generate";
            p.page = "Image Gen";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Output Vertically";
            p.page = "Image Gen";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Generate") == 0)
            myWantGenerate = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 9; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        static const char* names[9] = {"busy", "ready", "progress", "step", "steps", "gen_seconds",
                                       "image_serial", "seed", "executes"};
        std::lock_guard<std::mutex> l(myMutex);
        float v[9] = {myBusy ? 1.f : 0.f, myReady ? 1.f : 0.f, (float)myProgress, (float)myStep,
                      (float)mySteps, (float)myGenSeconds, (float)myResult.serial, (float)myLastSeed,
                      (float)myExecCount};
        chan->name->setString(names[index]);
        chan->value = v[index];
    }

    bool getInfoDATSize(OP_InfoDATSize* s, void*) override
    {
        s->rows = 5;
        s->cols = 2;
        s->byColumn = false;
        return true;
    }
    void getInfoDATEntries(int32_t index, int32_t, OP_InfoDATEntries* e, void*) override
    {
        static const char* keys[5] = {"status", "model", "kind", "size", "img2img"};
        std::lock_guard<std::mutex> l(myMutex);
        std::string vals[5] = {myStatus, myName, myKind,
                               std::to_string(myModelW) + "x" + std::to_string(myModelH),
                               myModelImg2img ? "1" : "0"};
        e->values[0]->setString(keys[index]);
        e->values[1]->setString(vals[index].c_str());
    }

    void getErrorString(OP_String* e, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (myStatus.rfind("error", 0) == 0 || myStatus.rfind("helper", 0) == 0 ||
            myStatus.rfind("unavailable", 0) == 0)
            e->setString(myStatus.c_str());
    }

private:
    void handleEvent(NSDictionary* d)
    {
        NSString* type = d[@"type"];
        if (![type isKindOfClass:[NSString class]])
            return;
        std::lock_guard<std::mutex> l(myMutex);
        if ([type isEqualToString:@"status"]) {
            NSString* t = d[@"text"];
            if ([t isKindOfClass:[NSString class]])
                myStatus = t.UTF8String ?: "";
        } else if ([type isEqualToString:@"progress"]) {
            myProgress = [d[@"pct"] intValue];
        } else if ([type isEqualToString:@"ready"]) {
            myReady = true;
            myProgress = 100;
            myStatus = "ready";
            NSString* k = d[@"kind"];
            NSString* n = d[@"name"];
            myKind = [k isKindOfClass:[NSString class]] ? (k.UTF8String ?: "") : "";
            myName = [n isKindOfClass:[NSString class]] ? (n.UTF8String ?: "") : "";
            myModelW = [d[@"width"] intValue];
            myModelH = [d[@"height"] intValue];
            myModelImg2img = [d[@"img2img"] boolValue];
        } else if ([type isEqualToString:@"step"]) {
            myStep = [d[@"step"] intValue];
            mySteps = [d[@"total"] intValue];
        } else if ([type isEqualToString:@"done"]) {
            myBusy = false;
            myStatus = "ready";
            myDoneSerial = [d[@"serial"] intValue];
            myDoneW = [d[@"width"] intValue];
            myDoneH = [d[@"height"] intValue];
            myGenSeconds = [d[@"seconds"] doubleValue];
            myLastSeed = [d[@"seed"] longLongValue];
        } else if ([type isEqualToString:@"error"]) {
            NSString* t = d[@"text"];
            myBusy = false;
            myStatus = std::string("error: ") +
                       ([t isKindOfClass:[NSString class]] ? (t.UTF8String ?: "") : "");
        }
    }

    static std::string jsonEscape(const std::string& s)
    {
        std::string o;
        o.reserve(s.size() + 8);
        for (char c : s) {
            switch (c) {
                case '"': o += "\\\""; break;
                case '\\': o += "\\\\"; break;
                case '\n': o += "\\n"; break;
                case '\r': o += "\\r"; break;
                case '\t': o += "\\t"; break;
                default:
                    if ((unsigned char)c < 0x20) {
                        char b[8];
                        snprintf(b, sizeof(b), "\\u%04x", c);
                        o += b;
                    } else {
                        o += c;
                    }
            }
        }
        return o;
    }

    TOP_Context* myContext;
    tdcoreai::HelperProcess myHelper;
    std::string myTmpBase;
    std::string myLoadedModel;
    std::atomic<bool> myWantGenerate{false};
    int myExecCount = 0;

    // ヘルパの状態(myMutex 保護)
    std::mutex myMutex;
    std::string myStatus = "no model";
    std::string myKind, myName;
    int myModelW = 0, myModelH = 0;
    bool myModelImg2img = false;
    bool myReady = false, myBusy = false;
    int myProgress = 0, myStep = 0, mySteps = 0;
    double myGenSeconds = 0;
    long long myLastSeed = 0;
    int myDoneSerial = 0, myDoneW = 0, myDoneH = 0;

    int myLoadedSerial = 0;   // cook スレッドのみ
    Result myResult;          // cook スレッドのみ(最新画像のキャッシュ)
};

}  // namespace

extern "C" {

DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* info)
{
    if (!info->setAPIVersion(TOPCPlusPlusAPIVersion))
        return;
    info->executeMode = TOP_ExecuteMode::CPUMem;
    OP_CustomOPInfo& c = info->customOPInfo;
    c.opType->setString("Coreaiimagegen");
    c.opLabel->setString("CoreAI ImageGen");
    c.opIcon->setString("CAG");
    c.authorName->setString("SYGNAL Inc.");
    c.authorEmail->setString("");
    c.minInputs = 0;
    c.maxInputs = 1;
    c.majorVersion = 0;
    c.minorVersion = 9;
    if (c.opHelpURL)
        c.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/CoreAI/README.md");
}

DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new CoreAIImageGenTOP(info, context);
}

DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (CoreAIImageGenTOP*)instance;
}
}
