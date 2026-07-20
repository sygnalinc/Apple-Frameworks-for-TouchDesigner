// CreateMLMotionHelper — CreateML の MLActivityClassifier で、時系列の特徴列
// (VisionPose 等の CHOP チャンネルを録画したCSV)から動き/ジェスチャを学習し .mlmodel を書き出す。
// 学習は非同期(MLJob)。進捗・精度は poll 方式で C ABI(cma_)から取得する。
import Foundation
import CreateML
import Combine

final class CMAState: @unchecked Sendable {
    let lock = NSLock()
    var status = "idle"          // idle / training / done / error / cancelled
    var progress: Double = 0
    var trainAcc: Double = 0
    var valAcc: Double = 0
    var classes: [String] = []
    var features: [String] = []
    var error = ""
    var modelPath = ""
    var job: MLJob<MLActivityClassifier>?
    var cancellable: AnyCancellable?
}

@_cdecl("cma_create")
public func cma_create() -> UnsafeMutableRawPointer { Unmanaged.passRetained(CMAState()).toOpaque() }

@_cdecl("cma_destroy")
public func cma_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    Unmanaged<CMAState>.fromOpaque(h).release()
}

// 学習開始(非同期)。csv=録画CSV, out=.mlmodel, featureCSV=特徴列(カンマ区切り, 空で自動),
// labelCol/recCol=ラベル列/収録ID列, window=予測窓, maxIter=最大反復
@_cdecl("cma_train")
public func cma_train(_ h: UnsafeMutableRawPointer?, _ csv: UnsafePointer<CChar>?, _ out: UnsafePointer<CChar>?,
                      _ featureCSV: UnsafePointer<CChar>?, _ labelCol: UnsafePointer<CChar>?, _ recCol: UnsafePointer<CChar>?,
                      _ window: Int32, _ maxIter: Int32) {
    guard let h = h, let csv = csv, let out = out else { return }
    let s = Unmanaged<CMAState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); if s.status == "training" { s.lock.unlock(); return }
    s.status = "training"; s.progress = 0; s.error = ""; s.trainAcc = 0; s.valAcc = 0; s.lock.unlock()
    let csvPath = String(cString: csv)
    let outPath = String(cString: out)
    let label = labelCol != nil ? String(cString: labelCol!) : "label"
    let rec = recCol != nil ? String(cString: recCol!) : "recording"
    let featStr = featureCSV != nil ? String(cString: featureCSV!) : ""

    do {
        // フラットCSV(1行=1サンプル)を収録IDでグループ化し、各特徴を [Double] シーケンス列にした
        // MLDataTable を作る。MLActivityClassifier は特徴列がシーケンス型であることを要求する。
        let raw = try String(contentsOfFile: csvPath, encoding: .utf8)
        let lines = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { String($0) }
        guard lines.count > 1 else { throw NSError(domain: "cma", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty CSV"]) }
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let recIdx = header.firstIndex(of: rec), let labIdx = header.firstIndex(of: label) else {
            throw NSError(domain: "cma", code: 2, userInfo: [NSLocalizedDescriptionKey: "label/recording column not found"])
        }
        var features: [String]
        if featStr.trimmingCharacters(in: .whitespaces).isEmpty {
            features = header.filter { $0 != label && $0 != rec }
        } else {
            features = featStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let featIdx = features.compactMap { header.firstIndex(of: $0) }
        guard featIdx.count == features.count else { throw NSError(domain: "cma", code: 3, userInfo: [NSLocalizedDescriptionKey: "some feature columns not found"]) }
        s.lock.lock(); s.features = features; s.lock.unlock()

        var order: [String] = []; var labelOf: [String: String] = [:]; var seqs: [String: [[Double]]] = [:]
        for i in 1..<lines.count {
            let f = lines[i].split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            if f.count <= recIdx { continue }
            let r = f[recIdx]
            if seqs[r] == nil { seqs[r] = features.map { _ in [] }; order.append(r); labelOf[r] = (labIdx < f.count ? f[labIdx] : "") }
            for (k, fi) in featIdx.enumerated() { seqs[r]![k].append(fi < f.count ? (Double(f[fi]) ?? 0) : 0) }
        }
        var cols: [String: MLDataValueConvertible] = [:]
        cols[label] = order.map { labelOf[$0] ?? "" }
        cols[rec] = order
        for (k, name) in features.enumerated() { cols[name] = order.map { seqs[$0]![k] } }
        let table = try MLDataTable(dictionary: cols)

        let params = MLActivityClassifier.ModelParameters(validation: .split(strategy: .automatic),
                                                          maximumIterations: Int(max(1, maxIter)),
                                                          predictionWindowSize: Int(max(2, window)))
        let job = try MLActivityClassifier.train(trainingData: table, featureColumns: features,
                                                 labelColumn: label, recordingFileColumn: rec, parameters: params)
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
            } catch { s.lock.lock(); s.status = "error"; s.error = "write failed: \(error)"; s.lock.unlock() }
        })
        s.lock.lock(); s.cancellable = c; s.lock.unlock()
    } catch {
        s.lock.lock(); s.status = "error"; s.error = "\(error)"; s.lock.unlock()
    }
}

@_cdecl("cma_cancel")
public func cma_cancel(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    let s = Unmanaged<CMAState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let job = s.job; s.lock.unlock()
    job?.cancel()
    s.lock.lock(); if s.status == "training" { s.status = "cancelled" }; s.lock.unlock()
}

@_cdecl("cma_status")
public func cma_status(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h = h else { return nil }
    let s = Unmanaged<CMAState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    if s.status == "training", let job = s.job { s.progress = job.progress.fractionCompleted }
    let feats = s.features.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" }.joined(separator: ",")
    let json = "{\"status\":\"\(s.status)\",\"progress\":\(s.progress),\"train_acc\":\(s.trainAcc),\"val_acc\":\(s.valAcc),\"features\":[\(feats)],\"model\":\"\(s.modelPath)\",\"error\":\"\(s.error.replacingOccurrences(of: "\"", with: "'"))\"}"
    s.lock.unlock()
    return UnsafePointer(strdup(json))
}
