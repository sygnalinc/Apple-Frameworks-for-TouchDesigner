import Foundation

private struct Turn: Codable { var role: String; var text: String }

private final class StreamDelegate: NSObject, URLSessionDataDelegate {
    var onText: ((String) -> Void)?
    var onDone: ((Error?) -> Void)?
    private var pending = ""

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pending += String(decoding: data, as: UTF8.self)
        while let range = pending.range(of: "\n") {
            let line = String(pending[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(..<range.upperBound)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]], let first = choices.first else { continue }
            if let delta = first["delta"] as? [String: Any], let text = delta["content"] as? String { onText?(text) }
            else if let message = first["message"] as? [String: Any], let text = message["content"] as? String { onText?(text) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onDone?(error)
    }
}

private final class GemmaSession {
    private let lock = NSLock()
    private var history: [Turn] = []
    private var status = "idle"
    private var busy = false
    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var server: Process?

    func submit(endpoint: String, model: String, system: String, prompt: String,
                temperature: Double, maxTokens: Int, keepContext: Bool) -> Bool {
        lock.lock()
        if busy { lock.unlock(); return false }
        if !keepContext { history.removeAll() }
        history.append(Turn(role: "user", text: prompt))
        history.append(Turn(role: "assistant", text: ""))
        busy = true; status = "generating"; lock.unlock()

        guard let url = URL(string: endpoint) else { finish("invalid endpoint"); return false }
        var messages: [[String: String]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        lock.lock(); let snapshot = history.dropLast().map { ["role": $0.role, "content": $0.text] }; lock.unlock()
        messages.append(contentsOf: snapshot)
        let body: [String: Any] = ["model": model, "messages": messages, "temperature": temperature,
                                   "max_tokens": maxTokens, "stream": true]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { finish("JSON encode failed"); return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let delegate = StreamDelegate()
        delegate.onText = { [weak self] text in
            guard let self else { return }; self.lock.lock()
            if !self.history.isEmpty { self.history[self.history.count - 1].text += text }
            self.lock.unlock()
        }
        delegate.onDone = { [weak self, weak delegate] error in
            _ = delegate
            self?.finish(error == nil ? "ready" : "error: \(error!.localizedDescription)")
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        lock.lock(); urlSession = session; dataTask = task; lock.unlock()
        task.resume()
        return true
    }

    func cancel() {
        lock.lock(); let task = dataTask; lock.unlock(); task?.cancel()
    }

    private func finish(_ newStatus: String) {
        lock.lock(); status = newStatus; busy = false; dataTask = nil; urlSession = nil; lock.unlock()
    }

    func clear() { cancel(); lock.lock(); history.removeAll(); status = "idle"; busy = false; lock.unlock() }

    func startServer(binary: String, model: String, port: Int, context: Int, gpuLayers: Int) -> Bool {
        lock.lock()
        if server?.isRunning == true { status = "server already running"; lock.unlock(); return false }
        lock.unlock()
        guard !binary.isEmpty, !model.isEmpty else { setStatus("server binary/model path required"); return false }
        let p = Process(); p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", String(port), "-c", String(context), "-ngl", String(gpuLayers)]
        let log = Pipe(); p.standardOutput = log; p.standardError = log
        p.terminationHandler = { [weak self] process in self?.setStatus("server exited (\(process.terminationStatus))") }
        do { try p.run(); lock.lock(); server = p; status = "server starting"; lock.unlock(); return true }
        catch { setStatus("server start error: \(error.localizedDescription)"); return false }
    }

    func stopServer() { lock.lock(); let p = server; server = nil; lock.unlock(); if p?.isRunning == true { p?.terminate() }; setStatus("server stopped") }
    private func setStatus(_ text: String) { lock.lock(); status = text; lock.unlock() }

    func poll() -> Data {
        lock.lock(); let value: [String: Any] = ["status": status, "busy": busy, "server": server?.isRunning == true,
                                                "history": history.map { ["role": $0.role, "text": $0.text] }]; lock.unlock()
        return (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
    }
}

private func session(_ p: UnsafeMutableRawPointer?) -> GemmaSession? {
    guard let p else { return nil }; return Unmanaged<GemmaSession>.fromOpaque(p).takeUnretainedValue()
}

@_cdecl("gm_create") public func gmCreate() -> UnsafeMutableRawPointer { Unmanaged.passRetained(GemmaSession()).toOpaque() }
@_cdecl("gm_submit") public func gmSubmit(_ h: UnsafeMutableRawPointer?, _ endpoint: UnsafePointer<CChar>?, _ model: UnsafePointer<CChar>?, _ system: UnsafePointer<CChar>?, _ prompt: UnsafePointer<CChar>?, _ temperature: Double, _ maxTokens: Int32, _ keep: Bool) -> Bool {
    guard let s = session(h) else { return false }
    return s.submit(endpoint: endpoint.map(String.init(cString:)) ?? "", model: model.map(String.init(cString:)) ?? "",
                    system: system.map(String.init(cString:)) ?? "", prompt: prompt.map(String.init(cString:)) ?? "",
                    temperature: temperature, maxTokens: Int(maxTokens), keepContext: keep)
}
@_cdecl("gm_start_server") public func gmStartServer(_ h: UnsafeMutableRawPointer?, _ binary: UnsafePointer<CChar>?, _ model: UnsafePointer<CChar>?, _ port: Int32, _ context: Int32, _ gpuLayers: Int32) -> Bool {
    session(h)?.startServer(binary: binary.map(String.init(cString:)) ?? "", model: model.map(String.init(cString:)) ?? "", port: Int(port), context: Int(context), gpuLayers: Int(gpuLayers)) ?? false
}
@_cdecl("gm_stop_server") public func gmStopServer(_ h: UnsafeMutableRawPointer?) { session(h)?.stopServer() }
@_cdecl("gm_cancel") public func gmCancel(_ h: UnsafeMutableRawPointer?) { session(h)?.cancel() }
@_cdecl("gm_clear") public func gmClear(_ h: UnsafeMutableRawPointer?) { session(h)?.clear() }
@_cdecl("gm_poll") public func gmPoll(_ h: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let data = session(h)?.poll(), let buffer, capacity > 0 else { return 0 }
    let count = min(data.count, Int(capacity) - 1); data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer, count: count)); buffer[count] = 0; return Int32(count)
}
@_cdecl("gm_destroy") public func gmDestroy(_ h: UnsafeMutableRawPointer?) { guard let h else { return }; let s = Unmanaged<GemmaSession>.fromOpaque(h).takeRetainedValue(); s.stopServer() }
