// CoreAIHelper — Core AI(macOS 27+)の .aimodel を TouchDesigner から回すための Swift ヘルパ
//
// C ABI(ai_*)で ObjC++ の TOP から呼ばれる。設計は家族の型:
//   - ロードも推論も Task で非同期。呼び出し側(cook)は一切ブロックしない
//   - 結果は「最新値」を lock 付きで保持し、serial で更新を検知する
//   - 状態は poll 方式の JSON(ai_status_json)
//
// Core AI は Swift 専用フレームワーク(ObjC ヘッダ無し)なので、この層が必須。
// 入出力は関数ディスクリプタが自己記述(shape / dtype / image)なので、モデルごとの
// 特別扱いをせず、TOP 側は「最初の画像入力」「選んだ出力名」だけを指定する。
//
// macOS 26 では CoreAI framework 自体が無いので -weak_framework でリンクし、
// 全ての実体を @available(macOS 27.0, *) の裏に置く(ロードは落ちず status に理由が出る)。
import Foundation
import CoreGraphics
import CoreVideo
import Accelerate
#if canImport(CoreAI)
import CoreAI
#endif

// MARK: - 共有の小物

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
}()

private func jsonString(_ v: Any) -> String {
    guard JSONSerialization.isValidJSONObject(v),
          let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
          let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

/// 推論結果(出力1個ぶん)。dtype に関わらず Float32 に揃えて持つ
fileprivate struct OutputTensor {
    var shape: [Int]
    var dtype: String
    var data: [Float]
}

/// 画像として解釈したときのレイアウト
fileprivate struct ImageLayout {
    var w: Int, h: Int, c: Int
    var chw: Bool          // true: [C,H,W] / false: [H,W,C]
    var base: Int          // データ先頭からのオフセット(要素数)
}

// MARK: - 状態(macOS 27+)

#if canImport(CoreAI)
@available(macOS 27.0, *)
final class AIState: @unchecked Sendable {
    let lock = NSLock()

    // 設定(cook スレッドから書く)
    var modelPath = ""
    var functionName = "main"
    var computeUnits = 0            // 0 auto / 1 cpu / 2 gpu / 3 ane

    // ロード状態
    var model: AIModel?
    var function: InferenceFunction?
    var loaded = false
    var loading = false
    var loadSerial: UInt64 = 0      // 古いロード結果を捨てるため
    var loadMs: Double = 0
    var status = "no model"
    var lastError = ""
    var inputsInfo: [[String: Any]] = []
    var outputsInfo: [[String: Any]] = []
    var functionNames: [String] = []
    var assetMeta: [String: Any] = [:]

    // 推論
    var busy = false
    var submits: UInt64 = 0
    var results: UInt64 = 0
    var inferMs: Double = 0
    var stage = ""                  // 診断用: 推論のどこまで進んだか
    var preMs: Double = 0, runMs: Double = 0, postMs: Double = 0   // 前処理 / 推論本体 / 出力回収
    var serial: UInt64 = 0
    fileprivate var latest: [String: OutputTensor] = [:]

    // MARK: ロード

    func requestLoad(path: String, fn: String, units: Int) {
        lock.lock()
        modelPath = path; functionName = fn; computeUnits = units
        loaded = false; function = nil; model = nil
        latest = [:]
        serial = 0              // 結果無し = 0(TOP 側の「結果はあるのに画像でない」判定に使う)
        loadSerial &+= 1
        let mySerial = loadSerial
        if path.isEmpty {
            status = "no model"; loading = false
            lock.unlock()
            return
        }
        loading = true
        busy = false            // 前のモデルの推論が宙に浮いていても、新しいモデルで投入できるように
        status = "loading"
        lastError = ""
        lock.unlock()

        Task.detached { [self] in
            let t0 = Date()
            var opts = SpecializationOptions.default
            switch units {
            case 1: opts = .cpuOnly
            case 2: opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
            case 3: opts = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
            default: break
            }
            do {
                let url = URL(fileURLWithPath: path)
                // メタデータ(著者/ライセンス/説明)は失敗しても致命ではない
                var meta: [String: Any] = [:]
                if let asset = try? AIModelAsset(contentsOf: url) {
                    let m = asset.metadata
                    let mirror = Mirror(reflecting: m)
                    // Metadata は storage 1つを持つ struct。文字列プロパティだけ拾う
                    if let storage = mirror.children.first?.value {
                        for c in Mirror(reflecting: storage).children {
                            if let k = c.label, let v = c.value as? String { meta[k] = v }
                            else if let k = c.label, let v = (c.value as? String?) ?? nil { meta[k] = v }
                        }
                    }
                }
                let m = try await AIModel(contentsOf: url, options: opts)
                let names = m.functionNames
                let target = names.contains(fn) ? fn : (names.first ?? fn)
                guard let f = try m.loadFunction(named: target) else {
                    throw NSError(domain: "CoreAIHelper", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "function '\(target)' not found (\(names))"])
                }
                let d = f.descriptor
                let ins = d.inputNames.map { describeValue(name: $0, d.inputDescriptor(of: $0)) }
                let outs = d.outputNames.map { describeValue(name: $0, d.outputDescriptor(of: $0)) }
                let ms = Date().timeIntervalSince(t0) * 1000
                lock.lock()
                if loadSerial == mySerial {
                    model = m; function = f; loaded = true; loading = false
                    functionName = target
                    functionNames = names
                    inputsInfo = ins; outputsInfo = outs
                    assetMeta = meta
                    loadMs = ms
                    status = "ready"
                }
                lock.unlock()
            } catch {
                lock.lock()
                if loadSerial == mySerial {
                    loading = false; loaded = false
                    lastError = "\(error)"
                    status = "error: \(error.localizedDescription)"
                }
                lock.unlock()
            }
        }
    }

    // MARK: 推論

    /// bgra は top-down・非事前乗算の BGRA8。busy なら false(取りこぼしは cook 側が次フレームで再投入)
    func submit(bgra: UnsafePointer<UInt8>, w: Int, h: Int, normalize: Int) -> Bool {
        lock.lock()
        guard loaded, let fn = function, !busy else { lock.unlock(); return false }
        busy = true
        submits &+= 1
        lock.unlock()

        // 画素はコピーして Task に渡す(呼び出し元のバッファは cook 後に消える)
        let pixels = [UInt8](UnsafeBufferPointer(start: bgra, count: w * h * 4))
        Task.detached { [self] in
            let t0 = Date()
            lock.lock(); stage = "preprocess"; lock.unlock()
            do {
                let d = fn.descriptor
                var inputs: [String: NDArray] = [:]
                var imageAssigned = false
                for name in d.inputNames {
                    guard let desc = d.inputDescriptor(of: name) else { continue }
                    switch desc {
                    case .ndArray(let nd):
                        if !imageAssigned, let arr = makeImageTensor(nd, pixels: pixels, w: w, h: h, normalize: normalize) {
                            inputs[name] = arr
                            imageAssigned = true
                        } else {
                            // 画像でない入力はゼロ埋め(形だけ合わせる)。将来 CHOP/DAT 入力で埋める
                            inputs[name] = NDArray(shape: nd.shape, scalarType: nd.scalarType)
                        }
                    case .image(let img):
                        if !imageAssigned {
                            // CVPixelBuffer 入力: NDArray 経由では渡せないので Inputs を組む
                            // (現状は NDArray 経路のみ対応。image 入力はエラーにして明示する)
                            throw NSError(domain: "CoreAIHelper", code: 2, userInfo: [NSLocalizedDescriptionKey:
                                "input '\(name)' is an image (\(img.width)x\(img.height)); pixel-buffer inputs are not supported yet"])
                        }
                    @unknown default:
                        continue
                    }
                }
                if !imageAssigned {
                    throw NSError(domain: "CoreAIHelper", code: 3, userInfo: [NSLocalizedDescriptionKey:
                        "function has no image-shaped input (rank 3-5 with a 1/3/4 channel dim)"])
                }
                let t1 = Date()
                lock.lock(); stage = "run"; lock.unlock()
                var outs = try await fn.run(inputs: inputs)
                let t2 = Date()
                lock.lock(); stage = "collect"; lock.unlock()
                var got: [String: OutputTensor] = [:]
                for name in Array(outs.names) {
                    guard let v = outs.remove(name), let nd = v.ndArray else { continue }
                    if let t = tensorFrom(nd) { got[name] = t }
                }
                let t3 = Date()
                let ms = t3.timeIntervalSince(t0) * 1000
                lock.lock()
                preMs = t1.timeIntervalSince(t0) * 1000
                runMs = t2.timeIntervalSince(t1) * 1000
                postMs = t3.timeIntervalSince(t2) * 1000
                latest = got
                serial &+= 1
                results &+= 1
                inferMs = ms
                busy = false
                if status.hasPrefix("error") { status = "ready" }
                lock.unlock()
            } catch {
                lock.lock()
                busy = false
                lastError = "\(error)"
                status = "error: \(error.localizedDescription)"
                lock.unlock()
            }
        }
        return true
    }

    // MARK: 状態 JSON

    func statusJSON() -> String {
        lock.lock(); defer { lock.unlock() }
        var o: [String: Any] = [
            "status": status, "stage": stage, "loaded": loaded, "loading": loading, "busy": busy,
            "submits": submits, "results": results, "serial": serial,
            "load_ms": loadMs, "infer_ms": inferMs, "pre_ms": preMs, "run_ms": runMs, "post_ms": postMs,
            "function": functionName, "functions": functionNames,
            "inputs": inputsInfo, "outputs": outputsInfo,
            "compute_units": ["auto", "cpu", "gpu", "ane"][max(0, min(3, computeUnits))],
            "device": AIModel.deviceArchitectureName,
            "available_units": ComputeUnitKind.availableKinds.map { "\($0)" }.sorted(),
            "metadata": assetMeta,
        ]
        if !lastError.isEmpty { o["error"] = lastError }
        return jsonString(o)
    }

    // MARK: 出力の取り出し

    /// 出力名(空なら最初の出力)を画像として解釈できるか。できれば w/h/c を返す
    fileprivate func imageInfo(name: String, channel: Int) -> (String, ImageLayout, UInt64)? {
        lock.lock(); defer { lock.unlock() }
        let key = name.isEmpty ? (outputsInfo.first?["name"] as? String ?? "") : name
        guard let t = latest[key], let lay = imageLayout(t.shape) else { return nil }
        return (key, lay, serial)
    }

    /// RGBA32F(w*h*4)へ書き出す。mode 0=auto(min-max) 1=raw 2=manual。channel -1=auto
    func copyImage(name: String, dst: UnsafeMutablePointer<Float>, mode: Int, lo: Float, hi: Float,
                   invert: Bool, channel: Int, flip: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = name.isEmpty ? (outputsInfo.first?["name"] as? String ?? "") : name
        guard let t = latest[key], let lay = imageLayout(t.shape) else { return false }
        let w = lay.w, h = lay.h, c = lay.c
        // 取り出すチャンネル集合
        var chans: [Int]
        if channel >= 0 { chans = [min(channel, c - 1)] }
        else if c == 1 || c == 3 || c == 4 { chans = Array(0..<c) }
        else if c == 2 { chans = [0, 1] }
        else { chans = [0] }   // 5ch以上は先頭だけ(意味のある表示にならない)
        // レンジ
        var vlo = lo, vhi = hi
        if mode == 0 {
            var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude
            for ch in chans {
                for y in 0..<h { for x in 0..<w {
                    let v = sample(t, lay, ch, x, y)
                    if v.isFinite { mn = min(mn, v); mx = max(mx, v) }
                } }
            }
            vlo = mn; vhi = mx
        } else if mode == 1 { vlo = 0; vhi = 1 }
        let scale: Float = (vhi - vlo) != 0 ? 1 / (vhi - vlo) : 1
        for y in 0..<h {
            let dy = flip ? (h - 1 - y) : y
            for x in 0..<w {
                var px: [Float] = [0, 0, 0, 1]
                for (i, ch) in chans.enumerated() where i < 4 {
                    var v = (sample(t, lay, ch, x, y) - vlo) * scale
                    if !v.isFinite { v = 0 }
                    if invert { v = 1 - v }
                    px[i] = v
                }
                if chans.count == 1 { px[1] = px[0]; px[2] = px[0] }
                let o = (dy * w + x) * 4
                dst[o] = px[0]; dst[o + 1] = px[1]; dst[o + 2] = px[2]; dst[o + 3] = px[3]
            }
        }
        return true
    }

    /// 出力を平坦な Float 配列として取り出す(CHOP 用)。戻り値は要素数(dst が nil なら数だけ)
    func copyFlat(name: String, dst: UnsafeMutablePointer<Float>?, capacity: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let key = name.isEmpty ? (outputsInfo.first?["name"] as? String ?? "") : name
        guard let t = latest[key] else { return 0 }
        if let dst { let n = min(capacity, t.data.count); t.data.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: n) } }
        return t.data.count
    }

    // MARK: 内部

    private func sample(_ t: OutputTensor, _ lay: ImageLayout, _ ch: Int, _ x: Int, _ y: Int) -> Float {
        let i = lay.chw ? lay.base + (ch * lay.h + y) * lay.w + x
                        : lay.base + (y * lay.w + x) * lay.c + ch
        return i < t.data.count ? t.data[i] : 0
    }
}

