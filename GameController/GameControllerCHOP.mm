// GameController CHOP — TouchDesigner カスタムオペレータ(macOS / GameController)
//
// PS5(DualSense)/ Xbox / MFi ゲームパッドの入力を CHOP チャンネルで出力する。
// TD 標準 Joystick CHOP のモダン代替。ボタン/スティックに加えて
// **アナログトリガー・モーションセンサー(対応パッド)・ランブル(振動)**に対応。
//
// 出力: connected / a,b,x,y / l1,r1,l2,r2(アナログ)/ lstick,rstick x,y /
//       dpad x,y / menu,options / lstickbtn,rstickbtn (+ Motion時 gravity/accel xyz)
// Rumble パラメータ(0〜1)で振動(CoreHaptics・対応パッドのみ)。
//
// 実装: GCController の値読みは cook 内で直接行う(軽量・ノンブロッキング)。

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>

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
    // 連続振動: 値が変わったときだけプレイヤーを作り直す
    void updateRumble(GCController* gc, float value)
    {
        if (fabsf(value - myRumbleValue) < 0.01f)
            return;
        myRumbleValue = value;
        stopRumble();
        if (value <= 0.0f || !gc.haptics)
            return;
        if (@available(macOS 11.0, *)) {
            CHHapticEngine* engine =
                [gc.haptics createEngineWithLocality:GCHapticsLocalityDefault];
            if (!engine)
                return;
            NSError* err = nil;
            if (![engine startAndReturnError:&err])
                return;
            CHHapticEventParameter* intensity = [[CHHapticEventParameter alloc]
                initWithParameterID:CHHapticEventParameterIDHapticIntensity value:value];
            CHHapticEvent* event = [[CHHapticEvent alloc]
                initWithEventType:CHHapticEventTypeHapticContinuous
                       parameters:@[intensity]
                     relativeTime:0
                         duration:3600];
            CHHapticPattern* pattern =
                [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
            id<CHHapticPatternPlayer> player =
                pattern ? [engine createPlayerWithPattern:pattern error:&err] : nil;
            if (player && [player startAtTime:0 error:&err]) {
                myEngine = engine;
                myPlayer = player;
            }
        }
    }

    void stopRumble()
    {
        if (@available(macOS 11.0, *)) {
            if (myPlayer)
                [myPlayer stopAtTime:0 error:nil];
            if (myEngine)
                [myEngine stopWithCompletionHandler:nil];
        }
        myPlayer = nil;
        myEngine = nil;
    }

    bool myMotion = false;
    float myRumbleValue = -1.0f;
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
    info->customOPInfo.opIcon->setString("GCT");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/GameController/README.md");
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
