import Foundation

/// Persistent Codex app-server transport. One process and one ephemeral thread are reused for the app session, which
/// avoids paying CLI startup and authentication overhead on every chat turn. The model still returns the same
/// provider-neutral `AIEditorPlan` consumed by the editor.
nonisolated final class CodexAppServerRunner: @unchecked Sendable {
    static let shared = CodexAppServerRunner()
    private let requestLock = NSLock(), stateLock = NSLock()
    private var process: Process?, input: FileHandle?, output: FileHandle?, root: URL?, threadID: String?
    private var nextID = 1

    func run(executable: URL, prompt: String, schema: String, referenceImage: URL?) async throws -> AIEditorPlan {
        try await Task.detached(priority: .userInitiated) { [self] in
            try requestLock.withLock {
                do { return try runSync(executable: executable, prompt: prompt, schema: schema, referenceImage: referenceImage) }
                catch {
                    stop()
                    throw error
                }
            }
        }.value
    }

    func cancel() { stop() }

    private func runSync(executable: URL, prompt: String, schema: String, referenceImage: URL?) throws -> AIEditorPlan {
        try startIfNeeded(executable)
        let schemaObject = try JSONSerialization.jsonObject(with: Data(schema.utf8))
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let referenceImage { content.append(["type": "localImage", "path": referenceImage.path]) }
        let id = requestID()
        try send(["id": id, "method": "turn/start", "params": [
            "threadId": threadID!, "input": content, "outputSchema": schemaObject
        ]])
        var finalText: String?
        while let message = try readMessage() {
            if message["method"] as? String == "item/completed",
               let params = message["params"] as? [String: Any],
               let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
               let text = item["text"] as? String { finalText = text }
            if message["method"] as? String == "turn/completed" { break }
            if message["id"] as? Int == id, let error = message["error"] as? [String: Any] {
                throw AIChatError.failed(error["message"] as? String ?? "Codex app-server error")
            }
        }
        guard let data = finalText?.data(using: .utf8) else { throw AIChatError.invalidResponse }
        return try LocalAgentRunner.decodePlan(data)
    }

    private func startIfNeeded(_ executable: URL) throws {
        if process?.isRunning == true, threadID != nil { return }
        stop()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorAppServer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AIChatError.launch(error.localizedDescription) }
        stateLock.withLock {
            self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; self.root = root
        }
        let initID = requestID()
        try send(["id": initID, "method": "initialize", "params": [
            "clientInfo": ["name": "compositor-ai", "title": "Compositor AI Designer", "version": "0.1"],
            "capabilities": ["experimentalApi": false]
        ]])
        _ = try waitForResponse(initID)
        try send(["method": "initialized", "params": [:]])
        let threadID = requestID()
        try send(["id": threadID, "method": "thread/start", "params": [
            "cwd": root.path, "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true,
            "baseInstructions": "You are the design-planning engine inside Compositor. Never run shell commands or edit files. Return only the requested JSON schema."
        ]])
        let response = try waitForResponse(threadID)
        guard let result = response["result"] as? [String: Any], let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String else { throw AIChatError.invalidResponse }
        self.threadID = id
    }

    private func waitForResponse(_ id: Int) throws -> [String: Any] {
        while let message = try readMessage() {
            guard message["id"] as? Int == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw AIChatError.failed(error["message"] as? String ?? "Codex app-server error")
            }
            return message
        }
        throw AIChatError.invalidResponse
    }

    private func requestID() -> Int { defer { nextID += 1 }; return nextID }
    private func send(_ object: [String: Any]) throws {
        guard let input else { throw AIChatError.invalidResponse }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a); try input.write(contentsOf: data)
    }
    private func readMessage() throws -> [String: Any]? {
        guard let output else { return nil }
        var line = Data()
        while line.count < 16_000_000 {
            let byte = try output.read(upToCount: 1) ?? Data()
            if byte.isEmpty { return line.isEmpty ? nil : try decode(line) }
            if byte[0] == 0x0a { return line.isEmpty ? [:] : try decode(line) }
            line.append(byte)
        }
        throw AIChatError.invalidResponse
    }
    private func decode(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIChatError.invalidResponse }
        return value
    }

    private func stop() {
        stateLock.withLock {
            if process?.isRunning == true { process?.terminate() }
            try? input?.close(); try? output?.close()
            if let root { try? FileManager.default.removeItem(at: root) }
            process = nil; input = nil; output = nil; root = nil; threadID = nil
        }
    }

    deinit { stop() }
}
