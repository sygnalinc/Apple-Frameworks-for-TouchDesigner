// GameController CHOP — TouchDesigner カスタムオペレータ(macOS / GameController)
//
// PS5(DualSense)/ Xbox / MFi ゲームパッドの入力を CHOP チャンネルで出力する。
// TD 標準 Joystick CHOP のモダン代替。ボタン/スティックに加えて
// **アナログトリガー・モーションセンサー(対応パッド)・ランブル(振動)**に対応。
//
// 出力: connected / a,b,x,y / l1,r1,l2,r2(アナログ)/ lstick,rstick x,y /
//       dpad x,y / menu,options / lstickbtn,rstickbtn (+ Motion時 gravity/accel xyz)
// Rumble パラメータ(0〜1)で連続振動、Pulse で単発振動(CoreHaptics・対応パッドのみ)。
// 振動は cook されている間だけ続く(短いパターンを掛け直す方式)。
//
// 実装: GCController の値読みは cook 内で直接行う(軽量・ノンブロッキング)。

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <algorithm>
#include <chrono>
#include <memory>

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
// モーション。パッドによって「何が取れるか」が違うので、能力に応じて中身を変える。
//
// Apple のドキュメントが明言している: gravity と userAcceleration を**分離できないパッドがある**
// (hasGravityAndUserAcceleration == NO)。その場合この2つは 0 のままで、代わりに合計加速度の
// acceleration を読む。Switch Pro 系・DualShock 系は分離できない側で、
// 「Motion Sensors を On にしても加速度が 0」の正体はこれ(実際に踏んだ)。
//
//   gravity*  分離できるパッドのみ。できなければ 0
//   accel*    分離できれば userAcceleration(重力を除いた動き)、
//             できなければ acceleration(重力込みの合計)。**どちらでも必ず値が入る**
//   rot*      角速度(rad/s)。ジャイロを持つパッドはここが一番使える
//
// 何が有効かは Info CHOP の hasgravity / hasrotation で確認する
constexpr int kMotionChans = 9;
static const char* kMotionNames[kMotionChans] = {
    "gravityx", "gravityy", "gravityz",
    "accelx", "accely", "accelz",
    "rotx", "roty", "rotz",
};

class GameControllerCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit GameControllerCHOP(const OP_NodeInfo*)
    {
        // 接続監視を有効化(初回列挙のため)
        [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    }

    ~GameControllerCHOP() override { myAlive->store(false); shutdownHaptics(); }

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

    // CoreHaptics は不正な状態(エンジンが止まった後の stop など)で NSError を返さず
    // **ObjC 例外を投げる**。C++ の呼び出し元へ伝わると std::terminate でプロセスごと落ちる。
    // パッドの Switch/Xbox モード切替(=切断→別デバイスとして再接続)で実際にTDが落ちた。
    // CoreHaptics に触る箇所は必ずこれで包み、例外が出たら握っている参照を捨てる。
    // エンジンは接続中のパッド1台につき1つ。パッドが変わったら必ず作り直す
    // (Switch/Xbox モード切替は「切断 → 別デバイスとして再接続」なので、
    //  古いエンジンを掴んだままだと落ちる)
    bool ensureEngine(GCController* gc) API_AVAILABLE(macos(11.0))
    {
        if (myEngineDead.exchange(false))
            forgetHaptics();
        if (myEngine && myHapticsOwner != gc)
            forgetHaptics();
        if (myEngine)
            return true;
        if (!gc.haptics)
            return false;
        CHHapticEngine* e = [gc.haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!e)
            return false;
        BOOL ok = NO;
        if (!hapticCall([&] { ok = [e startAndReturnError:nil]; }) || !ok)
            return false;
        // エンジンが自分で止まったら(デバイス切断など)、次のcookで参照を捨てる。
        // ハンドラは別スレッドで呼ばれるので、ここではフラグを立てるだけにする
        auto alive = myAlive;
        std::atomic<bool>* dead = &myEngineDead;
        e.stoppedHandler = ^(CHHapticEngineStoppedReason) {
            if (alive->load()) dead->store(true);
        };
        e.resetHandler = ^{
            if (alive->load()) dead->store(true);
        };
        myEngine = e;
        myHapticsOwner = gc;
        return true;
    }

    template <typename F>
    bool hapticCall(F&& f)
    {
        @try {
            f();
            return true;
        } @catch (NSException*) {
            forgetHaptics();
            return false;
        }
    }

    // 参照を捨てるだけ(止めようとしない)。次のcookで作り直される
    void forgetHaptics()
    {
        if (@available(macOS 11.0, *)) {
            myPlayer = nil;
            myShotPlayer = nil;
            myEngine = nil;
        }
        myHapticsOwner = nil;
        myRumbleValue = 0.0f;
        myZeroSince = {};
    }

    void pulsePressed(const char* name, void*) override
    { if (!strcmp(name, "Pulse")) myPulse = true; }

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

                myHasMotion = (gc.motion != nil);
                if (myMotion && gc.motion) {
                    GCMotion* m = gc.motion;
                    // センサーは明示的に起こす必要がある(電池を食うので既定は止まっている)。
                    // 起こした直後の1フレームは 0 のまま
                    if (m.sensorsRequireManualActivation && !m.sensorsActive)
                        m.sensorsActive = YES;

                    const bool sep = m.hasGravityAndUserAcceleration;
                    myHasGravity  = sep;
                    myHasRotation = m.hasRotationRate;
                    mySensorsOn   = m.sensorsActive;

                    GCAcceleration acc = sep ? m.userAcceleration : m.acceleration;
                    if (sep) {
                        v[kBaseChans + 0] = (float)m.gravity.x;
                        v[kBaseChans + 1] = (float)m.gravity.y;
                        v[kBaseChans + 2] = (float)m.gravity.z;
                    }
                    v[kBaseChans + 3] = (float)acc.x;
                    v[kBaseChans + 4] = (float)acc.y;
                    v[kBaseChans + 5] = (float)acc.z;

                    if (myHasRotation) {
                        GCRotationRate r = m.rotationRate;
                        v[kBaseChans + 6] = (float)r.x;
                        v[kBaseChans + 7] = (float)r.y;
                        v[kBaseChans + 8] = (float)r.z;
                    }
                }
                updateRumble(gc, rumble);
                if (myPulse.exchange(false))
                    playPulse(gc,
                              inputs->getParString("Pulsestyle") ? inputs->getParString("Pulsestyle") : "tap",
                              (float)inputs->getParDouble("Pulseintensity"),
                              (float)inputs->getParDouble("Pulsesharpness"),
                              inputs->getParDouble("Pulsegap"));
            } else {
                shutdownHaptics();   // パッドが無くなったらエンジンごと畳む
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
            OP_StringParameter p("Pulsestyle");
            p.label = "Pulse Style";
            p.page = "Game Controller";
            p.defaultValue = "tap";
            const char* n[] = {"tap", "click", "thud", "double", "buzz"};
            const char* l[] = {"Tap", "Click", "Thud", "Double Tap", "Buzz"};
            manager->appendMenu(p, 5, n, l);
        }
        {
            OP_NumericParameter p("Pulseintensity");
            p.label = "Pulse Intensity";
            p.page = "Game Controller";
            p.defaultValues[0] = 1.0;
            p.minSliders[0] = 0; p.maxSliders[0] = 1;
            p.minValues[0] = 0;  p.maxValues[0] = 1;
            p.clampMins[0] = p.clampMaxes[0] = true;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Pulsesharpness");
            p.label = "Pulse Sharpness";
            p.page = "Game Controller";
            p.defaultValues[0] = 0.5;
            p.minSliders[0] = 0; p.maxSliders[0] = 1;
            p.minValues[0] = 0;  p.maxValues[0] = 1;
            p.clampMins[0] = p.clampMaxes[0] = true;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Pulsegap");
            p.label = "Pulse Gap (sec, Double Tap)";
            p.page = "Game Controller";
            p.defaultValues[0] = 0.26;
            p.minSliders[0] = 0.05; p.maxSliders[0] = 0.6;
            p.minValues[0] = 0.02;  p.maxValues[0] = 1.0;
            p.clampMins[0] = p.clampMaxes[0] = true;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Pulse");
            p.label = "Pulse";
            p.page = "Game Controller";
            manager->appendPulse(p);
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

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        // モーション系は「このパッドで何が取れるか」の診断。
        // hasgravity が 0 なら gravity* は 0 のままで、accel* に重力込みの合計が入る
        const char* names[6] = {"executes", "controllers",
                                "hasmotion", "hasgravity", "hasrotation", "sensorsactive"};
        float values[6] = {(float)myExecCount, (float)[GCController controllers].count,
                           (float)myHasMotion, (float)myHasGravity,
                           (float)myHasRotation, (float)mySensorsOn};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        if ([GCController controllers].count == 0)
            warning->setString("No game controller connected");
        else if (myMotion && !myHasMotion)
            warning->setString("This controller has no motion sensors. "
                               "Xbox-mode pads have none; try Nintendo Switch mode.");
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

    // 単発の振動。CoreHaptics に名前付きプリセットは無いので、
    // transient(一撃)と continuous(持続)+ sharpness の組み合わせで定番の触感を作る。
    // 連続振動(Rumble)とは別プレイヤーで鳴らすので、鳴っていても邪魔しない。
    void playPulse(GCController* gc, const char* style, float intensity, float sharpness,
                   double gap)
    {
        if (@available(macOS 11.0, *)) {
            if (!gc.haptics || intensity <= 0.0f)
                return;
            NSError* err = nil;
            if (!ensureEngine(gc))
                return;
            auto ev = [&](BOOL transient, float inten, float sharp, double at, double dur) {
                NSArray* ps = @[
                    [[CHHapticEventParameter alloc]
                        initWithParameterID:CHHapticEventParameterIDHapticIntensity value:inten],
                    [[CHHapticEventParameter alloc]
                        initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharp]
                ];
                return transient
                    ? [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                   parameters:ps relativeTime:at]
                    : [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                   parameters:ps relativeTime:at duration:dur];
            };
            // スタイルは「長さと打数」で作り分ける。
            // Xbox系のようにモーター2個のパッドは sharpness(触感の質)をほとんど反映しないので、
            // transient だけだと Tap と Click の区別が付かない。どのスタイルも
            // transient(対応パッド用)+ 短い continuous(モーターだけのパッド用)を重ねて、
            // continuous の長さで差を出す。Sharpness はどのスタイルでもそのまま渡す。
            NSMutableArray<CHHapticEvent*>* events = [NSMutableArray array];
            const std::string st = style;
            auto hit = [&](double at, double dur, float inten) {
                [events addObject:ev(YES, inten, sharpness, at, 0)];       // 一撃(対応パッドのみ)
                if (dur > 0)
                    [events addObject:ev(NO, inten, sharpness, at, dur)];  // モーターで感じる本体
            };
            if (st == "click") {                       // 一番短い
                hit(0.0, 0.03, intensity);
            } else if (st == "thud") {                 // 長めの鈍い一撃
                hit(0.0, 0.22, intensity);
            } else if (st == "double") {               // 二連打
                // 余韻の長さはパッドによって違い、詰めると1回に聞こえる。
                // Xbox系(回転モーター)は 0.20秒で分かれたが、Switch系(HD振動)は繋がった。
                // 手元のパッドに合わせられるよう Pulse Gap で調整できるようにしてある
                hit(0.0, 0.06, intensity);
                hit(std::max(0.08, gap), 0.06, intensity);
            } else if (st == "buzz") {                 // はっきり続く
                hit(0.0, 0.40, intensity);
            } else {                                   // tap
                hit(0.0, 0.08, intensity);
            }
            CHHapticPattern* pattern =
                [[CHHapticPattern alloc] initWithEvents:events parameters:@[] error:&err];
            id<CHHapticPatternPlayer> player = nil;
            if (pattern)
                hapticCall([&] { player = [myEngine createPlayerWithPattern:pattern error:&err]; });
            BOOL ok = NO;
            if (player && hapticCall([&] { ok = [player startAtTime:0 error:&err]; }) && ok)
                myShotPlayer = player;                 // 再生中に解放されないよう保持する
        }
    }

    void sendIntensity(float value) API_AVAILABLE(macos(11.0))
    {
        if (!myPlayer)
            return;
        CHHapticDynamicParameter* p = [[CHHapticDynamicParameter alloc]
            initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                          value:value
                   relativeTime:0];
        id<CHHapticPatternPlayer> pl = myPlayer;
        hapticCall([&] { [pl sendParameters:@[p] atTime:0 error:nil]; });
    }

    void armPlayer(GCController* gc, float value) API_AVAILABLE(macos(11.0))
    {
        NSError* err = nil;
        if (!ensureEngine(gc))
            return;
        CHHapticEventParameter* intensity = [[CHHapticEventParameter alloc]
            initWithParameterID:CHHapticEventParameterIDHapticIntensity value:value];
        CHHapticEvent* event = [[CHHapticEvent alloc]
            initWithEventType:CHHapticEventTypeHapticContinuous
                   parameters:@[intensity]
                 relativeTime:0
                     duration:kRumbleDur];
        CHHapticPattern* pattern =
            [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
        id<CHHapticPatternPlayer> next = nil;
        if (pattern)
            hapticCall([&] { next = [myEngine createPlayerWithPattern:pattern error:&err]; });
        if (!next)
            return;
        // 重ねない。古いプレイヤーは必ず止めてから差し替える
        if (myPlayer) {
            sendIntensity(0.0f);
            id<CHHapticPatternPlayer> old = myPlayer;
            myPlayer = nil;
            hapticCall([&] { [old stopAtTime:0 error:nil]; });
        }
        BOOL started = NO;
        if (hapticCall([&] { started = [next startAtTime:0 error:&err]; }) && started)
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

    // 連続振動もパルスもやめてエンジンごと畳む(切断時 / 破棄時)
    void shutdownHaptics()
    {
        stopRumble();
        if (@available(macOS 11.0, *)) {
            id<CHHapticPatternPlayer> shot = myShotPlayer;
            CHHapticEngine* eng = myEngine;
            if (shot)
                hapticCall([&] { [shot stopAtTime:0 error:nil]; });
            if (eng)
                hapticCall([&] { [eng stopWithCompletionHandler:nil]; });
        }
        myShotPlayer = nil;
        myEngine = nil;
    }

    void stopRumble()
    {
        if (@available(macOS 11.0, *)) {
            if (myPlayer) {
                sendIntensity(0.0f);            // 念のためもう一度0を命令してから止める
                id<CHHapticPatternPlayer> pl = myPlayer;
                hapticCall([&] { [pl stopAtTime:0 error:nil]; });
            }
            // エンジンは止めない(単発パルス用に残す。切断時と破棄時にだけ畳む)
        }
        myPlayer = nil;
        myRumbleValue = 0.0f;
        myZeroSince = {};
    }

    bool myMotion = false;
    bool myHasMotion = false;    // gc.motion があるか(Xboxモードのパッドは無い)
    bool myHasGravity = false;   // gravity と userAcceleration を分離できるか
    bool myHasRotation = false;  // 角速度が取れるか
    bool mySensorsOn = false;    // センサーが起きているか
    float myRumbleValue = -1.0f;
    std::chrono::steady_clock::time_point myRumbleStart{};
    std::chrono::steady_clock::time_point myZeroSince{};
    CHHapticEngine* myEngine API_AVAILABLE(macos(11.0)) = nil;
    id<CHHapticPatternPlayer> myPlayer API_AVAILABLE(macos(11.0)) = nil;
    id<CHHapticPatternPlayer> myShotPlayer API_AVAILABLE(macos(11.0)) = nil;
    GCController* myHapticsOwner = nil;            // エンジンを作った時のパッド
    std::atomic<bool> myEngineDead{false};         // 別スレッドのハンドラから立つ
    std::shared_ptr<std::atomic<bool>> myAlive =
        std::make_shared<std::atomic<bool>>(true);   // 破棄後にハンドラが触らないように
    std::atomic<bool> myPulse{false};
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
