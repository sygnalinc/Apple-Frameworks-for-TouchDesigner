// WhisperHelper.swift — WhisperKit(Core ML版Whisper)を C ABI(wk_)で包むヘルパ dylib。
//
// SpeechText DAT の Whisper バックエンド(macOS 14+)。Apple の SpeechAnalyzer
// (macOS 26+)が使えない環境や、多言語・英訳(translate)用。
//
//   wk_create(model, task, lang)  セッション生成。model: tiny/base/small/large-v3 等。
//                                 task: "transcribe" / "translate"。lang: "ja" 等(空=自動)
//   wk_feed(h, samples, n, rate)  モノラル float32 を流し込む(内部で16kに変換)
//   wk_poll(h, buf, n)            状態JSON {status, volatile, finalized:[...]}(sp_ と同形)
//   wk_clear(h)                   文字起こしをリセット
//   wk_destroy(h)
//
// 初回はモデルを Hugging Face から自動ダウンロードする(base 約150MB。status に出す)。
// Whisper はストリーミング非対応のため、溜めたバッファを定期的に再認識して volatile を
// 更新し、無音区切り(または30秒上限)で確定行に落とす方式。

import AVFAudio
import Foundation
import WhisperKit

final class WhisperSession: @unchecked Sendable {
    private let lock = NSLock()
    private var whisper: WhisperKit?
    private var status = "loading model..."
    private var pending: [Float] = []          // 16k mono の未確定バッファ
    private var volatileText = ""
    private var finalized: [String] = []
    private var busy = false
    private var lastLen = 0                    // 前回認識時の pending 長
    private var quit = false
    private var converter: AVAudioConverter?
    private var srcFormat: AVAudioFormat?
    private let task: String
    private let lang: String
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000, channels: 1,
                                          interleaved: false)!

    init(model: String, task: String, lang: String) {
        self.task = task
        self.lang = lang
        Task { [weak self] in
            do {
                let pipe = try await WhisperKit(model: model)
                self?.lock.lock()
                self?.whisper = pipe
                self?.status = "ready"
                self?.lock.unlock()
                self?.startLoop()
            } catch {
                self?.lock.lock()
                self?.status = "error: \(error.localizedDescription)"
                self?.lock.unlock()
            }
        }
    }

    // ------------------------------------------------- audio in
    func feed(_ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        if srcFormat?.sampleRate != rate {
            srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                      channels: 1, interleaved: false)
            converter = srcFormat.flatMap { AVAudioConverter(from: $0, to: outFormat) }
        }
        guard let srcFormat, let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                           frameCapacity: AVAudioFrameCount(count))
        else { return }
        inBuf.frameLength = AVAudioFrameCount(count)
        memcpy(inBuf.floatChannelData![0], samples, count * MemoryLayout<Float>.size)

        let outCap = AVAudioFrameCount(Double(count) * 16000.0 / rate + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap)
        else { return }
        var fed = false
        converter.convert(to: outBuf, error: nil) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        guard outBuf.frameLength > 0 else { return }
        let p = outBuf.floatChannelData![0]
        lock.lock()
        pending.append(contentsOf: UnsafeBufferPointer(start: p,
                                                       count: Int(outBuf.frameLength)))
        // 暴走防止(60秒でハード上限)
        if pending.count > 16000 * 60 {
            pending.removeFirst(pending.count - 16000 * 60)
        }
        lock.unlock()
    }

    // ------------------------------------------------- transcribe loop
    private func startLoop() {
        Task { [weak self] in
            while true {
                guard let self else { return }
                self.lock.lock()
                let stop = self.quit
                self.lock.unlock()
                if stop { return }
                await self.step()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private func step() async {
        lock.lock()
        guard let whisper, !busy else {
            lock.unlock()
            return
        }
        // バッファ全体がほぼ無音なら捨てる(Whisperは無音に "[音楽]" 等を幻覚する)
        if volatileText.isEmpty, pending.count > 16000 {
            var sum: Float = 0
            for s in pending { sum += s * s }
            if (sum / Float(pending.count)).squareRoot() < 0.004 {
                pending.removeAll(keepingCapacity: true)
                lastLen = 0
                lock.unlock()
                return
            }
        }
        // 新しい音声が0.7秒以上増えたときだけ再認識
        guard pending.count > 16000, pending.count - lastLen > 11200 else {
            // 増えていなくても、無音が続いていれば確定に落とす
            maybeFinalizeLocked(force: false)
            lock.unlock()
            return
        }
        busy = true
        status = "transcribing"
        lastLen = pending.count
        let audio = pending
        lock.unlock()

        var opts = DecodingOptions()
        opts.task = (task == "translate") ? .translate : .transcribe
        if !lang.isEmpty {
            opts.language = lang
            opts.detectLanguage = false
        }
        var text = ""
        do {
            let results = try await whisper.transcribe(audioArray: audio,
                                                       decodeOptions: opts)
            text = results.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            lock.lock()
            status = "error: \(error.localizedDescription)"
            busy = false
            lock.unlock()
            return
        }

        lock.lock()
        volatileText = text
        status = "ready"
        busy = false
        maybeFinalizeLocked(force: pending.count >= 16000 * 30)
        lock.unlock()
    }

    // 無音(末尾0.8秒のRMSが小さい)か30秒上限で volatile を確定行へ(lock保持で呼ぶ)
    private func maybeFinalizeLocked(force: Bool) {
        guard !volatileText.isEmpty, pending.count > 16000 * 2 else { return }
        var silent = false
        let tail = 12800   // 0.8s
        if pending.count > tail {
            var sum: Float = 0
            for s in pending.suffix(tail) { sum += s * s }
            silent = (sum / Float(tail)).squareRoot() < 0.005
        }
        if force || silent {
            // "[音楽]" "(拍手)" のような幻覚タグだけの行は確定に載せない
            let t = volatileText.trimmingCharacters(in: .whitespaces)
            let isTag = (t.hasPrefix("[") && t.hasSuffix("]")) ||
                        (t.hasPrefix("(") && t.hasSuffix(")")) ||
                        (t.hasPrefix("（") && t.hasSuffix("）"))
            if !isTag {
                finalized.append(volatileText)
            }
            volatileText = ""
            pending.removeAll(keepingCapacity: true)
            lastLen = 0
        }
    }

    func clear() {
        lock.lock()
        pending.removeAll()
        finalized.removeAll()
        volatileText = ""
        lastLen = 0
        lock.unlock()
    }

    func shutdown() {
        lock.lock()
        quit = true
        lock.unlock()
    }

    func poll() -> String {
        lock.lock()
        let dict: [String: Any] = [
            "status": status,
            "volatile": volatileText,
            "finalized": finalized,
        ]
        lock.unlock()
        if let d = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: d, encoding: .utf8) { return s }
        return "{}"
    }
}

// ------------------------------------------------------------------ C ABI

@_cdecl("wk_create")
public func wk_create(_ model: UnsafePointer<CChar>?, _ task: UnsafePointer<CChar>?,
                      _ lang: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
{
    let session = WhisperSession(
        model: model.map { String(cString: $0) } ?? "base",
        task: task.map { String(cString: $0) } ?? "transcribe",
        lang: lang.map { String(cString: $0) } ?? "")
    return Unmanaged.passRetained(session).toOpaque()
}

@_cdecl("wk_feed")
public func wk_feed(_ handle: UnsafeMutableRawPointer?, _ samples: UnsafePointer<Float>?,
                    _ count: Int32, _ rate: Double)
{
    guard let handle, let samples, count > 0 else { return }
    Unmanaged<WhisperSession>.fromOpaque(handle).takeUnretainedValue()
        .feed(samples, count: Int(count), rate: rate)
}

@_cdecl("wk_poll")
public func wk_poll(_ handle: UnsafeMutableRawPointer?,
                    _ buf: UnsafeMutablePointer<CChar>?, _ n: Int32) -> Int32
{
    guard let handle, let buf, n > 0 else { return 0 }
    let json = Unmanaged<WhisperSession>.fromOpaque(handle).takeUnretainedValue().poll()
    let utf8 = Array(json.utf8.prefix(Int(n) - 1))
    memcpy(buf, utf8, utf8.count)
    buf[utf8.count] = 0
    return Int32(utf8.count)
}

@_cdecl("wk_clear")
public func wk_clear(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<WhisperSession>.fromOpaque(handle).takeUnretainedValue().clear()
}

@_cdecl("wk_destroy")
public func wk_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    let s = Unmanaged<WhisperSession>.fromOpaque(handle).takeRetainedValue()
    s.shutdown()
}
