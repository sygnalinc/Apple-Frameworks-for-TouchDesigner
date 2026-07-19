import AVFAudio
import Foundation
import Speech

@available(macOS 26.0, *)
final class VoiceActivitySession: @unchecked Sendable {
    private let lock = NSLock()
    private var status = "starting"
    private var speaking = false
    private var onsets: UInt64 = 0
    private var offsets: UInt64 = 0
    private var start = 0.0
    private var end = 0.0
    private var duration = 0.0
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var srcFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var task: Task<Void, Never>?

    init(sensitivity: Int) { task = Task { [weak self] in await self?.run(sensitivity) } }
    deinit { task?.cancel(); lock.lock(); continuation?.finish(); lock.unlock() }

    private func setStatus(_ value: String) { lock.lock(); status = value; lock.unlock() }
    private func run(_ sensitivity: Int) async {
        do {
            let level: SpeechDetector.SensitivityLevel = sensitivity <= 0 ? .low : (sensitivity >= 2 ? .high : .medium)
            let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: level), reportResults: true)
            let analyzer = SpeechAnalyzer(modules: [detector])
            analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [detector])
            let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
            lock.lock(); continuation = cont; lock.unlock()
            let reader = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await result in detector.results {
                        let s = CMTimeGetSeconds(result.range.start)
                        let d = CMTimeGetSeconds(result.range.duration)
                        self.lock.lock()
                        if result.speechDetected && !self.speaking { self.onsets += 1 }
                        if !result.speechDetected && self.speaking { self.offsets += 1 }
                        self.speaking = result.speechDetected
                        self.start = s.isFinite ? s : 0
                        self.duration = d.isFinite ? d : 0
                        self.end = self.start + self.duration
                        self.lock.unlock()
                    }
                } catch { self.setStatus("result error: \(error.localizedDescription)") }
            }
            setStatus("listening")
            try await analyzer.start(inputSequence: stream)
            _ = reader
        } catch { setStatus("error: \(error.localizedDescription)") }
    }

    func feed(_ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        guard count > 0, let analyzerFormat else { return }
        if srcFormat == nil || srcFormat!.sampleRate != rate {
            srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = srcFormat.flatMap { AVAudioConverter(from: $0, to: analyzerFormat) }
        }
        guard let srcFormat, let converter,
              let input = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        memcpy(input.floatChannelData![0], samples, count * MemoryLayout<Float>.size)
        input.frameLength = AVAudioFrameCount(count)
        let cap = AVAudioFrameCount(Double(count) * analyzerFormat.sampleRate / rate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: cap) else { return }
        var supplied = false
        var err: NSError?
        converter.convert(to: output, error: &err) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard output.frameLength > 0 else { return }
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(AnalyzerInput(buffer: output))
    }

    func poll() -> String {
        lock.lock()
        let value: [String: Any] = ["status": status, "speaking": speaking, "onsets": onsets,
                                    "offsets": offsets, "start": start, "end": end, "duration": duration]
        lock.unlock()
        let data = try? JSONSerialization.data(withJSONObject: value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"status\":\"json error\"}"
    }
}

@_cdecl("va_create") public func va_create(_ sensitivity: Int32) -> UnsafeMutableRawPointer? {
    guard #available(macOS 26.0, *) else { return nil }
    return Unmanaged.passRetained(VoiceActivitySession(sensitivity: Int(sensitivity))).toOpaque()
}
@_cdecl("va_feed") public func va_feed(_ h: UnsafeMutableRawPointer?, _ p: UnsafePointer<Float>?, _ n: Int32, _ rate: Double) {
    guard #available(macOS 26.0, *), let h, let p else { return }
    Unmanaged<VoiceActivitySession>.fromOpaque(h).takeUnretainedValue().feed(p, count: Int(n), rate: rate)
}
@_cdecl("va_poll") public func va_poll(_ h: UnsafeMutableRawPointer?, _ b: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    guard let b, cap > 0 else { return 0 }
    var json = "{\"status\":\"requires macOS 26\"}"
    if #available(macOS 26.0, *), let h { json = Unmanaged<VoiceActivitySession>.fromOpaque(h).takeUnretainedValue().poll() }
    let bytes = Array(json.utf8.prefix(Int(cap)-1)); memcpy(b, bytes, bytes.count); b[bytes.count] = 0; return Int32(bytes.count)
}
@_cdecl("va_destroy") public func va_destroy(_ h: UnsafeMutableRawPointer?) {
    guard #available(macOS 26.0, *), let h else { return }
    Unmanaged<VoiceActivitySession>.fromOpaque(h).release()
}
