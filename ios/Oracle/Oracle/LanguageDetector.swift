import Foundation
import NaturalLanguage

// MARK: - LanguageDetector
//
// Thin wrapper around `NLLanguageRecognizer` for on-device language detection
// (#187).
//
// ## Short-string behaviour
//
// `NLLanguageRecognizer` requires sufficient text to make a reliable prediction.
// For strings shorter than approximately 10 characters, or for strings that are
// purely numeric/symbolic, the recogniser may return `.undetermined`. In those
// cases `detect(_:)` returns `nil`. Callers should treat `nil` as undetermined
// and fall back to a sensible default (e.g. the user's language hint from
// Settings, or "en").
//
// ## Thread safety
//
// `NLLanguageRecognizer` is not documented as thread-safe, but it is cheap to
// instantiate. We keep one shared instance and reset it before each call. Since
// detection is called from `@MainActor` contexts in `CaptureViewModel`, there is
// no concurrent access in practice.
//
// ## BCP-47 output format
//
// `NLLanguage.rawValue` returns codes like "en", "fr", "de", "zh-Hans". These
// are already in BCP-47 format — no conversion needed. The ticket requires BCP-47
// base codes for the payload `language` field.

enum LanguageDetector {

  // MARK: - Shared recogniser

  // A single instance is reused across calls. `processString(_:)` + reset is
  // cheaper than creating a new recogniser on each detection call for long text.
  private static let recogniser = NLLanguageRecognizer()

  // MARK: - Public API

  /// Detect the dominant language in `text`.
  ///
  /// Returns a BCP-47 language code string (e.g. `"en"`, `"fr"`, `"de"`) or
  /// `nil` if the language cannot be determined (text is too short, ambiguous,
  /// or purely non-linguistic content).
  ///
  /// - Parameter text: The text to analyse. May be empty.
  /// - Returns: A BCP-47 code, or `nil` for undetermined.
  static func detect(_ text: String) -> String? {
    guard !text.isEmpty else { return nil }

    recogniser.reset()
    recogniser.processString(text)

    let language = recogniser.dominantLanguage
    guard let language, language != .undetermined else {
      return nil
    }
    return language.rawValue
  }
}
