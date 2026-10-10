import SwiftUI

/// Notes, as a read-and-write list.
///
/// Notes are their own object in Open WebUI — their own list, editor and sharing
/// — so they get their own screen rather than being smuggled into chats. The
/// body is markdown, which the chat transcript already knows how to draw, so the
/// reader is reused instead of a second renderer being written.
struct NotesView: View {
    let client: OWUIClient

    @State private var notes: [Note] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""

    private var visible: [Note] {
        guard !query.isEmpty else { return notes }
        let needle = query.lowercased()
        return notes.filter {
            $0.title.lowercased().contains(needle) || $0.markdown.lowercased().contains(needle)
        }
    }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(visible) { note in
                NavigationLink {
                    NoteDetailView(client: client, note: note) {
                        await load()
                    }
                } label: {
                    row(note)
                }
            }
            if visible.isEmpty, !loading {
                ContentUnavailableView(
                    notes.isEmpty ? "No notes yet" : "Nothing matches",
                    systemImage: "note.text",
                    description: Text(
                        notes.isEmpty
                            ? "Notes are shared with the web UI."
                            : "Try a different word."))
            }
        }
        .navigationTitle("Notes")
        .searchable(text: $query)
        .refreshable { await load() }
        .task { await load() }
        .overlay {
            if loading && notes.isEmpty { ProgressView() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    notes.insert(Note(id: "", title: "", data: nil), at: 0)
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
            }
        }
    }

    private func row(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(note.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(note.updatedAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            notes = try await client.notes()
            error = nil
        } catch {
            // Said rather than swallowed: a server with notes switched off for
            // this role answers 401, and an empty list would look like the user
            // had written nothing.
            self.error = error.localizedDescription
        }
    }
}

/// One note: rendered, then editable as plain markdown.
///
/// Editing is a plain text editor rather than a rich one. The web UI stores a
/// rich-editor document next to the markdown; this client writes only the
/// markdown, which is the part both sides agree on, and the server merges just
/// the keys sent — so the rich document is left alone rather than clobbered.
struct NoteDetailView: View {
    let client: OWUIClient
    let note: Note
    /// Called after a save or delete so the list can re-read.
    var onChanged: () async -> Void

    @State private var title = ""
    @State private var text = ""
    @State private var editing = false
    @State private var busy = false
    @State private var saveError: String?
    @State private var noteID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            VStack(spacing: 0) {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.08))
                }
                if editing { editor } else { reading }
            }
        }
        .navigationTitle(title.isEmpty ? "Note" : title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .task {
            noteID = note.id.isEmpty ? nil : note.id
            if let id = noteID {
                // The list truncates note bodies, so the full text is fetched
                // when a note is opened rather than trusted from the list row.
                if let full = try? await client.note(id: id) {
                    title = full.title
                    text = full.markdown
                } else {
                    title = note.title
                    text = note.markdown
                }
            } else {
                editing = true
            }
        }
    }

    private var reading: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block)
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Empty note")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $title)
                .font(.headline)
                .padding(.horizontal)
                .padding(.vertical, 10)
            Divider()
            TextField("Write in markdown…", text: $text, axis: .vertical)
                .font(.body.monospaced())
                .multilineTextAlignment(.leading)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if editing {
                Button(busy ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button("Edit") { editing = true }
            }
        }
        if !editing {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    Task {
                        guard let id = noteID else { dismiss(); return }
                        try? await client.deleteNote(id: id)
                        await onChanged()
                        dismiss()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @MainActor
    private func save() async {
        busy = true
        saveError = nil
        defer { busy = false }
        let markdown = text
        let name = title.trimmingCharacters(in: .whitespaces)
        do {
            if let id = noteID {
                _ = try await client.updateNote(id: id, title: name, markdown: markdown)
            } else {
                let created = try await client.createNote(title: name, markdown: markdown)
                noteID = created.id
            }
            editing = false
            await onChanged()
        } catch {
            // Said out loud and the edit kept: a save that failed silently and
            // threw the text away is the worst possible outcome.
            saveError = "Could not save: \(error.localizedDescription)"
        }
    }
}
