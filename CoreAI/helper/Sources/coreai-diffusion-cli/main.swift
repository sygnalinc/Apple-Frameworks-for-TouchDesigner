// CoreAI ImageGen TOP のヘルパ(別プロセス)。Apple coreai-models の CoreAIDiffusion で
// SD 1.x / 2.x / SD3 / FLUX.2 のバンドル(exports/<name>/)を回す。
//
// プロトコル(JSON-lines・stdin→stdout):
//   in : {"cmd":"load","model":<dir>,"decode":"auto|full|half|tiled"}
//        {"cmd":"gen","prompt","negative","steps","guidance","seed","strength",
//                     "image":<raw RGBA8 path or "">,"imagew","imageh","out":<raw RGBA8 path>}
//        {"cmd":"quit"}
//   out: {"type":"status","text"} / {"type":"progress","pct"}
//        {"type":"ready","kind","name","width","height","steps","guidance","img2img","decode"}
//        {"type":"step","step","total"} / {"type":"done","width","height","seconds","serial"}
//        {"type":"error","text"}
//
// 画像はファイル経由の生 RGBA8(top-down)でやり取りする。PNG エンコードを挟まない。
// パイプラインは常駐(lazyModelLoading=false)。diffusion-runner は生成ごとにロード/アンロード
// するので 1 枚に 1〜2 分かかるが、常駐すれば 2 枚目以降はデノイズだけになる。
import CoreAI
import CoreAIDiffusionPipeline
import CoreAIShared
import CoreGraphics
import Foundation
import ImageIO

setvbuf(stdout, nil, _IONBF, 0)

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) {
        print(s)
    }
}

