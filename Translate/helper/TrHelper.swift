// Translate DAT の Swift ヘルパ（libTrHelper.dylib）。
//
// Apple の Translation framework（macOS 15+・オンデバイス翻訳）を C ABI（tr_*）で
// ObjC++ プラグインへ提供する。
//
// 重要な実装事情: TranslationSession は公開イニシャライザが無く、SwiftUI の
// .translationTask 修飾子経由でしか取得できない。そのため**不可視の 1x1 ウインドウ**に
// NSHostingView を貼り、translationTask のクロージャ内でワークキューを回し続ける
// ことでセッションを保持する（コミュニティ定石のワークアラウンド）。
//
// C API:
//   tr_create()                        セッション生成（不可視ウインドウはメインスレッドで生成）
//   tr_set_languages(h, src, tgt)      言語ペア設定（例 "ja" → "en"。変更で作り直し）
//   tr_submit(h, text)                 翻訳を依頼（キャッシュ/実行中なら何もしない）
//   tr_get(h, text, buf, cap) -> int   0=未依頼 / 1=翻訳中 / 2=完了（buf に訳文）
//   tr_status(h, buf, cap)             状態文字列
//   tr_clear(h)                        キャッシュをクリア
//   tr_destroy(h)

import AppKit
import Foundation
import SwiftUI
import Translation


// ------------------------------------------------------------------ core

@available(macOS 15.0, *)
final class TrCore: @unchecked Sendable {
    let lock = NSLock()
    var pending: [String] = []
    var inflight: Set<String> = []
    var results: [String: String] = [:]
    var status = "starting"
    var wake: AsyncStream<Void>.Continuation?

    func setStatus(_ s: String) {
        lock.lock()
        status = s
        lock.unlock()
    }

    func enqueue(_ text: String) {
        lock.lock()
        let known = results[text] != nil || inflight.contains(text) || pending.contains(text)
        if !known {
            pending.append(text)
        }
        let w = wake
        lock.unlock()
        if !known {
            w?.yield(())
        }
    }

    private func popPending() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if pending.isEmpty {
            return nil
        }
        let text = pending.removeFirst()
        inflight.insert(text)
        return text
    }

    private func store(_ text: String, _ translated: String) {
        lock.lock()
        inflight.remove(text)
        results[text] = translated
        lock.unlock()
    }

    // translationTask のクロージャから呼ばれ、セッションが有効な間キューを回し続ける
    func run(session: TranslationSession) async {
        do {
            try await session.prepareTranslation()   // 言語モデル未導入ならダウンロード
        } catch {
            setStatus("prepare error: \(error.localizedDescription)")
        }
        setStatus("ready")
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        lock.lock()
        wake = cont
        lock.unlock()
        cont.yield(())   // 積み残しがあれば処理

        for await _ in stream {
            while let text = popPending() {
                do {
                    let response = try await session.translate(text)
                    store(text, response.targetText)
                    setStatus("ready")
                } catch {
                    store(text, "")
                    setStatus("translate error: \(error.localizedDescription)")
                }
            }
            if Task.isCancelled {
                break
            }
        }
    }
}

// ------------------------------------------------------------------ SwiftUI 足場

@available(macOS 15.0, *)
final class TrModel: ObservableObject {
    @Published var config: TranslationSession.Configuration?
}

@available(macOS 15.0, *)
struct TrView: View {
    @ObservedObject var model: TrModel
    let core: TrCore

    var body: some View {
        Color.clear
            .translationTask(model.config) { session in
                await core.run(session: session)
            }
    }
}

// ------------------------------------------------------------------ session handle

@available(macOS 15.0, *)
final class TrSession: @unchecked Sendable {
    let core = TrCore()
    private var model: TrModel?
    private var window: NSWindow?
    private var srcLang = ""
    private var tgtLang = ""

