// ImageGen TOP の Swift ヘルパ（libImageGenHelper.dylib）。
//
// Apple 公式 ml-stable-diffusion の StableDiffusionPipeline / StableDiffusionXLPipeline を
// C ABI（sd_*）で ObjC++ プラグインへ提供する。モデルフォルダに TextEncoder2.mlmodelc が
// あれば XL パイプラインを使う（自動判定）。
//
// C API:
//   sd_create(modelDir, computeUnits) セッション生成。非同期でモデルロード
//   sd_generate(...)                  text2img / img2img を非同期実行（busy 中は false）
//   sd_poll(h, buf, cap)              状態 JSON {status, busy, step, steps, imageSerial, w, h, genSeconds}
//   sd_copy_image(h, buf, cap)        最新画像の RGBA8 バイト列をコピー（行順は top-down）
//   sd_destroy(h)

import CoreGraphics
import CoreML
import Foundation
import StableDiffusion

// ------------------------------------------------------------------ session

enum SDPipe {
    case sd(StableDiffusionPipeline)
    case xl(StableDiffusionXLPipeline)
}

final class SDSession: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "sd.generate")
    private var pipe: SDPipe?
    private var status = "loading model"
    private var busy = true          // ロード中も busy 扱い
    private var step = 0
    private var steps = 0
    private var genSeconds = 0.0
    private var image: [UInt8] = []
    private var imageW = 0
    private var imageH = 0
    private var imageSerial = 0
    private var sampleSize = 512

    init(modelDir: String, computeUnits: Int32) {
        queue.async { [weak self] in self?.load(modelDir: modelDir, computeUnits: computeUnits) }
    }

    private func setStatus(_ s: String, busy b: Bool) {
        lock.lock()
        status = s
        busy = b
        lock.unlock()
    }

    private func load(modelDir: String, computeUnits: Int32) {
        do {
            let url = URL(fileURLWithPath: modelDir)
            let config = MLModelConfiguration()
            switch computeUnits {
            case 1: config.computeUnits = .cpuAndGPU
            case 2: config.computeUnits = .all
            default: config.computeUnits = .cpuAndNeuralEngine
            }
            let isXL = FileManager.default.fileExists(
                atPath: url.appendingPathComponent("TextEncoder2.mlmodelc").path)
            lock.lock()
            sampleSize = isXL ? 1024 : 512
            lock.unlock()
            if isXL {
                let p = try StableDiffusionXLPipeline(
                    resourcesAt: url, configuration: config, reduceMemory: false)
                try p.loadResources()
                lock.lock()
                pipe = .xl(p)
                lock.unlock()
            } else {
                let p = try StableDiffusionPipeline(
                    resourcesAt: url, controlNet: [], configuration: config,
                    disableSafety: true, reduceMemory: false)
                try p.loadResources()
                lock.lock()
                pipe = .sd(p)
                lock.unlock()
            }
            setStatus(isXL ? "ready (SDXL)" : "ready (SD)", busy: false)
        } catch {
            setStatus("load error: \(error.localizedDescription)", busy: false)
        }
    }

    // ---------------------------------------------------------- generate

    func generate(prompt: String, negative: String, stepCount: Int, guidance: Float,
                  seed: Int64, strength: Float, inputRGBA: [UInt8]?, inputW: Int, inputH: Int)
        -> Bool
    {
        lock.lock()
        if busy || pipe == nil {
            lock.unlock()
            return false
        }
        busy = true
        status = "generating"
        step = 0
        steps = stepCount
        lock.unlock()

        queue.async { [weak self] in
            self?.runGenerate(prompt: prompt, negative: negative, stepCount: stepCount,
                              guidance: guidance, seed: seed, strength: strength,
                              inputRGBA: inputRGBA, inputW: inputW, inputH: inputH)
        }
        return true
    }

    private func runGenerate(prompt: String, negative: String, stepCount: Int,
                             guidance: Float, seed: Int64, strength: Float,
                             inputRGBA: [UInt8]?, inputW: Int, inputH: Int)
    {
        let start = Date()
        let actualSeed: UInt32 =
            seed < 0 ? UInt32.random(in: 0...UInt32.max) : UInt32(truncatingIfNeeded: seed)
        lock.lock()
        let targetSize = sampleSize
        lock.unlock()
        let starting: CGImage? = inputRGBA.flatMap {
            Self.rgbaToCGImage($0, inputW, inputH, resizedTo: targetSize)
        }
        do {
            lock.lock()
            let pipeRef = pipe
            lock.unlock()
            guard let pipeRef else { return }

            let progress: (Int) -> Bool = { [weak self] s in
                guard let self else { return false }
                self.lock.lock()
                self.step = s
                self.lock.unlock()
                return true
            }

            var result: [CGImage?] = []
            switch pipeRef {
            case .sd(let p):
                var config = StableDiffusionPipeline.Configuration(prompt: prompt)
                config.negativePrompt = negative
                config.stepCount = stepCount
                config.guidanceScale = guidance
                config.seed = actualSeed
                config.imageCount = 1
                config.schedulerType = .dpmSolverMultistepScheduler
                if let starting {
                    config.startingImage = starting
                    config.strength = strength
                }
                result = try p.generateImages(configuration: config) { prog in
                    progress(prog.step)
                }
            case .xl(let p):
                var config = StableDiffusionXLPipeline.Configuration(prompt: prompt)
                config.negativePrompt = negative
                config.stepCount = stepCount
                config.guidanceScale = guidance
                config.seed = actualSeed
                config.imageCount = 1
                config.schedulerType = .dpmSolverMultistepScheduler
                if let starting {
                    config.startingImage = starting
                    config.strength = strength
                }
                result = try p.generateImages(configuration: config) { prog in
                    progress(prog.step)
                }
            }

            if let cg = result.compactMap({ $0 }).first,
               let converted = Self.cgImageToRGBA(cg) {
                lock.lock()
                image = converted.0
                imageW = converted.1
                imageH = converted.2
                imageSerial += 1
                genSeconds = Date().timeIntervalSince(start)
                status = String(format: "done (%.1fs, seed %u)", genSeconds, actualSeed)
                busy = false
                lock.unlock()
            } else {
                setStatus("generate failed (no image)", busy: false)
            }
        } catch {
            setStatus("generate error: \(error.localizedDescription)", busy: false)
        }
    }

    // ---------------------------------------------------------- image conv

    private static func rgbaToCGImage(_ rgba: [UInt8], _ w: Int, _ h: Int,
                                      resizedTo target: Int) -> CGImage? {
        guard w > 0, h > 0, rgba.count >= w * h * 4 else { return nil }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let src = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(
                                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true,
                                intent: .defaultIntent) else { return nil }
        if w == target && h == target { return src }
        // モデルのサンプルサイズへリサイズ（アスペクトは維持せず全面に引き伸ばす）
        guard let ctx = CGContext(
            data: nil, width: target, height: target, bitsPerComponent: 8,
            bytesPerRow: target * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return src }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: target, height: target))
        return ctx.makeImage() ?? src
    }

    private static func cgImageToRGBA(_ cg: CGImage) -> ([UInt8], Int, Int)? {
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

    // ---------------------------------------------------------- poll

    func pollJSON() -> String {
        lock.lock()
        let dict: [String: Any] = [
            "status": status,
            "busy": busy,
            "loaded": pipe != nil,
            "step": step,
            "steps": steps,
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

// ------------------------------------------------------------------ C ABI

@_cdecl("sd_create")
public func sd_create(_ modelDir: UnsafePointer<CChar>, _ computeUnits: Int32)
    -> UnsafeMutableRawPointer?
{
    let session = SDSession(modelDir: String(cString: modelDir), computeUnits: computeUnits)
    return Unmanaged.passRetained(session).toOpaque()
}

@_cdecl("sd_generate")
public func sd_generate(_ handle: UnsafeMutableRawPointer?,
                        _ prompt: UnsafePointer<CChar>?,
                        _ negative: UnsafePointer<CChar>?,
                        _ steps: Int32, _ guidance: Float, _ seed: Int64,
                        _ strength: Float,
                        _ inputRGBA: UnsafePointer<UInt8>?, _ inputW: Int32,
                        _ inputH: Int32) -> Bool
{
    guard let handle else { return false }
    let session = Unmanaged<SDSession>.fromOpaque(handle).takeUnretainedValue()
    var input: [UInt8]? = nil
    if let inputRGBA, inputW > 0, inputH > 0 {
        input = Array(UnsafeBufferPointer(start: inputRGBA, count: Int(inputW * inputH * 4)))
    }
    return session.generate(
        prompt: prompt.map { String(cString: $0) } ?? "",
        negative: negative.map { String(cString: $0) } ?? "",
        stepCount: Int(steps), guidance: guidance, seed: seed, strength: strength,
        inputRGBA: input, inputW: Int(inputW), inputH: Int(inputH))
}

@_cdecl("sd_poll")
public func sd_poll(_ handle: UnsafeMutableRawPointer?,
                    _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32
{
    guard let handle, let buffer, capacity > 0 else { return 0 }
    let session = Unmanaged<SDSession>.fromOpaque(handle).takeUnretainedValue()
    let json = session.pollJSON()
    let utf8 = Array(json.utf8.prefix(Int(capacity) - 1))
    memcpy(buffer, utf8, utf8.count)
    buffer[utf8.count] = 0
    return Int32(utf8.count)
}

@_cdecl("sd_copy_image")
public func sd_copy_image(_ handle: UnsafeMutableRawPointer?,
                          _ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int64) -> Int64
{
    guard let handle, let buffer else { return 0 }
    let session = Unmanaged<SDSession>.fromOpaque(handle).takeUnretainedValue()
    return Int64(session.copyImage(into: buffer, capacity: Int(capacity)))
}

@_cdecl("sd_destroy")
public func sd_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<SDSession>.fromOpaque(handle).release()
}
