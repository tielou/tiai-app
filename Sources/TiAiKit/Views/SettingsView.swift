import SwiftUI

/// The account and the knobs that belong to the app rather than to one chat.
///
/// Everything here is deliberately small. Open WebUI owns model management,
/// memory, tools and knowledge, and duplicating any of it here would be a second
/// place for the same setting to disagree with the first. What the app does own
/// is what it puts on the wire on the user's behalf: the instructions and the
/// sampling it sends when nobody has said otherwise for this chat.
public struct SettingsView: View {
    let session: SessionStore
    var store: SettingsStore = .shared
    var onSignOut: () -> Void = {}

    @State private var promptDraft = ""
    @State private var useTemperature = false
    @State private var temperature = 0.7
    @State private var confirmSignOut = false

    public init(session: SessionStore, onSignOut: @escaping () -> Void) {
        self.session = session
        self.onSignOut = onSignOut
    }

    public var body: some View {
        Form {
            profile
            defaults
            server
            signOut
        }
        .navigationTitle("Settings")
        .onAppear(perform: load)
        .confirmationDialog(
            "Sign out of \(session.server.baseURL.host ?? "this server")?",
            isPresented: $confirmSignOut, titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive, action: onSignOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chats stay on the server. The app forgets the password it kept for silent re-sign-in.")
        }
    }

    // MARK: - sections

    private var profile: some View {
        Section("Account") {
            HStack(spacing: 12) {
                Avatar(name: session.user?.name ?? "", email: session.user?.email ?? "")
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.user?.name ?? "Signed out")
                        .font(.headline)
                    Text(session.user?.email ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let role = session.user?.role, !role.isEmpty {
                    // Admin is worth showing: it explains why the tool and
                    // memory screens have things in them here and not elsewhere.
                    Text(role)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: .capsule)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var defaults: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("System prompt")
                Text("Sent with every new conversation on this server. Not retroactive — a chat already started keeps what it was given.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $promptDraft)
                    .font(.body)
                    .frame(minHeight: 110)
                    .onChange(of: promptDraft) { _, new in commit() }
            }

            Toggle("Set a temperature", isOn: $useTemperature)
                .onChange(of: useTemperature) { _, on in
                    store.defaults.temperature = on ? temperature : nil
                    commit()
                }
            if useTemperature {
                HStack {
                    Slider(value: $temperature, in: 0...2, step: 0.05) {
                        Text("Temperature")
                    } minimumValueLabel: {
                        Text("0").font(.caption2).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("2").font(.caption2).foregroundStyle(.secondary)
                    }
                    .onChange(of: temperature) { _, new in
                        store.defaults.temperature = new
                        commit()
                    }
                    Text(temperature, format: .number.precision(.fractionLength(2)))
                        .font(.callout.monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
                Text("Lower is more literal, higher is more varied. Leave it off to use whatever the server configured for each model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Defaults for new chats")
        } footer: {
            Text("Stored on this device, per server. The web UI's own settings are left alone.")
        }
    }

    private var server: some View {
        Section("Server") {
            LabeledContent("Address", value: session.server.baseURL.host ?? "—")
            if let version = session.serverVersion {
                LabeledContent("Open WebUI", value: version)
            }
            LabeledContent("tiAi", value: appVersion)
        }
    }

    private var signOut: some View {
        Section {
            Button("Sign out", role: .destructive) { confirmSignOut = true }
        }
    }

    // MARK: - plumbing

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version { return build == version || build == nil ? version : "\(version) (\(build))" }
        return "development"
    }

    private func load() {
        store.point(at: session.server.baseURL)
        promptDraft = store.defaults.systemPrompt
        useTemperature = store.defaults.temperature != nil
        temperature = store.defaults.temperature ?? 0.7
    }

    private func commit() {
        store.defaults.systemPrompt = promptDraft
    }
}

/// Initials when the server has no picture. The server stores one as a data URL
/// or a path that needs the bearer token, so a plain `AsyncImage` would 401;
/// initials are always right and never fetch.
struct Avatar: View {
    let name: String
    let email: String

    var body: some View {
        Text(initials)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Color.accentColor, in: .circle)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let source = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = source.split(separator: " ").filter { $0.count > 1 }
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        // The server's `name` is usually the email address, so fall back to the
        // local part rather than rendering "T" for thilo@wobker.co.
        let base = (source.isEmpty ? email : source).split(separator: "@").first.map(String.init) ?? source
        return String(base.prefix(2)).uppercased()
    }
}
