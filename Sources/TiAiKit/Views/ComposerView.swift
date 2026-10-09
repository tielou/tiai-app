import SwiftUI

/// The composer: what you type, which model answers, and which features are on.
///
/// The send button turns into Stop while a run is in flight rather than the
/// screen going modal. The draft is held by the conversation model, so a run in
/// progress does not lock the keyboard and a half-typed follow-up is not lost.
struct ComposerView: View {
    @Bindable var conversation: ConversationModel
    var models: [ChatModel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $conversation.draft, axis: .vertical)
                    .lineLimit(1...8)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))
                    .onSubmit { conversation.send() }

                Button {
                    if conversation.phase.isBusy { conversation.stop() } else { conversation.send() }
                } label: {
                    Image(systemName: conversation.phase.isBusy ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.borderless)
                .disabled(!conversation.phase.isBusy && !conversation.canSend)
                .accessibilityLabel(conversation.phase.isBusy ? "Stop" : "Send")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 12) {
            modelPicker
            featurePicker
            Spacer()
            if let phase = phaseLabel {
                Text(phase).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var modelPicker: some View {
        Menu {
            ForEach(conversation.modelIDs, id: \.self) { id in
                Button {
                    conversation.select(model: id, from: models)
                } label: {
                    if id == conversation.model {
                        Label(id, systemImage: "checkmark")
                    } else {
                        Text(id)
                    }
                }
            }
        } label: {
            Label(conversation.model.isEmpty ? "Model" : conversation.model, systemImage: "cpu")
                .lineLimit(1)
        }
        .disabled(conversation.phase.isBusy)
    }

    /// Only the toggles this model says it has. An empty capability map means "no
    /// metadata" rather than "no features", so the model with no capabilities still
    /// gets the full list — hiding web search there would be a feature removal
    /// invented by a missing dict on the server.
    private var featurePicker: some View {
        Menu {
            ForEach(ChatFeature.allCases, id: \.self) { feature in
                Toggle(isOn: binding(for: feature)) {
                    Text(feature.title)
                }
                .disabled(!available(feature))
            }
        } label: {
            Label("Features", systemImage: "switch.2")
        }
        .disabled(conversation.phase.isBusy)
    }

    private func available(_ feature: ChatFeature) -> Bool {
        models.first(where: { $0.id == conversation.model })?.supports(feature) ?? true
    }

    private func binding(for feature: ChatFeature) -> Binding<Bool> {
        Binding(
            get: { conversation.features[feature.rawValue] ?? false },
            set: { conversation.features[feature.rawValue] = $0 })
    }

    private var phaseLabel: String? {
        switch conversation.phase {
        case .waiting: "waiting…"
        case .streaming: "streaming…"
        case .stopping: "stopping…"
        case .loading: "loading…"
        case .ready: nil
        }
    }
}
