// FoundationModel DAT の Swift ヘルパ（libFMHelper.dylib）。
//
// Apple Intelligence のオンデバイスLLM（FoundationModels framework・macOS 26+・Swift専用）を
// C ABI（fm_*）で ObjC++ プラグインへ提供する。完全オンデバイス・ネットワーク不要。
// 端末で Apple Intelligence が有効になっている必要がある（無効時は status に理由が出る）。
//
// macOS 27(AFM3世代)対応:
//   - Model 選択: On-Device(SystemLanguageModel=AFM3) / Private Cloud Compute
//     (PrivateCloudComputeLanguageModel・Appleのサーバ側大型モデル)
//   - 画像入力: Attachment(CGImage) → Prompt(AFM3 は capabilities.vision 対応)
//   - Reasoning: ContextOptions.ReasoningLevel(light/moderate/deep)
//   - 診断: capabilities / contextSize / usage(トークン数)を poll JSON に出す
//   26以前では #available ガードで従来動作にフォールバックする。
//
// C API:
//   fm_create(instructions)                    セッション生成（システム指示つき）
//   fm_set_config(h, model, reasoning)         モデル(0=on-device/1=PCC)とreasoning(0..3)
//   fm_submit(h, prompt, temp, maxTok, keep)   生成を非同期実行（busy 中は false）。
//                                              keep=false なら毎回新しいセッション（文脈を持たない）
//   fm_submit_image(h, prompt, rgba, w, h, ...) 画像つき生成(BGRA8・top-down)
//   fm_poll(h, buf, cap)                       状態 JSON {status, busy, history:[{role,text}]}
//   fm_clear(h)                                会話履歴とセッションをリセット
//   fm_destroy(h)

import Foundation
import CoreGraphics
import FoundationModels

// 動的ツール: パラメータスキーマを実行時に構築し、呼び出しをホスト(TD)へ委譲する。
// LLM が call を要求すると arguments(JSON)をホストへ渡し、ホストが TD ノードを
// 読み書きした結果(文字列)を await して返す = TouchDesigner をツール実行系にする。
@available(macOS 26.0, *)
final class TDDynamicTool: Tool, @unchecked Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    private let onCall: @Sendable (String, String) async -> String

    init(name: String, description: String, parameters: GenerationSchema,
         onCall: @escaping @Sendable (String, String) async -> String) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.onCall = onCall
    }

    func call(arguments: GeneratedContent) async throws -> String {
        return await onCall(name, arguments.jsonString)
    }
}

@available(macOS 26.0, *)
final class FMSession: @unchecked Sendable {
    private let lock = NSLock()
    private var session: LanguageModelSession?
    private var instructions: String
    private var status = "checking availability"
    private var busy = false
    private var history: [[String: String]] = []   // {role, text}
    private var structured: [String: Any] = [:]    // 最後の構造化出力
    private var generation = 0
    // ツール呼び出し(ホスト実行)の往復状態
    private var pendingToolName = ""
    private var pendingToolArgs = ""
    private var toolCont: CheckedContinuation<String, Never>?
    // AFM3(macOS 27)向け設定と診断
    private var modelKind = 0        // 0=on-device(AFM3) / 1=Private Cloud Compute
    private var reasoningLevel = 0   // 0=off / 1=light / 2=moderate / 3=deep
    private var capabilitiesList: [String] = []
    private var contextSize = 0
    private var inputTokens = 0
    private var outputTokens = 0

    init(instructions: String) {
        self.instructions = instructions
        checkAvailability()
    }

    // モデル/レベル設定(cook毎に呼ばれる)。モデル変更時はセッションを作り直す
    func setConfig(model: Int, reasoning: Int) {
        lock.lock()
        let modelChanged = (model != modelKind)
        modelKind = model
        reasoningLevel = reasoning
        if modelChanged {
            session = nil
            capabilitiesList = []
            contextSize = 0
        }
        lock.unlock()
        if modelChanged { checkAvailability() }
    }

