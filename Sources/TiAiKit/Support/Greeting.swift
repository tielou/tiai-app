import Foundation

/// The name and greeting shown on an empty chat.
///
/// The server's `name` field is usually the email — `thilo@wobker.co` — because
/// that is what Open WebUI stores when an account is created by signup rather
/// than by someone filling in a profile. Showing that in a greeting would be
/// absurd, so the local part is taken and capitalised, which is what the web
/// client does too. A real name with a space in it is handled the same way: first
/// word, nothing else.
public enum Greeting {
    /// "Thilo", from "Thilo", "thilo@wobker.co", "thilo.wobker@…" or "Thilo Wobker".
    public static func firstName(from raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.contains("@") ? String(raw.split(separator: "@").first ?? "") : raw
        // Emails are lower-case by convention; names are not. Capitalising the
        // first letter is the one thing that is safe either way.
        let word = base
            .split(whereSeparator: { ".-_ ".contains($0) })
            .first.map(String.init) ?? base
        guard !word.isEmpty else { return nil }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// "Good afternoon", "Good morning", … — local time, four buckets.
    ///
    /// The late bucket is deliberately not "Good night": someone opening a chat
    /// client at 1am is not being sent to bed, they are being acknowledged.
    public static func timeOfDay(hour: Int) -> String {
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<22: return "Good evening"
        default: return "Still up"
        }
    }

    /// The whole line, or a bare greeting when there is no name to use.
    public static func line(for name: String?, at date: Date = Date(), calendar: Calendar = .current) -> String {
        let greeting = timeOfDay(hour: calendar.component(.hour, from: date))
        guard let first = firstName(from: name) else { return greeting }
        return "\(greeting), \(first)"
    }
}
