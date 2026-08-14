// PhotogrammetryHelper.swift — RealityKit Object Capture を C ABI で包むヘルパ(ph_)
//
//   ph_create()                        ハンドル生成
//   ph_start(h, imgFolder, outPath, detail, splatPath, splatScale)
//                                      再構成開始(detail 0=preview..3=full)。
//                                      splatPath 非空なら pointCloud リクエストも同時実行し、
//                                      3DGS形式の .ply を書き出す(RealityKit Splat TOP で描画可)
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
    private var texture = ""
    private var convertTo: URL?
    private var splatPath = ""
    private var splatPoints = 0
    private var pendingRequests = 0
    private var wantSplatPath = ""
    private var wantSplatScale = 1.0

    // usdz(実体はzip)から焼き込みテクスチャを取り出し、
    // <出力名>_tex0.png 等に改名して並べる。mtl の usdz 内部参照も書き換える。
    // 戻り値は最初のテクスチャのパス(無ければ空)
    private func extractTextures(usdz: URL, obj: URL?) -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "tdappleml_tex_\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? fm.removeItem(at: tmp) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-j", usdz.path, "-d", tmp.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return ""
        }
        let base = (obj ?? usdz).deletingPathExtension()
        let exts = ["png", "jpg", "jpeg", "heic"]
        let images = ((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [])
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        var first = ""
        for (i, name) in images.enumerated() {
            let ext = (name as NSString).pathExtension.lowercased()
            let dst = URL(fileURLWithPath:
                "\(base.path)_tex\(i).\(ext)")
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: tmp.appendingPathComponent(name), to: dst)
            if i == 0 { first = dst.path }
        }
        // mtl の map_Kd を抽出したテクスチャへ書き換え(TDや他ツールで直接読めるように)
        if let obj, !first.isEmpty {
            let mtlURL = obj.deletingPathExtension().appendingPathExtension("mtl")
            if var mtl = try? String(contentsOf: mtlURL, encoding: .utf8) {
                let texName = URL(fileURLWithPath: first).lastPathComponent
                var lines = mtl.components(separatedBy: "\n")
                for i in lines.indices {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("map_Kd") {
                        lines[i] = "\tmap_Kd \(texName)"
                    }
                }
                mtl = lines.joined(separator: "\n")
                try? mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
            }
        }
        return first
    }

    func start(imageFolder: String, outputPath: String, detail: Int,
               splatOut: String, splatScale: Double) {
        cancel()
        lock.lock()
        status = "starting"; progress = 0; done = false; errorMsg = ""
        splatPath = ""; splatPoints = 0
        lock.unlock()
        self.wantSplatPath = splatOut
        self.wantSplatScale = splatScale

        let inputURL = URL(fileURLWithPath: imageFolder, isDirectory: true)
        // PhotogrammetrySession の modelFile 出力は USDZ のみ(.obj は invalidOutput・実測)。
        // .obj 指定時は一時 USDZ に出してから ModelIO で変換する
        let finalURL = URL(fileURLWithPath: outputPath)
        let wantsOBJ = finalURL.pathExtension.lowercased() == "obj"
        let outputURL = wantsOBJ
            ? finalURL.deletingPathExtension().appendingPathExtension("usdz")
            : finalURL
        self.convertTo = wantsOBJ ? finalURL : nil
        // 既存の出力があると invalidOutput になる(実測)ので先に消す
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: finalURL)
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
                            var texPath: String? = nil
                            if case .modelFile(let usdzURL) = result {
                                if let objURL = self.convertTo {
                                    do {
                                        let asset = MDLAsset(url: usdzURL)
                                        try asset.export(to: objURL)
                                        texPath = self.extractTextures(usdz: usdzURL,
                                                                       obj: objURL)
                                    } catch {
                                        convertError = "OBJ convert failed: \(error)"
                                    }
                                } else {
                                    // USDZ 直指定でもテクスチャは取り出しておく
                                    texPath = self.extractTextures(usdz: usdzURL, obj: nil)
                                }
                            }
                            // 点群 → 3DGS形式 .ply(RealityKit Splat TOP がそのまま描画できる)
                            var splatWritten = ""
                            var splatCount = 0
                            if #available(macOS 14.0, *),
                               case .pointCloud(let pc) = result, !self.wantSplatPath.isEmpty {
                                do {
                                    splatCount = try self.writeSplatPLY(
                                        pc, to: self.wantSplatPath,
                                        scaleFactor: self.wantSplatScale)
                                    splatWritten = self.wantSplatPath
                                } catch {
                                    convertError = "splat write failed: \(error)"
                                }
                            }
                            self.lock.lock()
                            self.pendingRequests -= 1
                            if self.pendingRequests <= 0 {
                                self.progress = 1.0
                                self.done = convertError.isEmpty
                                self.status = convertError.isEmpty ? "complete" : "error"
                            }
                            if !convertError.isEmpty {
                                self.errorMsg = convertError
                                self.status = "error"
                            }
                            if let t = texPath { self.texture = t }
                            if !splatWritten.isEmpty {
                                self.splatPath = splatWritten
                                self.splatPoints = splatCount
                            }
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
            var requests: [PhotogrammetrySession.Request] =
                [.modelFile(url: outputURL, detail: detailLevel)]
            if !wantSplatPath.isEmpty {
                if #available(macOS 14.0, *) {
                    try? FileManager.default.removeItem(atPath: wantSplatPath)
                    requests.append(.pointCloud)
                } else {
                    lock.lock(); errorMsg = "splat output requires macOS 14+"; lock.unlock()
                }
            }
            lock.lock(); pendingRequests = requests.count; lock.unlock()
            try s.process(requests: requests)
            lock.lock(); status = "processing"; lock.unlock()
        } catch {
            lock.lock()
            errorMsg = "\(error)"
            status = "error"
            lock.unlock()
        }
    }

    // Object Capture の点群 → 3DGS形式(INRIA互換)バイナリ .ply。
    // RealityKit Splat TOP がそのまま真のsplatとして描画できるレイアウトで書く:
    //   x,y,z,nx,ny,nz,f_dc_0..2,opacity,scale_0..2,rot_0..3(全float・LE)
    //   - f_dc = (color/255 - 0.5) / C0(SH DC逆変換。degree0で元色が再現される)
    //   - opacity = logit(0.95)(生値・レンダラの .sigmoid が適用)
    //   - scale = log(最近傍距離の中央値 × scaleFactor)(等方ガウシアン・生値・.exponential)
    //   - rot = 恒等クォータニオン(w,x,y,z = 1,0,0,0)
    @available(macOS 14.0, *)
    private func writeSplatPLY(_ pc: PhotogrammetrySession.PointCloud,
                               to path: String, scaleFactor: Double) throws -> Int {
        let pts = pc.points
        guard !pts.isEmpty else {
            throw NSError(domain: "splat", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "empty point cloud"])
        }
        // 最近傍距離の中央値をサンプルで推定(2000点の総当り・十分速い)
        let sampleN = min(2000, pts.count)
        let step = max(1, pts.count / sampleN)
        var sample: [SIMD3<Float>] = []
        sample.reserveCapacity(sampleN)
        for i in stride(from: 0, to: pts.count, by: step) { sample.append(pts[i].position) }
        var nnDists: [Float] = []
        nnDists.reserveCapacity(sample.count)
        for i in 0..<sample.count {
            var best = Float.greatestFiniteMagnitude
            for j in 0..<sample.count where j != i {
                let d = simd_distance_squared(sample[i], sample[j])
                if d < best { best = d }
            }
            if best.isFinite { nnDists.append(best.squareRoot()) }
        }
        nnDists.sort()
        let median = nnDists.isEmpty ? Float(0.01) : nnDists[nnDists.count / 2]
        let radius = max(median * Float(scaleFactor), 1e-6)
        let logScale = log(radius)
        let opacityLogit: Float = 2.944  // sigmoid^-1(0.95)
        let c0: Float = 0.28209479177387814

        var header = "ply\nformat binary_little_endian 1.0\n"
        header += "element vertex \(pts.count)\n"
        for n in ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2",
                  "opacity", "scale_0", "scale_1", "scale_2",
                  "rot_0", "rot_1", "rot_2", "rot_3"] {
            header += "property float \(n)\n"
        }
        header += "end_header\n"

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + pts.count * 17 * 4)
        var row = [Float](repeating: 0, count: 17)
        for p in pts {
            // Object Capture は Y上向き、3DGS ply の慣例は Y下向き → y,z を反転して書く
            // (RealityKit Splat TOP のX軸180°自動正立や他の3DGSビューアでそのまま正しい向きになる)
            row[0] = p.position.x; row[1] = -p.position.y; row[2] = -p.position.z
            row[3] = 0; row[4] = 0; row[5] = 0
            row[6] = (Float(p.color.x) / 255 - 0.5) / c0
            row[7] = (Float(p.color.y) / 255 - 0.5) / c0
            row[8] = (Float(p.color.z) / 255 - 0.5) / c0
            row[9] = opacityLogit
            row[10] = logScale; row[11] = logScale; row[12] = logScale
            row[13] = 1; row[14] = 0; row[15] = 0; row[16] = 0   // rot_0=w
            row.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try data.write(to: URL(fileURLWithPath: path))
        return pts.count
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
                                   "done": done, "error": errorMsg,
                                   "texture": texture,
                                   "splat": splatPath, "splat_points": splatPoints]
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
                     _ output: UnsafePointer<CChar>?, _ detail: Int32,
                     _ splatOut: UnsafePointer<CChar>?, _ splatScale: Double) {
    guard let handle, let folder, let output else { return }
    if #available(macOS 12.0, *) {
        let s = Unmanaged<PhotoSession>.fromOpaque(handle).takeUnretainedValue()
        s.start(imageFolder: String(cString: folder),
                outputPath: String(cString: output), detail: Int(detail),
                splatOut: splatOut.map { String(cString: $0) } ?? "",
                splatScale: splatScale)
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
