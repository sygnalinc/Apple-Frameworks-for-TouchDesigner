// RealityKitSplatHelper — RealityRenderer で 3D Gaussian Splat(.ply)/ USD / USDZ / Reality を
// オフスクリーン描画し、BGRA8 のCPUバッファへ落とすCヘルパ。
//
// macOS 27 の公開API GaussianSplatComponent / GaussianSplatResource を使用:
//   - 3DGS .ply(INRIA形式)を自前パースし LowLevelBuffer へ投入(フレームワークはファイルを
//     直接ロードしない、とAppleドキュメント明記)
//   - scale は raw log値のまま .exponential、opacity は raw logit のまま .sigmoid activation
//   - NaN/Inf を含む splat は必ず除去する(混入すると "GSAsset: NaN/Inf detected" で
//     シーン全体が描画されなくなる・実測)
//   - LowLevelBuffer の capacity にはアライメント要件がある(256B境界へ切り上げ・実測)
//
// RealityRenderer は @MainActor 拘束。TDのcookはメインスレッドではないため
// DispatchQueue.main へ描画を回す(TDがメインランループをpump)。cookは非ブロック。
import Foundation
import Metal
import RealityKit
import CoreGraphics
import simd

// 3DGS .ply のパース結果(生値のまま保持し、activation はレンダラに任せる)
struct SplatCloud: @unchecked Sendable {
    var count = 0
    var pos: [Float] = []      // xyz
    var scale: [Float] = []    // raw log-scale xyz
    var rot: [Float] = []      // quaternion xyzw(plyは wxyz 順なので並べ替え+正規化済み)
    var opacity: [Float] = []  // raw logit
    var shDC: [Float] = []     // f_dc_0..2(SH degree 0)
    var center = SIMD3<Float>(0, 0, 0)   // ロバスト中心(各軸中央値)
    var radius: Float = 1                 // 距離70パーセンタイル
}

final class RKState: @unchecked Sendable {
    let device: MTLDevice
    var renderer: RealityRenderer?
    var camera: PerspectiveCamera?
    var content: Entity?
    var contentBase = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) // plyは π回転(Y下→Y上)
    var outTex: MTLTexture?
    var outW = 0, outH = 0

    let lock = NSLock()
    // camera / bg / rotate params
    var distance: Float = 2.6, yaw: Float = 0.6, pitch: Float = 0.35, fov: Float = 50
    var target = SIMD3<Float>(0, 0, 0)
    var bg = SIMD4<Float>(0.03, 0.03, 0.05, 1)
    var spin: Float = 0
    var rotDeg = SIMD3<Float>(0, 0, 0)   // コンテンツの追加回転(deg)
    // render request
    var reqW = 1280, reqH = 720
    var reqDt: Float = 1.0 / 60.0
    var reqSpin: Float = 0
    var pendingRender = false
    // 自動フレーミング用(コンテンツのbase回転適用後の値)
    var loadedCenter = SIMD3<Float>(0, 0, 0)
    var loadedRadius: Float = 1
    // load
    var reqPath = ""
    var reqMax = 500000
    var loadedPath = "\u{01}"
    var loadedMax = -1
    var loading = false
    var splatCount = 0
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

// ---------- 3DGS .ply パーサ ----------

