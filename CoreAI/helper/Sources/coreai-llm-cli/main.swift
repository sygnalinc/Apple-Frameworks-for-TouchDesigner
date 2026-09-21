// coreai-llm-cli — LLM CoreAI DAT のヘルパ(常駐プロセス)
//
// 使い方:
//   coreai-llm-cli --serve                     JSON-lines プロトコル(DAT が使う)
//   coreai-llm-cli <bundle dir> [prompt] [img]  単発生成(手動テスト)
//
// --serve プロトコル(LLM MLX の mlxllm-helper と同じ形)
//   stdin  1行1JSON:
//     {"cmd":"load","model":"/path/to/exports/qwen3_1_7b_4bit_dynamic"}
//     {"cmd":"gen","prompt":"...","system":"...","temp":0.7,"max":512,"keep":true,
//      "image":"/tmp/x.png","think":false}
//     {"cmd":"reset"}   {"cmd":"quit"}
//   stdout 1行1イベント(flush 済み):
//     {"type":"status","text":"..."} {"type":"progress","pct":50}
//     {"type":"ready","kind":"llm|vlm","name":"...","context":32768}
//     {"type":"token","text":"..."}  {"type":"think","text":"..."}(推論モデルの思考部分)
//     {"type":"done","tokens":N,"tps":34.2}  {"type":"error","text":"..."}
//   stderr: 人間向けログのみ
//
// モデルバンドルは Apple coreai-models の export 形式(metadata.json / *.aimodel / tokenizer)。
// LLM(main のみ)と VLM(main + vision + embedding)を metadata の kind で自動判別する。
import CoreAI
import CoreAILanguageModels
import CoreAIShared
import CoreImage
import Foundation
import Tokenizers

let emitLock = NSLock()
func emit(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj),
          var s = String(data: d, encoding: .utf8) else { return }
    s += "\n"
    emitLock.lock()
    FileHandle.standardOutput.write(s.data(using: .utf8)!)
    emitLock.unlock()
}
func logErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// ロード済みモデル一式
struct Loaded {
    let bundle: LanguageBundle
    let engine: any InferenceEngine
    let tokenizer: any Tokenizer
    let extraEOS: [Int32]
    let thinking: ThinkTagParser.Format
    var isVLM: Bool { engine is any MultimodalInferenceEngine }
}

