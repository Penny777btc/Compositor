import Observation
import SwiftUI

@MainActor @Observable
final class AIChatController {
    var provider: LocalAIProvider = .codex
    var draft = ""
    var messages: [AIChatMessage] = [
        AIChatMessage(role: .assistant, text: L10n.text("Tell me what you want to create or change. I can operate the canvas and layers with Codex or Claude."))
    ]
    var isRunning = false
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func send(in session: EditorSession) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
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
                let prompt = LocalAgentRunner.prompt(userText: text, history: history, context: context)
                let plan = try await LocalAgentRunner.run(provider: provider, prompt: prompt)
                guard !Task.isCancelled else { return }
                let results = AIEditorEngine.execute(plan, in: session)
                var reply = plan.message
                if !results.isEmpty { reply += "\n\n" + results.joined(separator: "\n") }
                messages.append(AIChatMessage(role: .assistant, text: reply))
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
    }
}

struct AIChatPanel: View {
    @Bindable var controller: AIChatController
    let session: EditorSession
    @FocusState private var inputFocused: Bool

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
                    }
                    .padding(.vertical, 14)
                }
                .onChange(of: controller.messages.count) {
                    if let id = controller.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }

            Divider()
            VStack(spacing: 10) {
                TextField("Describe what to create or change", text: $controller.draft, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).focused($inputFocused)
                    .onSubmit { controller.send(in: session) }
                HStack {
                    Text("Uses your local \(controller.provider.rawValue) login; prompts and canvas metadata are sent to its model service.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if controller.isRunning {
                        Button("Stop") { controller.cancel() }.buttonStyle(.borderless)
                    } else {
                        Button { controller.send(in: session) } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain).disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send")
                    }
                }
            }
            .padding(12)
            .background(.black.opacity(0.12))
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        .background(Color(white: 0.12))
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