@available(macOS 27.0, *)
fileprivate func describeValue(name: String, _ d: InferenceValue.Descriptor?) -> [String: Any] {
    var o: [String: Any] = ["name": name]
    guard let d else { o["kind"] = "unknown"; return o }
    switch d {
    case .ndArray(let nd):
        o["kind"] = "ndarray"; o["shape"] = nd.shape; o["dtype"] = "\(nd.scalarType)"
        o["dynamic"] = nd.hasDynamicShape
    case .image(let im):
        o["kind"] = "image"; o["shape"] = [im.height, im.width]
        o["dtype"] = fourcc(im.pixelFormatType)
    @unknown default:
        o["kind"] = "unknown"
    }
    return o
}

fileprivate func fourcc(_ t: OSType) -> String {
    let b = [UInt8((t >> 24) & 0xff), UInt8((t >> 16) & 0xff), UInt8((t >> 8) & 0xff), UInt8(t & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? String(t)
}

/// 出力 shape を画像として解釈する。[H,W] / [C,H,W] / [H,W,C] / [1,...] / [1,V,C,H,W](先頭ビュー)
fileprivate func imageLayout(_ shape: [Int]) -> ImageLayout? {
    var s = shape
    // 先頭のバッチ次元 1 を落とす
    while s.count > 2 && s[0] == 1 { s.removeFirst() }
    switch s.count {
    case 2:
        return ImageLayout(w: s[1], h: s[0], c: 1, chw: true, base: 0)
    case 3:
        if s[0] <= 4 { return ImageLayout(w: s[2], h: s[1], c: s[0], chw: true, base: 0) }
        if s[2] <= 4 { return ImageLayout(w: s[1], h: s[0], c: s[2], chw: false, base: 0) }
        // [V,H,W] のような多ビュー深度: 各「チャンネル」= ビュー扱い
        return ImageLayout(w: s[2], h: s[1], c: s[0], chw: true, base: 0)
    case 4:
        // [V,C,H,W]: 先頭ビューだけ
        if s[1] <= 4 { return ImageLayout(w: s[3], h: s[2], c: s[1], chw: true, base: 0) }
        return nil
    default:
        return nil
    }
}

/// NDArray → Float 配列(dtype を吸収)
@available(macOS 27.0, *)
fileprivate func tensorFrom(_ ndIn: NDArray) -> OutputTensor? {
    var nd = ndIn
    let shape = nd.shape
    let n = shape.reduce(1, *)
    guard n > 0 else { return nil }
    let dtype = "\(nd.scalarType)"
    var out = [Float](repeating: 0, count: n)
    switch nd.scalarType {
    case .float32:
        nd.mutableView(as: Float32.self).withUnsafeMutablePointer { p, _, _ in
            for i in 0..<n { out[i] = p[i] }
        }
    case .float16:
        nd.mutableView(as: Float16.self).withUnsafeMutablePointer { p, _, _ in
            for i in 0..<n { out[i] = Float(p[i]) }
        }
    case .int32:
        nd.mutableView(as: Int32.self).withUnsafeMutablePointer { p, _, _ in
            for i in 0..<n { out[i] = Float(p[i]) }
        }
    case .uint8:
        nd.mutableView(as: UInt8.self).withUnsafeMutablePointer { p, _, _ in
            for i in 0..<n { out[i] = Float(p[i]) }
        }
    case .bool:
        nd.mutableView(as: Bool.self).withUnsafeMutablePointer { p, _, _ in
            for i in 0..<n { out[i] = p[i] ? 1 : 0 }
        }
    default:
        return nil
    }
    // 注意: 上は連続(strides = 既定)前提。CoreAI の出力は ioSurface/bytes とも
    // 実測で連続だった(da3 / edsr / yolos)。非連続が来たら strides を見て直す
    return OutputTensor(shape: shape, dtype: dtype, data: out)
}

/// 入力 TOP(BGRA8 top-down)→ モデルの入力テンソル。
/// [1,3,H,W] / [1,H,W,3] / [1,V,3,H,W](全ビューに同じ画像)/ [3,H,W] に対応
/// 前処理は毎フレーム走るので、vImage のリサイズ + LUT + 生ポインタで書く
/// (Swift 配列の添字アクセスで書いた初版は 1280x720→224 で 116ms かかった。実測)
@available(macOS 27.0, *)
fileprivate func makeImageTensor(_ nd: NDArrayDescriptor, pixels: [UInt8], w: Int, h: Int, normalize: Int) -> NDArray? {
    let shape = nd.shape
    guard shape.count >= 3, shape.count <= 5, !nd.hasDynamicShape else { return nil }
    // レイアウト判定
    var s = shape
    var lead = 1                       // 先頭の複製回数(バッチ×ビュー)
    while s.count > 3 { lead *= s[0]; s.removeFirst() }
    let chw: Bool
    let C: Int, H: Int, W: Int
    if s[0] == 3 || s[0] == 1 { chw = true; C = s[0]; H = s[1]; W = s[2] }
    else if s[2] == 3 || s[2] == 1 { chw = false; H = s[0]; W = s[1]; C = s[2] }
    else { return nil }
    guard W > 0, H > 0 else { return nil }

    // BGRA → 目的サイズ(vImage・Lanczos)。BGRA のまま縮小し、チャンネル並びは LUT 適用時に直す
    guard let bgra = resampleBGRA(pixels, w, h, W, H) else { return nil }

    // 正規化を 256 エントリの LUT に(チャンネル別)
    var mean: [Float] = [0, 0, 0], sdv: [Float] = [1, 1, 1], scale: Float = 1 / 255
    switch normalize {
    case 1: mean = [0.5, 0.5, 0.5]; sdv = [0.5, 0.5, 0.5]                      // -1..1
    case 2: mean = [0.485, 0.456, 0.406]; sdv = [0.229, 0.224, 0.225]          // ImageNet
    case 3: scale = 1                                                           // 0..255
    default: break                                                              // 0..1
    }
    var lut = [Float](repeating: 0, count: 3 * 256)
    for c in 0..<3 { for v in 0..<256 { lut[c * 256 + v] = (Float(v) * scale - mean[c]) / sdv[c] } }

    let plane = W * H
    let per = C * plane
    let total = lead * per
    var f = [Float](repeating: 0, count: total)
    f.withUnsafeMutableBufferPointer { fp in
        bgra.withUnsafeBufferPointer { bp in
            lut.withUnsafeBufferPointer { lp in
                let src = bp.baseAddress!, dst = fp.baseAddress!, l = lp.baseAddress!
                if C == 1 {
                    // グレー化(BT.601)は LUT の後で混ぜる
                    for i in 0..<plane {
                        let p = i * 4
                        let r = l[Int(src[p + 2])], g = l[256 + Int(src[p + 1])], b = l[512 + Int(src[p])]
                        dst[i] = r * 0.299 + g * 0.587 + b * 0.114
                    }
                } else if chw {
                    let dR = dst, dG = dst + plane, dB = dst + 2 * plane
                    for i in 0..<plane {
                        let p = i * 4
                        dR[i] = l[Int(src[p + 2])]
                        dG[i] = l[256 + Int(src[p + 1])]
                        dB[i] = l[512 + Int(src[p])]
                    }
                } else {
                    for i in 0..<plane {
                        let p = i * 4, q = i * 3
                        dst[q] = l[Int(src[p + 2])]
                        dst[q + 1] = l[256 + Int(src[p + 1])]
                        dst[q + 2] = l[512 + Int(src[p])]
                    }
                }
                if lead > 1 {
                    for k in 1..<lead { (dst + k * per).update(from: dst, count: per) }
                }
            }
        }
    }
    // NDArray(scalars:) は 30万要素で 63ms かかる(実測・要素ごとの処理)。
    // 形だけ確保して mutableView へ memcpy すると 0.1ms
    switch nd.scalarType {
    case .float32:
        var out = NDArray(shape: shape, scalarType: .float32)
        out.mutableView(as: Float32.self).withUnsafeMutablePointer { p, _, _ in
            f.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: total) }
        }
        return out
    case .float16:
        var out = NDArray(shape: shape, scalarType: .float16)
        out.mutableView(as: Float16.self).withUnsafeMutablePointer { p, _, _ in
            for i in 0..<total { p[i] = Float16(f[i]) }
        }
        return out
    default: return nil
    }
}

