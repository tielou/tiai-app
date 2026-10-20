import Foundation
#if os(iOS)
import UIKit
import UserNotifications
#endif

/// Telling the user an answer finished while they were not looking at the app.
///
/// The honest limit: iOS does not keep a websocket alive in the background, so
/// the app cannot *watch* a run finish while suspended. What it can do is notice
/// completion in the windows where it is still running — notification centre,
/// app switcher, a quick switch to another app — and say so there. A run that
/// finishes while the phone is locked is read off the server record the next
/// time the app opens, which is the existing reconcile path and needs no
/// notification because you are already looking at it.
///
/// Off until asked for. A chat app that starts posting notifications on its own
/// is a notification app with a chat attached.
@MainActor
public enum CompletionNotifier {
    #if os(iOS)
    /// Whether a notification may be posted at all. False until the user turns
    /// the setting on, which is also when permission is requested — asking at
    /// launch, for a feature nobody has opted into, is how permissions get
    /// permanently denied on the first prompt.
    public static var isEnabled = false

    public static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        isEnabled = granted
        return granted
    }

    /// Post if — and only if — the app is not the thing on screen.
    ///
    /// Announcing an answer the user is already reading is worse than silence.
    public static func answerReady(title: String, preview: String) {
        guard isEnabled else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Answer ready" : title
        // Truncated on purpose: a notification is a line, and a wall of text is
        // read as a bug rather than as detail.
        content.body = preview.count > 120 ? String(preview.prefix(120)) + "…" : preview
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "answer-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    #else
    // Nothing notifies here; the members exist so shared code compiles on macOS.
    public static var isEnabled = false

    public static func requestAuthorization() async -> Bool { false }

    public static func answerReady(title: String, preview: String) {}
    #endif
}