    private func checkAvailability() {
        lock.lock(); let kind = modelKind; lock.unlock()
        if kind == 1 {
#if TD_AFM3
            // Private Cloud Compute(Appleサーバ側モデル・macOS 27+)
            guard #available(macOS 27.0, *) else {
                setStatus("unavailable: Private Cloud Compute requires macOS 27+")
                return
            }
            let pcc = PrivateCloudComputeLanguageModel()
            switch pcc.availability {
            case .available:
                updateCapabilities(pcc.capabilities)
                setStatus("ready (Private Cloud Compute)")
                Task { [weak self] in   // contextSize は PCC 専用・async
                    if let cs = try? await pcc.contextSize {
                        self?.lock.lock()
                        self?.contextSize = cs
                        self?.lock.unlock()
                    }
                }
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    setStatus("unavailable: device not eligible (PCC)")
                case .systemNotReady:
                    setStatus("unavailable: PCC system not ready (ネットワーク/サインイン確認)")
                @unknown default:
                    setStatus("unavailable (PCC)")
                }
            }
#else
            // macOS 26 SDK には PrivateCloudComputeLanguageModel が無い(型ごと不在なので
            // #available では解決できない)。27 SDK でビルドしたときだけ有効になる
            setStatus("unavailable: Private Cloud Compute requires building on the macOS 27 SDK")
#endif
            return
        }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
#if TD_AFM3
            if #available(macOS 27.0, *) { updateCapabilities(model.capabilities) }
#endif
            setStatus("ready")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                setStatus("unavailable: device not eligible")
            case .appleIntelligenceNotEnabled:
                setStatus("unavailable: Apple Intelligence not enabled (設定で有効化が必要)")
            case .modelNotReady:
                setStatus("unavailable: model not ready (ダウンロード中の可能性)")
            @unknown default:
                setStatus("unavailable")
            }
        }
    }

#if TD_AFM3
    @available(macOS 27.0, *)
    private func updateCapabilities(_ caps: LanguageModelCapabilities) {
        var list: [String] = []
        if caps.contains(.vision) { list.append("vision") }
        if caps.contains(.reasoning) { list.append("reasoning") }
        if caps.contains(.toolCalling) { list.append("toolCalling") }
        if caps.contains(.guidedGeneration) { list.append("guidedGeneration") }
        lock.lock(); capabilitiesList = list; lock.unlock()
    }
#endif

    // 選択中モデルでセッションを生成(macOS 27はmodel指定・26以前は従来の既定モデル)
    private func makeSession(tools: [any Tool] = []) -> LanguageModelSession {
#if TD_AFM3
        if #available(macOS 27.0, *), modelKind == 1 {
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
                                        tools: tools, instructions: instructions)
        }
#endif
        return LanguageModelSession(tools: tools, instructions: instructions)
    }

    // ContextOptions(reasoningLevel)。off または macOS 26以前では nil
#if TD_AFM3
    @available(macOS 27.0, *)
    private func makeContextOptions() -> ContextOptions? {
        lock.lock(); let lv = reasoningLevel; lock.unlock()
        switch lv {
        case 1: return ContextOptions(reasoningLevel: .light)
        case 2: return ContextOptions(reasoningLevel: .moderate)
        case 3: return ContextOptions(reasoningLevel: .deep)
        default: return nil
        }
    }
