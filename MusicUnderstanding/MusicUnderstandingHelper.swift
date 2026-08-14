// MusicUnderstandingHelper — Apple MusicUnderstanding framework(macOS 27+)の Cヘルパ。
//
// 音楽ファイルをオンデバイス解析して、TDの演出制御に直結する構造データを返す:
//   rhythm    … ビート/小節の時刻列 + BPM
//   key       … 調(トニック+メジャー/マイナー)の時間区間
//   structure … 楽曲構造(セクション/セグメント/フレーズ)の時間区間
//   pace      … ペース(時間区間+値)
//   loudness  … ラウドネス(integrated/momentary/shortTerm/peak)
//   instruments … 楽器アクティビティ(vocal/drum/bass/other の区間+レベル曲線)
// 解析は actor MusicUnderstandingSession(async)。結果は JSON(strdup)で返し、呼び側が free。
// 26以前では status に理由を返す(クラッシュしない)。
import Foundation
import AVFoundation
import CoreMedia
import MusicUnderstanding

final class MUState: @unchecked Sendable {
    let lock = NSLock()
    var status = "ready"
    var busy = false
    var resultJSON = "{}"
    var serial: UInt64 = 0
    var analyzes: UInt64 = 0
}

private func sec(_ t: CMTime) -> Double {
    let s = CMTimeGetSeconds(t)
    return s.isFinite ? (s * 1000).rounded() / 1000 : 0
}

@available(macOS 27.0, *)
private func rangeDict(_ r: CMTimeRange) -> [String: Double] {
    ["start": sec(r.start), "end": sec(CMTimeAdd(r.start, r.duration))]
}

@_cdecl("mu_create")
public func mu_create() -> UnsafeMutableRawPointer? {
    let s = MUState()
    if #available(macOS 27.0, *) {} else { s.status = "requires macOS 27+" }
    return Unmanaged.passRetained(s).toOpaque()
}

@_cdecl("mu_destroy")
public func mu_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h else { return }
    Unmanaged<MUState>.fromOpaque(h).release()
}

// flags: bit0=rhythm bit1=key bit2=structure bit3=pace bit4=loudness bit5=instruments
@_cdecl("mu_analyze")
public func mu_analyze(_ h: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?,
                       _ flags: Int32) -> Bool
{
    guard let h, let path else { return false }
    let s = Unmanaged<MUState>.fromOpaque(h).takeUnretainedValue()
    guard #available(macOS 27.0, *) else { return false }
    let file = String(cString: path)
    if file.isEmpty { return false }
    s.lock.lock()
    if s.busy { s.lock.unlock(); return false }
    s.busy = true
    s.status = "analyzing"
    s.analyzes += 1
    s.lock.unlock()

    var types = Set<AnalysisType>()
    if flags & 1 != 0 { types.insert(.rhythm) }
    if flags & 2 != 0 { types.insert(.key) }
    if flags & 4 != 0 { types.insert(.structure) }
    if flags & 8 != 0 { types.insert(.pace) }
    if flags & 16 != 0 { types.insert(.loudness) }
    if flags & 32 != 0 { types.insert(.instrumentActivity) }

    Task.detached(priority: .userInitiated) {
        do {
            let asset = AVURLAsset(url: URL(fileURLWithPath: file))
            let session = try await MusicUnderstandingSession(asset: asset)
            let r = try await session.analyze(for: types)

            var dict: [String: Any] = [:]
            if let rhythm = r.rhythm {
                var d: [String: Any] = [
                    "beats": rhythm.beats.map(sec),
                    "bars": rhythm.bars.map(sec),
                ]
                if let bpm = rhythm.beatsPerMinute { d["bpm"] = Double(bpm) }
                dict["rhythm"] = d
            }
            if let key = r.key {
                dict["key"] = key.ranges.map { rv -> [String: Any] in
                    var d: [String: Any] = rangeDict(rv.range)
                    d["tonic"] = rv.value.tonic.rawValue
                    d["mode"] = rv.value.mode.rawValue
                    return d
                }
            }
            if let st = r.structure {
                dict["structure"] = [
                    "sections": st.sections.map(rangeDict),
                    "segments": st.segments.map(rangeDict),
                    "phrases": st.phrases.map(rangeDict),
                ]
            }
            if let pace = r.pace {
                dict["pace"] = pace.ranges.map { rv -> [String: Any] in
                    var d: [String: Any] = rangeDict(rv.range)
                    d["value"] = rv.value
                    return d
                }
            }
            if let loud = r.loudness {
                dict["loudness"] = [
                    "integrated": ["time": sec(loud.integrated.time), "value": Double(loud.integrated.value)],
                    "peak": ["time": sec(loud.peak.time), "value": Double(loud.peak.value)],
                    "momentary": loud.momentary.map { ["time": sec($0.time), "value": Double($0.value)] },
                    "short_term": loud.shortTerm.map { ["time": sec($0.time), "value": Double($0.value)] },
                ]
            }
            if let inst = r.instrumentActivity {
                func name(_ i: InstrumentActivityResult.Instrument) -> String {
                    switch i {
                    case .vocal: return "vocal"
                    case .drum: return "drum"
                    case .bass: return "bass"
                    case .other: return "other"
                    default: return "unknown"
                    }
                }
                var ranges: [String: [[String: Double]]] = [:]
                for (k, v) in inst.ranges { ranges[name(k)] = v.map(rangeDict) }
                var activity: [String: [[String: Double]]] = [:]
                for (k, v) in inst.activity {
                    activity[name(k)] = v.map { ["time": sec($0.time), "value": Double($0.value)] }
                }
                dict["instruments"] = ["ranges": ranges, "activity": activity]
            }

            let json: String
            if let d = try? JSONSerialization.data(withJSONObject: dict),
               let str = String(data: d, encoding: .utf8) { json = str } else { json = "{}" }
            s.lock.lock()
            s.resultJSON = json
            s.serial += 1
            s.busy = false
            s.status = "done"
            s.lock.unlock()
        } catch {
            s.lock.lock()
            s.busy = false
            s.status = "error: \(error)"
            s.lock.unlock()
        }
    }
    return true
}

@_cdecl("mu_status_json")
public func mu_status_json(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h else { return nil }
    let s = Unmanaged<MUState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    let json = "{\"status\":\"\(s.status.replacingOccurrences(of: "\"", with: "'"))\",\"busy\":\(s.busy),\"serial\":\(s.serial),\"analyzes\":\(s.analyzes)}"
    s.lock.unlock()
    return UnsafePointer(strdup(json))
}

// 解析結果のフルJSON(呼び側が free)
@_cdecl("mu_result_json")
public func mu_result_json(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h else { return nil }
    let s = Unmanaged<MUState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    let json = s.resultJSON
    s.lock.unlock()
    return UnsafePointer(strdup(json))
}
