// SwiftUIPanelHelper — 本物の macOS ウインドウ(NSWindow + NSHostingView)に**操作可能な**
// SwiftUI コントロール(Slider/Toggle/Button/Stepper)を表示し、ユーザーが操作した値を
// スレッドセーフに保持する。TouchDesigner の SwiftUI Panel CHOP が C ABI(sp_)で読み戻す。
//
// テクスチャ(ImageRenderer)ではなく**実ウインドウ**なので、ネイティブコントロールがそのまま
// 描画・操作できる(ImageRenderer が描けない Slider/Toggle も本物として動く)。
// UI はメインスレッド、CHOP の読み取りはロック保護の store から。
import SwiftUI
import AppKit

final class PanelModel: ObservableObject {
    @Published var v: [String: Double] = [:]   // UIバインディング用(メインスレッド)
    private let lock = NSLock()
    private var store: [String: Double] = [:]   // CHOP読み取り用(ロック保護)
    private var pressed = Set<String>()          // ボタン押下(1回消費)

    func seed(_ id: String, _ x: Double) {       // 既定値(まだ無ければ設定)
        if v[id] == nil { v[id] = x }
        lock.lock(); if store[id] == nil { store[id] = x }; lock.unlock()
    }
    func set(_ id: String, _ x: Double) {        // UIから(メインスレッド)
        v[id] = x
        lock.lock(); store[id] = x; lock.unlock()
    }
    func press(_ id: String) { lock.lock(); pressed.insert(id); lock.unlock() }
    func read(_ id: String) -> Double { lock.lock(); defer { lock.unlock() }; return store[id] ?? 0 }
    func takeBtn(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return pressed.remove(id) != nil }
}

@MainActor
struct PanelView: View {
    @ObservedObject var model: PanelModel
    let controls: [[String: Any]]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(controls.indices, id: \.self) { i in row(controls[i]) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder func row(_ c: [String: Any]) -> some View {
        let type = c["type"] as? String ?? "text"
        let id = c["id"] as? String ?? ""
        let label = c["label"] as? String ?? ""
        switch type {
        case "slider":
            let mn = (c["min"] as? NSNumber)?.doubleValue ?? 0
            let mx = (c["max"] as? NSNumber)?.doubleValue ?? 1
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                    Spacer()
                    Text(String(format: "%.2f", model.v[id] ?? 0)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(get: { model.v[id] ?? mn }, set: { model.set(id, $0) }), in: mn...mx)
            }
        case "toggle":
            Toggle(label, isOn: Binding(get: { (model.v[id] ?? 0) > 0.5 }, set: { model.set(id, $0 ? 1 : 0) }))
        case "stepper":
            let mn = (c["min"] as? NSNumber)?.doubleValue ?? 0
            let mx = (c["max"] as? NSNumber)?.doubleValue ?? 100
            let step = (c["step"] as? NSNumber)?.doubleValue ?? 1
            Stepper(value: Binding(get: { model.v[id] ?? mn }, set: { model.set(id, $0) }), in: mn...mx, step: step) {
                HStack { Text(label); Spacer(); Text(String(format: "%.0f", model.v[id] ?? 0)).foregroundStyle(.secondary).monospacedDigit() }
            }
        case "button":
            Button(label) { model.press(id) }.buttonStyle(.borderedProminent)
        case "header":
            Text(label).font(.headline)
        case "text":
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        case "divider":
            Divider()
        default:
            EmptyView()
        }
    }
}

final class PanelState {
    var window: NSWindow?
    let model = PanelModel()
}

@_cdecl("sp_create")
public func sp_create() -> UnsafeMutableRawPointer { Unmanaged.passRetained(PanelState()).toOpaque() }

@_cdecl("sp_destroy")
public func sp_destroy(_ h: UnsafeMutableRawPointer?) {
    guard let h = h else { return }
    let s = Unmanaged<PanelState>.fromOpaque(h).takeRetainedValue()
    DispatchQueue.main.async { s.window?.orderOut(nil); s.window?.close(); s.window = nil }
}

@_cdecl("sp_configure")
public func sp_configure(_ h: UnsafeMutableRawPointer?, _ jsonC: UnsafePointer<CChar>?,
                         _ titleC: UnsafePointer<CChar>?, _ x: Double, _ y: Double,
                         _ w: Double, _ hh: Double, _ show: Int32) {
    guard let h = h else { return }
    let s = Unmanaged<PanelState>.fromOpaque(h).takeUnretainedValue()
    let json = jsonC != nil ? String(cString: jsonC!) : "{}"
    let title = titleC != nil ? String(cString: titleC!) : "Panel"
    DispatchQueue.main.async {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let controls = (obj["controls"] as? [[String: Any]]) ?? []
        for c in controls {
            if let id = c["id"] as? String {
                let d = (c["value"] as? NSNumber)?.doubleValue
                    ?? (((c["on"] as? NSNumber)?.boolValue == true) ? 1.0 : 0.0)
                s.model.seed(id, d)
            }
        }
        if show == 0 { s.window?.orderOut(nil); return }
        let content = NSHostingView(rootView: PanelView(model: s.model, controls: controls))
        if s.window == nil {
            let win = NSWindow(contentRect: NSRect(x: x, y: y, width: max(120, w), height: max(80, hh)),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.level = .floating
            win.isReleasedWhenClosed = false
            win.titlebarAppearsTransparent = false
            s.window = win
        }
        s.window?.title = title
        s.window?.setContentSize(NSSize(width: max(120, w), height: max(80, hh)))
        s.window?.contentView = content
        s.window?.orderFront(nil)
    }
}

@_cdecl("sp_value")
public func sp_value(_ h: UnsafeMutableRawPointer?, _ idC: UnsafePointer<CChar>?) -> Double {
    guard let h = h, let idC = idC else { return 0 }
    return Unmanaged<PanelState>.fromOpaque(h).takeUnretainedValue().model.read(String(cString: idC))
}

@_cdecl("sp_take_button")
public func sp_take_button(_ h: UnsafeMutableRawPointer?, _ idC: UnsafePointer<CChar>?) -> Int32 {
    guard let h = h, let idC = idC else { return 0 }
    return Unmanaged<PanelState>.fromOpaque(h).takeUnretainedValue().model.takeBtn(String(cString: idC)) ? 1 : 0
}
