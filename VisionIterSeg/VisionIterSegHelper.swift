// VisionIterSegHelper — Vision GenerateIterativeSegmentationRequest(macOS 27+)の Cヘルパ。
//
// Apple純正の対話的セグメンテーション(SAM相当・外部モデル不要)。プロンプトは3種:
//   point    … 正規化uv座標の1点(Vision既定の lowerLeft 原点 = TDのuvと無変換で一致)
//   box      … 正規化uv矩形
//   scribble … 8bitグレーのなぞり書きマスク(CVReadOnlyPixelBuffer)
// モデル資産はOS管理のダウンロード式(assetStatus / downloadAssets)。
// 生成は Swift async(Task)で走らせ、cook側は poll で最新マスク(Float32・top-down)を取る。
// 26以前では status に理由を返す(クラッシュしない)。
import Foundation
import CoreVideo
import CoreGraphics
import Vision

final class VIState: @unchecked Sendable {
    let lock = NSLock()
    var status = "init"
    var busy = false
    var assetReady = 0        // 0=unknown/no, 1=ready, 2=downloading
    var latest = [Float]()    // マスク(0..1・top-down)
    var latestW = 0, latestH = 0
    var latestSerial: UInt64 = 0
    var serialCtr: UInt64 = 0
    var submits: UInt64 = 0
    var results: UInt64 = 0
}

// BGRA8(top-down)バイト列 → CVPixelBuffer(IOSurface付き)
private func makePixelBufferBGRA(_ bytes: UnsafePointer<UInt8>, _ w: Int, _ h: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let buf = pb else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    let dst = CVPixelBufferGetBaseAddress(buf)!
    let dstStride = CVPixelBufferGetBytesPerRow(buf)
    for y in 0..<h {
        memcpy(dst + y * dstStride, bytes + y * w * 4, w * 4)
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

// 8bitグレー(top-down)バイト列 → CVPixelBuffer(OneComponent8)
private func makePixelBufferGray(_ bytes: UnsafePointer<UInt8>, _ w: Int, _ h: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_OneComponent8, attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let buf = pb else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    let dst = CVPixelBufferGetBaseAddress(buf)!
    let dstStride = CVPixelBufferGetBytesPerRow(buf)
    for y in 0..<h {
        memcpy(dst + y * dstStride, bytes + y * w, w)
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

// 観測結果のマスク(CVPixelBuffer)→ Float32 0..1 へ変換(OneComponent8/Float32両対応)
private func maskToFloats(_ pb: CVPixelBuffer) -> ([Float], Int, Int)? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb), w > 0, h > 0 else { return nil }
    var out = [Float](repeating: 0, count: w * h)
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    out.withUnsafeMutableBufferPointer { dst in
        switch fmt {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { dst[y * w + x] = Float(row[x]) / 255.0 }
            }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
                for x in 0..<w { dst[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w {
                    dst[y * w + x] = Float(Float16(bitPattern: row[x]))
                }
            }
        default:
            // 未知形式: 先頭バイトで近似(実測で必要になったら追加)
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { dst[y * w + x] = Float(row[x]) / 255.0 }
            }
        }
    }
    return (out, w, h)
}

@available(macOS 27.0, *)
private func makeRequest(mode: Int32, px: Double, py: Double,
                         bx: Double, by: Double, bw: Double, bh: Double,
                         scribble: CVPixelBuffer?, quality: Int32)
    -> GenerateIterativeSegmentationRequest?
{
    var req: GenerateIterativeSegmentationRequest
    switch mode {
    case 1:
        req = GenerateIterativeSegmentationRequest(
            seedBox: NormalizedRect(x: bx, y: by, width: bw, height: bh))
    case 2:
        guard let sc = scribble else { return nil }
        req = GenerateIterativeSegmentationRequest(
            seedScribbleBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: sc))
    default:
        req = GenerateIterativeSegmentationRequest(
            seedPoint: NormalizedPoint(x: px, y: py))
    }
    switch quality {
    case 0: req.qualityLevel = .fast
    case 2: req.qualityLevel = .accurate
    default: req.qualityLevel = .balanced
    }
    return req
}

// ---------- C ABI ----------

@_cdecl("vi_create")
public func vi_create() -> UnsafeMutableRawPointer? {
    let s = VIState()
    if #available(macOS 27.0, *) {
        s.status = "ready"
        // 資産状態の初期問い合わせ
        Task {
            let req = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.5))
            let st = await req.assetStatus
            s.lock.lock()
            switch st {
            case .ready: s.assetReady = 1
            case .downloading: s.assetReady = 2; s.status = "downloading assets"
            default:
                s.assetReady = 0
                s.status = "assets not downloaded (pulse Download Assets)"
            }
            s.lock.unlock()
        }
    } else {
        s.status = "requires macOS 27+"
    }
    return Unmanaged.passRetained(s).toOpaque()
}

@_cdecl("vi_destroy")
public func vi_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h else { return }
    Unmanaged<VIState>.fromOpaque(h).release()
}

