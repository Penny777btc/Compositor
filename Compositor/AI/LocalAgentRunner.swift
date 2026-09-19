import Foundation

nonisolated enum LocalAgentRunner {
    private static let running = ProcessSlot()
    private static let schema = """
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "message": { "type": "string" },
        "actions": {
          "type": "array",
          "maxItems": 24,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "type": { "type": "string", "enum": ["create_canvas", "add_shape", "rename_layer", "set_opacity", "set_visibility", "transform_layer", "duplicate_layer", "no_action"] },
              "layerID": { "type": ["string", "null"] },
              "name": { "type": ["string", "null"] },
              "shape": { "type": ["string", "null"], "enum": ["rectangle", "ellipse", null] },
              "color": { "type": ["string", "null"] },
              "width": { "type": ["number", "null"] },
              "height": { "type": ["number", "null"] },
              "x": { "type": ["number", "null"] },
              "y": { "type": ["number", "null"] },
              "rotation": { "type": ["number", "null"] },
              "opacity": { "type": ["number", "null"] },
              "visible": { "type": ["boolean", "null"] },
              "cornerRadius": { "type": ["number", "null"] }
            },
            "required": ["type", "layerID", "name", "shape", "color", "width", "height", "x", "y", "rotation", "opacity", "visible", "cornerRadius"]
          }
        }
      },
      "required": ["message", "actions"]
    }
    """

    static func run(provider: LocalAIProvider, prompt: String) async throws -> AIEditorPlan {
        try await Task.detached(priority: .userInitiated) {
            let executable = try locate(provider)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorAI-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            switch provider {
            case .codex: return try codex(executable: executable, prompt: prompt, root: root)
            case .claude: return try claude(executable: executable, prompt: prompt, root: root)
            }
        }.value
    }

    static func cancelCurrent() { running.cancel() }

    private static func codex(executable: URL, prompt: String, root: URL) throws -> AIEditorPlan {
        let schemaURL = root.appendingPathComponent("response.schema.json")
        let outputURL = root.appendingPathComponent("response.json")
        try Data(schema.utf8).write(to: schemaURL, options: .atomic)
        let result = try process(executable: executable, arguments: [
            "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "--sandbox", "read-only", "--color", "never", "--output-schema", schemaURL.path,
            "--output-last-message", outputURL.path, "-C", root.path, "-"
        ], input: prompt)
        guard result.status == 0 else { throw AIChatError.failed(clean(result.error)) }
        guard let data = try? Data(contentsOf: outputURL) else { throw AIChatError.invalidResponse }
        return try decodePlan(data)
    }

    private static func claude(executable: URL, prompt: String, root: URL) throws -> AIEditorPlan {
        let result = try process(executable: executable, arguments: [
            "-p", "--safe-mode", "--restricted", "--tools", "", "--permission-mode", "dontAsk",
            "--permission-prompts", "none", "--no-session-persistence", "--output-format", "json",
            "--json-schema", schema
        ], input: prompt, directory: root)
        guard result.status == 0 else { throw AIChatError.failed(clean(result.error)) }
        guard let data = result.output.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIChatError.invalidResponse
        }
        if let structured = envelope["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            return try decodePlan(JSONSerialization.data(withJSONObject: structured))
        }
        if let text = envelope["result"] as? String, let inner = text.data(using: .utf8) {
            return try decodePlan(inner)
        }
        return try decodePlan(data)
    }

    private static func decodePlan(_ data: Data) throws -> AIEditorPlan {
        do { return try JSONDecoder().decode(AIEditorPlan.self, from: data) }
        catch { throw AIChatError.invalidResponse }
    }

    private static func locate(_ provider: LocalAIProvider) throws -> URL {
        let name = provider == .codex ? "codex" : "claude"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw AIChatError.executableMissing(provider)
        }
        return URL(fileURLWithPath: path)
    }

    private static func process(executable: URL, arguments: [String], input: String, directory: URL? = nil)
        throws -> (status: Int32, output: String, error: String) {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch { throw AIChatError.launch(error.localizedDescription) }
        running.set(process)
        defer { running.clear(process) }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: error, as: UTF8.self))
    }

    private static func clean(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? L10n.text("The local AI process exited without a response.") : String(text.suffix(2_000))
    }

    static func prompt(userText: String, history: [AIChatMessage], context: String) -> String {
        let conversation = history.suffix(10).map { message in
            let role = message.role == .user ? "User" : message.role == .assistant ? "Assistant" : "System"
            return "\(role): \(message.text)"
        }.joined(separator: "\n")
        return """
        You are the design assistant inside Compositor, a local image editor. Return only the JSON object required by
        the supplied schema. Explain the result briefly in `message`, and place deterministic editor operations in
        `actions`. Never request shell access, files, or network tools.

        Allowed actions:
        - create_canvas: width and height, only when no canvas exists.
        - add_shape: shape rectangle or ellipse; x/y are top-left canvas coordinates; width/height; #RRGGBB color;
          optional cornerRadius and name. These remain editable basic shape layers.
        - rename_layer, set_opacity (0...1 or 0...100), set_visibility, transform_layer, duplicate_layer: use an exact
          layerID from the current state. Omit unrelated values as null.
        - no_action: use when the request needs unsupported text, vector-path, image-generation, painting, deletion,
          or when essential details are missing. Explain what is not supported yet.

        Keep every shape inside the canvas unless the user explicitly asks otherwise. Prefer a small sequence of clear,
        reversible actions. Never replace an existing canvas.

        Current editor state:
        \(context)

        Recent conversation:
        \(conversation.isEmpty ? "none" : conversation)

        User request:
        \(userText)
        """
    }

    private final class ProcessSlot: @unchecked Sendable {
        private let lock = NSLock()
        private weak var process: Process?
        func set(_ process: Process) { lock.withLock { self.process = process } }
        func clear(_ process: Process) {
            lock.withLock { if self.process === process { self.process = nil } }
        }
        func cancel() {
            lock.withLock {
                guard let process, process.isRunning else { return }
                process.terminate()
            }
        }
    }
}
