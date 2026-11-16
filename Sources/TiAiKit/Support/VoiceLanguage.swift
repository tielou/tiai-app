import Foundation
import NaturalLanguage

/// Mapping from the language of an answer to a voice the TTS engine has.
///
/// Why this exists: the app only sent a `voice` when the user picked one in
/// Settings, so a German answer was read aloud with the server's English
/// default — wrong pronunciation on every word. Detecting the language of the
/// text and naming a matching neural voice fixes that without a Settings
/// round-trip.
///
/// The map covers the languages this instance actually sees (the user's own
/// prompts and answers in them). English is deliberately ABSENT: the server
/// default is an English voice, so for English the server stays the authority
/// and we send nothing — one less name that could go stale on a server
/// upgrade.
///
/// An unknown language returns nil, which means no voice is sent and the
/// server default speaks. That is the right failure direction: a
/// wrong-but-understandable accent beats a voice name the engine may not
/// know, which is a 400 and silence.
///
/// Known soft edge: `NLLanguageRecognizer` needs a few words to have an
/// opinion, so very short or heavily mixed-language text can misdetect. The
/// cost of a misdetection is only a different voice — never a failure, never
/// lost audio — so there is no confidence threshold guarding it.
enum VoiceLanguage {
    /// Keyed by `NLLanguage.rawValue` (ISO 639-1).
    private static let voices: [String: String] = [
        "de": "de-DE-KatjaNeural",  // German, the primary language in use
        "fr": "fr-FR-DeniseNeural", // French
        "es": "es-ES-ElviraNeural", // Spanish
        "it": "it-IT-ElsaNeural",   // Italian
        "pt": "pt-BR-AntonioNeural", // Portuguese (Brazilian voice; pt-PT is rarer here)
        "nl": "nl-NL-FennaNeural",  // Dutch, common in mixed DE/NL usage
    ]

    /// The voice name to send for this text, or nil to let the server default speak.
    static func voice(for text: String) -> String? {
        guard let language = dominantLanguage(of: text) else { return nil }
        return voices[language]
    }

    /// The dominant language of `text` as an ISO 639-1 code, or nil when the
    /// recognizer has no opinion ("und" — under-determined — counts as none).
    static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage?.rawValue, language != "und"
        else { return nil }
        return language
    }
}
