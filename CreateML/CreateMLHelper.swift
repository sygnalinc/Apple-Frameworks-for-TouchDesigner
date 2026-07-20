// CreateMLHelper — CreateML の各種学習タスクを1本のヘルパに統合し、C ABI(ml_)で公開する。
// フォルダ系(Image / Hand Pose / Action / Hand Action / Sound)は labeledDirectories + MLJob、
// Activity(CHOP時系列)はシーケンス列 MLDataTable + MLJob、Tabular(分類/回帰)は MLDataTable を
// バックグラウンドスレッドで同期学習。進捗・精度・クラスは poll 方式のJSONで返す。
import Foundation
import CreateML
import Combine

// Task ID(DAT側 Task メニューの index と一致させる)
// 0 Image / 1 Hand Pose / 2 Action(body) / 3 Hand Action / 4 Sound /
// 5 Activity(CHOP時系列) / 6 Tabular Classifier / 7 Tabular Regressor

final class MLState: @unchecked Sendable {
    let lock = NSLock()
    var status = "idle"          // idle / training / done / error / cancelled
    var progress: Double = 0
    var trainAcc: Double = 0     // 分類=accuracy、回帰=決定係数の代わりに 1-正規化RMSEは出さず 0
    var valAcc: Double = 0
    var metric = ""              // 回帰時の "rmse" 等の補足
    var classes: [String] = []
    var features: [String] = []
    var error = ""
    var modelPath = ""
    var progressObj: Progress?   // MLJob.progress(フォルダ/Activity)
    var cancelFn: (() -> Void)?
    var cancellable: AnyCancellable?
    var cancelledFlag = false
}

@_cdecl("ml_create")
public func ml_create() -> UnsafeMutableRawPointer { Unmanaged.passRetained(MLState()).toOpaque() }

@_cdecl("ml_destroy")
public func ml_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    Unmanaged<MLState>.fromOpaque(h).release()
}

private func begin(_ s: MLState) {
    s.lock.lock(); s.status = "training"; s.progress = 0; s.error = ""
    s.trainAcc = 0; s.valAcc = 0; s.metric = ""; s.classes = []; s.features = []
    s.cancelledFlag = false; s.lock.unlock()
}
private func fail(_ s: MLState, _ msg: String) {
    s.lock.lock(); s.status = "error"; s.error = msg; s.lock.unlock()
}

// MLJob<T> を state に紐付け、完了で書き出し+精度取得する共通配線
private func wireJob<T>(_ s: MLState, _ job: MLJob<T>, _ outPath: String,
                        _ metrics: @escaping (T) -> (Double, Double),
                        _ writeModel: @escaping (T, URL) throws -> Void) {
    s.lock.lock(); s.progressObj = job.progress; s.cancelFn = { job.cancel() }; s.lock.unlock()
    let c = job.result.sink(receiveCompletion: { comp in
        if case .failure(let e) = comp { s.lock.lock(); if !s.cancelledFlag { s.status = "error"; s.error = "\(e)" }; s.lock.unlock() }
    }, receiveValue: { model in
        do {
            try writeModel(model, URL(fileURLWithPath: outPath))
            let (t, v) = metrics(model)
            s.lock.lock(); s.trainAcc = t; s.valAcc = v; s.modelPath = outPath
            s.progress = 1.0; s.status = "done"; s.error = ""; s.lock.unlock()
        } catch { s.lock.lock(); s.status = "error"; s.error = "write failed: \(error)"; s.lock.unlock() }
    })
    s.lock.lock(); s.cancellable = c; s.lock.unlock()
}

// フォルダのサブフォルダ名(=クラス)を列挙
private func subdirs(_ path: String) -> [String] {
    var out: [String] = []
    if let items = try? FileManager.default.contentsOfDirectory(atPath: path) {
        for it in items.sorted() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(it), isDirectory: &isDir),
               isDir.boolValue, !it.hasPrefix(".") { out.append(it) }
        }
    }
    return out
}