// INRIA形式 3DGS .ply(binary_little_endian・float property群)をパースする。
// mmap(alwaysMapped)で読み、maxPoints を超える場合は等間隔サブサンプル。
func parse3DGS(_ path: String, maxPoints: Int) -> (SplatCloud?, String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
        return (nil, "cannot open file")
    }
    // ヘッダ(テキスト)
    let probe = data.prefix(65536)
    guard let end = probe.range(of: Data("end_header\n".utf8)) else { return (nil, "not a ply (no end_header)") }
    guard let htxt = String(data: probe[..<end.lowerBound], encoding: .utf8) else { return (nil, "bad ply header") }
    if !htxt.contains("binary_little_endian") { return (nil, "only binary_little_endian ply supported") }
    var props: [String] = []
    var nverts = 0
    for line in htxt.split(separator: "\n") {
        if line.hasPrefix("element vertex") { nverts = Int(line.dropFirst(15)) ?? 0 }
        else if line.hasPrefix("property float") { props.append(String(line.dropFirst(15))) }
        else if line.hasPrefix("property") && !line.hasPrefix("property float") && props.isEmpty == false {
            return (nil, "non-float vertex property not supported")
        }
    }
    func idx(_ n: String) -> Int { props.firstIndex(of: n) ?? -1 }
    let ix = idx("x"), iy = idx("y"), iz = idx("z")
    let idc0 = idx("f_dc_0"), idc1 = idx("f_dc_1"), idc2 = idx("f_dc_2")
    let iop = idx("opacity")
    let is0 = idx("scale_0"), is1 = idx("scale_1"), is2 = idx("scale_2")
    let ir0 = idx("rot_0"), ir1 = idx("rot_1"), ir2 = idx("rot_2"), ir3 = idx("rot_3")
    let nProps = props.count
    guard ix >= 0, iy >= 0, iz >= 0, is0 >= 0, ir0 >= 0, nverts > 0 else {
        return (nil, "unexpected ply layout (need x/y/z, scale_*, rot_* float properties)")
    }
    let bodyStart = end.upperBound
    let avail = (data.count - bodyStart) / (nProps * 4)
    let total = min(nverts, avail)
    if total <= 0 { return (nil, "ply body truncated") }
    let sub = maxPoints > 0 ? max(1, total / maxPoints) : 1

    var s = SplatCloud()
    let estimate = total / sub + 1
    s.pos.reserveCapacity(estimate * 3); s.scale.reserveCapacity(estimate * 3)
    s.rot.reserveCapacity(estimate * 4); s.opacity.reserveCapacity(estimate)
    s.shDC.reserveCapacity(estimate * 3)

    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let base = raw.baseAddress! + bodyStart
        var i = 0
        while i < total {
            let row = base + i * nProps * 4
            func f(_ j: Int) -> Float { row.loadUnaligned(fromByteOffset: j * 4, as: Float.self) }
            func fin(_ v: Float, _ fb: Float) -> Float { v.isFinite ? v : fb }
            let px = f(ix), py = f(iy), pz = f(iz)
            if px.isFinite && py.isFinite && pz.isFinite {
                s.pos.append(contentsOf: [px, py, pz])
                s.scale.append(contentsOf: [fin(f(is0), -10), fin(f(is1), -10), fin(f(is2), -10)])
                // ply は w,x,y,z 順。RealityKit へは x,y,z,w で渡す(実測で正しい向き)
                var q = SIMD4<Float>(fin(f(ir1), 0), fin(f(ir2), 0), fin(f(ir3), 0), fin(f(ir0), 1))
                let len = simd_length(q)
                if len > 1e-6 { q /= len } else { q = SIMD4<Float>(0, 0, 0, 1) }
                s.rot.append(contentsOf: [q.x, q.y, q.z, q.w])
                s.opacity.append(iop >= 0 ? fin(f(iop), 10) : 10)
                s.shDC.append(contentsOf: [idc0 >= 0 ? fin(f(idc0), 0) : 0,
                                           idc1 >= 0 ? fin(f(idc1), 0) : 0,
                                           idc2 >= 0 ? fin(f(idc2), 0) : 0])
                s.count += 1
            }
            i += sub
        }
    }
    if s.count == 0 { return (nil, "no finite splats in ply") }

    // ロバストなフレーミング: 遠方の背景splatに引っ張られないよう
    // 各軸中央値を中心、距離の70パーセンタイルを半径にする
    var xs = [Float](), ys = [Float](), zs = [Float]()
    let step = max(1, s.count / 50000)
    for j in Swift.stride(from: 0, to: s.pos.count, by: 3 * step) {
        xs.append(s.pos[j]); ys.append(s.pos[j + 1]); zs.append(s.pos[j + 2])
    }
    xs.sort(); ys.sort(); zs.sort()
    let med = SIMD3<Float>(xs[xs.count / 2], ys[ys.count / 2], zs[zs.count / 2])
    var dists = [Float]()
    for j in Swift.stride(from: 0, to: s.pos.count, by: 3 * step) {
        dists.append(simd_length(SIMD3<Float>(s.pos[j], s.pos[j + 1], s.pos[j + 2]) - med))
    }
    dists.sort()
    s.center = med
    s.radius = max(dists[Int(Float(dists.count) * 0.7)], 0.001)
    return (s, "")
}

