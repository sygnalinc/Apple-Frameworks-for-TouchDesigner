// SpeechText DAT の Swift ヘルパ（libSpeechHelper.dylib）。
//
// 新しい SpeechAnalyzer / SpeechTranscriber（macOS 26+・Swift 専用API）による
// 高度なオンデバイス文字起こしを、C ABI（sp_*）で ObjC++ プラグインへ提供する。
// 旧 SFSpeechRecognizer と違い音声認識の TCC 許可が不要で、音声は端末外へ出ない
// （初回のみ言語モデルのダウンロードが走る）。
//
// C API:
//   sp_create(locale)   セッション生成（例 "ja-JP"）。非同期でモデル準備→解析開始
//   sp_feed(h, f, n, r) モノラル float32 サンプルを流し込む（任意レート・内部で変換）
//   sp_poll(h, buf, n)  状態と全文を JSON で取得 {status, volatile, finalized:[...]}
//   sp_clear(h)         確定済みテキストをクリア
//   sp_destroy(h)       破棄

import AVFAudio
import Foundation
import Speech

// ------------------------------------------------------------------ session

@available(macOS 26.0, *)
final class SpeechSession: @unchecked Sendable {
    private let lock = NSLock()
    private var status = "starting"
    private var finalized: [String] = []
    private var volatileText = ""
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var srcFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var runTask: Task<Void, Never>?

    init(locale: String) {
        runTask = Task { [weak self] in await self?.run(localeId: locale) }
    }

    deinit {
        runTask?.cancel()
        lock.lock()
        continuation?.finish()
        lock.unlock()
    }

    private func setStatus(_ s: String) {
        lock.lock()
        status = s
        lock.unlock()
    }

    private func run(localeId: String) async {
        do {
            let locale = Locale(identifier: localeId)
            let supported = await SpeechTranscriber.supportedLocales
            guard supported.contains(where: {
                $0.identifier(.bcp47) == locale.identifier(.bcp47)
            }) else {
                setStatus("unsupported locale: \(localeId)")
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [])

            // 言語モデルの用意（初回はダウンロードが走る）
            if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]) {
                setStatus("downloading model")
                try await request.downloadAndInstall()
            }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber])
            let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
            lock.lock()
            continuation = cont
            lock.unlock()

            // 結果の読み取り
            let readTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        self.lock.lock()
                        if result.isFinal {
                            if !text.isEmpty {
                                self.finalized.append(text)
                            }
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        self.lock.unlock()
                    }
                } catch {
                    self.setStatus("result error: \(error.localizedDescription)")
                }
            }

            setStatus("listening")
            try await analyzer.start(inputSequence: stream)
            _ = readTask
        } catch {
            setStatus("error: \(error.localizedDescription)")
        }
    }

    func feed(_ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        guard count > 0, let analyzerFormat else { return }

        if srcFormat == nil || srcFormat!.sampleRate != rate {
            srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                      channels: 1, interleaved: false)
            converter = srcFormat.flatMap { AVAudioConverter(from: $0, to: analyzerFormat) }
        }
        guard let srcFormat, let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                           frameCapacity: AVAudioFrameCount(count)) else {
            return
        }
        memcpy(inBuf.floatChannelData![0], samples, count * MemoryLayout<Float>.size)
        inBuf.frameLength = AVAudioFrameCount(count)

        let outCapacity = AVAudioFrameCount(
            Double(count) * analyzerFormat.sampleRate / rate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: analyzerFormat,
                                            frameCapacity: outCapacity) else { return }
        var provided = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard outBuf.frameLength > 0 else { return }

        lock.lock()
        let cont = continuation
        lock.unlock()
        cont?.yield(AnalyzerInput(buffer: outBuf))
    }

    func clear() {
        lock.lock()
        finalized.removeAll()
        volatileText = ""
        lock.unlock()
    }

    func pollJSON() -> String {
        lock.lock()
        let dict: [String: Any] = [
            "status": status,
            "volatile": volatileText,
            "finalized": finalized,
        ]
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"json error\"}"
        }
        return json
    }
}

// ------------------------------------------------------------------ C ABI

@_cdecl("sp_create")
public func sp_create(_ locale: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    guard #available(macOS 26.0, *) else { return nil }
    let session = SpeechSession(locale: String(cString: locale))
    return Unmanaged.passRetained(session).toOpaque()
}

@_cdecl("sp_feed")
public func sp_feed(_ handle: UnsafeMutableRawPointer?, _ samples: UnsafePointer<Float>?,
                    _ count: Int32, _ rate: Double) {
    guard #available(macOS 26.0, *), let handle, let samples else { return }
    let session = Unmanaged<SpeechSession>.fromOpaque(handle).takeUnretainedValue()
    session.feed(samples, count: Int(count), rate: rate)
}

@_cdecl("sp_poll")
public func sp_poll(_ handle: UnsafeMutableRawPointer?,
                    _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return 0 }
    var json = "{\"status\":\"requires macOS 26\"}"
    if #available(macOS 26.0, *), let handle {
        let session = Unmanaged<SpeechSession>.fromOpaque(handle).takeUnretainedValue()
        json = session.pollJSON()
    }
    let utf8 = Array(json.utf8.prefix(Int(capacity) - 1))
    memcpy(buffer, utf8, utf8.count)
    buffer[utf8.count] = 0
    return Int32(utf8.count)
}

@_cdecl("sp_clear")
public func sp_clear(_ handle: UnsafeMutableRawPointer?) {
    guard #available(macOS 26.0, *), let handle else { return }
    Unmanaged<SpeechSession>.fromOpaque(handle).takeUnretainedValue().clear()
}

@_cdecl("sp_destroy")
public func sp_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard #available(macOS 26.0, *), let handle else { return }
    Unmanaged<SpeechSession>.fromOpaque(handle).release()
}

// 対応ロケール一覧を "bcp47\t英語名\t0|1(端末にインストール済みか)" の改行区切りで返す。
// TD 側の Locale プルダウンを組むために使う。**OSのバージョンで中身が変わる**ので
// ハードコードせず実行時に取る（macOS 26.6 実測で 30 件・うち10件がインストール済み）。
//
// 呼び出しは cook スレッドなので、初回だけ待って以後はキャッシュを返す。
// supportedLocales は静的な一覧なので実測では即返る。
private var localeCache: String? = nil
private let localeCacheLock = NSLock()

@_cdecl("sp_locales")
public func sp_locales() -> UnsafePointer<CChar>? {
    localeCacheLock.lock()
    defer { localeCacheLock.unlock() }
    if localeCache == nil {
        var text = ""
        if #available(macOS 26.0, *) {
            let sem = DispatchSemaphore(value: 0)
            Task {
                let supported = await SpeechTranscriber.supportedLocales
                let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
                let en = Locale(identifier: "en_US")
                for l in supported.sorted(by: { $0.identifier(.bcp47) < $1.identifier(.bcp47) }) {
                    let id = l.identifier(.bcp47)
                    // TD のUIラベルは非ASCIIが化けるので英語名から ASCII 以外を落とす
                    let name = (en.localizedString(forIdentifier: l.identifier) ?? id)
                        .unicodeScalars.filter { $0.isASCII }.map(String.init).joined()
                    text += "\(id)\t\(name)\t\(installed.contains(id) ? 1 : 0)\n"
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 5)
        }
        localeCache = text
    }
    return UnsafePointer(strdup(localeCache!))   // TD側は使い捨てで読むだけ
}
