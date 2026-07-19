// VisionDocumentHelper — 新Vision APIの RecognizeDocumentsRequest(macOS 26+)で
// 文書の段落・表・行・セル・リスト構造を認識し、JSON行配列で返す。ObjC++からC ABIで使う。
import Foundation
import Vision

final class DVState: @unchecked Sendable {
    let lock = NSLock()
    var status = "idle"      // idle / analyzing / done / error
    var json = "[]"
    var error = ""
    var counts = "0,0,0,0"   // paragraphs,tables,lists,cells
}

private func esc(_ s: String) -> String {
    var o = ""
    for c in s {
        switch c {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += " "
        case "\r": o += " "
        case "\t": o += " "
        default: o.append(c)
        }
    }
    return o
}

@available(macOS 26.0, *)
private func walk(_ container: DocumentObservation.Container, page: Int, rows: inout [String], counts: inout (Int,Int,Int,Int)) {
    // 段落
    for (pi, para) in container.paragraphs.enumerated() {
        counts.0 += 1
        rows.append("{\"type\":\"paragraph\",\"page\":\(page),\"index\":\(pi),\"row\":-1,\"col\":-1,\"text\":\"\(esc(para.transcript))\"}")
    }
    // 表
    for (ti, table) in container.tables.enumerated() {
        counts.1 += 1
        let nrows = table.rows.count
        let ncols = table.rows.first?.count ?? 0
        rows.append("{\"type\":\"table\",\"page\":\(page),\"index\":\(ti),\"row\":\(nrows),\"col\":\(ncols),\"text\":\"\"}")
        for (ri, row) in table.rows.enumerated() {
            for (ci, cell) in row.enumerated() {
                counts.3 += 1
                rows.append("{\"type\":\"cell\",\"page\":\(page),\"index\":\(ti),\"row\":\(ri),\"col\":\(ci),\"text\":\"\(esc(cell.content.text.transcript))\"}")
            }
        }
    }
    // リスト
    for (li, list) in container.lists.enumerated() {
        counts.2 += 1
        for (ii, item) in list.items.enumerated() {
            rows.append("{\"type\":\"list\",\"page\":\(page),\"index\":\(li),\"row\":\(ii),\"col\":-1,\"text\":\"\(esc(item.markerString)) \(esc(item.content.text.transcript))\"}")
        }
    }
}

@_cdecl("dv_create")
public func dv_create() -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained(DVState()).toOpaque()
}

@_cdecl("dv_destroy")
public func dv_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    Unmanaged<DVState>.fromOpaque(h).release()
}

@_cdecl("dv_analyze")
public func dv_analyze(_ h: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?) {
    guard let h = h, let path = path else { return }
    let s = Unmanaged<DVState>.fromOpaque(h).takeUnretainedValue()
    let p = String(cString: path)
    s.lock.lock(); if s.status == "analyzing" { s.lock.unlock(); return }; s.status = "analyzing"; s.lock.unlock()
    guard #available(macOS 26.0, *) else {
        s.lock.lock(); s.status = "error"; s.error = "RecognizeDocumentsRequest requires macOS 26+"; s.lock.unlock(); return
    }
    let url = URL(fileURLWithPath: p)
    Task.detached {
        do {
            let request = RecognizeDocumentsRequest()
            let observations = try await request.perform(on: url)
            var rows: [String] = []
            var counts = (0,0,0,0)
            for obs in observations {
                walk(obs.document, page: 0, rows: &rows, counts: &counts)
            }
            let json = "[" + rows.joined(separator: ",") + "]"
            s.lock.lock(); s.json = json; s.counts = "\(counts.0),\(counts.1),\(counts.2),\(counts.3)"; s.status = "done"; s.error = ""; s.lock.unlock()
        } catch {
            s.lock.lock(); s.status = "error"; s.error = "\(error)"; s.lock.unlock()
        }
    }
}

@_cdecl("dv_status")
public func dv_status(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h = h else { return nil }
    let s = Unmanaged<DVState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let out = "\(s.status)|\(s.counts)|\(s.error)"; s.lock.unlock()
    return UnsafePointer(strdup(out))
}

@_cdecl("dv_result")
public func dv_result(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h = h else { return nil }
    let s = Unmanaged<DVState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let j = s.json; s.lock.unlock()
    return UnsafePointer(strdup(j))
}
