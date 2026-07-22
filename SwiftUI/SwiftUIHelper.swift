// SwiftUIHelper — パラメータ駆動の SwiftUI ビューを ImageRenderer でテクスチャ(BGRA)にレンダする。
// TouchDesigner の SwiftUI TOP から C ABI(su_)で呼ぶ。SwiftUI はメインスレッド専用なので
// レンダは DispatchQueue.main.async で回し(TDがメインrunloopをpumpする)、結果を latest に保持。
// cook 側は latest を非ブロックで読む。
import SwiftUI
import AppKit

final class SUState {
    let lock = NSLock()
    var buf: [UInt8] = []          // BGRA・下から上(TD表示に合わせ行反転済み)
    var w = 0, h = 0
    var serial: UInt64 = 0
    var rendering = false
}

// パラメータ駆動の SwiftUI ビュー(Mode で代表的なコンポーネントを切替)
struct SUView: View {
    let mode: Int
    let text: String
    let symbol: String
    let value: Double
    let fontSize: Double
    let fg: Color
    let bg: Color
    let w: Double
    let h: Double

    var body: some View {
        ZStack {
            bg
            switch mode {
            case 1:   // SF Symbol
                Image(systemName: symbol.isEmpty ? "star.fill" : symbol)
                    .font(.system(size: fontSize))
                    .foregroundStyle(fg)
            case 2:   // Gauge(円形)
                Gauge(value: value.isFinite ? min(max(value, 0), 1) : 0) {
                    Text(text)
                } currentValueLabel: {
                    Text("\(Int((value.isFinite ? min(max(value,0),1) : 0) * 100))")
                }
                .gaugeStyle(.accessoryCircular)
                .tint(fg)
                .scaleEffect(fontSize / 30.0)
                .foregroundStyle(fg)
            case 3:   // ProgressView(横バー)
                ProgressView(value: value.isFinite ? min(max(value, 0), 1) : 0) {
                    Text(text).foregroundStyle(fg)
                }
                .tint(fg)
                .padding(.horizontal, 24)
            default:  // Text
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(fg)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
        }
        .frame(width: w, height: h)
    }
}

@available(macOS 13.0, *)
@MainActor
private func renderNow(_ s: SUState, _ mode: Int32, _ text: String, _ symbol: String,
                       _ value: Double, _ fontSize: Double,
                       _ fr: Double, _ fg: Double, _ fb: Double, _ fa: Double,
                       _ br: Double, _ bg: Double, _ bb: Double, _ ba: Double,
                       _ w: Int, _ h: Int) {
    let view = SUView(
        mode: Int(mode), text: text, symbol: symbol, value: value, fontSize: fontSize,
        fg: Color(.sRGB, red: fr, green: fg, blue: fb, opacity: fa),
        bg: Color(.sRGB, red: br, green: bg, blue: bb, opacity: ba),
        w: Double(w), h: Double(h))
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    renderer.isOpaque = false
    guard let cg = renderer.cgImage else {
        s.lock.lock(); s.rendering = false; s.lock.unlock(); return
    }
    let cw = cg.width, ch = cg.height
    var top = [UInt8](repeating: 0, count: cw * ch * 4)   // BGRA・top-down
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    top.withUnsafeMutableBytes { p in
        if let ctx = CGContext(data: p.baseAddress, width: cw, height: ch, bitsPerComponent: 8,
                               bytesPerRow: cw * 4, space: cs, bitmapInfo: info) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        }
    }
    // TD 表示に合わせて行反転(bottom-up)
    var flipped = [UInt8](repeating: 0, count: cw * ch * 4)
    let rowBytes = cw * 4
    top.withUnsafeBufferPointer { src in
        flipped.withUnsafeMutableBufferPointer { dst in
            for y in 0..<ch {
                let s0 = y * rowBytes
                let d0 = (ch - 1 - y) * rowBytes
                dst.baseAddress!.advanced(by: d0)
                    .update(from: src.baseAddress!.advanced(by: s0), count: rowBytes)
            }
        }
    }
    s.lock.lock()
    s.buf = flipped; s.w = cw; s.h = ch; s.serial &+= 1; s.rendering = false
    s.lock.unlock()
}

@_cdecl("su_create")
public func su_create() -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained(SUState()).toOpaque()
}

@_cdecl("su_destroy")
public func su_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    Unmanaged<SUState>.fromOpaque(h).release()
}

@_cdecl("su_submit")
public func su_submit(_ h: UnsafeMutableRawPointer?, _ mode: Int32,
                      _ textC: UnsafePointer<CChar>?, _ symbolC: UnsafePointer<CChar>?,
                      _ value: Double, _ fontSize: Double,
                      _ fr: Double, _ fg: Double, _ fb: Double, _ fa: Double,
                      _ br: Double, _ bg: Double, _ bb: Double, _ ba: Double,
                      _ w: Int32, _ hh: Int32) {
    guard let h = h else { return }
    let s = Unmanaged<SUState>.fromOpaque(h).takeUnretainedValue()
    let text = textC != nil ? String(cString: textC!) : ""
    let symbol = symbolC != nil ? String(cString: symbolC!) : ""
    s.lock.lock()
    if s.rendering { s.lock.unlock(); return }   // 多重投入を防ぐ
    s.rendering = true
    s.lock.unlock()
    DispatchQueue.main.async {
        if #available(macOS 13.0, *) {
            renderNow(s, mode, text, symbol, value, fontSize, fr, fg, fb, fa, br, bg, bb, ba,
                      Int(max(1, w)), Int(max(1, hh)))
        } else {
            s.lock.lock(); s.rendering = false; s.lock.unlock()
        }
    }
}

@_cdecl("su_latest_info")
public func su_latest_info(_ h: UnsafeMutableRawPointer?, _ w: UnsafeMutablePointer<Int32>?,
                           _ hh: UnsafeMutablePointer<Int32>?,
                           _ serial: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let h = h else { return 0 }
    let s = Unmanaged<SUState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); defer { s.lock.unlock() }
    w?.pointee = Int32(s.w); hh?.pointee = Int32(s.h); serial?.pointee = s.serial
    return s.buf.isEmpty ? 0 : 1
}

@_cdecl("su_copy")
public func su_copy(_ h: UnsafeMutableRawPointer?, _ dst: UnsafeMutableRawPointer?) {
    guard let h = h, let dst = dst else { return }
    let s = Unmanaged<SUState>.fromOpaque(h).takeUnretainedValue()
    s.lock.lock(); let buf = s.buf; s.lock.unlock()
    if !buf.isEmpty { buf.withUnsafeBytes { _ = memcpy(dst, $0.baseAddress, buf.count) } }
}