    init() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let model = TrModel()
            let hosting = NSHostingView(rootView: TrView(model: model, core: self.core))
            hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            // ほぼ不可視のウインドウに貼って translationTask を発火させる。
            // 完全な画面外/alpha0 だと SwiftUI が「表示された」と見なさず task が
            // 走らないため、画面隅に 2x2px・alpha 0.01 で置く
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.alphaValue = 0.01
            window.level = .floating
            window.contentView = hosting
            window.orderFrontRegardless()
            window.displayIfNeeded()
            self.model = model
            self.window = window
        }
    }

    func setLanguages(_ src: String, _ tgt: String) {
        guard src != srcLang || tgt != tgtLang else { return }
        srcLang = src
        tgtLang = tgt
        core.lock.lock()
        core.results.removeAll()
        core.inflight.removeAll()
        core.pending.removeAll()
        core.lock.unlock()
        core.setStatus("loading language pair \(src) → \(tgt)")
        DispatchQueue.main.async { [weak self] in
            self?.model?.config = TranslationSession.Configuration(
                source: Locale.Language(identifier: src),
                target: Locale.Language(identifier: tgt))
        }
    }

    func destroy() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.model = nil
        }
    }
}

// ------------------------------------------------------------------ C ABI

@_cdecl("tr_create")
public func tr_create() -> UnsafeMutableRawPointer? {
    guard #available(macOS 15.0, *) else { return nil }
    return Unmanaged.passRetained(TrSession()).toOpaque()
}

@_cdecl("tr_set_languages")
public func tr_set_languages(_ handle: UnsafeMutableRawPointer?,
                             _ src: UnsafePointer<CChar>?, _ tgt: UnsafePointer<CChar>?) {
    guard #available(macOS 15.0, *), let handle, let src, let tgt else { return }
    Unmanaged<TrSession>.fromOpaque(handle).takeUnretainedValue()
        .setLanguages(String(cString: src), String(cString: tgt))
}

@_cdecl("tr_submit")
public func tr_submit(_ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?) {
    guard #available(macOS 15.0, *), let handle, let text else { return }
    let s = String(cString: text)
    if !s.isEmpty {
        Unmanaged<TrSession>.fromOpaque(handle).takeUnretainedValue().core.enqueue(s)
    }
}

@_cdecl("tr_get")
public func tr_get(_ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?,
                   _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard #available(macOS 15.0, *), let handle, let text else { return 0 }
    let core = Unmanaged<TrSession>.fromOpaque(handle).takeUnretainedValue().core
    let s = String(cString: text)
    core.lock.lock()
    let result = core.results[s]
    let busy = core.inflight.contains(s) || core.pending.contains(s)
    core.lock.unlock()
    if let result {
        if let buffer, capacity > 0 {
            let utf8 = Array(result.utf8.prefix(Int(capacity) - 1))
            memcpy(buffer, utf8, utf8.count)
            buffer[utf8.count] = 0
        }
        return 2
    }
    return busy ? 1 : 0
}

@_cdecl("tr_status")
public func tr_status(_ handle: UnsafeMutableRawPointer?,
                      _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return 0 }
    var status = "requires macOS 15"
    if #available(macOS 15.0, *), let handle {
        let core = Unmanaged<TrSession>.fromOpaque(handle).takeUnretainedValue().core
        core.lock.lock()
        status = core.status
        core.lock.unlock()
    }
    let utf8 = Array(status.utf8.prefix(Int(capacity) - 1))
    memcpy(buffer, utf8, utf8.count)
    buffer[utf8.count] = 0
    return Int32(utf8.count)
}

@_cdecl("tr_clear")
public func tr_clear(_ handle: UnsafeMutableRawPointer?) {
    guard #available(macOS 15.0, *), let handle else { return }
    let core = Unmanaged<TrSession>.fromOpaque(handle).takeUnretainedValue().core
    core.lock.lock()
    core.results.removeAll()
    core.pending.removeAll()
    core.lock.unlock()
}

@_cdecl("tr_destroy")
public func tr_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard #available(macOS 15.0, *), let handle else { return }
    let session = Unmanaged<TrSession>.fromOpaque(handle).takeRetainedValue()
    session.destroy()
}
