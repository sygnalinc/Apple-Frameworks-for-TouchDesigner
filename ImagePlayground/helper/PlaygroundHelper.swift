// Image Playground TOP の Swift ヘルパ（libPlaygroundHelper.dylib）。
//
// Apple の ImagePlayground フレームワーク（ImageCreator・macOS 15.4+）でテキスト+スタイルから
// 画像を生成し、C ABI（pg_*）で ObjC++ プラグインへ提供する。**外部モデル不要**（端末の
// Apple Intelligence が生成する。人物はテキストのみからは生成できない仕様）。
//
// C API:
//   pg_create()                  セッション生成（非同期で ImageCreator を用意）
//   pg_generate(h, prompt, style) 生成を非同期実行（busy 中は false）
//   pg_poll(h, buf, cap)         状態 JSON {status, busy, loaded, imageSerial, width, height, genSeconds}
//   pg_copy_image(h, buf, cap)   最新画像の RGBA8 バイト列をコピー（top-down）
//   pg_destroy(h)

import Foundation
import CoreGraphics
import ImagePlayground

// CGImage → RGBA8（top-down・premultipliedLast）
func igCGImageToRGBA(_ cg: CGImage) -> ([UInt8], Int, Int)? {
    let w = cg.width
    let h = cg.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (bytes, w, h) : nil
}

@available(macOS 15.4, *)
final class PGSession: @unchecked Sendable {
    private let lock = NSLock()
    private var creator: ImageCreator?
    private var status = "loading model"
    private var busy = true
    private var genSeconds = 0.0
    private var image: [UInt8] = []
    private var imageW = 0
    private var imageH = 0
    private var imageSerial = 0

    init() {
        Task { [weak self] in await self?.setup() }
    }

    private func setStatus(_ s: String, busy b: Bool) {
        lock.lock()
        status = s
        busy = b
        lock.unlock()
    }

    private func setup() async {
        do {
            let c = try await ImageCreator()
            lock.lock()
            creator = c
            lock.unlock()
            setStatus("ready (Image Playground)", busy: false)
        } catch {
            setStatus("unavailable: \(error.localizedDescription)", busy: false)
        }
    }

    func generate(prompt: String, style styleName: String) -> Bool {
        lock.lock()
        if busy || creator == nil {
            lock.unlock()
            return false
        }
        busy = true
        status = "generating"
        lock.unlock()
        Task { [weak self] in await self?.run(prompt: prompt, styleName: styleName) }
        return true
    }

    private func run(prompt: String, styleName: String) async {
        let start = Date()
        lock.lock()
        let creatorRef = creator
        lock.unlock()
        guard let creatorRef else { return }
        let style: ImagePlaygroundStyle
        switch styleName {
        case "illustration": style = .illustration
        case "sketch": style = .sketch
        default: style = .animation
        }
        do {
            let concepts = [ImagePlaygroundConcept.text(prompt)]
            var got = false
            for try await created in creatorRef.images(for: concepts, style: style, limit: 1) {
                if let converted = igCGImageToRGBA(created.cgImage) {
                    lock.lock()
                    image = converted.0
                    imageW = converted.1
                    imageH = converted.2
                    imageSerial += 1
                    genSeconds = Date().timeIntervalSince(start)
                    status = String(format: "done (%.1fs)", genSeconds)
                    busy = false
                    lock.unlock()
                    got = true
                }
                break
            }
            if !got {
                setStatus("generate failed (no image)", busy: false)
            }
        } catch {
            setStatus("generate error: \(error.localizedDescription)", busy: false)
        }
    }

    func pollJSON() -> String {
        lock.lock()
        let dict: [String: Any] = [
            "status": status,
            "busy": busy,
            "loaded": creator != nil,
            "step": 0,
            "steps": 0,
            "imageSerial": imageSerial,
            "width": imageW,
            "height": imageH,
            "genSeconds": genSeconds,
        ]
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"json error\"}"
        }
        return json
    }

    func copyImage(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = min(image.count, capacity)
        if n > 0 {
            image.withUnsafeBufferPointer { src in
                memcpy(buffer, src.baseAddress!, n)
            }
        }
        return n
    }
}

@_cdecl("pg_create")
public func pg_create() -> UnsafeMutableRawPointer? {
    guard #available(macOS 15.4, *) else { return nil }
    return Unmanaged.passRetained(PGSession()).toOpaque()
}

@_cdecl("pg_generate")
public func pg_generate(_ handle: UnsafeMutableRawPointer?,
                        _ prompt: UnsafePointer<CChar>?,
                        _ style: UnsafePointer<CChar>?) -> Bool {
    guard #available(macOS 15.4, *), let handle else { return false }
    let session = Unmanaged<PGSession>.fromOpaque(handle).takeUnretainedValue()
    return session.generate(
        prompt: prompt.map { String(cString: $0) } ?? "",
        style: style.map { String(cString: $0) } ?? "animation")
}

@_cdecl("pg_poll")
public func pg_poll(_ handle: UnsafeMutableRawPointer?,
                    _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return 0 }
    var json = "{\"status\":\"requires macOS 15.4\"}"
    if #available(macOS 15.4, *), let handle {
        json = Unmanaged<PGSession>.fromOpaque(handle).takeUnretainedValue().pollJSON()
    }
    let utf8 = Array(json.utf8.prefix(Int(capacity) - 1))
    memcpy(buffer, utf8, utf8.count)
    buffer[utf8.count] = 0
    return Int32(utf8.count)
}

@_cdecl("pg_copy_image")
public func pg_copy_image(_ handle: UnsafeMutableRawPointer?,
                          _ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int64) -> Int64 {
    guard #available(macOS 15.4, *), let handle, let buffer else { return 0 }
    let session = Unmanaged<PGSession>.fromOpaque(handle).takeUnretainedValue()
    return Int64(session.copyImage(into: buffer, capacity: Int(capacity)))
}

@_cdecl("pg_destroy")
public func pg_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard #available(macOS 15.4, *), let handle else { return }
    Unmanaged<PGSession>.fromOpaque(handle).release()
}
