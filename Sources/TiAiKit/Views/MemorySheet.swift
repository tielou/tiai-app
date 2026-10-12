import SwiftUI

/// What the server remembers about you, with the ability to correct it.
///
/// This used to be read-only on the reasoning that the update route did not
/// exist. It does — `POST /memories/{id}/update`, taking `content`, `type` and
/// `path` — and a list of things the assistant believes about you that you cannot
/// correct is not really a memory feature, it is a rumour mill. So: add, edit and
/// forget from here, against the same records the web UI shows.
struct MemorySheet: View {
    let client: OWUIClient

    @Environment(\.dismiss) private var dismiss
    @State private var memories: [Memory] = []
    @State private var loading = true
    @State private var error: String?
    @State private var editing: Editing?
    @State private var busy = false
    @State private var failure: String?

    /// `topBarLeading` does not exist on macOS, and the tests build the views
    /// for macOS, so the placement is picked per platform.
    private var addPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// Which memory the editor is on. `nil` content means "add a new one".
    private enum Editing: Identifiable, Equatable {
        case add
        case edit(Memory)
        var id: String {
            switch self {
            case .add: return "new"
            case .edit(let memory): return memory.id
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView {
                        Label("Could not load memory", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    }
                } else if memories.isEmpty {
                    ContentUnavailableView(
                        "Nothing remembered", systemImage: "brain",
                        description: Text(
                            "Turn memory on in a chat and what the model learns about you appears here. "
                                + "You can also write something down yourself."
                        ))
                } else {
                    List {
                        ForEach(memories) { memory in
                            Button {
                                editing = .edit(memory)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(memory.content)
                                    if let path = memory.path, !path.isEmpty {
                                        Text(path).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 2)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await forget(memory) }
                                } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                                Button {
                                    editing = .edit(memory)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.indigo)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Memory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: addPlacement) {
                    Button {
                        editing = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add to memory")
                }
            }
            .overlay {
                if busy { ProgressView().controlSize(.large) }
            }
            .safeAreaInset(edge: .bottom) {
                if let failure {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.bar)
                }
            }
            .sheet(item: $editing) { target in
                MemoryEditor(initial: text(for: target), isNew: target == .add) { text in
                    try await commit(target, text)
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func text(for target: Editing) -> String {
        if case .edit(let memory) = target { return memory.content }
        return ""
    }

    /// Save for both paths, so add and edit cannot drift apart.
    private func commit(_ target: Editing, _ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        defer { busy = false }
        switch target {
        case .add: _ = try await client.addMemory(trimmed)
        case .edit(let memory): _ = try await client.updateMemory(id: memory.id, content: trimmed)
        }
        await load()
    }

    private func forget(_ memory: Memory) async {
        busy = true
        defer { busy = false }
        failure = nil
        // Drop it locally first. The list is small and a row that lingers after a
        // successful delete looks like the forget did not work.
        memories.removeAll { $0.id == memory.id }
        do { try await client.deleteMemory(id: memory.id) }
        catch {
            failure = error.localizedDescription
            await load()
        }
    }

    private func load() async {
        loading = memories.isEmpty
        defer { loading = false }
        do { memories = try await client.memories() }
        catch { self.error = error.localizedDescription }
    }
}

/// One field, because a memory is one sentence.
///
/// Deliberately not a rich editor: the server cleans memory content and embeds
/// the result, and markup in a fact about you only makes the embedding worse.
private struct MemoryEditor: View {
    let initial: String
    let isNew: Bool
    /// Throws if the server refuses, so the reason appears in this sheet rather
    /// than behind it, and a failed save never throws away what was typed.
    let onSave: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var failure: String?

    init(initial: String, isNew: Bool, onSave: @escaping (String) async throws -> Void) {
        self.initial = initial
        self.isNew = isNew
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(isNew ? "What should it remember?" : "Correct it", text: $text, axis: .vertical)
                    .lineLimit(2...8)

                if let failure {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(isNew ? "Add to memory" : "Edit memory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        failure = nil
                        Task {
                            do {
                                try await onSave(text)
                                dismiss()
                            } catch {
                                failure = error.localizedDescription
                            }
                            saving = false
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
        }
    }
}
