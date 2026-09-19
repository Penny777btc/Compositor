import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum AIImageRole: String, Codable, CaseIterable, Sendable {
    case background, photo, illustration, texture, element
}

nonisolated enum AIImageReferenceMode: String, Codable, CaseIterable, Sendable {
    case style, composition, subject, edit
}

nonisolated enum AIImageBackground: String, Codable, CaseIterable, Sendable {
    case auto, opaque, transparent
}

nonisolated enum AIImageQuality: String, Codable, CaseIterable, Sendable {
    case draft, standard, high
}

nonisolated struct AIImageReference: Sendable {
    let data: Data
    let mediaType: String
}

nonisolated struct AIImageGenerationRequest: Sendable {
    let id: UUID
    let prompt: String
    let role: AIImageRole
    let referenceMode: AIImageReferenceMode?
    let background: AIImageBackground
    let quality: AIImageQuality
    let requestedWidth: Int
    let requestedHeight: Int
    let placement: CGRect
    let layerName: String
    let reference: AIImageReference?

    var isValid: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf8.count <= 20_000
            && (1...30_000).contains(requestedWidth) && (1...30_000).contains(requestedHeight)
            && requestedWidth * requestedHeight <= 100_000_000
            && placement.width >= 1 && placement.height >= 1 && placement.width.isFinite && placement.height.isFinite
            && placement.origin.x.isFinite && placement.origin.y.isFinite
            && !layerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && reference.map { !$0.data.isEmpty && $0.data.count <= 50 * 1024 * 1024 && $0.mediaType.hasPrefix("image/") } ?? true
    }
}

nonisolated struct AIImageGenerationArtifact: @unchecked Sendable {
    let data: Data
    let mediaType: String
    let model: String
    var revisedPrompt: String? = nil
}

nonisolated protocol AIImageGenerationProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var isConfigured: Bool { get }
    func generate(_ request: AIImageGenerationRequest) async throws -> AIImageGenerationArtifact
}

nonisolated struct UnconfiguredImageGenerationProvider: AIImageGenerationProvider {
    let identifier = "unconfigured"
    let displayName = "Not configured"
    let isConfigured = false
    func generate(_ request: AIImageGenerationRequest) async throws -> AIImageGenerationArtifact {
        throw AIImageGenerationError.providerNotConfigured
    }
}

/// Non-secret provenance saved with a generated raster layer so later versions can offer regenerate/replace.
nonisolated struct LayerGenerationRecord: Codable, Equatable, Sendable {
    let providerID: String
    let model: String
    let prompt: String
    let revisedPrompt: String?
    let role: AIImageRole
    let referenceMode: AIImageReferenceMode?
    let usedReference: Bool
    let background: AIImageBackground
    let quality: AIImageQuality
    let requestedWidth: Int
    let requestedHeight: Int

    var isValid: Bool {
        !providerID.isEmpty && providerID.utf8.count <= 512 && !model.isEmpty && model.utf8.count <= 512
            && !prompt.isEmpty && prompt.utf8.count <= 20_000
            && (1...30_000).contains(requestedWidth) && (1...30_000).contains(requestedHeight)
            && revisedPrompt.map { $0.utf8.count <= 20_000 } ?? true
    }
}