/// BGRA8(top-down)を W×H の BGRA8 に縮小/拡大(vImage Lanczos)。行順はそのまま
fileprivate func resampleBGRA(_ bgra: [UInt8], _ sw: Int, _ sh: Int, _ dw: Int, _ dh: Int) -> [UInt8]? {
    if sw == dw && sh == dh { return bgra }
    var dst = [UInt8](repeating: 0, count: dw * dh * 4)
    var src = bgra
    let err: vImage_Error = src.withUnsafeMutableBytes { sp in
        dst.withUnsafeMutableBytes { dp in
            var sb = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: sw * 4)
            var db = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dw * 4)
            return vImageScale_ARGB8888(&sb, &db, nil, vImage_Flags(kvImageHighQualityResampling))
        }
    }
    return err == kvImageNoError ? dst : nil
}
#endif

// MARK: - C ABI

private final class Box { var any: AnyObject? }

@_cdecl("ai_create") public func ai_create() -> UnsafeMutableRawPointer {
    let b = Box()
    #if canImport(CoreAI)
    if #available(macOS 27.0, *) { b.any = AIState() }
    #endif
    return Unmanaged.passRetained(b).toOpaque()
}

@_cdecl("ai_destroy") public func ai_destroy(_ p: UnsafeMutableRawPointer?) {
    guard let p else { return }
    Unmanaged<Box>.fromOpaque(p).release()
}