// SplatCloud → GaussianSplatResource(macOS 27+)
@available(macOS 27.0, *)
@MainActor
func makeSplatResource(_ s: SplatCloud) throws -> GaussianSplatResource {
    func buf(_ arr: [Float]) throws -> LowLevelBuffer {
        let used = arr.count * 4
        let cap = (used + 255) & ~255   // capacity にはアライメント要件がある(実測: count*12 素のままだと invalid)
        let b = try LowLevelBuffer(descriptor: .init(capacity: cap))
        b.withUnsafeMutableBytes { dst in
            arr.withUnsafeBytes { src in
                dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: used)
            }
        }
        b.bytesUsed = used
        return b
    }
    let br = try GaussianSplatResource.BufferResource(
        count: s.count,
        position: .init(buffer: try buf(s.pos), format: .float3, stride: 12, offset: 0),
        scale: .init(buffer: try buf(s.scale), format: .float3, stride: 12, offset: 0),
        rotation: .init(buffer: try buf(s.rot), format: .float4, stride: 16, offset: 0),
        opacity: .init(buffer: try buf(s.opacity), format: .float, stride: 4, offset: 0),
        sphericalHarmonics: (.init(buffer: try buf(s.shDC), format: .float3, stride: 12, offset: 0), .zero))
    let res = GaussianSplatResource(br)
    res.scaleActivation = .exponential   // 3DGS の scale は log値
    res.opacityActivation = .sigmoid     // 3DGS の opacity は logit
    return res
}

// ---------- ライティング/シーン ----------

private func makeEnvImage(_ w: Int = 128, _ h: Int = 64) -> CGImage? {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        let t = Float(y) / Float(h - 1)
        let top = SIMD3<Float>(0.75, 0.85, 1.0), bot = SIMD3<Float>(0.55, 0.5, 0.45)
        let c = top * (1 - t) + bot * t
        for x in 0..<w {
            let i = (y * w + x) * 4
            px[i + 0] = UInt8(min(255, c.z * 255)); px[i + 1] = UInt8(min(255, c.y * 255))
            px[i + 2] = UInt8(min(255, c.x * 255)); px[i + 3] = 255
        }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    return ctx.makeImage()
}

@MainActor private func ensureRenderer(_ s: RKState) throws {
    if s.renderer != nil { return }
    let r = try RealityRenderer()
    if let env = makeEnvImage(), let ibl = try? EnvironmentResource(equirectangular: env) {
        r.lighting.resource = ibl
        r.lighting.intensityExponent = 1.0
    }
    let l1 = DirectionalLight(); l1.light.intensity = 2500
    l1.look(at: SIMD3<Float>(0, 0, 0), from: SIMD3<Float>(1, 1.5, 1), relativeTo: nil)
    let l2 = DirectionalLight(); l2.light.intensity = 1200
    l2.look(at: SIMD3<Float>(0, 0, 0), from: SIMD3<Float>(-1, 0.5, -0.8), relativeTo: nil)
    r.entities.append(l1); r.entities.append(l2)
    let cam = PerspectiveCamera()
    r.entities.append(cam); r.activeCamera = cam
    s.renderer = r; s.camera = cam
}

// デフォルトの手続きシーン(アセット無しでも描画確認できる)
@MainActor private func makeDefaultContent() -> Entity {
    let root = Entity()
    let mesh = MeshResource.generateBox(size: 0.6, cornerRadius: 0.06)
    let cols: [(Float, Float, Float)] = [(0.92, 0.26, 0.21), (0.20, 0.60, 0.86), (0.95, 0.77, 0.06)]
    for (i, c) in cols.enumerated() {
        let mat = UnlitMaterial(color: .init(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1))
        let e = ModelEntity(mesh: mesh, materials: [mat])
        e.position = SIMD3<Float>(Float(i - 1) * 0.85, 0, 0)
        root.addChild(e)
    }
    return root
}

// コンテンツ差し替え。center/radius を明示指定(splat)または visualBounds から取得(メッシュ)
@MainActor private func swapContent(_ s: RKState, _ newContent: Entity, base: simd_quatf,
                                    center: SIMD3<Float>? = nil, radius: Float? = nil) {
    if let old = s.content { s.renderer?.entities.remove(old) }
    s.content = newContent
    s.contentBase = base
    s.renderer?.entities.append(newContent)
    var c = center; var r = radius
    if c == nil || r == nil {
        let b = newContent.visualBounds(relativeTo: nil)
        let rr = max(b.extents.x, max(b.extents.y, b.extents.z)) * 0.5
        c = b.center; r = max(rr, 0.001)
    }
    s.lock.lock(); s.loadedCenter = c!; s.loadedRadius = max(r!, 0.001); s.lock.unlock()
}

// ---------- ロード ----------

