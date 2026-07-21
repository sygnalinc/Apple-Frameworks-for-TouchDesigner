// ImageGen TOP — text2img / img2img（macOS / Core ML 画像生成）
//
// Core ML の画像生成モデルで text2img / img2img を行う TD カスタム TOP。
// 現行バックエンドは Apple の ml-stable-diffusion（SD 2.x / SDXL をフォルダ内容で自動判定）。
// Stable Diffusion 以外の Core ML 生成モデルにも対応できるよう、推論は同梱の
// ヘルパ dylib（Swift）に分離してある。
//
// 使い方:
//   Model Folder に Core ML SD モデルのフォルダ（*.mlmodelc 群が入った階層）を指定 →
//   ロード完了（Info DAT の status が ready）後、Prompt を書いて Generate をパルス。
//   入力 TOP を接続して Image to Image をオンにすると img2img（Strength で寄せ具合）。
//
// 生成は非同期（cook はブロックしない）。進行は Info CHOP の step/steps、
// 完了すると出力テクスチャが差し替わる。

#import <Foundation/Foundation.h>

#include <atomic>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

// libImageGenHelper.dylib（Swift）の C API（外部 Core ML 生成モデル・現行は Stable Diffusion）
extern "C" {
void* sd_create(const char* modelDir, int32_t computeUnits);
bool sd_generate(void* handle, const char* prompt, const char* negative,
                 int32_t steps, float guidance, int64_t seed, float strength,
                 const uint8_t* inputRGBA, int32_t inputW, int32_t inputH);
int32_t sd_poll(void* handle, char* buffer, int32_t capacity);
int64_t sd_copy_image(void* handle, uint8_t* buffer, int64_t capacity);
void sd_destroy(void* handle);
}

namespace {

class ImageGenTOP : public TOP_CPlusPlusBase
{
public:
    ImageGenTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context) {}