#if canImport(CoreAI)
@available(macOS 27.0, *)
private func state(_ p: UnsafeMutableRawPointer?) -> AIState? {
    guard let p else { return nil }
    return Unmanaged<Box>.fromOpaque(p).takeUnretainedValue().any as? AIState
}
#endif

/// モデルをロード(非同期)。path が変わったときだけ呼ぶ
@_cdecl("ai_load") public func ai_load(_ p: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?,
                                       _ fn: UnsafePointer<CChar>?, _ units: Int32) {
    #if canImport(CoreAI)
    if #available(macOS 27.0, *), let s = state(p) {
        s.requestLoad(path: path.map { String(cString: $0) } ?? "",
                      fn: fn.map { String(cString: $0) } ?? "main", units: Int(units))
    }
    #endif
}

/// 画像を投入。busy なら 0
@_cdecl("ai_submit") public func ai_submit(_ p: UnsafeMutableRawPointer?, _ bgra: UnsafePointer<UInt8>?,
                                           _ w: Int32, _ h: Int32, _ normalize: Int32) -> Int32 {
    #if canImport(CoreAI)
    if #available(macOS 27.0, *), let s = state(p), let bgra, w > 0, h > 0 {
        return s.submit(bgra: bgra, w: Int(w), h: Int(h), normalize: Int(normalize)) ? 1 : 0
    }
    #endif
    return 0
}

