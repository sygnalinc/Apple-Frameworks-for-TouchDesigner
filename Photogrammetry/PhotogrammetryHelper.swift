// PhotogrammetryHelper.swift — RealityKit Object Capture を C ABI で包むヘルパ(ph_)
//
//   ph_create()                        ハンドル生成
//   ph_start(h, imgFolder, outPath, detail)  再構成開始(detail 0=preview..3=full)
//   ph_poll(h, buf, n)                 状態JSON {status, progress, done, error}
//   ph_cancel(h)                       中断
//   ph_destroy(h)
//
// 出力形式は outPath の拡張子で決まる(.obj / .usdz)。SOP 表示には .obj を使う。

import Foundation
import ModelIO
import RealityKit

@available(macOS 12.0, *)
final class PhotoSession {
    private var session: PhotogrammetrySession?
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var status = "idle"
    private var progress = 0.0
    private var done = false
    private var errorMsg = ""
    private var convertTo: URL?

    func start(imageFolder: String, outputPath: String, detail: Int) {
        cancel()
        lock.lock()
        status = "starting"; progress = 0; done = false; errorMsg = ""
        lock.unlock()

        let inputURL = URL(fileURLWithPath: imageFolder, isDirectory: true)
        // PhotogrammetrySession の modelFile 出力は USDZ のみ(.obj は invalidOutput・実測)。
        // .obj 指定時は一時 USDZ に出してから ModelIO で変換する
        let finalURL = URL(fileURLWithPath: outputPath)
        let wantsOBJ = finalURL.pathExtension.lowercased() == "obj"
        let outputURL = wantsOBJ
            ? finalURL.deletingPathExtension().appendingPathExtension("usdz")
            : finalURL
        self.convertTo = wantsOBJ ? finalURL : nil
        let detailLevel: PhotogrammetrySession.Request.Detail =
            detail == 0 ? .preview : detail == 1 ? .reduced : detail == 3 ? .full : .medium

        do {
            var config = PhotogrammetrySession.Configuration()
            config.featureSensitivity = .normal
            let s = try PhotogrammetrySession(input: inputURL, configuration: config)
            session = s
            task = Task { [weak self] in
                do {
                    for try await output in s.outputs {
                        guard let self else { return }
                        switch output {
                        case .requestProgress(_, let fraction):
                            self.lock.lock()
                            self.progress = fraction
                            self.status = "processing"
                            self.lock.unlock()
                        case .requestComplete(_, let result):
                            var convertError = ""
                            if case .modelFile(let usdzURL) = result,
                               let objURL = self.convertTo {
                                do {
                                    let asset = MDLAsset(url: usdzURL)
                                    try asset.export(to: objURL)
                                } catch {
                                    convertError = "OBJ convert failed: \(error)"
                                }
                            }
                            self.lock.lock()
                            self.progress = 1.0
                            self.done = convertError.isEmpty
                            self.status = convertError.isEmpty ? "complete" : "error"
                            self.errorMsg = convertError
                            self.lock.unlock()
                        case .requestError(_, let error):
                            self.lock.lock()
                            self.errorMsg = "\(error)"
                            self.status = "error"
                            self.lock.unlock()
                        case .processingComplete:
                            break
                        case .inputComplete:
                            self.lock.lock()
                            self.status = "processing"
                            self.lock.unlock()
                        case .invalidSample(let id, let reason):
                            NSLog("Photogrammetry: invalid sample %d: %@", id, reason)
                        case .skippedSample(let id):
                            NSLog("Photogrammetry: skipped sample %d", id)
                        case .automaticDownsampling:
                            break
                        case .processingCancelled:
                            self.lock.lock()
                            self.status = "cancelled"
                            self.lock.unlock()
                        @unknown default:
                            break
                        }
                    }
                } catch {
                    self?.lock.lock()
                    self?.errorMsg = "\(error)"
                    self?.status = "error"
                    self?.lock.unlock()
                }
            }
            try s.process(requests: [.modelFile(url: outputURL, detail: detailLevel)])
            lock.lock(); status = "processing"; lock.unlock()
        } catch {
            lock.lock()
            errorMsg = "\(error)"
            status = "error"
            lock.unlock()
        }
    }

    func cancel() {
        session?.cancel()
        task?.cancel()
        session = nil
        task = nil
    }

    func poll() -> String {
        lock.lock(); defer { lock.unlock() }
        let dict: [String: Any] = ["status": status, "progress": progress,
                                   "done": done, "error": errorMsg]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }
}

// ------------------------------------------------------------------ C ABI

@_cdecl("ph_create")
public func ph_create() -> UnsafeMutableRawPointer? {
    if #available(macOS 12.0, *) {
        return Unmanaged.passRetained(PhotoSession()).toOpaque()
    }
    return nil
}

@_cdecl("ph_start")
public func ph_start(_ handle: UnsafeMutableRawPointer?, _ folder: UnsafePointer<CChar>?,
                     _ output: UnsafePointer<CChar>?, _ detail: Int32) {
    guard let handle, let folder, let output else { return }
    if #available(macOS 12.0, *) {
        let s = Unmanaged<PhotoSession>.fromOpaque(handle).takeUnretainedValue()
        s.start(imageFolder: String(cString: folder),
                outputPath: String(cString: output), detail: Int(detail))
    }
}

@_cdecl("ph_poll")
public func ph_poll(_ handle: UnsafeMutableRawPointer?,
                    _ buf: UnsafeMutablePointer<CChar>?, _ n: Int32) {
    guard let handle, let buf, n > 0 else { return }
    if #available(macOS 12.0, *) {
        let s = Unmanaged<PhotoSession>.fromOpaque(handle).takeUnretainedValue()
        _ = s.poll().withCString { strlcpy(buf, $0, Int(n)) }
    } else {
        _ = "{\"status\":\"requires macOS 12+\"}".withCString { strlcpy(buf, $0, Int(n)) }
    }
}

@_cdecl("ph_cancel")
public func ph_cancel(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    if #available(macOS 12.0, *) {
        Unmanaged<PhotoSession>.fromOpaque(handle).takeUnretainedValue().cancel()
    }
}

@_cdecl("ph_destroy")
public func ph_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    if #available(macOS 12.0, *) {
        let s = Unmanaged<PhotoSession>.fromOpaque(handle).takeRetainedValue()
        s.cancel()
    }
}
