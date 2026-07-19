// CinematicHelper — iPhone Cinematicモード動画の共有リーダ。C ABI(cn_)で ObjC++ の
// Cinematic CHOP / Cinematic TOP から使う。
//  - メタデータ(フォーカス深度・被写体)は CNScript から時刻指定で取得(ピクセルデコード不要)
//  - 深度マップ(視差)は disparity トラックを時刻指定でデコード
//  - 再レンダ(f値/ピント差し替え)は CNRenderingSession.encodeRender(Metal)
// 実装は Apple サンプル "Playing and editing Cinematic mode video" の API 準拠。
import Foundation
import AVFoundation
import Cinematic
import CoreMedia
import CoreVideo
import Metal
import Accelerate

final class CNState: @unchecked Sendable {
    let lock = NSLock()
    var status = "idle"        // idle / loading / ready / error
    var error = ""
    var duration: Double = 0
    var fps: Double = 30
    var metaJSON = "{}"        // 直近 cn_meta の結果

    // ロード済み資産(ready後のみ・メインでなくても参照する)
    var asset: AVAsset?
    var info: CNAssetInfo?
    var script: CNScript?
    var session: CNRenderingSession?
    var attrs: CNRenderingSession.Attributes?
    var device: MTLDevice?
    var queue: MTLCommandQueue?
    var timeScale: CMTimeScale = 600

    // 深度/再レンダの出力(latest)
    var depthBuf: [Float] = []
    var depthW = 0, depthH = 0
    var depthSerial: UInt64 = 0
    var rgbaBuf: [UInt16] = []
    var rgbaW = 0, rgbaH = 0
    var rgbaSerial: UInt64 = 0
    var serialCtr: UInt64 = 0
}

@available(macOS 26.0, *)
private func detTypeString(_ t: CNDetectionType) -> String {
    // accessibilityLabel は "Human Face" 等の文字列を返す
    return CNDetection.accessibilityLabel(for: t)
}

@_cdecl("cn_create")
public func cn_create() -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained(CNState()).toOpaque()
}

@_cdecl("cn_destroy")
public func cn_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    Unmanaged<CNState>.fromOpaque(h).release()
}

@_cdecl("cn_open")
public func cn_open(_ h: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?) {
    guard let h = h, let path = path else { return }
    let s = Unmanaged<CNState>.fromOpaque(h).takeUnretainedValue()
    let p = String(cString: path)
    s.lock.lock(); if s.status == "loading" { s.lock.unlock(); return }; s.status = "loading"; s.lock.unlock()
    guard #available(macOS 26.0, *) else {
        s.lock.lock(); s.status = "error"; s.error = "Cinematic framework requires macOS 26+"; s.lock.unlock(); return
    }
    let url = URL(fileURLWithPath: p)
    Task.detached {
        do {
            let asset = AVURLAsset(url: url)
            let info = try await CNAssetInfo(asset: asset)
            let attrs = try await CNRenderingSession.Attributes(asset: asset)
            guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
                throw NSError(domain: "cn", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
            }
            let session = CNRenderingSession(commandQueue: q, sessionAttributes: attrs,
                                             preferredTransform: info.preferredTransform, quality: .preview)
            let script = try await CNScript(asset: asset)
            let dur = script.timeRange.duration.seconds
            let fps = (try? await info.frameTimingTrack.load(.nominalFrameRate)).map { Double($0) } ?? 30
            let ts = (try? await info.frameTimingTrack.load(.naturalTimeScale)) ?? 600
            s.lock.lock()
            s.asset = asset; s.info = info; s.attrs = attrs; s.session = session; s.script = script
            s.device = dev; s.queue = q; s.duration = dur; s.fps = fps > 0 ? fps : 30; s.timeScale = ts
            s.status = "ready"; s.error = ""
            s.lock.unlock()
        } catch {
            s.lock.lock(); s.status = "error"; s.error = "\(error)"; s.lock.unlock()
        }
    }
}