#endif

    // 生成完了後に usage を取り込む(macOS 27)。
    // contextSize は PCC モデル専用のプロパティで、checkAvailability 時に取得する
    private func captureUsage(_ sess: LanguageModelSession) async {
#if TD_AFM3
        guard #available(macOS 27.0, *) else { return }
        let usage = sess.usage
        let inTok = usage.input.totalTokenCount
        let outTok = usage.output.totalTokenCount
        lock.lock()
        inputTokens = inTok
        outputTokens = outTok
        lock.unlock()
#endif
    }

    private func setStatus(_ s: String) {
        lock.lock()
        status = s
        lock.unlock()
    }

    func submit(prompt: String, temperature: Double, maxTokens: Int, keepContext: Bool)
        -> Bool
    {
        lock.lock()
        if busy {
            lock.unlock()
            return false
        }
        busy = true
        status = "generating"
        history.append(["role": "user", "text": prompt])
        history.append(["role": "assistant", "text": ""])
        let gen = generation + 1
        generation = gen
        lock.unlock()

        Task { [weak self] in
            await self?.run(prompt: prompt, temperature: temperature,
                            maxTokens: maxTokens, keepContext: keepContext, gen: gen)
        }
        return true
    }

    private func run(prompt: String, temperature: Double, maxTokens: Int,
                     keepContext: Bool, gen: Int) async
    {
        do {
            lock.lock()
            if !keepContext || session == nil {
                lock.unlock()
                let s = makeSession()
                lock.lock()
                session = s
            }
            let sess = session!
            lock.unlock()

            var options = GenerationOptions()
            options.temperature = temperature
            options.maximumResponseTokens = maxTokens

            // partial は累積スナップショット。**Swift の #if は波括弧が閉じた単位でしか
            // 使えない**(C のテキスト置換と違い、if の途中で切ると構文エラーになる)ため、
            // 受け取り側をクロージャに切り出して分岐ごと丸ごと書く
            let consume: (String) -> Void = { [self] text in
                lock.lock()
                if generation == gen, var last = history.last, last["role"] == "assistant" {
                    last["text"] = text
                    history[history.count - 1] = last
                }
                lock.unlock()
            }
#if TD_AFM3
            if #available(macOS 27.0, *), let co = makeContextOptions() {
                for try await partial in sess.streamResponse(to: prompt, options: options,
                                                             contextOptions: co) {
                    consume(partial.content)
                }
            } else {
                for try await partial in sess.streamResponse(to: prompt, options: options) {
                    consume(partial.content)
                }
            }
#else
            for try await partial in sess.streamResponse(to: prompt, options: options) {
                consume(partial.content)
            }
#endif
            await captureUsage(sess)
            lock.lock()
            busy = false
            status = "ready"
            lock.unlock()
        } catch {
            lock.lock()
            busy = false
            status = "error: \(error.localizedDescription)"
            if var last = history.last, last["role"] == "assistant", last["text"]!.isEmpty {
                last["text"] = "(エラー)"
                history[history.count - 1] = last
            }
            lock.unlock()
        }
    }

    // ------------------------------------------------- 画像つき生成(AFM3 vision・macOS 27+)
    // bgra: BGRA8・top-down(TDのdownloadTexture verticalFlip=true の出力)
    func submitImage(prompt: String, bgra: Data, width: Int, height: Int,
                     temperature: Double, maxTokens: Int, keepContext: Bool) -> Bool
    {
#if !TD_AFM3
        // 26 SDK には Attachment が無い。27 SDK でビルドしたときだけ使える
        setStatus("error: image input requires building on the macOS 27 SDK")
        return false
#else
        guard #available(macOS 27.0, *) else {
            setStatus("error: image input requires macOS 27+")
            return false
        }
        lock.lock()
        if busy {
            lock.unlock()
            return false
        }
        if !capabilitiesList.contains("vision") {
            status = "error: selected model does not support vision"
            lock.unlock()
            return false
        }
        busy = true
        status = "generating"
        history.append(["role": "user", "text": "[image] " + prompt])
        history.append(["role": "assistant", "text": ""])
        let gen = generation + 1
        generation = gen
        lock.unlock()

        Task { [weak self] in
            await self?.runImage(prompt: prompt, bgra: bgra, width: width, height: height,
                                 temperature: temperature, maxTokens: maxTokens,
                                 keepContext: keepContext, gen: gen)
        }
        return true
#endif
    }