// 学習開始。task=上記ID。trainPath=フォルダ or CSV、outPath=.mlmodel。
// featureCSV/labelCol/recCol/targetCol は該当Taskのみ使用。maxIter/window/augMask も同様。
@_cdecl("ml_train")
public func ml_train(_ h: UnsafeMutableRawPointer?, _ task: Int32,
                     _ trainPathC: UnsafePointer<CChar>?, _ outC: UnsafePointer<CChar>?,
                     _ featureC: UnsafePointer<CChar>?, _ labelC: UnsafePointer<CChar>?,
                     _ recC: UnsafePointer<CChar>?, _ targetC: UnsafePointer<CChar>?,
                     _ maxIter: Int32, _ window: Int32, _ augMask: Int32) {
    guard let h = h, let trainPathC = trainPathC, let outC = outC else { return }
    let s = Unmanaged<MLState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); if s.status == "training" { s.lock.unlock(); return }; s.lock.unlock()
    begin(s)

    let trainPath = String(cString: trainPathC)
    let outPath = String(cString: outC)
    let featStr = featureC != nil ? String(cString: featureC!) : ""
    let label = labelC != nil ? String(cString: labelC!) : "label"
    let rec = recC != nil ? String(cString: recC!) : "recording"
    let target = targetC != nil ? String(cString: targetC!) : "target"
    let iters = Int(max(1, maxIter))
    let win = Int(max(2, window))
    let url = URL(fileURLWithPath: trainPath)
    let auto = MLModelMetadata(author: "TDAppleML", shortDescription: "Trained in TouchDesigner", version: "1.0")

    do {
        switch task {
        case 0: // Image Classifier
            s.lock.lock(); s.classes = subdirs(trainPath); s.lock.unlock()
            var aug: MLImageClassifier.ImageAugmentationOptions = []
            if augMask & 1 != 0 { aug.insert(.flip) }; if augMask & 2 != 0 { aug.insert(.crop) }
            if augMask & 4 != 0 { aug.insert(.rotation) }; if augMask & 8 != 0 { aug.insert(.blur) }
            if augMask & 16 != 0 { aug.insert(.exposure) }; if augMask & 32 != 0 { aug.insert(.noise) }
            let p = MLImageClassifier.ModelParameters(validation: .split(strategy: .automatic), maxIterations: iters, augmentation: aug)
            let job = try MLImageClassifier.train(trainingData: .labeledDirectories(at: url), parameters: p)
            wireJob(s, job, outPath, { (1 - $0.trainingMetrics.classificationError, 1 - $0.validationMetrics.classificationError) }, { try $0.write(to: $1) })

        case 1: // Hand Pose(静的)
            s.lock.lock(); s.classes = subdirs(trainPath); s.lock.unlock()
            let p = MLHandPoseClassifier.ModelParameters(validation: .split(strategy: .automatic), maximumIterations: iters)
            let job = try MLHandPoseClassifier.train(trainingData: .labeledDirectories(at: url), parameters: p)
            wireJob(s, job, outPath, { (1 - $0.trainingMetrics.classificationError, 1 - $0.validationMetrics.classificationError) }, { try $0.write(to: $1) })

        case 2: // Action(body・動画)
            s.lock.lock(); s.classes = subdirs(trainPath); s.lock.unlock()
            let p = MLActionClassifier.ModelParameters(validation: .split(strategy: .automatic), maximumIterations: iters, predictionWindowSize: win)
            let job = try MLActionClassifier.train(trainingData: .labeledDirectories(at: url), parameters: p)
            wireJob(s, job, outPath, { (1 - $0.trainingMetrics.classificationError, 1 - $0.validationMetrics.classificationError) }, { try $0.write(to: $1) })

        case 3: // Hand Action(動画)
            s.lock.lock(); s.classes = subdirs(trainPath); s.lock.unlock()
            let p = MLHandActionClassifier.ModelParameters(validation: .split(strategy: .automatic), maximumIterations: iters, predictionWindowSize: win)
            let job = try MLHandActionClassifier.train(trainingData: .labeledDirectories(at: url), parameters: p)
            wireJob(s, job, outPath, { (1 - $0.trainingMetrics.classificationError, 1 - $0.validationMetrics.classificationError) }, { try $0.write(to: $1) })

        case 4: // Sound
            s.lock.lock(); s.classes = subdirs(trainPath); s.lock.unlock()
            let p = MLSoundClassifier.ModelParameters(validation: .split(strategy: .automatic), maxIterations: iters)
            let job = try MLSoundClassifier.train(trainingData: .labeledDirectories(at: url), parameters: p)
            wireJob(s, job, outPath, { (1 - $0.trainingMetrics.classificationError, 1 - $0.validationMetrics.classificationError) }, { try $0.write(to: $1) })

        case 5: // Activity(CHOP時系列CSV)
            try trainActivity(s, csvPath: trainPath, outPath: outPath, featStr: featStr, label: label, rec: rec, iters: iters, win: win)

        case 6, 7: // Tabular Classifier / Regressor(同期学習をバックグラウンドで)
            let isReg = (task == 7)
            let t = Thread {
                do {
                    let table = try loadFlatTable(trainPath)
                    let cols = featStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if isReg {
                        let m = cols.isEmpty ? try MLRegressor(trainingData: table, targetColumn: target)
                                             : try MLRegressor(trainingData: table, targetColumn: target, featureColumns: cols)
                        try m.write(to: URL(fileURLWithPath: outPath), metadata: auto)
                        let tr = m.trainingMetrics.rootMeanSquaredError
                        s.lock.lock(); s.metric = "rmse"; s.trainAcc = tr; s.valAcc = m.validationMetrics.rootMeanSquaredError
                        s.modelPath = outPath; s.progress = 1.0; s.status = "done"; s.lock.unlock()
                    } else {
                        let m = cols.isEmpty ? try MLClassifier(trainingData: table, targetColumn: target)
                                             : try MLClassifier(trainingData: table, targetColumn: target, featureColumns: cols)
                        try m.write(to: URL(fileURLWithPath: outPath), metadata: auto)
                        s.lock.lock(); s.trainAcc = 1 - m.trainingMetrics.classificationError
                        s.valAcc = 1 - m.validationMetrics.classificationError
                        s.modelPath = outPath; s.progress = 1.0; s.status = "done"; s.lock.unlock()
                    }
                } catch { fail(s, "\(error)") }
            }
            s.lock.lock(); s.cancelFn = nil; s.lock.unlock()
            t.stackSize = 8 << 20; t.start()

        default:
            fail(s, "unknown task \(task)")
        }
    } catch { fail(s, "\(error)") }
}

