// ImagePlayground TOP — テキスト+スタイルからの画像生成（Apple Image Playground）
//
// Apple の ImagePlayground フレームワーク（ImageCreator・macOS 15.4+）で、プロンプトと
// スタイルから画像を生成する TD カスタム TOP。**外部モデル不要**（端末の Apple Intelligence
// が生成する）。Core ML の外部モデルを使う CoreML ImageGen とは別系統。
//
// 制約（Apple 仕様）: 人物はテキストのみからは生成できない → **入力0に顔のソース画像 TOP**
// を接続すると人物を生成できる（ImagePlaygroundConcept.image）。Steps / Seed / img2img は無し。
// スタイルは animation / illustration / sketch の3種。
//
// 使い方: Style と Prompt を設定して Generate をパルス。人物なら入力0に顔画像 TOP を接続。
// 生成は非同期（cook 非ブロック）。

#import <Foundation/Foundation.h>

#include <atomic>
#include <cstring>
#include <string>
#include <vector>

#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

// libPlaygroundHelper.dylib（Swift）の C API
extern "C" {
void* pg_create(void);
bool pg_generate(void* handle, const char* prompt, const char* style,
                 const uint8_t* sourceRGBA, int32_t sourceW, int32_t sourceH);
int32_t pg_poll(void* handle, char* buffer, int32_t capacity);
int64_t pg_copy_image(void* handle, uint8_t* buffer, int64_t capacity);
void pg_destroy(void* handle);
}

namespace {

class ImagePlaygroundTOP : public TOP_CPlusPlusBase
{
public:
    ImagePlaygroundTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context) {}

    ~ImagePlaygroundTOP() override
    {
        if (mySession)
            pg_destroy(mySession);
    }

    void getGeneralInfo(TOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(TOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        if (!mySession)
            mySession = pg_create();

        // 状態ポーリング
        myStatus = "no session";
        int imageSerial = 0, imgW = 0, imgH = 0;
        if (mySession) {
            char pbuf[1024];
            pg_poll(mySession, pbuf, sizeof(pbuf));
            parsePoll(pbuf, imageSerial, imgW, imgH);
        }

        // Generate パルス
        if (myWantGenerate && mySession) {
            myWantGenerate = false;
            // 入力0にソース画像（顔）があれば渡す。**人物生成は Apple 仕様で顔ソースが必須**
            const OP_TOPInput* src = inputs->getInputTOP(0);
            OP_SmartRef<OP_TOPDownloadResult> dl;
            const uint8_t* srcData = nullptr;
            int srcW = 0, srcH = 0;
            if (src) {
                OP_TOPInputDownloadOptions opts;
                opts.pixelFormat = OP_PixelFormat::RGBA8Fixed;   // ヘルパは RGBA 前提
                opts.verticalFlip = true;   // TD は bottom-up → 正立画像で顔認識
                dl = src->downloadTexture(opts, nullptr);
                if (dl) {
                    srcData = (const uint8_t*)dl->getData();   // 準備できるまで stall
                    srcW = (int)dl->textureDesc.width;
                    srcH = (int)dl->textureDesc.height;
                }
            }
            pg_generate(mySession, inputs->getParString("Prompt") ?: "",
                        inputs->getParString("Style") ?: "animation",
                        srcData, srcW, srcH);
        }

        // 新しい画像ができていたらアップロード
        if (mySession && imageSerial != myUploadedSerial && imgW > 0 && imgH > 0) {
            const uint64_t bytes = (uint64_t)imgW * imgH * 4;
            std::vector<uint8_t> pixels(bytes);
            const int64_t copied = pg_copy_image(mySession, pixels.data(), (int64_t)bytes);
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
            OP_StringParameter p("Style");
            p.label = "Style";
            p.page = "Image Playground";
            p.defaultValue = "animation";
            const char* names[] = {"animation", "illustration", "sketch"};
            const char* labels[] = {"Animation", "Illustration", "Sketch"};
            manager->appendMenu(p, 3, names, labels);
        }
        {
            OP_StringParameter p("Prompt");
            p.label = "Prompt";
            p.page = "Image Playground";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Generate");
            p.label = "Generate";
            p.page = "Image Playground";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Output Vertically";
            p.page = "Image Playground";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Generate") == 0)
            myWantGenerate = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[4] = {"busy", "gen_seconds", "image_serial", "executes"};
        float values[4] = {(float)myBusy, (float)myGenSeconds, (float)myUploadedSerial,
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
    void parsePoll(const char* json, int& imageSerial, int& imgW, int& imgH)
    {
        @autoreleasepool {
            NSData* data = [NSData dataWithBytes:json length:strlen(json)];
            NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0 error:nil];
            if (![dict isKindOfClass:[NSDictionary class]])
                return;
            NSString* status = dict[@"status"];
            if ([status isKindOfClass:[NSString class]])
                myStatus = status.UTF8String;
            myBusy = [dict[@"busy"] boolValue] ? 1 : 0;
            myGenSeconds = [dict[@"genSeconds"] floatValue];
            imageSerial = [dict[@"imageSerial"] intValue];
            imgW = [dict[@"width"] intValue];
            imgH = [dict[@"height"] intValue];
        }
    }

    TOP_Context* myContext;
    void* mySession = nullptr;
    std::atomic<bool> myWantGenerate{false};
    int myUploadedSerial = 0;
    std::string myStatus = "no session";
    int myBusy = 0;
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
    info->customOPInfo.opType->setString("Imageplayground");
    info->customOPInfo.opLabel->setString("ImagePlayground");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("IPG");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/ImagePlayground/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;   // 入力0 = ソース画像(顔)。人物生成に必須
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new ImagePlaygroundTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (ImagePlaygroundTOP*)instance;
}

}   // extern "C"