#if TD_AFM3
    @available(macOS 27.0, *)
    private func runImage(prompt: String, bgra: Data, width: Int, height: Int,
                          temperature: Double, maxTokens: Int, keepContext: Bool,
                          gen: Int) async
    {
        do {
            // BGRA8(little-endian)→ CGImage。アルファは無視(noneSkipFirst)
            guard let provider = CGDataProvider(data: bgra as CFData),
                  let image = CGImage(
                      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                               | CGBitmapInfo.byteOrder32Little.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true,
                      intent: .defaultIntent)
            else {
                lock.lock(); busy = false; status = "error: cannot build CGImage"; lock.unlock()
                return
            }
            lock.lock()
            if !keepContext || session == nil {
                lock.unlock()
                let s = makeSession()
                lock.lock()
                session = s
            }
            let sess = session!
            lock.unlock()

            var options = GenerationOptions()
            options.temperature = temperature
            options.maximumResponseTokens = maxTokens
            let co = makeContextOptions() ?? ContextOptions()

            let attachment = Attachment(image)
            let stream = sess.streamResponse(options: options, contextOptions: co) {
                attachment
                prompt
            }
            for try await partial in stream {
                lock.lock()
                if generation == gen, var last = history.last, last["role"] == "assistant" {
                    last["text"] = partial.content
                    history[history.count - 1] = last
                }
                lock.unlock()
            }
            await captureUsage(sess)
            lock.lock()
            busy = false
            status = "ready"
            lock.unlock()
        } catch {
            lock.lock()
            busy = false
            status = "error: \(error.localizedDescription)"
            if var last = history.last, last["role"] == "assistant", last["text"]!.isEmpty {
                last["text"] = "(エラー)"
                history[history.count - 1] = last
            }
            lock.unlock()
        }
    }
