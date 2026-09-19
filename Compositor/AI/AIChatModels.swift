import Foundation

nonisolated enum LocalAIProvider: String, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
}

nonisolated struct AIChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant, system }
    let id = UUID()
    let role: Role
    let text: String
}

nonisolated struct AIEditorPlan: Codable, Sendable {
    let message: String
    let actions: [AIEditorAction]
}

/// A deliberately small, provider-neutral command envelope. Optional fields keep one JSON Schema usable for every
/// action; `AIEditorEngine` performs stricter, action-specific validation before changing a document.
nonisolated struct AIEditorAction: Codable, Sendable {
    let type: String
    var layerID: String? = nil
    var name: String? = nil
    var shape: String? = nil
    var color: String? = nil
    var width: Double? = nil
    var height: Double? = nil
    var x: Double? = nil
    var y: Double? = nil
    var rotation: Double? = nil
    var opacity: Double? = nil
    var visible: Bool? = nil
    var cornerRadius: Double? = nil
}

nonisolated enum AIChatError: LocalizedError {
    case executableMissing(LocalAIProvider)
    case launch(String)
    case failed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .executableMissing(let provider):
            return L10n.format("%@ is not installed in a supported location.", provider.rawValue)
        case .launch(let message): return message
        case .failed(let message): return message
        case .invalidResponse: return L10n.text("The AI returned a response that could not be understood.")
        }
    }
}