    ~ImageGenTOP() override
    {
        if (mySession)
            sd_destroy(mySession);
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
        const int compute = (int)inputs->getParInt("Compute");

        // モデル変更（または初回）でセッションを作り直す
        if (!model.empty() && (model != myModelPath || compute != myCompute)) {
            if (mySession)
                sd_destroy(mySession);
            mySession = sd_create(model.c_str(), compute);
            myModelPath = model;
            myCompute = compute;
        }
        void* active_session = mySession;

        inputs->enablePar("Strength", inputs->getParInt("Img2img") != 0);

        // 状態ポーリング（トリガ判定に使うので先に行う）
        myStatus = "no model";
        int imageSerial = 0, imgW = 0, imgH = 0;
        bool loaded = false;
        if (active_session) {
            char pbuf[1024];
            sd_poll(active_session, pbuf, sizeof(pbuf));
            loaded = parsePoll(pbuf, imageSerial, imgW, imgH);
        }

        // 生成トリガ: Generate パルス、または Continuous（前の生成が終わり次第
        // 最新の入力フレーム/パラメータで自動再生成 = リアルタイム変換モード）
        const bool continuous = inputs->getParInt("Continuous") != 0;
        const bool trigger = myWantGenerate || (continuous && loaded && !myBusy);
        if (trigger && mySession) {
            myWantGenerate = false;
            const bool img2img = inputs->getParInt("Img2img") != 0;
            const OP_TOPInput* top = inputs->getInputTOP(0);
            GenParams params;
            params.session = mySession;
            params.prompt = inputs->getParString("Prompt") ?: "";
            params.negative = inputs->getParString("Negativeprompt") ?: "";
            params.steps = (int)inputs->getParInt("Steps");
            params.guidance = (float)inputs->getParDouble("Guidance");
            params.seed = (int64_t)inputs->getParInt("Seed");
            params.strength = (float)inputs->getParDouble("Strength");

            if (img2img && top) {
                OP_TOPInputDownloadOptions opts;
                opts.pixelFormat = OP_PixelFormat::RGBA8Fixed;   // ヘルパは RGBA 前提
                opts.verticalFlip = true;   // TD は bottom-up → CGImage は top-down
                OP_SmartRef<OP_TOPDownloadResult> download =
                    top->downloadTexture(opts, nullptr);
                if (download) {
                    // getData() はブロックするので別スレッドで待ってから投入
                    std::thread([params, download = std::move(download)]() mutable {
                        void* data = download->getData();
                        const uint32_t w = download->textureDesc.width;
                        const uint32_t h = download->textureDesc.height;
                        if (data && w && h) {
                            sd_generate(params.session, params.prompt.c_str(),
                                        params.negative.c_str(), params.steps,
                                        params.guidance, params.seed, params.strength,
                                        (const uint8_t*)data, w, h);
                        }
                    }).detach();
                }
            } else {
                sd_generate(params.session, params.prompt.c_str(), params.negative.c_str(),
                            params.steps, params.guidance, params.seed, params.strength,
                            nullptr, 0, 0);
            }
        }

        // 新しい画像ができていたらアップロード（行反転で TD の bottom-up へ）
        if (active_session && imageSerial != myUploadedSerial && imgW > 0 && imgH > 0) {
            const uint64_t bytes = (uint64_t)imgW * imgH * 4;
            std::vector<uint8_t> pixels(bytes);
            const int64_t copied =
                sd_copy_image(active_session, pixels.data(), (int64_t)bytes);
            if (copied == (int64_t)bytes) {
                OP_SmartRef<TOP_Buffer> buf =
                    myContext->createOutputBuffer(bytes, TOP_BufferFlags::None, nullptr);
                if (buf) {
                    const bool flip = inputs->getParInt("Flip") != 0;
                    uint8_t* dst = (uint8_t*)buf->data;
                    const size_t row = (size_t)imgW * 4;
                    for (int y = 0; y < imgH; y++) {
                        const uint8_t* src = pixels.data() + (size_t)y * row;
                        memcpy(dst + (size_t)(flip ? (imgH - 1 - y) : y) * row, src, row);
                    }
                    TOP_UploadInfo info;
                    info.textureDesc.texDim = OP_TexDim::e2D;
                    info.textureDesc.width = imgW;
                    info.textureDesc.height = imgH;
                    info.textureDesc.pixelFormat = OP_PixelFormat::RGBA8Fixed;
                    output->uploadBuffer(&buf, info, nullptr);
                    myUploadedSerial = imageSerial;
                }
            }
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Model");
            p.label = "Model Folder";
            p.page = "Image Gen";
            manager->appendFolder(p);
        }
        {
            OP_StringParameter p("Compute");
            p.label = "Compute Units";
            p.page = "Image Gen";
            p.defaultValue = "0";
            const char* names[] = {"0", "1", "2"};
            const char* labels[] = {"CPU + Neural Engine", "CPU + GPU", "All"};
            manager->appendMenu(p, 3, names, labels);
        }
        {
            OP_StringParameter p("Prompt");
            p.label = "Prompt";
            p.page = "Image Gen";
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
            p.defaultValues[0] = 15;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 50;
            p.minValues[0] = 1;
            p.maxValues[0] = 100;
            p.clampMins[0] = true;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Guidance");
            p.label = "Guidance Scale";
            p.page = "Image Gen";
            p.defaultValues[0] = 7.5;
            p.minSliders[0] = 0;
            p.maxSliders[0] = 20;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Seed");
            p.label = "Seed (-1 = Random)";
            p.page = "Image Gen";
            p.defaultValues[0] = -1;
            p.minSliders[0] = -1;
            p.maxSliders[0] = 10000;
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
            p.defaultValues[0] = 0.6;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 1.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Generate");
            p.label = "Generate";
            p.page = "Image Gen";
            manager->appendPulse(p);
        }
        {
            // 前の生成が終わり次第、自動で次を生成（SD Turbo でのリアルタイム変換用）
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

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[6] = {"busy", "step", "steps", "gen_seconds", "image_serial",
                                "executes"};
        float values[6] = {(float)myBusy, (float)myStep, (float)mySteps,
                           (float)myGenSeconds, (float)myUploadedSerial,
                           (float)myExecCount};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    bool getInfoDATSize(OP_InfoDATSize* infoSize, void*) override
    {
        infoSize->rows = 1;
        infoSize->cols = 2;
        infoSize->byColumn = false;
        return true;
    }

    void getInfoDATEntries(int32_t, int32_t, OP_InfoDATEntries* entries, void*) override
    {
        entries->values[0]->setString("status");
        entries->values[1]->setString(myStatus.c_str());
    }

private:
    struct GenParams
    {
        void* session = nullptr;
        std::string prompt, negative;
        int steps = 15;
        float guidance = 7.5f;
        int64_t seed = -1;
        float strength = 0.6f;
    };

    bool parsePoll(const char* json, int& imageSerial, int& imgW, int& imgH)
    {
        bool loaded = false;
        @autoreleasepool {
            NSData* data = [NSData dataWithBytes:json length:strlen(json)];
            NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0 error:nil];
            if (![dict isKindOfClass:[NSDictionary class]])
                return false;
            NSString* status = dict[@"status"];
            if ([status isKindOfClass:[NSString class]])
                myStatus = status.UTF8String;
            myBusy = [dict[@"busy"] boolValue] ? 1 : 0;
            myStep = [dict[@"step"] intValue];
            mySteps = [dict[@"steps"] intValue];
            myGenSeconds = [dict[@"genSeconds"] floatValue];
            imageSerial = [dict[@"imageSerial"] intValue];
            imgW = [dict[@"width"] intValue];
            imgH = [dict[@"height"] intValue];
            loaded = [dict[@"loaded"] boolValue];
        }
        return loaded;
    }

    TOP_Context* myContext;
    void* mySession = nullptr;
    std::string myModelPath;
    int myCompute = 0;
    std::atomic<bool> myWantGenerate{false};
    int myUploadedSerial = 0;
    std::string myStatus = "no model";
    int myBusy = 0, myStep = 0, mySteps = 0;
    float myGenSeconds = 0;
    std::atomic<int> myExecCount{0};
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillTOPPluginInfo(TOP_PluginInfo* info)
{
    if (!info->setAPIVersion(TOPCPlusPlusAPIVersion))
        return;
    info->executeMode = TOP_ExecuteMode::CPUMem;
    info->customOPInfo.opType->setString("Coremlimagegen");
    info->customOPInfo.opLabel->setString("CoreML ImageGen");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("IMG");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new ImageGenTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (ImageGenTOP*)instance;
}

}   // extern "C"
