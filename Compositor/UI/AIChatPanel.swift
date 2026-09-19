import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class AIChatController {
    var provider: LocalAIProvider = .codex
    var draft = ""
    var messages: [AIChatMessage] = [
        AIChatMessage(role: .assistant, text: L10n.text("Tell me what you want to create or change. I can operate the canvas and layers with Codex or Claude."))
    ]
    var isRunning = false
    var error: String?
    var pendingPlan: AIEditorPlan?
    var referenceImageURL: URL?
    var wantsExportFolder = false
    var pendingVariants: [AIExportVariant] = []
    var pendingImageActions: [AIEditorAction] = []
    private(set) var imageProviderName: String
    private(set) var isImageProviderConfigured: Bool
    @ObservationIgnored private(set) var imageGenerationProvider: any AIImageGenerationProvider
    @ObservationIgnored private var task: Task<Void, Never>?

    init(imageGenerationProvider: any AIImageGenerationProvider = UnconfiguredImageGenerationProvider()) {
        self.imageGenerationProvider = imageGenerationProvider
        imageProviderName = imageGenerationProvider.displayName
        isImageProviderConfigured = imageGenerationProvider.isConfigured
    }

    var imageProviderStatus: String {
        isImageProviderConfigured
            ? L10n.format("Image provider: %@", imageProviderName)
            : L10n.text("Image provider: Not configured")
    }

    func send(in session: EditorSession) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, pendingPlan == nil else { return }
        draft = ""
        error = nil
        let history = messages
        messages.append(AIChatMessage(role: .user, text: text))
        let provider = provider
        let context = AIEditorEngine.context(for: session)
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let prompt = LocalAgentRunner.prompt(userText: text, history: history, context: context,
                    hasReferenceImage: referenceImageURL != nil)
                let scoped = referenceImageURL?.startAccessingSecurityScopedResource() == true
                defer { if scoped { referenceImageURL?.stopAccessingSecurityScopedResource() } }
                let plan = try await LocalAgentRunner.run(provider: provider, prompt: prompt,
                    referenceImage: referenceImageURL)
                guard !Task.isCancelled else { return }
                pendingPlan = plan
                messages.append(AIChatMessage(role: .assistant, text: plan.message))
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                messages.append(AIChatMessage(role: .system, text: error.localizedDescription))
            }
            isRunning = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        LocalAgentRunner.cancelCurrent()
        task = nil
        isRunning = false
    }

    func clear() {
        guard !isRunning else { return }
        messages = [AIChatMessage(role: .assistant,
            text: L10n.text("Tell me what you want to create or change. I can operate the canvas and layers with Codex or Claude."))]
        error = nil
        pendingPlan = nil
        pendingImageActions = []
    }

    func applyPending(in session: EditorSession) {
        guard let plan = pendingPlan else { return }
        pendingVariants = plan.actions.flatMap { $0.variants ?? [] }
        pendingImageActions = plan.actions.filter { $0.type == "generate_image" }
        let editing = AIEditorPlan(message: plan.message, referenceAnalysis: plan.referenceAnalysis,
            actions: plan.actions.filter { $0.type != "export_variants" && $0.type != "generate_image" })
        let results = AIEditorEngine.execute(editing, in: session)
        if !results.isEmpty { messages.append(AIChatMessage(role: .system, text: results.joined(separator: "\n"))) }
        pendingPlan = nil
        if !pendingVariants.isEmpty { wantsExportFolder = true }
        if !pendingImageActions.isEmpty { runPendingImages(in: session) }
    }

    func discardPending() { pendingPlan = nil }
    func setReferenceImage(_ url: URL?) { referenceImageURL = url }

    func setImageGenerationProvider(_ provider: any AIImageGenerationProvider) {
        imageGenerationProvider = provider
        imageProviderName = provider.displayName
        isImageProviderConfigured = provider.isConfigured
    }

    func runPendingImages(in session: EditorSession) {
        guard !pendingImageActions.isEmpty, !isRunning else { return }
        guard imageGenerationProvider.isConfigured else {
            messages.append(AIChatMessage(role: .system,
                text: L10n.text("Image requests are saved in this plan. Configure an image provider to generate and insert them.")))
            return
        }
        let actions = pendingImageActions
        let provider = imageGenerationProvider
        let reference = referenceImageURL
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await AIImageGenerationPipeline.execute(actions, provider: provider,
                    referenceURL: reference, in: session)
                guard !Task.isCancelled else { return }
                pendingImageActions = []
                for result in results { messages.append(AIChatMessage(role: .system, text: result)) }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                messages.append(AIChatMessage(role: .system, text: error.localizedDescription))
            }
            isRunning = false
            task = nil
        }
    }

    func exportVariants(to folder: URL, session: EditorSession) {
        guard let snapshot = session.projectSnapshot(), !pendingVariants.isEmpty else { return }
        let variants = pendingVariants
        pendingVariants = []
        isRunning = true
        Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            do {
                let files = try await BatchVariantExporter.shared.export(snapshot, variants: variants, to: folder)
                messages.append(AIChatMessage(role: .system,
                    text: L10n.format("Exported %lld files to %@.", files.count, folder.lastPathComponent)))
            } catch {
                messages.append(AIChatMessage(role: .system, text: error.localizedDescription))
            }
            isRunning = false
        }
    }
}

