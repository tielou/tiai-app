import SwiftUI

/// Which appearance the app draws in, and the control that changes it.
///
/// The app was already dark-mode correct without trying: every colour in it is
/// semantic (`.background.secondary`, `.separator`, `.secondary`) and there is
/// not a literal white or black in the codebase, so it follows the system
/// automatically. What it did not have is a say in the matter — Open WebUI has a
/// theme setting, and a client that ignores the one you picked in the browser
/// while forcing the system's is half a setting.
///
/// Stored under `tiai.appearance` as a raw string, so an unrecognised value
/// falls back to following the system rather than to a fixed theme.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public static let storageKey = "tiai.appearance"

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon.stars"
        }
    }

    /// `nil` means "no opinion", which is how SwiftUI expresses following the
    /// system — setting `.light`/`.dark` would override the system rather than
    /// agree with it.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Reads and writes the stored appearance. One place, because the app root needs
/// the value to apply it and the list needs it to show a tick.
@MainActor
@Observable
public final class AppearanceStore {
    public static let shared = AppearanceStore()

    public var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: AppearanceMode.storageKey)
        }
    }

    public init() {
        let stored = UserDefaults.standard.string(forKey: AppearanceMode.storageKey)
        mode = AppearanceMode(rawValue: stored ?? "") ?? .system
    }
}

public struct AppearancePicker: View {
    @Bindable var store: AppearanceStore

    public init(store: AppearanceStore = .shared) {
        self.store = store
    }

    public var body: some View {
        Menu {
            Picker("Appearance", selection: $store.mode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            // Without .inline a Picker in a Menu renders as a submenu with no
            // mark on the current choice, so the row that *is* selected looks
            // like one that has not been set.
            .pickerStyle(.inline)
        } label: {
            // Icon only: in a toolbar a `Label` renders its title too, and
            // "Appearance" in words next to a half-moon icon is one control
            // wearing two labels.
            Image(systemName: store.mode.systemImage)
        }
        .accessibilityLabel("Appearance: \(store.mode.title)")
    }
}