/// 状態 JSON(呼び出し側が free する)
@_cdecl("ai_status_json") public func ai_status_json(_ p: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    #if canImport(CoreAI)
    if #available(macOS 27.0, *), let s = state(p) { return strdup(s.statusJSON()) }
    #endif
    return strdup("{\"status\":\"unavailable: Core AI requires macOS 27+\",\"loaded\":false,\"busy\":false,\"inputs\":[],\"outputs\":[]}")
}

/// 選んだ出力が画像として取り出せるか。可能なら w/h/c/serial を返して 1
@_cdecl("ai_image_info") public func ai_image_info(_ p: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?,
                                                   _ channel: Int32, _ w: UnsafeMutablePointer<Int32>?, _ h: UnsafeMutablePointer<Int32>?,
                                                   _ c: UnsafeMutablePointer<Int32>?, _ serial: UnsafeMutablePointer<UInt64>?) -> Int32 {
    #if canImport(CoreAI)
    if #available(macOS 27.0, *), let s = state(p),
       let (_, lay, ser) = s.imageInfo(name: name.map { String(cString: $0) } ?? "", channel: Int(channel)) {
        w?.pointee = Int32(lay.w); h?.pointee = Int32(lay.h); c?.pointee = Int32(lay.c); serial?.pointee = ser
        return 1
    }
    #endif
    return 0
}

