// FoundationModel DAT の Swift ヘルパ（libFMHelper.dylib）。
//
// Apple Intelligence のオンデバイスLLM（FoundationModels framework・macOS 26+・Swift専用）を
// C ABI（fm_*）で ObjC++ プラグインへ提供する。完全オンデバイス・ネットワーク不要。
// 端末で Apple Intelligence が有効になっている必要がある（無効時は status に理由が出る）。
//
// C API:
//   fm_create(instructions)                    セッション生成（システム指示つき）
//   fm_submit(h, prompt, temp, maxTok, keep)   生成を非同期実行（busy 中は false）。
//                                              keep=false なら毎回新しいセッション（文脈を持たない）
//   fm_poll(h, buf, cap)                       状態 JSON {status, busy, history:[{role,text}]}
//   fm_clear(h)                                会話履歴とセッションをリセット
//   fm_destroy(h)

import Foundation
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

    init(instructions: String) {
        self.instructions = instructions
        checkAvailability()
    }

    private func checkAvailability() {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
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
                session = LanguageModelSession(instructions: instructions)
            }
            let sess = session!
            lock.unlock()

            var options = GenerationOptions()
            options.temperature = temperature
            options.maximumResponseTokens = maxTokens

            let stream = sess.streamResponse(to: prompt, options: options)
            for try await partial in stream {
                // partial は累積スナップショット
                lock.lock()
                if generation == gen, var last = history.last, last["role"] == "assistant" {
                    last["text"] = partial.content
                    history[history.count - 1] = last
                }
                lock.unlock()
            }
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
                session = LanguageModelSession(instructions: instructions)
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
            let sess = LanguageModelSession(tools: [tool], instructions: instructions)
            lock.lock(); session = sess; lock.unlock()

            var options = GenerationOptions()
            options.temperature = temperature
            options.maximumResponseTokens = maxTokens

            let resp = try await sess.respond(to: prompt, options: options)
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