@_cdecl("cn_status")
public func cn_status(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h = h else { return nil }
    let s = Unmanaged<CNState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let out = "\(s.status)|\(s.duration)|\(s.fps)|\(s.error)"; s.lock.unlock()
    return UnsafePointer(strdup(out))
}

// 指定秒の CNScript フレームからメタデータJSONを作る(ピクセルデコード不要)
@_cdecl("cn_meta")
public func cn_meta(_ h: UnsafeMutableRawPointer?, _ timeSec: Double) -> UnsafePointer<CChar>? {
    guard let h = h else { return nil }
    let s = Unmanaged<CNState>.fromOpaque(h).takeUnretainedValue()
    guard #available(macOS 26.0, *) else { return UnsafePointer(strdup("{}")) }
    s.lock.lock(); let script = s.script; let ts = s.timeScale; let fps = s.fps; s.lock.unlock()
    guard let script = script else { return UnsafePointer(strdup("{}")) }
    let t = CMTime(seconds: timeSec, preferredTimescale: ts)
    let tol = CMTime(seconds: 1.0 / max(fps, 1), preferredTimescale: ts)
    var focus: Float = 0
    var subjects: [String] = []
    var strong = 0
    if let frame = script.frame(at: t, tolerance: tol) {
        focus = frame.focusDisparity
        for d in frame.allDetections {
            let r = d.normalizedRect
            let id = d.detectionID.hashValue
            let ty = detTypeString(d.detectionType).replacingOccurrences(of: "\"", with: "'")
            subjects.append("{\"type\":\"\(ty)\",\"x\":\(r.origin.x),\"y\":\(r.origin.y),\"w\":\(r.size.width),\"h\":\(r.size.height),\"depth\":\(d.focusDisparity),\"id\":\(id)}")
        }
    }
    if let dec = script.decision(at: t, tolerance: tol) ?? script.decision(before: t) {
        strong = dec.isStrongDecision ? 1 : 0
    }
    let json = "{\"focus\":\(focus),\"strong\":\(strong),\"count\":\(subjects.count),\"subjects\":[\(subjects.joined(separator: ","))]}"
    return UnsafePointer(strdup(json))
}

// ---- 時刻指定デコード(depth / render 用) ----

