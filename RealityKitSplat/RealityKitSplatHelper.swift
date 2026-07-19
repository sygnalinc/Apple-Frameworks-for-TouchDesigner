// RealityKitSplatHelper — RealityRenderer で USD/USDZ シーン(Gaussian Splat を含む)を
// オフスクリーン描画し、BGRA8 のCPUバッファへ落とすCヘルパ。
// RealityRenderer は @MainActor 拘束。呼び出し側(TDのcook=メインスレッド)から
// rk_render を呼ぶ。GPU完了(onComplete)で latest バッファへ画素をコピーする非ブロック方式。
import Foundation
import Metal
import RealityKit
import CoreGraphics
import simd

final class RKState: @unchecked Sendable {
    let device: MTLDevice
    var renderer: RealityRenderer?
    var camera: PerspectiveCamera?
    var content: Entity?          // 現在のシーン内容(default or loaded)
    var outTex: MTLTexture?
    var outW = 0, outH = 0

    let lock = NSLock()
    // camera / bg params
    var distance: Float = 3, yaw: Float = 0.6, pitch: Float = 0.35, fov: Float = 50
    var target = SIMD3<Float>(0,0,0)
    var bg = SIMD4<Float>(0.03,0.03,0.05,1)
    var spin: Float = 0            // 自動回転の累積yaw
    // render request (rk_render が格納、main で消費)
    var reqW = 1280, reqH = 720
    var reqDt: Float = 1.0/60.0
    var reqSpin: Float = 0
    var pendingRender = false
    // ロード済みコンテンツの自動フレーミング用bounds
    var loadedCenter = SIMD3<Float>(0,0,0)
    var loadedRadius: Float = 1
    // load
    var reqPath = ""              // 要求パス("" = default scene)
    var loadedPath = "\u{01}"     // 実際に読んだパス(初期値をreqと不一致に)
    var loading = false
    // output
    var latest = [UInt8]()
    var latestW = 0, latestH = 0
    var latestSerial: UInt64 = 0
    var serialCtr: UInt64 = 0
    var busy = false
    // status
    var frames: UInt64 = 0
    var status = "init"
    var lastError = ""

    init(_ d: MTLDevice) { device = d }
}

// ライティング用の簡易equirect環境画像(上=空色/下=地面色の明るいグラデ)
private func makeEnvImage(_ w: Int = 128, _ h: Int = 64) -> CGImage? {
    var px = [UInt8](repeating: 0, count: w*h*4)
    for y in 0..<h {
        let t = Float(y) / Float(h-1)          // 0(上)→1(下)
        let top = SIMD3<Float>(0.75,0.85,1.0), bot = SIMD3<Float>(0.55,0.5,0.45)
        let c = top*(1-t) + bot*t
        for x in 0..<w {
            let i = (y*w+x)*4
            px[i+0] = UInt8(min(255, c.z*255)); px[i+1] = UInt8(min(255, c.y*255))
            px[i+2] = UInt8(min(255, c.x*255)); px[i+3] = 255
        }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    return ctx.makeImage()
}

// MainActor 上で renderer を用意(遅延生成)
@MainActor private func ensureRenderer(_ s: RKState) throws {
    if s.renderer != nil { return }
    let r = try RealityRenderer()
    // IBL環境光(ロードした PBR メッシュを見えるように)
    if let env = makeEnvImage(), let ibl = try? EnvironmentResource(equirectangular: env) {
        r.lighting.resource = ibl
        r.lighting.intensityExponent = 1.0
    }
    // 直接光(ハイライト用)
    let l1 = DirectionalLight(); l1.light.intensity = 2500
    l1.look(at: SIMD3<Float>(0,0,0), from: SIMD3<Float>(1,1.5,1), relativeTo: nil)
    let l2 = DirectionalLight(); l2.light.intensity = 1200
    l2.look(at: SIMD3<Float>(0,0,0), from: SIMD3<Float>(-1,0.5,-0.8), relativeTo: nil)
    r.entities.append(l1); r.entities.append(l2)
    let cam = PerspectiveCamera()
    r.entities.append(cam); r.activeCamera = cam
    s.renderer = r; s.camera = cam
}

// デフォルトの手続きシーン(アセット無しでも描画確認できる)
@MainActor private func makeDefaultContent() -> Entity {
    let root = Entity()
    let mesh = MeshResource.generateBox(size: 0.6, cornerRadius: 0.06)
    let cols: [(Float,Float,Float)] = [(0.92,0.26,0.21),(0.20,0.60,0.86),(0.95,0.77,0.06)]
    for (i,c) in cols.enumerated() {
        let mat = UnlitMaterial(color: .init(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1))
        let e = ModelEntity(mesh: mesh, materials: [mat])
        e.position = SIMD3<Float>(Float(i-1)*0.85, 0, 0)
        root.addChild(e)
    }
    return root
}

@MainActor private func swapContent(_ s: RKState, _ newContent: Entity) {
    if let old = s.content { s.renderer?.entities.remove(old) }
    s.content = newContent
    s.renderer?.entities.append(newContent)
    // 自動フレーミング用に world bounds を記録(エンティティ自体は変形しない)
    let b = newContent.visualBounds(relativeTo: nil)
    let r = max(b.extents.x, max(b.extents.y, b.extents.z)) * 0.5
    s.lock.lock(); s.loadedCenter = b.center; s.loadedRadius = max(r, 0.001); s.lock.unlock()
}

// ------------- C ABI -------------

@_cdecl("rk_create")
public func rk_create() -> UnsafeMutableRawPointer? {
    guard let d = MTLCreateSystemDefaultDevice() else { return nil }
    let s = RKState(d)
    return Unmanaged.passRetained(s).toOpaque()
}

@_cdecl("rk_destroy")
public func rk_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    Unmanaged<RKState>.fromOpaque(h).release()
}