func loadBundle(_ path: String) async throws -> Loaded {
    let bundle = try LanguageBundle(from: path)
    try bundle.bundle.verify()
    let isVLM = bundle.bundle.kind == .vlm
    let mainURL = try bundle.requireModelURL(for: ModelBundle.ComponentKey.main)
    let visionURL = isVLM ? try bundle.requireModelURL(for: ModelBundle.ComponentKey.vision) : nil
    let embedURL = isVLM ? try bundle.requireModelURL(for: ModelBundle.ComponentKey.embedding) : nil

    let cached = PreparedModel.isCached(at: mainURL)
    emit(["type": "status", "text": cached ? "loading (cached)" : "preparing model (first time: minutes)"])
    emit(["type": "progress", "pct": 5])

    async let tokenizerTask = bundle.loadTokenizer()
    let options = EngineOptions()
    let engine: any InferenceEngine
    if let visionURL, let embedURL {
        guard let visionConfig = bundle.visionConfig else {
            throw NSError(domain: "coreai-llm", code: 1, userInfo: [NSLocalizedDescriptionKey: "VLM bundle has no vision config"])
        }
        let base = ModelConfig(name: bundle.name, tokenizer: bundle.tokenizer, vocabSize: bundle.vocabSize,
                               maxContextLength: bundle.maxContextLength, serializedModel: [mainURL.path],
                               function: bundle.language.functionMap?.name(for: "main") ?? "main")
        let cfg = VLMModelConfig(base: base, visionConfig: visionConfig)
        // 3モデルは直列で(並列だと実行時エラー・llm-runner の注記どおり)
        emit(["type": "status", "text": "preparing vision model"])
        let vision = try await PreparedModel.prepare(at: visionURL)
        emit(["type": "progress", "pct": 30])
        emit(["type": "status", "text": "preparing embedding model"])
        let embed = try await PreparedModel.prepare(at: embedURL)
        emit(["type": "progress", "pct": 50])
        emit(["type": "status", "text": "preparing language model"])
        let llm = try await PreparedModel.prepare(at: mainURL)
        emit(["type": "progress", "pct": 90])
        engine = try await CoreAISequentialVLMEngine(config: cfg, visionModel: vision, embedModel: embed,
                                                     llmModel: llm, options: options)
    } else {
        let cfg = ModelConfig(name: bundle.name, tokenizer: bundle.tokenizer, vocabSize: bundle.vocabSize,
                              maxContextLength: bundle.maxContextLength, serializedModel: [bundle.modelAssetPath],
                              function: bundle.language.functionMap?.name(for: "main") ?? "main")
        let data = try JSONEncoder().encode(cfg)
        emit(["type": "status", "text": "preparing language model"])
        engine = try await EngineFactory.createEngine(config: data, modelURL: mainURL, options: options)
        emit(["type": "progress", "pct": 90])
    }
    let tokenizer = try await tokenizerTask
    var extra: [Int32] = []
    if let dir = bundle.tokenizerPath {
        extra = LanguageConfig.additionalStopTokenIds(from: dir, tokenizer: tokenizer)
    }
    // coreai-models のエクスポータは tokenizer_config.json から added_tokens_decoder を落とすので、
    // 上の関数は Gemma の <end_of_turn> や Phi の <|end|> を拾えない(実測: stops=[] のまま
    // 生成が止まらず <end_of_turn> を吐き続ける)。既知のターン終端トークンを語彙から直接引く
    let mainEos = tokenizer.eosTokenId.map { Int32($0) }
    for name in ["<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<|end|>", "<|endoftext|>",
                 "<|return|>", "<|call|>", "<|eom_id|>", "</s>", "<eos>"] {
        // 1トークンに符号化されて復号が同じ文字列なら、その語彙に実在する特殊トークン
        let ids = tokenizer.encode(text: name, addSpecialTokens: false)
        if ids.count == 1, tokenizer.decode(tokens: ids, skipSpecialTokens: false) == name {
            let id32 = Int32(ids[0])
            if id32 != mainEos, !extra.contains(id32) { extra.append(id32) }
        }
    }
    return Loaded(bundle: bundle, engine: engine, tokenizer: tokenizer, extraEOS: extra,
                  thinking: detectThinkingFormat(using: tokenizer))
}

/// 会話履歴 → チャットテンプレート適用済みトークン列
func templateTokens(_ messages: [[String: any Sendable]], _ tok: any Tokenizer) -> [Int] {
    if let t = try? tok.applyChatTemplate(messages: messages) { return t }
    let text = messages.map { "\($0["role"] ?? "user"): \($0["content"] ?? "")" }.joined(separator: "\n")
    return tok.encode(text: text)
}

