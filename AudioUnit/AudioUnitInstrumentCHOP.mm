// AudioUnit Instrument CHOP — Audio Unit 楽器(aumu)を TouchDesigner でホストする。
// 実装の本体は AudioUnitCommon.h(AudioUnit Effect と共通)。
#define TDAU_DELEGATE TDAudioUnitInstrumentWinDelegate
#include "AudioUnitCommon.h"

class AudioUnitInstrumentCHOP : public AudioUnitBase
{
public:
    explicit AudioUnitInstrumentCHOP(const OP_NodeInfo* info)
        : AudioUnitBase(info, AUKind{ kAudioUnitType_MusicDevice, true }) {}
};

extern "C" {

DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    // 戻り値を見ないと、SDK バージョンが食い違ったときに未設定の opType ポインタへ
    // 書き込んでクラッシュする。TD 側に安全に拒否させる。
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Auinstrument");
    info->customOPInfo.opLabel->setString("AU Instrument");
    info->customOPInfo.opIcon->setString("AUI");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.authorEmail->setString("");
    info->customOPInfo.minInputs = 0;      // 入力0=ノート(任意) / 入力1=パラメータのパネル
    info->customOPInfo.maxInputs = 2;
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    if (info->customOPInfo.opHelpURL)
        info->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/AudioUnit/README.md");
}

DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new AudioUnitInstrumentCHOP(info);
}

DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (AudioUnitInstrumentCHOP*)instance;
}

}
