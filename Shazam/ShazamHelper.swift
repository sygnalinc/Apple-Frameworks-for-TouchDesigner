// ShazamHelper.swift — ShazamKit を C ABI で包むヘルパ dylib(sh_ プレフィックス)
//
//   sh_create()                     セッション生成
//   sh_build_catalog(h, folder)     フォルダ内の音声ファイルからカスタムカタログを
//                                   非同期構築(wav/mp3/m4a/aif)。曲名=ファイル名
//   sh_feed(h, samples, n, rate)    モノラル float32 を流し込む(内部で44.1kに変換)
//   sh_poll(h, buf, n)              状態JSON {status, matched, title, offset, skew}
//   sh_reset(h)                     マッチ状態をクリア
//   sh_destroy(h)
//
// カスタムカタログ照合は完全オンデバイス(ネットワーク不要)。

import Foundation
import AVFAudio
import ShazamKit

@available(macOS 12.0, *)
final class ShazamSession: NSObject, SHSessionDelegate {
    private var session: SHSession?
    private var converter: AVAudioConverter?
    private var srcFormat: AVAudioFormat?
    private let matchFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 44100, channels: 1,
                                            interleaved: false)!
    private let lock = NSLock()
    private var status = "no catalog"
    private var matched = false
    private var title = ""
    private var offset = 0.0
    private var skew = 0.0
    private var refCount = 0

    // ------------------------------------------------- catalog
    func buildCatalog(folder: String) {
        lock.lock(); status = "building catalog..."; matched = false; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let catalog = SHCustomCatalog()
            var count = 0
            let exts = ["wav", "mp3", "m4a", "aif", "aiff", "caf"]
            let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for item in items.sorted() {
                let ext = (item as NSString).pathExtension.lowercased()
                guard exts.contains(ext) else { continue }
                let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                do {
                    let sig = try self.signature(for: url)
                    let media = SHMediaItem(properties: [
                        .title: (item as NSString).deletingPathExtension])
                    try catalog.addReferenceSignature(sig, representing: [media])
                    count += 1
                } catch {
                    NSLog("Shazam catalog: skip \(item): \(error)")
                }
            }
            self.lock.lock()
            self.refCount = count
            if count > 0 {
                let s = SHSession(catalog: catalog)
                s.delegate = self
                self.session = s
                self.status = "ready (\(count) tracks)"
            } else {
                self.session = nil
                self.status = "no audio files found in folder"
            }
            self.lock.unlock()
        }
    }

    private func signature(for url: URL) throws -> SHSignature {
        let file = try AVAudioFile(forReading: url)
        let gen = SHSignatureGenerator()
        let inFormat = file.processingFormat
        let conv = AVAudioConverter(from: inFormat, to: matchFormat)!
        let inCap = AVAudioFrameCount(65536)
        while true {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCap)
            else { break }
            try file.read(into: inBuf, frameCount: inCap)
            if inBuf.frameLength == 0 { break }
            let outCap = AVAudioFrameCount(
                Double(inBuf.frameLength) * 44100.0 / inFormat.sampleRate + 1024)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: matchFormat,
                                                frameCapacity: outCap) else { break }
            var fed = false
            conv.convert(to: outBuf, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return inBuf
            }
            if outBuf.frameLength > 0 {
                try gen.append(outBuf, at: nil)
            }
            if file.framePosition >= file.length { break }
        }
        return try gen.signature()
    }

    // ------------------------------------------------- streaming match
    func feed(_ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        guard let session else { return }
        if srcFormat?.sampleRate != rate {
            srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                      channels: 1, interleaved: false)
            converter = srcFormat.flatMap { AVAudioConverter(from: $0, to: matchFormat) }
        }
        guard let srcFormat, let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                           frameCapacity: AVAudioFrameCount(count))
        else { return }
        inBuf.frameLength = AVAudioFrameCount(count)
        memcpy(inBuf.floatChannelData![0], samples, count * MemoryLayout<Float>.size)

        let outCap = AVAudioFrameCount(Double(count) * 44100.0 / rate + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: matchFormat, frameCapacity: outCap)
        else { return }
        var fed = false
        converter.convert(to: outBuf, error: nil) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        if outBuf.frameLength > 0 {
            session.matchStreamingBuffer(outBuf, at: nil)
        }
    }

    // ------------------------------------------------- delegate
    func session(_ session: SHSession, didFind match: SHMatch) {
        lock.lock()
        matched = true
        if let item = match.mediaItems.first {
            title = item.title ?? ""
            offset = item.matchOffset
            skew = Double(item.frequencySkew)
        }
        lock.unlock()
    }

    func session(_ session: SHSession,
                 didNotFindMatchFor signature: SHSignature, error: Error?) {
        lock.lock(); matched = false; lock.unlock()
    }

    func reset() {
        lock.lock(); matched = false; title = ""; offset = 0; lock.unlock()
    }

    func poll() -> String {
        lock.lock(); defer { lock.unlock() }
        let dict: [String: Any] = [
            "status": status, "matched": matched, "title": title,
            "offset": offset, "skew": skew, "tracks": refCount,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }
}

// ------------------------------------------------------------------ C ABI

@_cdecl("sh_create")
public func sh_create() -> UnsafeMutableRawPointer? {
    if #available(macOS 12.0, *) {
        return Unmanaged.passRetained(ShazamSession()).toOpaque()
    }
    return nil
}

@_cdecl("sh_build_catalog")
public func sh_build_catalog(_ handle: UnsafeMutableRawPointer?,
                             _ folder: UnsafePointer<CChar>?) {
    guard let handle, let folder else { return }
    if #available(macOS 12.0, *) {
        let s = Unmanaged<ShazamSession>.fromOpaque(handle).takeUnretainedValue()
        s.buildCatalog(folder: String(cString: folder))
    }
}

@_cdecl("sh_feed")
public func sh_feed(_ handle: UnsafeMutableRawPointer?, _ samples: UnsafePointer<Float>?,
                    _ count: Int32, _ rate: Double) {
    guard let handle, let samples, count > 0 else { return }
    if #available(macOS 12.0, *) {
        let s = Unmanaged<ShazamSession>.fromOpaque(handle).takeUnretainedValue()
        s.feed(samples, count: Int(count), rate: rate)
    }
}

@_cdecl("sh_poll")
public func sh_poll(_ handle: UnsafeMutableRawPointer?,
                    _ buf: UnsafeMutablePointer<CChar>?, _ n: Int32) {
    guard let handle, let buf, n > 0 else { return }
    if #available(macOS 12.0, *) {
        let s = Unmanaged<ShazamSession>.fromOpaque(handle).takeUnretainedValue()
        let json = s.poll()
        _ = json.withCString { strlcpy(buf, $0, Int(n)) }
    } else {
        _ = "{\"status\":\"requires macOS 12+\"}".withCString { strlcpy(buf, $0, Int(n)) }
    }
}

@_cdecl("sh_reset")
public func sh_reset(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    if #available(macOS 12.0, *) {
        Unmanaged<ShazamSession>.fromOpaque(handle).takeUnretainedValue().reset()
    }
}

@_cdecl("sh_destroy")
public func sh_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    if #available(macOS 12.0, *) {
        Unmanaged<ShazamSession>.fromOpaque(handle).release()
    }
}
