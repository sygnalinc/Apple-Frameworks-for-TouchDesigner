import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

// MLX LLM helper for the TouchDesigner MLX LLM DAT.
//
// Two modes:
//   mlxllm-cli --serve            persistent JSON-lines protocol (used by the DAT)
//   mlxllm-cli [modelId] [prompt] one-shot generate to stdout (manual testing)
//
// --serve protocol
//   stdin  (one JSON object per line):
//     {"cmd":"load","model":"mlx-community/gemma-4-e2b-it-4bit"}
//     {"cmd":"gen","prompt":"...","system":"...","temp":0.7,"max":512,"keep":true}
//     {"cmd":"reset"}
//     {"cmd":"quit"}
//   stdout (one JSON event per line, flushed):
//     {"type":"progress","pct":42}   {"type":"ready"}   {"type":"status","text":"..."}
//     {"type":"token","text":"chunk"} {"type":"done"}   {"type":"error","text":"..."}
//   stderr: human-readable logs only.

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

// Model 文字列がローカルディレクトリなら .directory（ダウンロード無し・完全オフライン）、
// そうでなければ HF リポジトリID として扱う。
func makeConfig(_ model: String) -> ModelConfiguration {
    var isDir: ObjCBool = false
    let expanded = (model as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
        return ModelConfiguration(directory: URL(fileURLWithPath: expanded))
    }
    return ModelConfiguration(id: model)
}

func serve() async {
    var container: ModelContainer? = nil
    var session: ChatSession? = nil
    var loadedModel = ""
    var currentSystem = "\u{01}uninit"

    logErr("mlxllm-helper: serve mode ready")
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            emit(["type": "error", "text": "bad command json"])
            continue
        }

        switch cmd {
        case "load":
            let model = obj["model"] as? String ?? ""
            if model == loadedModel, container != nil {
                emit(["type": "ready"])
                break
            }
            do {
                emit(["type": "status", "text": "loading \(model)"])
                let cont = try await #huggingFaceLoadModelContainer(
                    configuration: makeConfig(model)
                ) { (p: Progress) in
                    emit(["type": "progress", "pct": Int(p.fractionCompleted * 100)])
                }
                container = cont
                session = ChatSession(cont)
                loadedModel = model
                currentSystem = ""
                emit(["type": "ready"])
            } catch {
                emit(["type": "error", "text": "\(error)"])
            }

        case "gen":
            guard let cont = container else {
                emit(["type": "error", "text": "no model loaded"])
                break
            }
            let prompt = obj["prompt"] as? String ?? ""
            let system = obj["system"] as? String ?? ""
            let temp = obj["temp"] as? Double ?? 0.7
            let maxTok = obj["max"] as? Int ?? 512
            let keep = obj["keep"] as? Bool ?? true

            if !keep || session == nil || system != currentSystem {
                var gp = GenerateParameters()
                gp.temperature = Float(temp)
                gp.maxTokens = maxTok
                session = ChatSession(
                    cont,
                    instructions: system.isEmpty ? nil : system,
                    generateParameters: gp)
                currentSystem = system
            }
            do {
                for try await chunk in session!.streamResponse(to: prompt) {
                    emit(["type": "token", "text": chunk])
                }
                emit(["type": "done"])
            } catch {
                emit(["type": "error", "text": "\(error)"])
            }

        case "reset":
            if let cont = container {
                session = ChatSession(cont)
                currentSystem = ""
            }
            emit(["type": "status", "text": "reset"])

        case "quit":
            logErr("mlxllm-helper: quit")
            return

        default:
            emit(["type": "error", "text": "unknown cmd \(cmd)"])
        }
    }
}

func oneShot(_ modelId: String, _ prompt: String) async {
    do {
        logErr("loading \(modelId) ...")
        let container = try await #huggingFaceLoadModelContainer(
            configuration: makeConfig(modelId)
        ) { (p: Progress) in
            logErr("  download \(Int(p.fractionCompleted * 100))%")
        }
        logErr("model loaded. generating...\n")
        let session = ChatSession(container)
        var full = ""
        for try await chunk in session.streamResponse(to: prompt) {
            full += chunk
            FileHandle.standardError.write(chunk.data(using: .utf8)!)
        }
        logErr("\n")
        print("RESULT:\(full)")
    } catch {
        print("ERROR:\(error)")
        exit(1)
    }
}

let args = CommandLine.arguments
if args.contains("--serve") {
    await serve()
} else {
    let modelId = args.count > 1 ? args[1] : "mlx-community/gemma-4-e2b-it-4bit"
    let prompt = args.count > 2 ? args[2]
        : "In one short friendly sentence, say hello to a TouchDesigner artist."
    await oneShot(modelId, prompt)
}