/// 出力を RGBA32F へ書き出す
@_cdecl("ai_copy_image") public func ai_copy_image(_ p: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?,
                                                   _ dst: UnsafeMutablePointer<Float>?, _ mode: Int32, _ lo: Float, _ hi: Float,
                                                   _ invert: Int32, _ channel: Int32, _ flip: Int32) -> Int32 {
    #if canImport(CoreAI)
    if #available(macOS 27.0, *), let s = state(p), let dst {
        return s.copyImage(name: name.map { String(cString: $0) } ?? "", dst: dst, mode: Int(mode), lo: lo, hi: hi,
                           invert: invert != 0, channel: Int(channel), flip: flip != 0) ? 1 : 0
    }
    #endif
    return 0
}

/// 出力を平坦な float 配列として取り出す(dst が nil なら要素数だけ返す)
@_cdecl("ai_copy_flat") public func ai_copy_flat(_ p: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?,
                                                 _ dst: UnsafeMutablePointer<Float>?, _ capacity: Int32) -> Int32 {
    #if canImport(CoreAI)
    if #available(macOS 27.0, *), let s = state(p) {
        return Int32(s.copyFlat(name: name.map { String(cString: $0) } ?? "", dst: dst, capacity: Int(capacity)))
    }
    #endif
    return 0
}

