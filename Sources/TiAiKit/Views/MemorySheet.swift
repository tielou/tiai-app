import SwiftUI

/// What the server remembers about you.
///
/// Read-only on purpose. The memory router exposes `/add` and `/update`, but the
/// update form is not documented, and the delete call this app used to attempt
/// (`POST /memories/{id}/update`) matches no route on the server — it has been
/// deleted rather than left as dead code that looks like a feature. A delete
/// button that silently does nothing is worse than none, so the sheet shows the
/// list and says where to change it.
struct MemorySheet: View {
    let client: OWUIClient

    @Environment(\.dismiss) private var dismiss
    @State private var memories: [Memory] = []
    @State private var loading = true
    @State private var error: String?

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
                            "Turn memory on in a chat and what the model learns about you appears here."
                        ))
                } else {
                    List {
                        ForEach(memories) { memory in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(memory.content)
                                if let path = memory.path, !path.isEmpty {
                                    Text(path).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
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
            }
            .safeAreaInset(edge: .bottom) {
                if !memories.isEmpty {
                    Text("To forget something, edit it in the web UI.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.bar)
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { memories = try await client.memories() }
        catch { self.error = error.localizedDescription }
    }
}