@_cdecl("rk_set_scene")
public func rk_set_scene(_ h: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?) {
    guard let h = h else { return }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    let p = path != nil ? String(cString: path!) : ""
    s.lock.lock(); s.reqPath = p; s.lock.unlock()
}

@_cdecl("rk_set_camera")
public func rk_set_camera(_ h: UnsafeMutableRawPointer?, _ dist: Float, _ yaw: Float, _ pitch: Float,
                          _ fov: Float, _ tx: Float, _ ty: Float, _ tz: Float) {
    guard let h = h else { return }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    s.distance = dist; s.yaw = yaw; s.pitch = pitch; s.fov = fov
    s.target = SIMD3<Float>(tx,ty,tz); s.lock.unlock()
}

@_cdecl("rk_set_bg")
public func rk_set_bg(_ h: UnsafeMutableRawPointer?, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    guard let h = h else { return }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); s.bg = SIMD4<Float>(r,g,b,a); s.lock.unlock()
}

// 実描画(必ず本物のメインスレッド上で呼ぶ)。RealityRenderer は @MainActor 拘束のため。
@MainActor private func renderOnMain(_ s: RKState) {
    s.lock.lock(); s.pendingRender = false
    let W = max(1, s.reqW), H = max(1, s.reqH), dt = s.reqDt, spinSpeed = s.reqSpin
    if s.busy { s.lock.unlock(); return }  // 前フレームのGPU未完了
    s.lock.unlock()
    do {
        try ensureRenderer(s)
        guard let r = s.renderer, let cam = s.camera else { return }

        // シーンのロード要求を処理
        s.lock.lock(); let req = s.reqPath; let loaded = s.loadedPath; let loading = s.loading; s.lock.unlock()
        if req != loaded && !loading {
            if req.isEmpty {
                swapContent(s, makeDefaultContent())
                s.lock.lock(); s.loadedPath = req; s.status = "default scene"; s.lock.unlock()
            } else {
                s.lock.lock(); s.loading = true; s.status = "loading"; s.lock.unlock()
                let url = URL(fileURLWithPath: req)
                Task { @MainActor in
                    do {
                        let e = try await Entity(contentsOf: url)
                        swapContent(s, e)
                        let b = e.visualBounds(relativeTo: nil)
                        s.lock.lock(); s.loadedPath = req; s.loading = false
                        s.status = "loaded size=\(String(format: "%.3f", max(b.extents.x, max(b.extents.y, b.extents.z))))"
                        s.lastError = ""; s.lock.unlock()
                    } catch {
                        s.lock.lock(); s.loading = false; s.loadedPath = req; s.status = "load error"
                        s.lastError = "\(error)"; s.lock.unlock()
                        swapContent(s, makeDefaultContent())
                    }
                }
            }
        }

        // 出力テクスチャ確保/再確保
        if s.outTex == nil || s.outW != W || s.outH != H {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
            s.outTex = s.device.makeTexture(descriptor: td); s.outW = W; s.outH = H
        }
        guard let tex = s.outTex else { return }

        // カメラ/背景を適用(bounds中心を注視・distanceは半径倍率で自動フレーミング)
        s.lock.lock()
        s.spin += spinSpeed * dt
        let distMul = s.distance, pitch = s.pitch, fov = s.fov, offset = s.target, bg = s.bg
        let center = s.loadedCenter, radius = s.loadedRadius
        let yaw = s.yaw + s.spin
        s.busy = true
        s.lock.unlock()
        let tgt = center + offset
        let dist = max(distMul, 0.01) * radius
        let dir = SIMD3<Float>(cos(pitch)*sin(yaw), sin(pitch), cos(pitch)*cos(yaw))
        let pos = tgt + dist * dir
        cam.camera.fieldOfViewInDegrees = fov
        cam.look(at: tgt, from: pos, relativeTo: nil)
        r.cameraSettings.colorBackground = .color(CGColor(red: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: CGFloat(bg.w)))

        let camOut = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: tex))
        try r.updateAndRender(deltaTime: TimeInterval(dt), cameraOutput: camOut, onComplete: { _ in
            // GPU完了(別スレッド)。shared textureをCPUへreadbackして latest へ
            var buf = [UInt8](repeating: 0, count: W*H*4)
            buf.withUnsafeMutableBytes { p in
                tex.getBytes(p.baseAddress!, bytesPerRow: W*4, from: MTLRegionMake2D(0,0,W,H), mipmapLevel: 0)
            }
            s.lock.lock()
            s.latest = buf; s.latestW = W; s.latestH = H
            s.serialCtr += 1; s.latestSerial = s.serialCtr
            s.frames += 1; s.busy = false
            s.lock.unlock()
        })
    } catch {
        s.lock.lock(); s.busy = false; s.status = "render error"; s.lastError = "\(error)"; s.lock.unlock()
    }
}