/// 数値の診断値をまとめて返す(Info CHOP 用・JSON を毎cook解析しないため)
/// v[0]=loaded v[1]=loading v[2]=busy v[3]=submits v[4]=results v[5]=infer_ms v[6]=load_ms v[7]=serial
/// v[8]=pre_ms v[9]=run_ms v[10]=post_ms(要素数 11)
@_cdecl("ai_stats") public func ai_stats(_ p: UnsafeMutableRawPointer?, _ v: UnsafeMutablePointer<Double>?) {
    guard let v else { return }
    for i in 0..<11 { v[i] = 0 }
    #if canImport(CoreAI)
    if #available(macOS 27.0, *), let s = state(p) {
        s.lock.lock(); defer { s.lock.unlock() }
        v[0] = s.loaded ? 1 : 0; v[1] = s.loading ? 1 : 0; v[2] = s.busy ? 1 : 0
        v[3] = Double(s.submits); v[4] = Double(s.results); v[5] = s.inferMs; v[6] = s.loadMs
        v[7] = Double(s.serial)
        v[8] = s.preMs; v[9] = s.runMs; v[10] = s.postMs
    }
    #endif
}

/// Info DAT 用の表(行=\n・列=\t)。呼び出し側が free する
/// 列: key / name / kind / dtype / shape
@_cdecl("ai_info_tsv") public func ai_info_tsv(_ p: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    var rows: [String] = []
    #if canImport(CoreAI)
    if #available(macOS 27.0, *), let s = state(p) {
        s.lock.lock(); defer { s.lock.unlock() }
        rows.append("status\t\(s.status)\t\t\t")
        if !s.stage.isEmpty { rows.append("stage\t\(s.stage)\t\t\t") }
        rows.append("model\t\(s.modelPath)\t\t\t")
        rows.append("function\t\(s.functionName)\t\t\t")
        rows.append("functions\t\(s.functionNames.joined(separator: ", "))\t\t\t")
        rows.append("compute_units\t\(["auto", "cpu", "gpu", "ane"][max(0, min(3, s.computeUnits))])\t\t\t")
        rows.append("device\t\(AIModel.deviceArchitectureName)\t\t\t")
        for k in ["description", "author", "license", "producer", "assetVersion"] {
            if let v = s.assetMeta[k] as? String, !v.isEmpty {
                rows.append("\(k)\t\(v.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " "))\t\t\t")
            }
        }
        func shapeStr(_ o: [String: Any]) -> String {
            guard let sh = o["shape"] as? [Int] else { return "" }
            return "[" + sh.map(String.init).joined(separator: ",") + "]"
        }
        for o in s.inputsInfo {
            rows.append("input\t\(o["name"] as? String ?? "")\t\(o["kind"] as? String ?? "")\t\(o["dtype"] as? String ?? "")\t\(shapeStr(o))")
        }
        for o in s.outputsInfo {
            rows.append("output\t\(o["name"] as? String ?? "")\t\(o["kind"] as? String ?? "")\t\(o["dtype"] as? String ?? "")\t\(shapeStr(o))")
        }
        if !s.lastError.isEmpty { rows.append("error\t\(s.lastError.replacingOccurrences(of: "\n", with: " "))\t\t\t") }
    } else {
        rows.append("status\tunavailable: Core AI requires macOS 27+\t\t\t")
    }
    #else
    rows.append("status\tunavailable: built without CoreAI\t\t\t")
    #endif
    return strdup(rows.joined(separator: "\n"))
}

/// 出力名の一覧(\n 区切り)。呼び出し側が free する
@_cdecl("ai_output_names") public func ai_output_names(_ p: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    #if canImport(CoreAI)
    if #available(macOS 27.0, *), let s = state(p) {
        s.lock.lock(); defer { s.lock.unlock() }
        return strdup(s.outputsInfo.compactMap { $0["name"] as? String }.joined(separator: "\n"))
    }
    #endif
    return strdup("")
}