/// 生成1回。戻り値は表示テキスト(思考部分を除く)
func generate(_ m: Loaded, messages: [[String: any Sendable]],
              temp: Double, maxTok: Int) async throws -> String {
    let sampling: SamplingConfiguration = temp <= 0 ? .greedy : SamplingConfiguration(temperature: temp)
    let stops = StopSequences(for: m.tokenizer, additionalEosTokenIds: m.extraEOS)
    var parser = ThinkTagParser(format: m.thinking)
    var visible = ""
    var count = 0
    let t0 = Date()
    var tFirst: Date? = nil

    func handle(_ delta: String) {
        if delta.isEmpty { return }
        if tFirst == nil { tFirst = Date() }
        count += 1
        for ev in parser.consume(delta) {
            switch ev {
            case .text(let t) where !t.isEmpty:
                // 思考ブロック除去後に残る先頭の改行(Qwen3 の "<think>\n\n</think>\n\n")は出さない
                if visible.isEmpty && t.allSatisfy({ $0.isWhitespace }) { break }
                visible += t
                emit(["type": "token", "text": t])
            case .reasoning(let t) where !t.isEmpty:
                emit(["type": "think", "text": t])
            default: break
            }
        }
    }

    // 画像が会話のどこかにあれば VLM 経路。画像を含む会話に純テキスト経路(VanillaDecodingStrategy)を
    // 混ぜると CoreAISequentialVLMEngine が範囲エラーで落ちる(実測・SIGTRAP)ので、
    // 画像ターン以降は常に最新の画像を持ったまま VLM 経路で生成する
    let imgIndex = messages.lastIndex { ($0["image"] as? String).map { !$0.isEmpty } ?? false }
    if let imgIndex, let imagePath = messages[imgIndex]["image"] as? String {
        guard let vlm = m.engine as? any MultimodalInferenceEngine,
              let vcfg = m.bundle.visionConfig else {
            throw NSError(domain: "coreai-llm", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "image input needs a VLM bundle (this model is text-only)"])
        }
        let url = URL(fileURLWithPath: imagePath)
        emit(["type": "status", "text": "encoding image"])
        let emb = try await vlm.encodeImage(at: url)
        // 画像を持つ user 発話の先頭に画像トークンを1つ置いてテンプレートを通し、その1つを
        // 視覚トークン数ぶんに展開する(llm-runner の buildVLMPromptFromChatTemplate と同じ)。
        // 画像は最新の1枚だけ(それより前の画像ターンはテキストのみになる)
        var msgs = messages.map { msg -> [String: any Sendable] in
            var m2 = msg; m2["image"] = nil; return m2
        }
        var target = msgs[imgIndex]
        var body = target["content"] as? String ?? ""
        if vcfg.includeImageInfo, let ci = CIImage(contentsOf: url) {
            body = "Image: \(Int(ci.extent.width))x\(Int(ci.extent.height))\n" + body
        }
        let imageToken = m.tokenizer.convertIdToToken(Int(vcfg.imageTokenId)) ?? "<image>"
        target["content"] = imageToken + "\n" + body
        msgs[imgIndex] = target
        let raw = templateTokens(msgs, m.tokenizer)
        var tokens: [Int32] = []
        var expanded = false
        for t in raw {
            let t32 = Int32(t)
            if t32 == vcfg.imageTokenId {
                if !expanded { tokens.append(contentsOf: [Int32](repeating: t32, count: emb.tokenCount)); expanded = true }
            } else { tokens.append(t32) }
        }
        if !expanded {   // テンプレートが画像トークンを落とした場合のフォールバック
            tokens = m.tokenizer.encode(text: "USER: ", addSpecialTokens: true).map { Int32($0) }
            tokens.append(contentsOf: [Int32](repeating: vcfg.imageTokenId, count: emb.tokenCount))
            let prompt = (messages.last?["content"] as? String) ?? ""
            tokens.append(contentsOf: m.tokenizer.encode(text: "\n" + prompt + "\nASSISTANT:", addSpecialTokens: false).map { Int32($0) })
        }
        var eos = Set<Int32>(m.extraEOS)
        if let e = m.tokenizer.eosTokenId { eos.insert(Int32(e)) }
        for s in stops.sequences where s.count == 1 { eos.insert(s[0]) }

        emit(["type": "status", "text": "generating"])
        // KV キャッシュは generate 間で保持される(InferenceEngine の仕様)。VLM 経路は毎回
        // 画像込みのプロンプトを頭から渡すので、前回の状態を消さないと
        // "No new tokens to process" で止まる(実測)。毎回フル reset して作り直す
        try await vlm.reset(to: 0)
        let stream = try await vlm.generate(with: emb, tokens: tokens, samplingConfiguration: sampling,
                                            inferenceOptions: InferenceOptions(maxTokens: maxTok))
        var ids: [Int] = []
        var prev = ""
        for try await out in stream {
            if eos.contains(out.tokenId) { break }
            ids.append(Int(out.tokenId))
            let full = m.tokenizer.decode(tokens: ids)
            let delta = String(full.dropFirst(prev.count))
            prev = full
            handle(delta)
        }
    } else {
        let plain = messages.map { msg -> [String: any Sendable] in var m2 = msg; m2["image"] = nil; return m2 }
        let tokens = templateTokens(plain, m.tokenizer)
        if tokens.count >= m.bundle.maxContextLength {
            throw NSError(domain: "coreai-llm", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "prompt (\(tokens.count) tokens) exceeds context length (\(m.bundle.maxContextLength)); use Reset"])
        }
        emit(["type": "status", "text": "generating"])
        let seq = try await VanillaDecodingStrategy().decode(
            from: .tokens(tokens), tokenizer: m.tokenizer, inferenceEngine: m.engine,
            samplingConfiguration: sampling, options: InferenceOptions(maxTokens: maxTok), stopSequences: stops)
        for try await r in seq { handle(r.text) }
    }
    for ev in parser.flush() {
        if case .text(let t) = ev, !t.isEmpty { visible += t; emit(["type": "token", "text": t]) }
        if case .reasoning(let t) = ev, !t.isEmpty { emit(["type": "think", "text": t]) }
    }
    let gen = tFirst.map { Date().timeIntervalSince($0) } ?? 0
    let ttft = tFirst.map { $0.timeIntervalSince(t0) } ?? 0
    emit(["type": "done", "tokens": count, "tps": gen > 0 ? Double(count) / gen : 0, "ttft": ttft])
    return visible
}