// Activity: フラットCSV(1行=1フレーム)を収録IDでグループ化し、各特徴を [Double] シーケンス列にした
// MLDataTable を作る。MLActivityClassifier は特徴列がシーケンス型であることを要求する。
private func trainActivity(_ s: MLState, csvPath: String, outPath: String, featStr: String,
                           label: String, rec: String, iters: Int, win: Int) throws {
    let raw = try String(contentsOfFile: csvPath, encoding: .utf8)
    let lines = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { String($0) }
    guard lines.count > 1 else { throw NSError(domain: "ml", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty CSV"]) }
    let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    guard let recIdx = header.firstIndex(of: rec), let labIdx = header.firstIndex(of: label) else {
        throw NSError(domain: "ml", code: 2, userInfo: [NSLocalizedDescriptionKey: "label/recording column not found"])
    }
    var features: [String]
    if featStr.trimmingCharacters(in: .whitespaces).isEmpty { features = header.filter { $0 != label && $0 != rec } }
    else { features = featStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    let featIdx = features.compactMap { header.firstIndex(of: $0) }
    guard featIdx.count == features.count else { throw NSError(domain: "ml", code: 3, userInfo: [NSLocalizedDescriptionKey: "some feature columns not found"]) }
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
    let params = MLActivityClassifier.ModelParameters(validation: .split(strategy: .automatic), maximumIterations: iters, predictionWindowSize: win)
    let job = try MLActivityClassifier.train(trainingData: table, featureColumns: features, labelColumn: label, recordingFileColumn: rec, parameters: params)
    wireJob(s, job, outPath, { (1 - $0.trainingMetrics.classificationError, 1 - $0.validationMetrics.classificationError) }, { try $0.write(to: $1) })
}

// フラットCSVを MLDataTable へ(数値はDouble、それ以外はStringとして読む)
private func loadFlatTable(_ path: String) throws -> MLDataTable {
    let raw = try String(contentsOfFile: path, encoding: .utf8)
    let lines = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { String($0) }
    guard lines.count > 1 else { throw NSError(domain: "ml", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty CSV"]) }
    let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    var rowsS: [[String]] = []
    for i in 1..<lines.count {
        let f = lines[i].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if f.count == header.count { rowsS.append(f) }
    }
    var cols: [String: MLDataValueConvertible] = [:]
    for (c, name) in header.enumerated() {
        let vals = rowsS.map { $0[c] }
        // 全行が数値なら Double 列、そうでなければ String 列
        if vals.allSatisfy({ Double($0) != nil }) { cols[name] = vals.map { Double($0)! } }
        else { cols[name] = vals }
    }
    return try MLDataTable(dictionary: cols)
}

@_cdecl("ml_cancel")
public func ml_cancel(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    let s = Unmanaged<MLState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let fn = s.cancelFn; s.cancelledFlag = true; if s.status == "training" { s.status = "cancelled" }; s.lock.unlock()
    fn?()
}

@_cdecl("ml_status")
public func ml_status(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h = h else { return nil }
    let s = Unmanaged<MLState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock()
    if s.status == "training", let p = s.progressObj { s.progress = p.fractionCompleted }
    func arr(_ a: [String]) -> String { a.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" }.joined(separator: ",") }
    let json = "{\"status\":\"\(s.status)\",\"progress\":\(s.progress),\"train_acc\":\(s.trainAcc),\"val_acc\":\(s.valAcc),\"metric\":\"\(s.metric)\",\"classes\":[\(arr(s.classes))],\"features\":[\(arr(s.features))],\"model\":\"\(s.modelPath)\",\"error\":\"\(s.error.replacingOccurrences(of: "\"", with: "'"))\"}"
    s.lock.unlock()
    return UnsafePointer(strdup(json))
}
