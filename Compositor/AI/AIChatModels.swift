import Foundation

nonisolated enum LocalAIProvider: String, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
}

nonisolated enum AIReferenceStrategy: String, CaseIterable, Sendable {
    case fidelity = "High Fidelity"
    case balanced = "Balanced"
    case editable = "Editable First"
}

nonisolated struct AIChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant, system }
    let id = UUID()
    let role: Role
    let text: String
    var attachment: AIChatAttachment? = nil
}

nonisolated struct AIChatAttachment: Sendable {
    let name: String
    let cachedURL: URL
}

nonisolated struct AIEditorPlan: Codable, Sendable {
    let message: String
    var referenceAnalysis: AIReferenceAnalysis? = nil
    let actions: [AIEditorAction]
}

nonisolated struct AIReferenceAnalysis: Codable, Equatable, Sendable {
    let summary: String
    let visualStyle: String
    let palette: [String]
    let composition: [String]
    let layerStrategy: [String]
}

/// A deliberately small, provider-neutral command envelope. Optional fields keep one JSON Schema usable for every
/// action; `AIEditorEngine` performs stricter, action-specific validation before changing a document.
nonisolated struct AIEditorAction: Codable, Sendable {
    let type: String
    var layerID: String? = nil
    var layerIDs: [String]? = nil
    var name: String? = nil
    var prompt: String? = nil
    var text: String? = nil
    var fontName: String? = nil
    var fontSize: Double? = nil
    var fontWeight: String? = nil
    var fontCategory: String? = nil
    var tracking: Double? = nil
    var fitText: Bool? = nil
    var singleLine: Bool? = nil
    var alignment: String? = nil
    var adjustment: String? = nil
    var mask: String? = nil
    var position: Int? = nil
    var variants: [AIExportVariant]? = nil
    var shape: String? = nil
    var imageRole: String? = nil
    var referenceMode: String? = nil
    var imageBackground: String? = nil
    var imageQuality: String? = nil
    var gradient: String? = nil
    var colors: [String]? = nil
    var locations: [Double]? = nil
    var angle: Double? = nil
    var centerX: Double? = nil
    var centerY: Double? = nil
    var color: String? = nil
    var width: Double? = nil
    var height: Double? = nil
    var x: Double? = nil
    var y: Double? = nil
    var sourceX: Double? = nil
    var sourceY: Double? = nil
    var sourceWidth: Double? = nil
    var sourceHeight: Double? = nil
    var points: [AIVectorPoint]? = nil
    var strokeColor: String? = nil
    var fillColor: String? = nil
    var lineWidth: Double? = nil
    var closed: Bool? = nil
    var roughness: Double? = nil
    var seed: Int? = nil
    var intensity: Double? = nil
    var rotation: Double? = nil
    var opacity: Double? = nil
    var visible: Bool? = nil
    var cornerRadius: Double? = nil
}

nonisolated struct AIVectorPoint: Codable, Sendable {
    let x: Double
    let y: Double
}

nonisolated struct AIExportVariant: Codable, Sendable {
    let name: String
    let width: Int
    let height: Int
}

nonisolated enum AIChatError: LocalizedError {
    case executableMissing(LocalAIProvider)
    case launch(String)
    case failed(String)
    case invalidResponse
    case referenceNotAnalyzed
    case referencePlanIncomplete

    var errorDescription: String? {
        switch self {
        case .executableMissing(let provider):
            return L10n.format("%@ is not installed in a supported location.", provider.rawValue)
        case .launch(let message): return message
        case .failed(let message): return message
        case .invalidResponse: return L10n.text("The AI returned a response that could not be understood.")
        case .referenceNotAnalyzed: return L10n.text("The reference image was attached, but the AI did not return a visual analysis. Please try again.")
        case .referencePlanIncomplete: return L10n.text("The AI analyzed the reference, but its plan still omitted important visual layers. Please try a more specific request.")
        }
    }
}
