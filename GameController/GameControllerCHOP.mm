// GameController CHOP — TouchDesigner カスタムオペレータ(macOS / GameController)
//
// PS5(DualSense)/ Xbox / MFi ゲームパッドの入力を CHOP チャンネルで出力する。
// TD 標準 Joystick CHOP のモダン代替。ボタン/スティックに加えて
// **アナログトリガー・モーションセンサー(対応パッド)・ランブル(振動)**に対応。
//
// 出力: connected / a,b,x,y / l1,r1,l2,r2(アナログ)/ lstick,rstick x,y /
//       dpad x,y / menu,options / lstickbtn,rstickbtn (+ Motion時 gravity/accel xyz)
// Rumble パラメータ(0〜1)で振動(CoreHaptics・対応パッドのみ)。
// 振動は cook されている間だけ続く(短いパターンを掛け直す方式)。
//
// 実装: GCController の値読みは cook 内で直接行う(軽量・ノンブロッキング)。

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <chrono>

#include <atomic>
#include <cstring>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

constexpr int kBaseChans = 19;
static const char* kChanNames[kBaseChans] = {
    "connected", "a", "b", "x", "y", "l1", "r1", "l2", "r2",
    "lstickx", "lsticky", "rstickx", "rsticky", "dpadx", "dpady",
    "menu", "options", "lstickbtn", "rstickbtn",
};
constexpr int kMotionChans = 6;
static const char* kMotionNames[kMotionChans] = {
    "gravityx", "gravityy", "gravityz", "accelx", "accely", "accelz",
};

class GameControllerCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit GameControllerCHOP(const OP_NodeInfo*)
    {
        // 接続監視を有効化(初回列挙のため)
        [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    }

    ~GameControllerCHOP() override { stopRumble(); }

    void getGeneralInfo(CHOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
        ginfo->timeslice = false;
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* inputs, void*) override
    {
        myMotion = inputs->getParInt("Motion") != 0;
        info->numChannels = kBaseChans + (myMotion ? kMotionChans : 0);
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        if (index < kBaseChans)
            name->setString(kChanNames[index]);
        else
            name->setString(kMotionNames[index - kBaseChans]);
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const int idx = (int)inputs->getParInt("Controllerindex");
        const float rumble = (float)inputs->getParDouble("Rumble");

        float v[kBaseChans + kMotionChans] = {};
        @autoreleasepool {
            NSArray<GCController*>* list = [GCController controllers];
            GCController* gc = (idx < (int)list.count) ? list[idx] : nil;
            GCExtendedGamepad* pad = gc.extendedGamepad;
            if (pad) {
                v[0] = 1;
                v[1] = pad.buttonA.value;
                v[2] = pad.buttonB.value;
                v[3] = pad.buttonX.value;
                v[4] = pad.buttonY.value;
                v[5] = pad.leftShoulder.value;
                v[6] = pad.rightShoulder.value;
                v[7] = pad.leftTrigger.value;
                v[8] = pad.rightTrigger.value;
                v[9] = pad.leftThumbstick.xAxis.value;
                v[10] = pad.leftThumbstick.yAxis.value;
                v[11] = pad.rightThumbstick.xAxis.value;
                v[12] = pad.rightThumbstick.yAxis.value;
                v[13] = pad.dpad.xAxis.value;
                v[14] = pad.dpad.yAxis.value;
                v[15] = pad.buttonMenu.value;
                v[16] = pad.buttonOptions ? pad.buttonOptions.value : 0.0f;
                v[17] = pad.leftThumbstickButton ? pad.leftThumbstickButton.value : 0.0f;
                v[18] = pad.rightThumbstickButton ? pad.rightThumbstickButton.value : 0.0f;

                if (myMotion && gc.motion) {
                    GCMotion* m = gc.motion;
                    if (m.sensorsRequireManualActivation && !m.sensorsActive)
                        m.sensorsActive = YES;
                    v[kBaseChans + 0] = (float)m.gravity.x;
                    v[kBaseChans + 1] = (float)m.gravity.y;
                    v[kBaseChans + 2] = (float)m.gravity.z;
                    v[kBaseChans + 3] = (float)m.userAcceleration.x;
                    v[kBaseChans + 4] = (float)m.userAcceleration.y;
                    v[kBaseChans + 5] = (float)m.userAcceleration.z;
                }
                updateRumble(gc, rumble);
            } else {
                stopRumble();
            }
        }

        const int n = kBaseChans + (myMotion ? kMotionChans : 0);
        for (int i = 0; i < n; i++)
            output->channels[i][0] = v[i];
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Controllerindex");
            p.label = "Controller Index";
            p.page = "Game Controller";
            p.defaultValues[0] = 0;
            p.minSliders[0] = 0;
            p.maxSliders[0] = 3;
            p.minValues[0] = 0;
            p.maxValues[0] = 7;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Motion");
            p.label = "Motion Sensors";
            p.page = "Game Controller";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Rumble");
            p.label = "Rumble";
            p.page = "Game Controller";
            p.defaultValues[0] = 0;
            p.minSliders[0] = 0;
            p.maxSliders[0] = 1;
            p.minValues[0] = 0;
            p.maxValues[0] = 1;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendFloat(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[2] = {"executes", "controllers"};
        float values[2] = {(float)myExecCount, (float)[GCController controllers].count};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        if ([GCController controllers].count == 0)
            warning->setString("No game controller connected");
    }

private:
    // 連続振動。
    //
    // 作り直しでは強度を変えられない: 前のパターンが残っている間に新しいものを重ねると
    // 振動が足し算になり、「上げると強くなるが下げても弱くならない」状態になる(実際に踏んだ)。
    // そのため走っているプレイヤーは1つだけに保ち、強度は sendParameters で動かす。
    //
    // 停止も cook に依存させない: パターンを有限長にして鳴らしたい間だけ掛け直すので、
    // CHOP が cook されなくなれば kRumbleDur 以内に自然に止まる。
    static constexpr double kRumbleDur   = 2.0;    // パターンの長さ(秒)
    static constexpr double kRumbleRenew = 1.2;    // 掛け直す間隔(秒)。必ず Dur より短く
    static constexpr double kZeroHold    = 0.15;   // 強度0を命令してから片付けるまで(秒)

    void sendIntensity(float value) API_AVAILABLE(macos(11.0))
    {
        if (!myPlayer)
            return;
        CHHapticDynamicParameter* p = [[CHHapticDynamicParameter alloc]
            initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                          value:value
                   relativeTime:0];
        [myPlayer sendParameters:@[p] atTime:0 error:nil];
    }

    void armPlayer(GCController* gc, float value) API_AVAILABLE(macos(11.0))
    {
        NSError* err = nil;
        if (!myEngine) {
            CHHapticEngine* engine =
                [gc.haptics createEngineWithLocality:GCHapticsLocalityDefault];
            if (!engine || ![engine startAndReturnError:&err])
                return;
            myEngine = engine;
        }
        CHHapticEventParameter* intensity = [[CHHapticEventParameter alloc]
            initWithParameterID:CHHapticEventParameterIDHapticIntensity value:value];
        CHHapticEvent* event = [[CHHapticEvent alloc]
            initWithEventType:CHHapticEventTypeHapticContinuous
                   parameters:@[intensity]
                 relativeTime:0
                     duration:kRumbleDur];
        CHHapticPattern* pattern =
            [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
        id<CHHapticPatternPlayer> next =
            pattern ? [myEngine createPlayerWithPattern:pattern error:&err] : nil;
        if (!next)
            return;
        // 重ねない。古いプレイヤーは必ず止めてから差し替える
        if (myPlayer) {
            sendIntensity(0.0f);
            [myPlayer stopAtTime:0 error:nil];
            myPlayer = nil;
        }
        if ([next startAtTime:0 error:&err])
            myPlayer = next;
    }

    void updateRumble(GCController* gc, float value)
    {
        if (@available(macOS 11.0, *)) {
            const auto now = std::chrono::steady_clock::now();
            const bool want = value > 0.001f && gc.haptics != nil;

            if (want) {
                myZeroSince = {};                       // 停止予約を解除
                const double since =
                    std::chrono::duration<double>(now - myRumbleStart).count();
                if (!myPlayer || since >= kRumbleRenew) {
                    armPlayer(gc, value);               // 期限が来たので掛け直す
                    myRumbleStart = now;
                    myRumbleValue = value;
                } else if (fabsf(value - myRumbleValue) >= 0.005f) {
                    sendIntensity(value);               // 走っているプレイヤーの強度だけ変える
                    myRumbleValue = value;
                }
                return;
            }

            // 0 になった。まず強度0を命令し、効いてから片付ける
            // (停止と同時に送ると反映されず、モーターが回り続けるパッドがある)
            if (!myPlayer) {
                myRumbleValue = 0.0f;
                return;
            }
            if (myZeroSince.time_since_epoch().count() == 0) {
                sendIntensity(0.0f);
                myRumbleValue = 0.0f;
                myZeroSince = now;
                return;
            }
            if (std::chrono::duration<double>(now - myZeroSince).count() >= kZeroHold)
                stopRumble();
        }
    }

    void stopRumble()
    {
        if (@available(macOS 11.0, *)) {
            if (myPlayer) {
                sendIntensity(0.0f);            // 念のためもう一度0を命令してから止める
                [myPlayer stopAtTime:0 error:nil];
            }
            if (myEngine)
                [myEngine stopWithCompletionHandler:nil];
        }
        myPlayer = nil;
        myEngine = nil;
        myRumbleValue = 0.0f;
        myZeroSince = {};
    }

    bool myMotion = false;
    float myRumbleValue = -1.0f;
    std::chrono::steady_clock::time_point myRumbleStart{};
    std::chrono::steady_clock::time_point myZeroSince{};
    CHHapticEngine* myEngine API_AVAILABLE(macos(11.0)) = nil;
    id<CHHapticPatternPlayer> myPlayer API_AVAILABLE(macos(11.0)) = nil;
    std::atomic<int> myExecCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Gamecontroller");
    info->customOPInfo.opLabel->setString("Game Controller");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("GCT");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/GameController/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new GameControllerCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (GameControllerCHOP*)instance;
}

}   // extern "C"
