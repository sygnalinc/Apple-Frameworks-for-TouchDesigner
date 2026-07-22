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
            case 3:   // 横バー(カスタム図形・ImageRendererで確実に描画、塗り色=Foreground)
                VStack(alignment: .leading, spacing: max(6, fontSize * 0.18)) {
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: fontSize * 0.45, weight: .semibold, design: .rounded))
                            .foregroundStyle(fg)
                    }
                    let v = value.isFinite ? min(max(value, 0), 1) : 0
                    let barW = max(1.0, w - 48)
                    let barH = max(10.0, fontSize * 0.4)
                    ZStack(alignment: .leading) {
                        Capsule().fill(fg.opacity(0.22)).frame(width: barW, height: barH)   // トラック
                        Capsule().fill(fg).frame(width: barW * v, height: barH)             // 塗り
                    }
                }
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

// ============================== JSON 駆動の macOS 風UI ==============================
// JSON でウインドウ+コントロールを記述してネイティブ風にレンダする「UIツール群」。
// 描けるものはネイティブ(Text/Button/SF Symbol/トラフィックライト/Material)、ImageRenderer が
// 描けない Toggle/Slider は見た目を自前図形で再現する。

private func colorFrom(_ v: Any?, _ def: Color) -> Color {
    guard let a = v as? [Any], a.count >= 3 else { return def }
    let d = a.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
    return Color(.sRGB, red: d[0], green: d[1], blue: d[2], opacity: a.count >= 4 ? d[3] : 1)
}
private func dbl(_ v: Any?, _ def: Double) -> Double { ((v as? NSNumber)?.doubleValue) ?? def }
private func str(_ v: Any?, _ def: String) -> String { (v as? String) ?? def }
private func boolv(_ v: Any?, _ def: Bool) -> Bool { (v as? NSNumber)?.boolValue ?? def }

@MainActor
struct UINode: View {
    let spec: [String: Any]
    let contentW: Double
    var body: some View {
        let type = (spec["type"] as? String) ?? "text"
        switch type {
        case "text":
            let w = str(spec["weight"], "regular")
            Text(str(spec["text"], ""))
                .font(.system(size: dbl(spec["size"], 15),
                              weight: w == "bold" ? .bold : (w == "semibold" ? .semibold : .regular)))
                .foregroundStyle(colorFrom(spec["color"], .primary))
        case "symbol":
            Image(systemName: str(spec["name"], "star.fill"))
                .font(.system(size: dbl(spec["size"], 22)))
                .foregroundStyle(colorFrom(spec["color"], .primary))
        case "button":                       // 自前描画(ネイティブButtonはTD埋め込みのImageRendererで描けない)
            let prominent = str(spec["style"], "prominent") == "prominent"
            let accent = colorFrom(spec["color"], Color.accentColor)
            Text(str(spec["label"], "Button"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : accent)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(prominent ? accent : accent.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(prominent ? Color.clear : accent.opacity(0.6), lineWidth: 1))
        case "toggle":                       // 自前で macOS スイッチの見た目
            let on = boolv(spec["on"], false)
            HStack {
                Text(str(spec["label"], "")).foregroundStyle(colorFrom(spec["color"], .primary))
                Spacer()
                Capsule().fill(on ? Color.green : Color.gray.opacity(0.45))
                    .frame(width: 38, height: 22)
                    .overlay(Circle().fill(.white).padding(2).offset(x: on ? 8 : -8))
            }
        case "slider":                       // 自前で track + knob
            let v = min(max(dbl(spec["value"], 0.5), 0), 1)
            let tw = max(60.0, contentW * 0.5)
            HStack {
                Text(str(spec["label"], "")).foregroundStyle(colorFrom(spec["color"], .primary))
                Spacer()
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.3)).frame(width: tw, height: 4)
                    Capsule().fill(colorFrom(spec["color"], .accentColor)).frame(width: tw * v, height: 4)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .shadow(radius: 1).offset(x: tw * v - 8)
                }.frame(width: tw, height: 16)
            }
        case "progress":                     // 自前バー
            let v = min(max(dbl(spec["value"], 0), 0), 1)
            let bw = max(40.0, contentW)
            VStack(alignment: .leading, spacing: 4) {
                let lbl = str(spec["label"], "")
                if !lbl.isEmpty { Text(lbl).font(.system(size: 12)).foregroundStyle(colorFrom(spec["color"], .primary)) }
                ZStack(alignment: .leading) {
                    Capsule().fill(colorFrom(spec["color"], .accentColor).opacity(0.22)).frame(width: bw, height: 8)
                    Capsule().fill(colorFrom(spec["color"], .accentColor)).frame(width: bw * v, height: 8)
                }
            }
        case "divider":
            Divider()
        case "spacer":
            Spacer()
        case "card":                         // 角丸ボックス(タイトル+サブ+シンボル)
            HStack(spacing: 12) {
                if let sym = spec["symbol"] as? String {
                    Image(systemName: sym).font(.system(size: 26)).foregroundStyle(colorFrom(spec["color"], .accentColor))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(str(spec["title"], "")).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    let sub = str(spec["subtitle"], "")
                    if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        case "row":
            let items = (spec["items"] as? [[String: Any]]) ?? []
            HStack(spacing: dbl(spec["spacing"], 10)) {
                ForEach(items.indices, id: \.self) { i in UINode(spec: items[i], contentW: contentW) }
            }
        case "col":
            let items = (spec["items"] as? [[String: Any]]) ?? []
            VStack(alignment: .leading, spacing: dbl(spec["spacing"], 8)) {
                ForEach(items.indices, id: \.self) { i in UINode(spec: items[i], contentW: contentW) }
            }
        default:
            EmptyView()
        }
    }
}