#endif

    // ------------------------------------------------- 構造化出力
    // schemaSpec: "color:string" 改行区切り(type ∈ string|number|int|bool)
    func submitStructured(prompt: String, schemaSpec: String, temperature: Double,
                          maxTokens: Int, keepContext: Bool) -> Bool
    {
        lock.lock()
        if busy {
            lock.unlock()
            return false
        }
        busy = true
        status = "generating"
        history.append(["role": "user", "text": prompt])
        history.append(["role": "assistant", "text": ""])
        let gen = generation + 1
        generation = gen
        lock.unlock()

        Task { [weak self] in
            await self?.runStructured(prompt: prompt, schemaSpec: schemaSpec,
                                      temperature: temperature, maxTokens: maxTokens,
                                      keepContext: keepContext, gen: gen)
        }
        return true
    }

    private func runStructured(prompt: String, schemaSpec: String, temperature: Double,
                               maxTokens: Int, keepContext: Bool, gen: Int) async
    {
        do {
            // "name:type" 行 → DynamicGenerationSchema
            var fields: [(String, String)] = []
            var props: [DynamicGenerationSchema.Property] = []
            for rawLine in schemaSpec.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
                let parts = rawLine.split(separator: ":", maxSplits: 1)
                guard let n = parts.first?.trimmingCharacters(in: .whitespaces),
                      !n.isEmpty else { continue }
                let t = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespaces).lowercased() : "string"
                fields.append((n, t))
                let s: DynamicGenerationSchema
                switch t {
                case "number", "float", "double":
                    s = DynamicGenerationSchema(type: Double.self)
                case "int", "integer":
                    s = DynamicGenerationSchema(type: Int.self)
                case "bool", "boolean":
                    s = DynamicGenerationSchema(type: Bool.self)
                default:
                    s = DynamicGenerationSchema(type: String.self)
                }
                props.append(DynamicGenerationSchema.Property(
                    name: n, description: nil, schema: s))
            }
            let root = DynamicGenerationSchema(name: "Output", description: nil,
                                               properties: props)
            let schema = try GenerationSchema(root: root, dependencies: [])

            lock.lock()
            if !keepContext || session == nil {
                lock.unlock()
                let s = makeSession()
                lock.lock()
                session = s
            }
            let sess = session!
            lock.unlock()

            var options = GenerationOptions()
            options.temperature = temperature
            options.maximumResponseTokens = maxTokens

            let resp = try await sess.respond(to: prompt, schema: schema,
                                              options: options)
            let content = resp.content
            var dict: [String: Any] = [:]
            for (n, t) in fields {
                switch t {
                case "number", "float", "double":
                    dict[n] = (try? content.value(Double.self, forProperty: n)) ?? 0
                case "int", "integer":
                    dict[n] = (try? content.value(Int.self, forProperty: n)) ?? 0
                case "bool", "boolean":
                    dict[n] = (try? content.value(Bool.self, forProperty: n)) ?? false
                default:
                    dict[n] = (try? content.value(String.self, forProperty: n)) ?? ""
                }
            }
            let jsonText: String
            if let d = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: d, encoding: .utf8) { jsonText = s }
            else { jsonText = "{}" }

            await captureUsage(sess)
            lock.lock()
            structured = dict
            if generation == gen, var last = history.last, last["role"] == "assistant" {
                last["text"] = jsonText
                history[history.count - 1] = last
            }
            busy = false
            status = "ready"
            lock.unlock()
        } catch {
            lock.lock()
            busy = false
            status = "error: \(error.localizedDescription)"
            lock.unlock()
        }
    }

    // ------------------------------------------------- ツール呼び出し(ホスト実行)
    // "name:type" 行 → GenerationSchema(ツールの parameters に使う)
    private func buildSchema(_ spec: String, rootName: String) throws -> GenerationSchema {
        var props: [DynamicGenerationSchema.Property] = []
        for rawLine in spec.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let parts = rawLine.split(separator: ":", maxSplits: 1)
            guard let n = parts.first?.trimmingCharacters(in: .whitespaces),
                  !n.isEmpty else { continue }
            let t = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces).lowercased() : "string"
            let s: DynamicGenerationSchema
            switch t {
            case "number", "float", "double": s = DynamicGenerationSchema(type: Double.self)
            case "int", "integer": s = DynamicGenerationSchema(type: Int.self)
            case "bool", "boolean": s = DynamicGenerationSchema(type: Bool.self)
            default: s = DynamicGenerationSchema(type: String.self)
            }
            props.append(DynamicGenerationSchema.Property(name: n, description: nil, schema: s))
        }
        let root = DynamicGenerationSchema(name: rootName, description: nil, properties: props)
        return try GenerationSchema(root: root, dependencies: [])
    }

    // ツールが呼ばれたらホスト(TD)へ引数を渡し、結果が来るまで await する
    func hostToolCall(name: String, argsJSON: String) async -> String {
        return await withCheckedContinuation { cont in
            lock.lock()
            pendingToolName = name
            pendingToolArgs = argsJSON
            status = "tool_call"
            toolCont = cont
            lock.unlock()
        }
    }

    // ホスト(TD)がツール結果を返す → 停止していた生成を再開させる
    func provideToolResult(_ result: String) {
        lock.lock()
        let c = toolCont
        toolCont = nil
        pendingToolName = ""
        pendingToolArgs = ""
        if c != nil { status = "generating" }
        lock.unlock()
        c?.resume(returning: result)
    }

    func submitWithTool(prompt: String, toolName: String, toolDesc: String,
                        toolParams: String, temperature: Double, maxTokens: Int) -> Bool {
        lock.lock()
        if busy { lock.unlock(); return false }
        busy = true
        status = "generating"
        history.append(["role": "user", "text": prompt])
        history.append(["role": "assistant", "text": ""])
        let gen = generation + 1
        generation = gen
        lock.unlock()

        Task { [weak self] in
            await self?.runWithTool(prompt: prompt, toolName: toolName, toolDesc: toolDesc,
                                    toolParams: toolParams, temperature: temperature,
                                    maxTokens: maxTokens, gen: gen)
        }
        return true
    }

    private func runWithTool(prompt: String, toolName: String, toolDesc: String,
                             toolParams: String, temperature: Double, maxTokens: Int,
                             gen: Int) async {
        do {
            let schema = try buildSchema(toolParams.isEmpty ? "query:string" : toolParams,
                                         rootName: "Arguments")
            let tool = TDDynamicTool(
                name: toolName.isEmpty ? "td_tool" : toolName,
                description: toolDesc,
                parameters: schema,
                onCall: { [weak self] n, a in
                    await self?.hostToolCall(name: n, argsJSON: a) ?? "{}"
                })
            // tools はセッション生成時に固定。ツール利用は毎回新規セッション
            let sess = makeSession(tools: [tool])
            lock.lock(); session = sess; lock.unlock()

            var options = GenerationOptions()
            options.temperature = temperature
            options.maximumResponseTokens = maxTokens

            let resp = try await sess.respond(to: prompt, options: options)
            await captureUsage(sess)
            lock.lock()
            if generation == gen, var last = history.last, last["role"] == "assistant" {
                last["text"] = resp.content
                history[history.count - 1] = last
            }
            busy = false
            status = "ready"
            pendingToolName = ""
            pendingToolArgs = ""
            lock.unlock()
        } catch {
            lock.lock()
            busy = false
            status = "error: \(error.localizedDescription)"
            let c = toolCont
            toolCont = nil
            pendingToolName = ""
            pendingToolArgs = ""
            lock.unlock()
            c?.resume(returning: "{}")   // 走行中のtool callを解放
        }
    }

    func clear() {
        lock.lock()
        history.removeAll()
        session = nil
        generation += 1     // 走行中のストリームを無効化
        let c = toolCont
        toolCont = nil
        pendingToolName = ""
        pendingToolArgs = ""
        busy = false
        lock.unlock()
        c?.resume(returning: "{}")
        checkAvailability()
    }

    func pollJSON() -> String {
        lock.lock()
        let dict: [String: Any] = [
            "status": status,
            "busy": busy,
            "history": history,
            "structured": structured,
            "pending_tool": pendingToolName,
            "pending_tool_args": pendingToolArgs,
            "model": modelKind == 1 ? "pcc" : "ondevice",
            "capabilities": capabilitiesList,
            "context_size": contextSize,
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
        ]
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"json error\"}"
        }
        return json
    }
}