func serve() async {
    var model: Loaded? = nil
    var loadedPath = ""
    var messages: [[String: any Sendable]] = []
    var currentSystem = "\u{01}uninit"

    logErr("coreai-llm-helper: serve mode ready")
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            emit(["type": "error", "text": "bad command json"]); continue
        }
        switch cmd {
        case "load":
            let path = ((obj["model"] as? String ?? "") as NSString).expandingTildeInPath
            if path == loadedPath, model != nil { emitReady(model!); break }
            model = nil; loadedPath = ""; messages = []
            do {
                let t0 = Date()
                let m = try await loadBundle(path)
                model = m; loadedPath = path; currentSystem = ""
                logErr("loaded \(m.bundle.name) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                emitReady(m)
            } catch {
                emit(["type": "error", "text": "load failed: \(error)"])
            }
        case "gen":
            guard let m = model else { emit(["type": "error", "text": "no model loaded"]); break }
            let prompt = obj["prompt"] as? String ?? ""
            var system = obj["system"] as? String ?? ""
            let temp = obj["temp"] as? Double ?? 0.7
            let maxTok = obj["max"] as? Int ?? 512
            let keep = obj["keep"] as? Bool ?? true
            let image = obj["image"] as? String ?? ""
            let think = obj["think"] as? Bool ?? true
            // Qwen3 等: /no_think を system に足すと思考を省く(llm-server と同じ流儀)
            if !think && m.thinking != nil {
                system += (system.isEmpty ? "" : "\n") + "/no_think"
            }
            if !keep || system != currentSystem {
                messages = system.isEmpty ? [] : [["role": "system", "content": system]]
                currentSystem = system
            }
            var userMsg: [String: any Sendable] = ["role": "user", "content": prompt]
            if !image.isEmpty { userMsg["image"] = image }
            messages.append(userMsg)
            do {
                let reply = try await generate(m, messages: messages, temp: temp, maxTok: maxTok)
                messages.append(["role": "assistant", "content": reply])
            } catch {
                messages.removeLast()
                emit(["type": "error", "text": "\(error)"])
            }
        case "reset":
            messages = []; currentSystem = "\u{01}uninit"
            emit(["type": "status", "text": "reset"])
        case "quit":
            logErr("coreai-llm-helper: quit"); return
        default:
            emit(["type": "error", "text": "unknown cmd \(cmd)"])
        }
    }
}

func emitReady(_ m: Loaded) {
    emit(["type": "ready", "kind": m.isVLM ? "vlm" : "llm", "name": m.bundle.name, "stops": m.extraEOS.map { Int($0) },
          "context": m.bundle.maxContextLength])
}

let args = CommandLine.arguments
if args.contains("--serve") {
    await serve()
} else {
    let path = args.count > 1 ? args[1] : ""
    let prompt = args.count > 2 ? args[2] : "Say hello to a TouchDesigner artist in one sentence."
    let image = args.count > 3 ? args[3] : ""
    do {
        let m = try await loadBundle(path)
        logErr("loaded \(m.bundle.name) (\(m.isVLM ? "vlm" : "llm"))")
        var um: [String: any Sendable] = ["role": "user", "content": prompt]
        if !image.isEmpty { um["image"] = image }
        let r = try await generate(m, messages: [um], temp: 0, maxTok: 80)
        print("RESULT:\(r)")
    } catch {
        print("ERROR:\(error)"); exit(1)
    }
}
