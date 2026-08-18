// AudioUnit Effect CHOP — Audio Unit エフェクト(aufx)を TouchDesigner でホストする。
// 実装の本体は AudioUnitCommon.h(AudioUnit Instrument と共通)。
#define TDAU_DELEGATE TDAudioUnitEffectWinDelegate
#include "AudioUnitCommon.h"

class AudioUnitEffectCHOP : public AudioUnitBase
{
public:
    explicit AudioUnitEffectCHOP(const OP_NodeInfo* info)
        : AudioUnitBase(info, AUKind{ kAudioUnitType_Effect, false }) {}
};

extern "C" {

DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    info->setAPIVersion(CHOPCPlusPlusAPIVersion);
    info->customOPInfo.opType->setString("Aueffect");
    info->customOPInfo.opLabel->setString("AU Effect");
    info->customOPInfo.opIcon->setString("AUE");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.authorEmail->setString("");
    info->customOPInfo.minInputs = 1;      // 入力0=音声 / 入力1=パラメータのパネル
    info->customOPInfo.maxInputs = 2;
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    if (info->customOPInfo.opHelpURL)
        info->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/AudioUnit/README.md");
}

DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new AudioUnitEffectCHOP(info);
}

DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (AudioUnitEffectCHOP*)instance;
}

}