// ------------------------------------------------------------------ C ABI

@_cdecl("fm_create")
public func fm_create(_ instructions: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard #available(macOS 26.0, *) else { return nil }
    let session = FMSession(
        instructions: instructions.map { String(cString: $0) } ?? "")
    return Unmanaged.passRetained(session).toOpaque()
}

@_cdecl("fm_submit")
public func fm_submit(_ handle: UnsafeMutableRawPointer?, _ prompt: UnsafePointer<CChar>?,
                      _ temperature: Double, _ maxTokens: Int32, _ keepContext: Bool)
    -> Bool
{
    guard #available(macOS 26.0, *), let handle, let prompt else { return false }
    let session = Unmanaged<FMSession>.fromOpaque(handle).takeUnretainedValue()
    return session.submit(prompt: String(cString: prompt), temperature: temperature,
                          maxTokens: Int(maxTokens), keepContext: keepContext)
}

@_cdecl("fm_poll")
public func fm_poll(_ handle: UnsafeMutableRawPointer?,
                    _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32
{
    guard let buffer, capacity > 0 else { return 0 }
    var json = "{\"status\":\"requires macOS 26\"}"
    if #available(macOS 26.0, *), let handle {
        let session = Unmanaged<FMSession>.fromOpaque(handle).takeUnretainedValue()
        json = session.pollJSON()
    }
    let utf8 = Array(json.utf8.prefix(Int(capacity) - 1))
    memcpy(buffer, utf8, utf8.count)
    buffer[utf8.count] = 0
    return Int32(utf8.count)
}