@MainActor private func handleLoad(_ s: RKState) {
    s.lock.lock()
    let req = s.reqPath, loaded = s.loadedPath, loading = s.loading
    let reqMax = s.reqMax, loadedMax = s.loadedMax
    s.lock.unlock()
    let isPly = req.lowercased().hasSuffix(".ply")
    let needs = (req != loaded) || (isPly && reqMax != loadedMax)
    if !needs || loading { return }

    if req.isEmpty {
        swapContent(s, makeDefaultContent(), base: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
        s.lock.lock(); s.loadedPath = req; s.loadedMax = reqMax; s.splatCount = 0
        s.status = "default scene"; s.lock.unlock()
        return
    }
    if isPly {
        guard #available(macOS 27.0, *) else {
            s.lock.lock(); s.loadedPath = req; s.loadedMax = reqMax
            s.status = "unavailable"; s.lastError = "Gaussian Splat requires macOS 27+"; s.lock.unlock()
            return
        }
        s.lock.lock(); s.loading = true; s.status = "parsing ply"; s.lock.unlock()
        Task.detached(priority: .userInitiated) {
            let (cloud, err) = parse3DGS(req, maxPoints: reqMax)   // 重いパースはバックグラウンド
            await MainActor.run {
                guard let cloud else {
                    s.lock.lock(); s.loading = false; s.loadedPath = req; s.loadedMax = reqMax
                    s.status = "load error"; s.lastError = err; s.lock.unlock()
                    swapContent(s, makeDefaultContent(), base: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
                    return
                }
                if #available(macOS 27.0, *) {
                    do {
                        let res = try makeSplatResource(cloud)     // リソース構築は MainActor
                        let ent = Entity()
                        ent.components.set(GaussianSplatComponent(res))
                        // 3DGS は Y下向き規約 → X軸π回転で正立させる
                        let base = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
                        ent.orientation = base
                        let c = SIMD3<Float>(cloud.center.x, -cloud.center.y, -cloud.center.z) // base回転後の中心
                        swapContent(s, ent, base: base, center: c, radius: cloud.radius)
                        s.lock.lock(); s.loading = false; s.loadedPath = req; s.loadedMax = reqMax
                        s.splatCount = cloud.count
                        s.status = "splats loaded (\(cloud.count))"; s.lastError = ""; s.lock.unlock()
                    } catch {
                        s.lock.lock(); s.loading = false; s.loadedPath = req; s.loadedMax = reqMax
                        s.status = "load error"; s.lastError = "\(error)"; s.lock.unlock()
                    }
                }
            }
        }
    } else {
        s.lock.lock(); s.loading = true; s.status = "loading"; s.lock.unlock()
        let url = URL(fileURLWithPath: req)
        Task { @MainActor in
            do {
                let e = try await Entity(contentsOf: url)
                swapContent(s, e, base: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
                let b = e.visualBounds(relativeTo: nil)
                s.lock.lock(); s.loadedPath = req; s.loadedMax = reqMax; s.loading = false; s.splatCount = 0
                s.status = "loaded size=\(String(format: "%.3f", max(b.extents.x, max(b.extents.y, b.extents.z))))"
                s.lastError = ""; s.lock.unlock()
            } catch {
                s.lock.lock(); s.loading = false; s.loadedPath = req; s.loadedMax = reqMax
                s.status = "load error"; s.lastError = "\(error)"; s.lock.unlock()
                swapContent(s, makeDefaultContent(), base: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
            }
        }
    }
}

// ---------- 描画 ----------

@MainActor private func renderOnMain(_ s: RKState) {
    s.lock.lock(); s.pendingRender = false
    let W = max(1, s.reqW), H = max(1, s.reqH), dt = s.reqDt, spinSpeed = s.reqSpin
    if s.busy { s.lock.unlock(); return }
    s.lock.unlock()
    do {
        try ensureRenderer(s)
        guard let r = s.renderer, let cam = s.camera else { return }
        handleLoad(s)

        if s.outTex == nil || s.outW != W || s.outH != H {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
            s.outTex = s.device.makeTexture(descriptor: td); s.outW = W; s.outH = H
        }
        guard let tex = s.outTex else { return }

        s.lock.lock()
        s.spin += spinSpeed * dt
        let distMul = s.distance, pitch = s.pitch, fov = s.fov, offset = s.target, bg = s.bg
        let center = s.loadedCenter, radius = s.loadedRadius
        let yaw = s.yaw + s.spin
        let rotDeg = s.rotDeg
        s.busy = true
        s.lock.unlock()

        // コンテンツの追加回転(ユーザーパラメータ)を base に合成
        let d2r = Float.pi / 180
        let qUser = simd_quatf(angle: rotDeg.z * d2r, axis: SIMD3<Float>(0, 0, 1))
                  * simd_quatf(angle: rotDeg.y * d2r, axis: SIMD3<Float>(0, 1, 0))
                  * simd_quatf(angle: rotDeg.x * d2r, axis: SIMD3<Float>(1, 0, 0))
        if let content = s.content { content.orientation = qUser * s.contentBase }

        // カメラ: 回転後の中心を注視し、distance は content 半径の倍率
        let tgt = qUser.act(center) + offset
        let dist = max(distMul, 0.01) * radius
        let dir = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        cam.camera.fieldOfViewInDegrees = fov
        cam.look(at: tgt, from: tgt + dist * dir, relativeTo: nil)
        r.cameraSettings.colorBackground = .color(CGColor(red: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: CGFloat(bg.w)))

        let camOut = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: tex))
        try r.updateAndRender(deltaTime: TimeInterval(dt), cameraOutput: camOut, onComplete: { _ in
            var buf = [UInt8](repeating: 0, count: W * H * 4)
            buf.withUnsafeMutableBytes { p in
                tex.getBytes(p.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
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

// ---------- C ABI ----------

@_cdecl("rk_create")
public func rk_create() -> UnsafeMutableRawPointer? {
    guard let d = MTLCreateSystemDefaultDevice() else { return nil }
    return Unmanaged.passRetained(RKState(d)).toOpaque()
}

@_cdecl("rk_destroy")
public func rk_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    Unmanaged<RKState>.fromOpaque(h).release()
}

@_cdecl("rk_set_scene")
public func rk_set_scene(_ h: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?, _ maxSplats: Int32) {
    guard let h = h else { return }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    let p = path != nil ? String(cString: path!) : ""
    s.lock.lock(); s.reqPath = p; s.reqMax = max(1000, Int(maxSplats)); s.lock.unlock()
}

@_cdecl("rk_set_camera")
public func rk_set_camera(_ h: UnsafeMutableRawPointer?, _ dist: Float, _ yaw: Float, _ pitch: Float,
                          _ fov: Float, _ tx: Float, _ ty: Float, _ tz: Float) {
    guard let h = h else { return }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    s.distance = dist; s.yaw = yaw; s.pitch = pitch; s.fov = fov
    s.target = SIMD3<Float>(tx, ty, tz); s.lock.unlock()
}

@_cdecl("rk_set_rotate")
public func rk_set_rotate(_ h: UnsafeMutableRawPointer?, _ rx: Float, _ ry: Float, _ rz: Float) {
    guard let h = h else { return }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); s.rotDeg = SIMD3<Float>(rx, ry, rz); s.lock.unlock()
}

@_cdecl("rk_set_bg")
public func rk_set_bg(_ h: UnsafeMutableRawPointer?, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    guard let h = h else { return }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); s.bg = SIMD4<Float>(r, g, b, a); s.lock.unlock()
}

@_cdecl("rk_render")
public func rk_render(_ h: UnsafeMutableRawPointer?, _ w: Int32, _ hgt: Int32, _ dt: Float, _ spinSpeed: Float) -> Int32 {
    guard let h = h else { return -2 }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    s.reqW = Int(w); s.reqH = Int(hgt); s.reqDt = dt; s.reqSpin = spinSpeed
    let already = s.pendingRender || s.busy
    if !already { s.pendingRender = true }
    s.lock.unlock()
    if already { return 0 }
    if Thread.isMainThread {
        MainActor.assumeIsolated { renderOnMain(s) }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { renderOnMain(s) } }
    }
    return 0
}

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

@_cdecl("rk_copy_latest")
public func rk_copy_latest(_ h: UnsafeMutableRawPointer?, _ dst: UnsafeMutableRawPointer?, _ flip: Int32) {
    guard let h = h, let dst = dst else { return }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let w = s.latestW, hh = s.latestH; let buf = s.latest; s.lock.unlock()
    if buf.isEmpty || w == 0 || hh == 0 { return }
    let row = w * 4
    let d = dst.assumingMemoryBound(to: UInt8.self)
    buf.withUnsafeBufferPointer { src in
        if flip != 0 {
            for y in 0..<hh { memcpy(d + y * row, src.baseAddress! + (hh - 1 - y) * row, row) }
        } else {
            memcpy(d, src.baseAddress!, w * hh * 4)
        }
    }
}

@_cdecl("rk_splat_count")
public func rk_splat_count(_ h: UnsafeMutableRawPointer?) -> Int32 {
    guard let h = h else { return 0 }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); defer { s.lock.unlock() }
    return Int32(s.splatCount)
}

@_cdecl("rk_status_json")
public func rk_status_json(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h = h else { return nil }
    let s = Unmanaged<RKState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    let json = "{\"status\":\"\(s.status)\",\"frames\":\(s.frames),\"splats\":\(s.splatCount),\"loaded\":\"\(s.loadedPath == "\u{01}" ? "" : s.loadedPath)\",\"error\":\"\(s.lastError.replacingOccurrences(of: "\"", with: "'"))\"}"
    s.lock.unlock()
    return UnsafePointer(strdup(json))
}