@MainActor
struct UIWindow: View {
    let spec: [String: Any]
    let w: Double
    let h: Double
    var body: some View {
        let items = (spec["body"] as? [[String: Any]]) ?? []
        let traffic = boolv(spec["traffic"], true)
        let contentW = w - 36
        VStack(spacing: 0) {
            if traffic {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                    Spacer()
                    Text(str(spec["title"], "")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Spacer()
                    Color.clear.frame(width: 44)
                }
                .padding(.horizontal, 12).frame(height: 34).background(.regularMaterial)
                Divider()
            }
            VStack(alignment: .leading, spacing: dbl(spec["spacing"], 12)) {
                ForEach(items.indices, id: \.self) { i in UINode(spec: items[i], contentW: contentW) }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: w, height: h)
        .background(colorFrom(spec["bg"], Color(white: 0.13)))
    }
}

@available(macOS 13.0, *)
@MainActor
private func renderView<V: View>(_ s: SUState, _ view: V, _ w: Int, _ h: Int) {
    let renderer = ImageRenderer(content: view.frame(width: Double(w), height: Double(h)))
    renderer.scale = 1
    renderer.isOpaque = false
    guard let cg = renderer.cgImage else { s.lock.lock(); s.rendering = false; s.lock.unlock(); return }
    let cw = cg.width, ch = cg.height
    var top = [UInt8](repeating: 0, count: cw * ch * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    top.withUnsafeMutableBytes { p in
        if let ctx = CGContext(data: p.baseAddress, width: cw, height: ch, bitsPerComponent: 8,
                               bytesPerRow: cw * 4, space: cs, bitmapInfo: info) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        }
    }
    var flipped = [UInt8](repeating: 0, count: cw * ch * 4)
    let rowBytes = cw * 4
    top.withUnsafeBufferPointer { src in
        flipped.withUnsafeMutableBufferPointer { dst in
            for y in 0..<ch {
                dst.baseAddress!.advanced(by: (ch - 1 - y) * rowBytes)
                    .update(from: src.baseAddress!.advanced(by: y * rowBytes), count: rowBytes)
            }
        }
    }
    s.lock.lock(); s.buf = flipped; s.w = cw; s.h = ch; s.serial &+= 1; s.rendering = false; s.lock.unlock()
}

@_cdecl("su_submit_json")
public func su_submit_json(_ h: UnsafeMutableRawPointer?, _ jsonC: UnsafePointer<CChar>?,
                           _ w: Int32, _ hh: Int32) {
    guard let h = h else { return }
    let s = Unmanaged<SUState>.fromOpaque(h).takeUnretainedValue()
    let json = jsonC != nil ? String(cString: jsonC!) : "{}"
    s.lock.lock(); if s.rendering { s.lock.unlock(); return }; s.rendering = true; s.lock.unlock()
    DispatchQueue.main.async {
        guard #available(macOS 13.0, *) else { s.lock.lock(); s.rendering = false; s.lock.unlock(); return }
        let data = json.data(using: .utf8) ?? Data("{}".utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        renderView(s, UIWindow(spec: obj, w: Double(max(1, w)), h: Double(max(1, hh))),
                   Int(max(1, w)), Int(max(1, hh)))
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