@_cdecl("fm_set_config")
public func fm_set_config(_ handle: UnsafeMutableRawPointer?, _ model: Int32,
                          _ reasoning: Int32)
{
    guard #available(macOS 26.0, *), let handle else { return }
    let session = Unmanaged<FMSession>.fromOpaque(handle).takeUnretainedValue()
    session.setConfig(model: Int(model), reasoning: Int(reasoning))
}

@_cdecl("fm_submit_image")
public func fm_submit_image(_ handle: UnsafeMutableRawPointer?,
                            _ prompt: UnsafePointer<CChar>?,
                            _ bgra: UnsafePointer<UInt8>?,
                            _ width: Int32, _ height: Int32,
                            _ temperature: Double, _ maxTokens: Int32,
                            _ keepContext: Bool) -> Bool
{
    guard #available(macOS 26.0, *), let handle, let prompt, let bgra,
          width > 0, height > 0 else { return false }
    let session = Unmanaged<FMSession>.fromOpaque(handle).takeUnretainedValue()
    let data = Data(bytes: bgra, count: Int(width) * Int(height) * 4)   // コピーして所有
    return session.submitImage(prompt: String(cString: prompt), bgra: data,
                               width: Int(width), height: Int(height),
                               temperature: temperature, maxTokens: Int(maxTokens),
                               keepContext: keepContext)
}

@_cdecl("fm_submit_structured")
public func fm_submit_structured(_ handle: UnsafeMutableRawPointer?,
                                 _ prompt: UnsafePointer<CChar>?,
                                 _ schema: UnsafePointer<CChar>?,
                                 _ temperature: Double, _ maxTokens: Int32,
                                 _ keepContext: Bool) -> Bool
{
    guard #available(macOS 26.0, *), let handle, let prompt, let schema else {
        return false
    }
    let session = Unmanaged<FMSession>.fromOpaque(handle).takeUnretainedValue()
    return session.submitStructured(prompt: String(cString: prompt),
                                    schemaSpec: String(cString: schema),
                                    temperature: temperature,
                                    maxTokens: Int(maxTokens), keepContext: keepContext)
}

@_cdecl("fm_submit_tool")
public func fm_submit_tool(_ handle: UnsafeMutableRawPointer?,
                          _ prompt: UnsafePointer<CChar>?,
                          _ toolName: UnsafePointer<CChar>?,
                          _ toolDesc: UnsafePointer<CChar>?,
                          _ toolParams: UnsafePointer<CChar>?,
                          _ temperature: Double, _ maxTokens: Int32) -> Bool {
    guard #available(macOS 26.0, *), let handle, let prompt else { return false }
    let session = Unmanaged<FMSession>.fromOpaque(handle).takeUnretainedValue()
    return session.submitWithTool(
        prompt: String(cString: prompt),
        toolName: toolName.map { String(cString: $0) } ?? "td_tool",
        toolDesc: toolDesc.map { String(cString: $0) } ?? "",
        toolParams: toolParams.map { String(cString: $0) } ?? "",
        temperature: temperature, maxTokens: Int(maxTokens))
}

@_cdecl("fm_tool_result")
public func fm_tool_result(_ handle: UnsafeMutableRawPointer?,
                          _ result: UnsafePointer<CChar>?) {
    guard #available(macOS 26.0, *), let handle else { return }
    let session = Unmanaged<FMSession>.fromOpaque(handle).takeUnretainedValue()
    session.provideToolResult(result.map { String(cString: $0) } ?? "{}")
}

@_cdecl("fm_clear")
public func fm_clear(_ handle: UnsafeMutableRawPointer?) {
    guard #available(macOS 26.0, *), let handle else { return }
    Unmanaged<FMSession>.fromOpaque(handle).takeUnretainedValue().clear()
}

@_cdecl("fm_destroy")
public func fm_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard #available(macOS 26.0, *), let handle else { return }
    Unmanaged<FMSession>.fromOpaque(handle).release()
}