@available(macOS 26.0, *)
private func readFrames(_ s: CNState, timeSec: Double, wantRender: Bool)
    -> (image: CVPixelBuffer?, disparity: CVPixelBuffer?, meta: CMSampleBuffer?)? {
    s.lock.lock(); let asset = s.asset; let info = s.info; let ts = s.timeScale; let fps = s.fps; s.lock.unlock()
    guard let asset = asset, let info = info else { return nil }
    guard let reader = try? AVAssetReader(asset: asset) else { return nil }
    let dur = CMTime(seconds: 1.0 / max(fps, 1) * 1.5, preferredTimescale: ts)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, timeSec), preferredTimescale: ts), duration: dur)

    // disparity(常に)
    let disOut = AVAssetReaderTrackOutput(track: info.cinematicDisparityTrack,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_DisparityFloat16,
                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
    disOut.alwaysCopiesSampleData = false
    if reader.canAdd(disOut) { reader.add(disOut) }

    var vidOut: AVAssetReaderTrackOutput? = nil
    var metaOut: AVAssetReaderTrackOutput? = nil
    if wantRender {
        let v = AVAssetReaderTrackOutput(track: info.cinematicVideoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                             kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        v.alwaysCopiesSampleData = false
        if reader.canAdd(v) { reader.add(v); vidOut = v }
        let m = AVAssetReaderTrackOutput(track: info.cinematicMetadataTrack, outputSettings: nil)
        if reader.canAdd(m) { reader.add(m); metaOut = m }
    }
    guard reader.startReading() else { return nil }
    let dis = disOut.copyNextSampleBuffer().flatMap { CMSampleBufferGetImageBuffer($0) }
    let img = vidOut?.copyNextSampleBuffer().flatMap { CMSampleBufferGetImageBuffer($0) }
    let meta = metaOut?.copyNextSampleBuffer()
    reader.cancelReading()
    return (img, dis, meta)
}

// float16 disparity CVPixelBuffer → Float 配列(上下反転してTD正立)
private func disparityToFloat(_ pb: CVPixelBuffer, flip: Bool, normalize: Bool, out: inout [Float], outW: inout Int, outH: inout Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    var tmp = [Float](repeating: 0, count: W * H)
    if fmt == kCVPixelFormatType_DisparityFloat16 || fmt == kCVPixelFormatType_DepthFloat16 {
        for y in 0..<H {
            var src = vImage_Buffer(data: base.advanced(by: y * bpr), height: 1, width: vImagePixelCount(W), rowBytes: W * 2)
            tmp.withUnsafeMutableBufferPointer { d in
                var dst = vImage_Buffer(data: d.baseAddress!.advanced(by: y * W), height: 1, width: vImagePixelCount(W), rowBytes: W * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            }
        }
    } else if fmt == kCVPixelFormatType_DisparityFloat32 || fmt == kCVPixelFormatType_DepthFloat32 {
        for y in 0..<H { memcpy(&tmp[y * W], base.advanced(by: y * bpr), W * 4) }
    } else {
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<H { for x in 0..<W { tmp[y * W + x] = Float(p[y * bpr + x]) / 255 } }
    }
    if normalize {
        var lo = tmp[0], hi = tmp[0]; for v in tmp { if v < lo { lo = v }; if v > hi { hi = v } }
        if hi > lo { let inv = 1 / (hi - lo); for i in 0..<tmp.count { tmp[i] = (tmp[i] - lo) * inv } }
    }
    out = [Float](repeating: 0, count: W * H)
    if flip { for y in 0..<H { memcpy(&out[(H - 1 - y) * W], &tmp[y * W], W * 4) } }
    else { out = tmp }
    outW = W; outH = H
}

// Depth: disparity を Float バッファへ。戻り 1=ok 0=fail(cn_latest_depth で取得)
@_cdecl("cn_depth")
public func cn_depth(_ h: UnsafeMutableRawPointer?, _ timeSec: Double, _ flip: Int32, _ normalize: Int32) -> Int32 {
    guard let h = h else { return 0 }
    let s = Unmanaged<CNState>.fromOpaque(h).takeUnretainedValue()
    guard #available(macOS 26.0, *) else { return 0 }
    guard let frames = readFrames(s, timeSec: timeSec, wantRender: false), let dis = frames.disparity else { return 0 }
    var buf: [Float] = []; var W = 0, H = 0
    disparityToFloat(dis, flip: flip != 0, normalize: normalize != 0, out: &buf, outW: &W, outH: &H)
    if buf.isEmpty { return 0 }
    s.lock.lock(); s.depthBuf = buf; s.depthW = W; s.depthH = H; s.serialCtr += 1; s.depthSerial = s.serialCtr; s.lock.unlock()
    return 1
}

@_cdecl("cn_latest_depth_info")
public func cn_latest_depth_info(_ h: UnsafeMutableRawPointer?, _ w: UnsafeMutablePointer<Int32>?, _ ht: UnsafeMutablePointer<Int32>?, _ serial: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let h = h else { return 0 }
    let s = Unmanaged<CNState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); defer { s.lock.unlock() }
    if s.depthBuf.isEmpty { return 0 }
    w?.pointee = Int32(s.depthW); ht?.pointee = Int32(s.depthH); serial?.pointee = s.depthSerial; return 1
}

@_cdecl("cn_copy_depth")
public func cn_copy_depth(_ h: UnsafeMutableRawPointer?, _ dst: UnsafeMutableRawPointer?) {
    guard let h = h, let dst = dst else { return }
    let s = Unmanaged<CNState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let buf = s.depthBuf; s.lock.unlock()
    if !buf.isEmpty { buf.withUnsafeBytes { memcpy(dst, $0.baseAddress!, $0.count) } }
}

// Render: f値/ピント差し替えで再レンダ → RGBA16Float バッファへ
@_cdecl("cn_render")
public func cn_render(_ h: UnsafeMutableRawPointer?, _ timeSec: Double, _ fNumber: Float, _ focusOverride: Float, _ flip: Int32) -> Int32 {
    guard let h = h else { return 0 }
    let s = Unmanaged<CNState>.fromOpaque(h).takeUnretainedValue()
    guard #available(macOS 26.0, *) else { return 0 }
    s.lock.lock(); let session = s.session; let script = s.script; let dev = s.device; let q = s.queue; let ts = s.timeScale; let fps = s.fps; s.lock.unlock()
    guard let session = session, let script = script, let dev = dev, let q = q else { return 0 }
    guard let frames = readFrames(s, timeSec: timeSec, wantRender: true),
          let img = frames.image, let dis = frames.disparity, let meta = frames.meta else { return 0 }
    guard var fa = CNRenderingSession.FrameAttributes(sampleBuffer: meta, sessionAttributes: session.sessionAttributes) else { return 0 }
    fa.fNumber = fNumber
    let t = CMTime(seconds: timeSec, preferredTimescale: ts)
    let tol = CMTime(seconds: 1.0 / max(fps, 1), preferredTimescale: ts)
    if focusOverride.isFinite && focusOverride != 0 { fa.focusDisparity = focusOverride }
    else if let f = script.frame(at: t, tolerance: tol) { fa.focusDisparity = f.focusDisparity }

    let W = CVPixelBufferGetWidth(img), H = CVPixelBufferGetHeight(img)
    var outPB: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_64RGBAHalf,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &outPB)
    guard let dst = outPB, let cb = q.makeCommandBuffer() else { return 0 }
    let ok = session.encodeRender(to: cb, frameAttributes: fa, sourceImage: img, sourceDisparity: dis, destinationImage: dst)
    if !ok { return 0 }
    cb.commit(); cb.waitUntilCompleted()

    // RGBA16Float(64RGBAHalf)を CPU へ、必要なら行反転
    CVPixelBufferLockBaseAddress(dst, .readOnly); defer { CVPixelBufferUnlockBaseAddress(dst, .readOnly) }
    let bpr = CVPixelBufferGetBytesPerRow(dst)
    guard let base = CVPixelBufferGetBaseAddress(dst) else { return 0 }
    var buf = [UInt16](repeating: 0, count: W * H * 4)
    let rowBytes = W * 4 * 2
    buf.withUnsafeMutableBytes { d in
        for y in 0..<H {
            let srcY = (flip != 0) ? (H - 1 - y) : y
            memcpy(d.baseAddress!.advanced(by: y * rowBytes), base.advanced(by: srcY * bpr), rowBytes)
        }
    }
    s.lock.lock(); s.rgbaBuf = buf; s.rgbaW = W; s.rgbaH = H; s.serialCtr += 1; s.rgbaSerial = s.serialCtr; s.lock.unlock()
    return 1
}

@_cdecl("cn_latest_render_info")
public func cn_latest_render_info(_ h: UnsafeMutableRawPointer?, _ w: UnsafeMutablePointer<Int32>?, _ ht: UnsafeMutablePointer<Int32>?, _ serial: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let h = h else { return 0 }
    let s = Unmanaged<CNState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); defer { s.lock.unlock() }
    if s.rgbaBuf.isEmpty { return 0 }
    w?.pointee = Int32(s.rgbaW); ht?.pointee = Int32(s.rgbaH); serial?.pointee = s.rgbaSerial; return 1
}

@_cdecl("cn_copy_render")
public func cn_copy_render(_ h: UnsafeMutableRawPointer?, _ dst: UnsafeMutableRawPointer?) {
    guard let h = h, let dst = dst else { return }
    let s = Unmanaged<CNState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let buf = s.rgbaBuf; s.lock.unlock()
    if !buf.isEmpty { buf.withUnsafeBytes { memcpy(dst, $0.baseAddress!, $0.count) } }
}