// どのスレッドから呼んでもよい。描画を本物のメインスレッドへ投げる(非ブロック)。
// TDのcookスレッドはメインではないため、DispatchQueue.main へ回す。戻り: 常に0。
@_cdecl("rk_render")
public func rk_render(_ h: UnsafeMutableRawPointer?, _ w: Int32, _ hgt: Int32, _ dt: Float, _ spinSpeed: Float) -> Int32 {
    guard let h = h else { return -2 }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    s.reqW = Int(w); s.reqH = Int(hgt); s.reqDt = dt; s.reqSpin = spinSpeed
    let already = s.pendingRender || s.busy
    if !already { s.pendingRender = true }
    s.lock.unlock()
    if already { return 0 }  // 既にスケジュール済み/描画中: パラメータだけ更新
    if Thread.isMainThread {
        MainActor.assumeIsolated { renderOnMain(s) }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { renderOnMain(s) } }
    }
    return 0
}

// 最新フレームの寸法とserialを得る。新規があれば true
@_cdecl("rk_latest_info")
public func rk_latest_info(_ h: UnsafeMutableRawPointer?, _ w: UnsafeMutablePointer<Int32>?,
                           _ hgt: UnsafeMutablePointer<Int32>?, _ serial: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let h = h else { return 0 }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); defer { s.lock.unlock() }
    if s.latest.isEmpty { return 0 }
    w?.pointee = Int32(s.latestW); hgt?.pointee = Int32(s.latestH); serial?.pointee = s.latestSerial
    return 1
}

// 最新フレームを dst へコピー(BGRA8, dst容量 = w*h*4)。flip=1で上下反転(TD正立用)
@_cdecl("rk_copy_latest")
public func rk_copy_latest(_ h: UnsafeMutableRawPointer?, _ dst: UnsafeMutableRawPointer?, _ flip: Int32) {
    guard let h = h, let dst = dst else { return }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let w = s.latestW, hh = s.latestH; let buf = s.latest; s.lock.unlock()
    if buf.isEmpty || w == 0 || hh == 0 { return }
    let row = w*4
    let d = dst.assumingMemoryBound(to: UInt8.self)
    buf.withUnsafeBufferPointer { src in
        if flip != 0 {
            for y in 0..<hh {
                memcpy(d + y*row, src.baseAddress! + (hh-1-y)*row, row)
            }
        } else {
            memcpy(d, src.baseAddress!, w*hh*4)
        }
    }
}

@_cdecl("rk_status_json")
public func rk_status_json(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h = h else { return nil }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    let json = "{\"status\":\"\(s.status)\",\"frames\":\(s.frames),\"loaded\":\"\(s.loadedPath == "\u{01}" ? "" : s.loadedPath)\",\"error\":\"\(s.lastError.replacingOccurrences(of: "\"", with: "'"))\"}"
    s.lock.unlock()
    return UnsafePointer(strdup(json))
}