// 生 RGBA8(top-down)→ CGImage
func rgbaToCGImage(_ data: Data, width: Int, height: Int) -> CGImage? {
    guard data.count >= width * height * 4 else { return nil }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

// CGImage → 生 RGBA8(top-down)
func cgImageToRGBA(_ img: CGImage) -> Data {
    let w = img.width, h = img.height
    var buf = Data(count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return buf
}

enum Loaded {
    case sd(StableDiffusionPipeline)
    case sd3(SD3Pipeline)
    case flux2(Flux2Pipeline)

    var kind: String {
        switch self { case .sd: return "sd"; case .sd3: return "sd3"; case .flux2: return "flux2" }
    }
    var size: (width: Int, height: Int) {
        switch self {
        case .sd(let p): return p.defaultImageSize
        case .sd3(let p): return p.defaultImageSize
        case .flux2(let p): return p.defaultImageSize
        }
    }
    var img2img: Bool {
        switch self {
        case .sd(let p): return p.supportsImageToImage
        case .sd3(let p): return p.supportsImageToImage
        case .flux2(let p): return p.supportsImageToImage
        }
    }
    /// FLUX.2 の img2img はバンドルに入っている参照グリッド(full / half / quarter)しか使えない。
    /// 実測: 512 書き出し(Transformer_512_img2img_half)は half のみ。full を頼むと
    /// unsupportedConfiguration になるので、あるものの中で一番細かいものを選ぶ
    var bestReferenceGrid: ReferenceGrid {
        if case .flux2(let p) = self {
            for g in [ReferenceGrid.full, .half, .quarter] where p.img2imgRoutes[g] != nil { return g }
        }
        return .full
    }
    func loadResources() async throws {
        switch self {
        case .sd(let p): try await p.loadResources()
        case .sd3(let p): try await p.loadResources()
        case .flux2(let p): try await p.loadResources()
        }
    }
    func generate(_ c: PipelineConfiguration, _ h: (PipelineProgress) -> Bool) async throws -> GenerationResult {
        switch self {
        case .sd(let p): return try await p.generateImages(configuration: c, progressHandler: h)
        case .sd3(let p): return try await p.generateImages(configuration: c, progressHandler: h)
        case .flux2(let p): return try await p.generateImages(configuration: c, progressHandler: h)
        }
    }
}

struct Model {
    let pipeline: Loaded
    let descriptor: PipelineDescriptor
    let decode: DecodeResolution
    let lazy: Bool   // true = 段階ごとにロード/アンロード(省メモリ・毎回ロード時間が乗る)
}

func loadModel(_ dir: String, decodeName: String, lazy: Bool = false) async throws -> Model {
    let url = URL(fileURLWithPath: dir)
    let decode = DecodeResolution(rawValue: decodeName) ?? .auto
    let descriptor = try PipelineDescriptor.resolve(at: url, config: .auto)
    emit(["type": "status", "text": "loading \(descriptor.type?.rawValue ?? "pipeline")"])
    emit(["type": "progress", "pct": 10])
    let loaded: Loaded
    switch descriptor.type {
    case .flux2:
        loaded = .flux2(try await Flux2Pipeline(from: url, config: .auto, mode: decode))
    case .stableDiffusion3:
        loaded = .sd3(try await SD3Pipeline(from: url, config: .auto))
    default:
        loaded = .sd(try await StableDiffusionPipeline.load(from: url, config: .auto))
    }
    emit(["type": "progress", "pct": 40])
    if !lazy {
        emit(["type": "status", "text": "compiling model (first load takes minutes)"])
        try await loaded.loadResources()   // 常駐: 生成ごとにロードし直さない
    }
    emit(["type": "progress", "pct": 100])
    return Model(pipeline: loaded, descriptor: descriptor, decode: decode, lazy: lazy)
}

func serve() async {
    var model: Model? = nil
    var loadedPath = ""
    var serial = 0
    emit(["type": "status", "text": "idle"])
    FileHandle.standardError.write(Data("coreai-diffusion-helper: serve mode ready\n".utf8))
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else { continue }
        switch cmd {
        case "quit":
            return
        case "load":
            let path = obj["model"] as? String ?? ""
            let decode = obj["decode"] as? String ?? "auto"
            let lazy = obj["lazy"] as? Bool ?? false
            if path.isEmpty { emit(["type": "error", "text": "model path is empty"]); continue }
            model = nil
            loadedPath = ""
            do {
                let m = try await loadModel(path, decodeName: decode, lazy: lazy)
                model = m; loadedPath = path
                let sz = m.pipeline.size
                emit(["type": "ready", "kind": m.pipeline.kind,
                      "name": URL(fileURLWithPath: path).lastPathComponent,
                      "width": sz.width, "height": sz.height,
                      "steps": m.descriptor.defaultSteps ?? 20,
                      "guidance": m.descriptor.defaultGuidanceScale ?? 7.5,
                      "img2img": m.pipeline.img2img, "decode": m.decode.rawValue])
            } catch {
                emit(["type": "error", "text": "load failed: \(error)"])
            }
        case "gen":
            guard let m = model else { emit(["type": "error", "text": "no model loaded"]); continue }
            let prompt = obj["prompt"] as? String ?? ""
            let negative = obj["negative"] as? String ?? ""
            let steps = obj["steps"] as? Int ?? (m.descriptor.defaultSteps ?? 20)
            let guidance = (obj["guidance"] as? Double).map { Float($0) } ?? (m.descriptor.defaultGuidanceScale ?? 7.5)
            let seedIn = obj["seed"] as? Int ?? 42
            let seed = seedIn < 0 ? UInt32.random(in: 0...UInt32.max) : UInt32(truncatingIfNeeded: seedIn)
            let strength = (obj["strength"] as? Double).map { Float($0) } ?? 0.85
            let outPath = obj["out"] as? String ?? ""
            var starting: CGImage? = nil
            if let ip = obj["image"] as? String, !ip.isEmpty,
               let w = obj["imagew"] as? Int, let h = obj["imageh"] as? Int,
               let d = try? Data(contentsOf: URL(fileURLWithPath: ip)) {
                starting = rgbaToCGImage(d, width: w, height: h)
                if starting == nil { emit(["type": "error", "text": "input image unreadable"]) }
            }
            if starting != nil && !m.pipeline.img2img {
                emit(["type": "status", "text": "this model has no img2img; ignoring input image"])
                starting = nil
            }
            let isFlow = (m.pipeline.kind != "sd")
            let config = PipelineConfiguration(
                prompt: prompt, negativePrompt: negative, seed: seed, stepCount: steps,
                guidanceScale: guidance,
                schedulerType: isFlow ? .discreteFlow : .dpmSolverMultistep,
                startingImage: starting, strength: strength,
                referenceGrid: m.pipeline.bestReferenceGrid, guidanceMode: .distilled,
                encoderScaleFactor: m.descriptor.encoderScaleFactor ?? 0.18215,
                decoderScaleFactor: m.descriptor.decoderScaleFactor ?? 0.18215,
                decoderShiftFactor: m.descriptor.decoderShiftFactor ?? 0.0,
                decodeResolution: m.decode,
                lazyModelLoading: m.lazy)
            emit(["type": "status", "text": "generating"])
            let t0 = Date()
            do {
                let result = try await m.pipeline.generate(config) { p in
                    // SD 系は 0 始まり、SD3/FLUX は 1 始まりなので 1..total に揃える
                    let s = m.pipeline.kind == "sd" ? p.step + 1 : p.step
                    emit(["type": "step", "step": s, "total": p.totalSteps])
                    return true
                }
                guard let img = result.images.first else {
                    emit(["type": "error", "text": "no image generated"]); continue
                }
                let rgba = cgImageToRGBA(img)
                try rgba.write(to: URL(fileURLWithPath: outPath))
                serial += 1
                emit(["type": "done", "width": img.width, "height": img.height,
                      "seconds": Date().timeIntervalSince(t0), "serial": serial, "seed": Int(seed)])
                emit(["type": "status", "text": "ready"])
            } catch {
                emit(["type": "error", "text": "generation failed: \(error)"])
            }
        default:
            emit(["type": "error", "text": "unknown cmd \(cmd)"])
        }
    }
    _ = loadedPath
}

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "--serve" {
    await serve()
} else if args.count >= 3 {
    // 単体テスト: coreai-diffusion-cli <bundle> <prompt> [out.png] [decode]
    do {
        let m = try await loadModel(args[1], decodeName: args.count >= 5 ? args[4] : "auto")
        let sz = m.pipeline.size
        FileHandle.standardError.write(Data("loaded \(m.pipeline.kind) \(sz.width)x\(sz.height)\n".utf8))
        let isFlow = (m.pipeline.kind != "sd")
        for i in 0..<2 {   // 2枚回して「常駐すると2枚目が速い」ことを測る
            let t0 = Date()
            let cfg = PipelineConfiguration(prompt: args[2], seed: 42 + UInt32(i),
                stepCount: m.descriptor.defaultSteps ?? 20,
                guidanceScale: m.descriptor.defaultGuidanceScale ?? 7.5,
                schedulerType: isFlow ? .discreteFlow : .dpmSolverMultistep,
                encoderScaleFactor: m.descriptor.encoderScaleFactor ?? 0.18215,
                decoderScaleFactor: m.descriptor.decoderScaleFactor ?? 0.18215,
                decoderShiftFactor: m.descriptor.decoderShiftFactor ?? 0.0,
                decodeResolution: m.decode, lazyModelLoading: false)
            let r = try await m.pipeline.generate(cfg) { _ in true }
            FileHandle.standardError.write(Data("image \(i): \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\n".utf8))
            if i == 0, args.count >= 4, let img = r.images.first,
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
            }
        }
    } catch {
        FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8)); exit(1)
    }
} else {
    FileHandle.standardError.write(Data("usage: coreai-diffusion-cli --serve | <bundle> <prompt> [out.png] [decode]\n".utf8))
    exit(2)
}