// モデル資産のダウンロード(OS管理・初回のみ)
@_cdecl("vi_download_assets")
public func vi_download_assets(_ h: UnsafeMutableRawPointer?) {
    guard let h else { return }
    let s = Unmanaged<VIState>.fromOpaque(h).takeUnretainedValue()
    guard #available(macOS 27.0, *) else { return }
    s.lock.lock(); s.assetReady = 2; s.status = "downloading assets"; s.lock.unlock()
    Task {
        do {
            let req = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.5))
            try await req.downloadAssets()
            s.lock.lock(); s.assetReady = 1; s.status = "ready"; s.lock.unlock()
        } catch {
            s.lock.lock(); s.assetReady = 0
            s.status = "asset download error: \(error.localizedDescription)"; s.lock.unlock()
        }
    }
}

// 画像(BGRA8 top-down)+プロンプトで非同期セグメンテーション。busy中は false
@_cdecl("vi_submit")
public func vi_submit(_ h: UnsafeMutableRawPointer?,
                      _ bgra: UnsafePointer<UInt8>?, _ w: Int32, _ hh: Int32,
                      _ mode: Int32, _ px: Double, _ py: Double,
                      _ bx: Double, _ by: Double, _ bw: Double, _ bh: Double,
                      _ scribble: UnsafePointer<UInt8>?, _ sw: Int32, _ sh: Int32,
                      _ quality: Int32) -> Bool
{
    guard let h, let bgra, w > 0, hh > 0 else { return false }
    let s = Unmanaged<VIState>.fromOpaque(h).takeUnretainedValue()
    guard #available(macOS 27.0, *) else { return false }
    s.lock.lock()
    if s.busy { s.lock.unlock(); return false }
    s.busy = true
    s.status = "segmenting"
    s.submits += 1
    s.lock.unlock()

    guard let image = makePixelBufferBGRA(bgra, Int(w), Int(hh)) else {
        s.lock.lock(); s.busy = false; s.status = "error: pixel buffer alloc"; s.lock.unlock()
        return false
    }
    var scribblePB: CVPixelBuffer? = nil
    if mode == 2, let scribble, sw > 0, sh > 0 {
        scribblePB = makePixelBufferGray(scribble, Int(sw), Int(sh))
    }

    Task.detached(priority: .userInitiated) {
        do {
            guard let req = makeRequest(mode: mode, px: px, py: py,
                                        bx: bx, by: by, bw: bw, bh: bh,
                                        scribble: scribblePB, quality: quality) else {
                s.lock.lock(); s.busy = false
                s.status = "error: scribble input required"; s.lock.unlock()
                return
            }
            let obs = try await req.perform(on: image, orientation: nil)
            guard let obs else {
                s.lock.lock(); s.busy = false; s.status = "no result"; s.lock.unlock()
                return
            }
            var converted: ([Float], Int, Int)? = nil
            obs.pixelBuffer.withUnsafeBuffer { pb in
                converted = maskToFloats(pb)
            }
            s.lock.lock()
            if let (floats, mw, mh) = converted {
                s.latest = floats; s.latestW = mw; s.latestH = mh
                s.serialCtr += 1; s.latestSerial = s.serialCtr
                s.results += 1
                s.status = "ready"
                s.assetReady = 1
            } else {
                s.status = "error: mask convert"
            }
            s.busy = false
            s.lock.unlock()
        } catch {
            s.lock.lock(); s.busy = false
            s.status = "error: \(error.localizedDescription)"; s.lock.unlock()
        }
    }
    return true
}

@_cdecl("vi_latest_info")
public func vi_latest_info(_ h: UnsafeMutableRawPointer?, _ w: UnsafeMutablePointer<Int32>?,
                           _ hh: UnsafeMutablePointer<Int32>?, _ serial: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let h else { return 0 }
    let s = Unmanaged<VIState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); defer { s.lock.unlock() }
    if s.latest.isEmpty { return 0 }
    w?.pointee = Int32(s.latestW); hh?.pointee = Int32(s.latestH); serial?.pointee = s.latestSerial
    return 1
}

// 最新マスク(Float32)を dst へ。flip=1 で上下反転(Vision top-down → TD正立)
@_cdecl("vi_copy_latest")
public func vi_copy_latest(_ h: UnsafeMutableRawPointer?, _ dst: UnsafeMutableRawPointer?, _ flip: Int32) {
    guard let h, let dst else { return }
    let s = Unmanaged<VIState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let w = s.latestW, hh = s.latestH; let buf = s.latest; s.lock.unlock()
    if buf.isEmpty || w == 0 || hh == 0 { return }
    let row = w * MemoryLayout<Float>.size
    let d = dst.assumingMemoryBound(to: UInt8.self)
    buf.withUnsafeBufferPointer { src in
        let sp = UnsafeRawPointer(src.baseAddress!)
        if flip != 0 {
            for y in 0..<hh { memcpy(d + y * row, sp + (hh - 1 - y) * row, row) }
        } else {
            memcpy(d, sp, hh * row)
        }
    }
}

@_cdecl("vi_status_json")
public func vi_status_json(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h else { return nil }
    let s = Unmanaged<VIState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    let json = "{\"status\":\"\(s.status.replacingOccurrences(of: "\"", with: "'"))\",\"busy\":\(s.busy),\"asset_ready\":\(s.assetReady),\"submits\":\(s.submits),\"results\":\(s.results)}"
    s.lock.unlock()
    return UnsafePointer(strdup(json))
}
