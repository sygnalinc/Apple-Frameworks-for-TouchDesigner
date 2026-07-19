// CreateMLImageHelper — CreateML の MLImageClassifier で、ラベル付きフォルダ
// (サブフォルダ名=クラス)から画像分類モデルをオンデバイス学習し .mlmodel を書き出す。
// 学習は非同期(MLJob)。進捗・精度は poll 方式で C ABI(cm_)から取得する。
import Foundation
import CreateML
import Combine

final class CMState: @unchecked Sendable {
    let lock = NSLock()
    var status = "idle"          // idle / training / done / error / cancelled
    var progress: Double = 0
    var trainAcc: Double = 0
    var valAcc: Double = 0
    var classes: [String] = []
    var error = ""
    var modelPath = ""
    var job: MLJob<MLImageClassifier>?
    var cancellable: AnyCancellable?
}

@_cdecl("cm_create")
public func cm_create() -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained(CMState()).toOpaque()
}

@_cdecl("cm_destroy")
public func cm_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    Unmanaged<CMState>.fromOpaque(h).release()
}

// 学習開始(非同期)。folder=ラベル付きサブフォルダ, out=出力.mlmodel, augMask ビット(1flip 2crop 4rotation 8blur 16exposure 32noise)
@_cdecl("cm_train")
public func cm_train(_ h: UnsafeMutableRawPointer?, _ folder: UnsafePointer<CChar>?, _ out: UnsafePointer<CChar>?, _ maxIter: Int32, _ augMask: Int32) {
    guard let h = h, let folder = folder, let out = out else { return }
    let s = Unmanaged<CMState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); if s.status == "training" { s.lock.unlock(); return }
    s.status = "training"; s.progress = 0; s.error = ""; s.trainAcc = 0; s.valAcc = 0; s.lock.unlock()
    let folderPath = String(cString: folder)
    let outPath = String(cString: out)

    // クラス名(サブフォルダ)を列挙
    var classNames: [String] = []
    if let items = try? FileManager.default.contentsOfDirectory(atPath: folderPath) {
        for it in items.sorted() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: (folderPath as NSString).appendingPathComponent(it), isDirectory: &isDir), isDir.boolValue, !it.hasPrefix(".") {
                classNames.append(it)
            }
        }
    }
    s.lock.lock(); s.classes = classNames; s.lock.unlock()

    var aug: MLImageClassifier.ImageAugmentationOptions = []
    if augMask & 1 != 0 { aug.insert(.flip) }
    if augMask & 2 != 0 { aug.insert(.crop) }
    if augMask & 4 != 0 { aug.insert(.rotation) }
    if augMask & 8 != 0 { aug.insert(.blur) }
    if augMask & 16 != 0 { aug.insert(.exposure) }
    if augMask & 32 != 0 { aug.insert(.noise) }

    let ds = MLImageClassifier.DataSource.labeledDirectories(at: URL(fileURLWithPath: folderPath))
    let params = MLImageClassifier.ModelParameters(validation: .split(strategy: .automatic),
                                                   maxIterations: Int(max(1, maxIter)),
                                                   augmentation: aug)
    do {
        let job = try MLImageClassifier.train(trainingData: ds, parameters: params)
        s.lock.lock(); s.job = job; s.lock.unlock()
        let c = job.result.sink(receiveCompletion: { comp in
            if case .failure(let e) = comp { s.lock.lock(); s.status = "error"; s.error = "\(e)"; s.lock.unlock() }
        }, receiveValue: { model in
            do {
                try model.write(to: URL(fileURLWithPath: outPath))
                s.lock.lock()
                s.trainAcc = 1.0 - model.trainingMetrics.classificationError
                s.valAcc = 1.0 - model.validationMetrics.classificationError
                s.modelPath = outPath; s.progress = 1.0; s.status = "done"; s.error = ""
                s.lock.unlock()
            } catch {
                s.lock.lock(); s.status = "error"; s.error = "write failed: \(error)"; s.lock.unlock()
            }
        })
        s.lock.lock(); s.cancellable = c; s.lock.unlock()
    } catch {
        s.lock.lock(); s.status = "error"; s.error = "\(error)"; s.lock.unlock()
    }
}

@_cdecl("cm_cancel")
public func cm_cancel(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    let s = Unmanaged<CMState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let job = s.job; s.lock.unlock()
    job?.cancel()
    s.lock.lock(); if s.status == "training" { s.status = "cancelled" }; s.lock.unlock()
}

@_cdecl("cm_status")
public func cm_status(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h = h else { return nil }
    let s = Unmanaged<CMState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    // 学習中は job.progress から進捗を更新
    if s.status == "training", let job = s.job { s.progress = job.progress.fractionCompleted }
    let cls = s.classes.map { $0.replacingOccurrences(of: "\"", with: "'") }.map { "\"\($0)\"" }.joined(separator: ",")
    let json = "{\"status\":\"\(s.status)\",\"progress\":\(s.progress),\"train_acc\":\(s.trainAcc),\"val_acc\":\(s.valAcc),\"classes\":[\(cls)],\"model\":\"\(s.modelPath)\",\"error\":\"\(s.error.replacingOccurrences(of: "\"", with: "'"))\"}"
    s.lock.unlock()
    return UnsafePointer(strdup(json))
}