@MainActor
enum AIImageGenerationPipeline {
    static func execute(_ actions: [AIEditorAction], provider: any AIImageGenerationProvider,
                        referenceURL: URL?, in session: EditorSession) async throws -> [String] {
        guard provider.isConfigured else { throw AIImageGenerationError.providerNotConfigured }
        guard let document = session.document else { throw AIImageGenerationError.noCanvas }
        let generationActions = actions.filter { $0.type == "generate_image" }
        guard generationActions.count <= 8 else { throw AIImageGenerationError.tooManyRequests }

        let needsReference = generationActions.contains { $0.referenceMode != nil }
        let reference: AIImageReference?
        if needsReference {
            guard let referenceURL else { throw AIImageGenerationError.referenceMissing }
            let scoped = referenceURL.startAccessingSecurityScopedResource()
            defer { if scoped { referenceURL.stopAccessingSecurityScopedResource() } }
            let url = referenceURL
            reference = try await Task.detached(priority: .userInitiated) {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 50 * 1024 * 1024 else {
                    throw AIImageGenerationError.referenceTooLarge
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                guard mediaType.hasPrefix("image/") else { throw AIImageGenerationError.referenceInvalid }
                return AIImageReference(data: data, mediaType: mediaType)
            }.value
        } else { reference = nil }

        var messages: [String] = []
        for action in generationActions {
            try Task.checkCancellation()
            let request = try request(action, document: document, reference: action.referenceMode == nil ? nil : reference)
            let artifact = try await provider.generate(request)
            let image = try decode(artifact)
            let record = LayerGenerationRecord(providerID: provider.identifier, model: artifact.model,
                prompt: request.prompt, revisedPrompt: artifact.revisedPrompt, role: request.role,
                referenceMode: request.referenceMode, usedReference: request.reference != nil,
                background: request.background, quality: request.quality,
                requestedWidth: request.requestedWidth, requestedHeight: request.requestedHeight)
            session.addPixelLayer(image, at: request.placement.origin, name: request.layerName,
                editName: "AI Generated Image", dropsSelection: false,
                displaySize: request.placement.size, generation: record)
            messages.append(L10n.format("Generated image layer: %@", request.layerName))
        }
        return messages
    }

    static func request(_ action: AIEditorAction, document: CanvasDocument,
                        reference: AIImageReference?) throws -> AIImageGenerationRequest {
        guard action.type == "generate_image",
              let prompt = action.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw AIImageGenerationError.invalidRequest
        }
        let width = try integer(action.width ?? Double(document.width))
        let height = try integer(action.height ?? Double(document.height))
        let x = action.x.flatMap(finite) ?? (CGFloat(document.width - width) / 2)
        let y = action.y.flatMap(finite) ?? (CGFloat(document.height - height) / 2)
        let request = AIImageGenerationRequest(id: UUID(), prompt: prompt,
            role: action.imageRole.flatMap(AIImageRole.init(rawValue:)) ?? .photo,
            referenceMode: action.referenceMode.flatMap(AIImageReferenceMode.init(rawValue:)),
            background: action.imageBackground.flatMap(AIImageBackground.init(rawValue:)) ?? .auto,
            quality: action.imageQuality.flatMap(AIImageQuality.init(rawValue:)) ?? .standard,
            requestedWidth: width, requestedHeight: height,
            placement: CGRect(x: x, y: y, width: CGFloat(width), height: CGFloat(height)),
            layerName: action.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? L10n.text("Generated Image"), reference: reference)
        guard request.isValid, request.referenceMode == nil || request.reference != nil else {
            throw AIImageGenerationError.invalidRequest
        }
        return request
    }

    private static func finite(_ value: Double) -> CGFloat? {
        value.isFinite ? CGFloat(value) : nil
    }

    private static func integer(_ value: Double) throws -> Int {
        guard value.isFinite, value >= 1, value <= 30_000 else { throw AIImageGenerationError.invalidRequest }
        return Int(value.rounded())
    }

    private nonisolated static func decode(_ artifact: AIImageGenerationArtifact) throws -> CGImage {
        guard artifact.data.count <= 512 * 1024 * 1024, artifact.mediaType.hasPrefix("image/"),
              let source = CGImageSourceCreateWithData(artifact.data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              (1...30_000).contains(image.width), (1...30_000).contains(image.height),
              image.width * image.height <= 100_000_000 else { throw AIImageGenerationError.invalidResult }
        return image
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

nonisolated enum AIImageGenerationError: LocalizedError {
    case providerNotConfigured, noCanvas, invalidRequest, invalidResult, tooManyRequests
    case referenceMissing, referenceTooLarge, referenceInvalid
    var errorDescription: String? {
        switch self {
        case .providerNotConfigured: L10n.text("Image generation is ready, but no image provider is configured yet.")
        case .noCanvas: L10n.text("Create a canvas before generating image layers.")
        case .invalidRequest: L10n.text("The image generation request is invalid.")
        case .invalidResult: L10n.text("The image provider returned an invalid or oversized image.")
        case .tooManyRequests: L10n.text("A plan can generate at most eight images at once.")
        case .referenceMissing: L10n.text("This image request needs the attached reference image.")
        case .referenceTooLarge: L10n.text("The reference image must be a regular image file no larger than 50 MB.")
        case .referenceInvalid: L10n.text("The selected reference is not a supported image.")
        }
    }
}
