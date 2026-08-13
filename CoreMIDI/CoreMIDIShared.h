// CoreMIDI In / Out で共有するデバイス列挙まわり。
//
// 別バンドルなのでヘッダに実体を置いても重複シンボルにならない
// (Multipeer In/Out の共有ヘッダと同じ考え方)。
#pragma once
#import <CoreMIDI/CoreMIDI.h>
#include <string>
#include <vector>

namespace tdmidi {

struct Device {
    SInt32 uid = 0;
    bool online = true;
    std::string name, manufacturer, model;
};

inline std::string strProp(MIDIObjectRef obj, CFStringRef key)
{
    CFStringRef s = nullptr;
    if (MIDIObjectGetStringProperty(obj, key, &s) != noErr || !s) return "";
    char buf[256] = {};
    CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    CFRelease(s);
    return buf;
}

inline SInt32 intProp(MIDIObjectRef obj, CFStringRef key)
{
    SInt32 v = 0;
    MIDIObjectGetIntegerProperty(obj, key, &v);
    return v;
}

// sources=true なら入力元、false なら出力先を列挙する
inline std::vector<Device> enumerate(bool sources)
{
    std::vector<Device> devs;
    const ItemCount n = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations();
    for (ItemCount i = 0; i < n; i++) {
        MIDIEndpointRef ep = sources ? MIDIGetSource(i) : MIDIGetDestination(i);
        if (!ep) continue;
        Device d;
        d.uid = intProp(ep, kMIDIPropertyUniqueID);
        d.online = intProp(ep, kMIDIPropertyOffline) == 0;
        d.name = strProp(ep, kMIDIPropertyDisplayName);
        if (d.name.empty()) d.name = strProp(ep, kMIDIPropertyName);
        d.manufacturer = strProp(ep, kMIDIPropertyManufacturer);
        d.model = strProp(ep, kMIDIPropertyModel);
        devs.push_back(d);
    }
    return devs;
}

// **TD が持っていない API**。表示名ではなく UniqueID で実体を引き直すので、
// 抜き差ししても同じ機材に繋ぎ直せる
inline MIDIEndpointRef findByUID(SInt32 uid, bool sources)
{
    if (!uid) return 0;
    MIDIObjectRef obj = 0;
    MIDIObjectType type = kMIDIObjectType_Other;
    if (MIDIObjectFindByUniqueID(uid, &obj, &type) != noErr) return 0;
    const bool ok = sources
        ? (type == kMIDIObjectType_Source || type == kMIDIObjectType_ExternalSource)
        : (type == kMIDIObjectType_Destination || type == kMIDIObjectType_ExternalDestination);
    return ok ? (MIDIEndpointRef)obj : 0;
}

} // namespace tdmidi