struct AIChatPanel: View {
    @Bindable var controller: AIChatController
    let session: EditorSession
    @FocusState private var inputFocused: Bool
    @State private var choosingReference = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("AI Designer").font(.headline)
                Spacer()
                Menu {
                    ForEach(LocalAIProvider.allCases, id: \.self) { provider in
                        Button {
                            controller.provider = provider
                        } label: {
                            if controller.provider == provider { Label(provider.rawValue, systemImage: "checkmark") }
                            else { Text(provider.rawValue) }
                        }
                    }
                    Divider()
                    Button("Clear Conversation") { controller.clear() }.disabled(controller.isRunning)
                } label: {
                    HStack(spacing: 4) {
                        Text(controller.provider.rawValue).font(.callout)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 14).frame(height: 48)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(controller.messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                        if controller.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking and editing…").foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                        }
                        if let plan = controller.pendingPlan {
                            PlanPreview(plan: plan, apply: { controller.applyPending(in: session) },
                                        discard: { controller.discardPending() })
                        }
                    }
                    .padding(.vertical, 14)
                }
                .onChange(of: controller.messages.count) {
                    if let id = controller.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }

            Divider()
            VStack(spacing: 10) {
                if let url = controller.referenceImageURL {
                    HStack(spacing: 8) {
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading) {
                            Text("Reference Image").font(.caption.weight(.semibold))
                            Text(url.lastPathComponent).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { controller.setReferenceImage(nil) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                }
                TextField("Describe what to create or change", text: $controller.draft, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).focused($inputFocused)
                    .onSubmit { controller.send(in: session) }
                HStack {
                    Button { choosingReference = true } label: { Image(systemName: "paperclip") }
                        .buttonStyle(.plain).help("Attach reference image")
                    Text("Uses your local \(controller.provider.rawValue) login; prompts, canvas metadata, and attached references are sent to its model service.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if controller.isRunning {
                        Button("Stop") { controller.cancel() }.buttonStyle(.borderless)
                    } else {
                        Button { controller.send(in: session) } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain).disabled(controller.pendingPlan != nil
                            || controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send")
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(controller.isImageProviderConfigured ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(controller.imageProviderStatus).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if !controller.pendingImageActions.isEmpty, controller.isImageProviderConfigured {
                        Button("Generate Pending Images") { controller.runPendingImages(in: session) }
                            .buttonStyle(.borderless).controlSize(.small)
                    }
                }
            }
            .padding(12)
            .background(.black.opacity(0.12))
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        .background(Color(white: 0.12))
        .fileImporter(isPresented: $choosingReference, allowedContentTypes: [.png, .jpeg, .heic, .tiff]) { result in
            if case .success(let url) = result { controller.setReferenceImage(url) }
        }
        .fileImporter(isPresented: $controller.wantsExportFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { controller.exportVariants(to: folder, session: session) }
        }
    }
}

private struct MessageBubble: View {
    let message: AIChatMessage
    private var user: Bool { message.role == .user }
    var body: some View {
        HStack {
            if user { Spacer(minLength: 32) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(user ? Color.accentColor.opacity(0.75)
                    : message.role == .system ? Color.orange.opacity(0.18) : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
            if !user { Spacer(minLength: 32) }
        }
        .padding(.horizontal, 10)
    }
}

private struct PlanPreview: View {
    let plan: AIEditorPlan
    let apply: () -> Void
    let discard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Proposed Changes", systemImage: "checklist").font(.caption.weight(.semibold))
            if let analysis = plan.referenceAnalysis {
                Text(analysis.summary).font(.caption).foregroundStyle(.secondary)
                if !analysis.palette.isEmpty {
                    Text(analysis.palette.joined(separator: "  ")).font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(plan.actions.prefix(24).enumerated()), id: \.offset) { _, action in
                Text("• \(summary(action))").font(.caption.monospaced())
            }
            HStack {
                Button("Discard", action: discard)
                Spacer()
                Button("Apply Plan", action: apply).buttonStyle(.borderedProminent)
            }.controlSize(.small)
        }
        .padding(11).background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
        .padding(.horizontal, 10)
    }

    private func summary(_ action: AIEditorAction) -> String {
        switch action.type {
        case "create_canvas": return "create_canvas \(number(action.width))×\(number(action.height))"
        case "add_shape": return "add_shape \(action.shape ?? "rectangle") \(number(action.width))×\(number(action.height)) \(action.color ?? "")"
        case "add_gradient": return "add_gradient \(action.gradient ?? "linear") \((action.colors ?? []).joined(separator: " → ")) angle \(number(action.angle))°"
        case "edit_gradient": return "edit_gradient \((action.colors ?? []).joined(separator: " → "))"
        case "add_text": return "add_text \(String((action.text ?? "").prefix(32)).debugDescription) \(number(action.fontSize)) pt"
        case "edit_text": return "edit_text \(String((action.text ?? "").prefix(32)).debugDescription)"
        case "generate_image": return "generate_image \(action.imageRole ?? "photo") \(number(action.width))×\(number(action.height)) \(String((action.prompt ?? "").prefix(40)).debugDescription)"
        case "transform_layer": return "transform_layer x:\(number(action.x)) y:\(number(action.y)) w:\(number(action.width)) h:\(number(action.height))"
        case "set_opacity": return "set_opacity \(number(action.opacity))"
        case "set_visibility": return "set_visibility \(action.visible.map { String($0) } ?? "")"
        case "add_adjustment": return "add_adjustment \(action.adjustment ?? "")"
        case "add_mask": return "add_mask \(action.mask ?? "reveal")"
        case "group_layers": return "group_layers \(action.layerIDs?.count ?? 0) layers"
        case "reorder_layer": return "reorder_layer position \(action.position.map { String($0) } ?? "")"
        case "export_variants": return "export_variants \(action.variants?.count ?? 0) sizes"
        default: return action.name.map { "\(action.type) \($0)" } ?? action.type
        }
    }

    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.4g", $0) } ?? "–"
    }
}
