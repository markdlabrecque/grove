import Foundation
import NaturalLanguage

// MARK: - LanguageDetector
//
// Thin wrapper around `NLLanguageRecognizer` for on-device language detection
// (#187).
//
// ## Short-string behaviour
//
// Inputs shorter than `minimumDetectableLength` (currently 4 characters) return
// `nil` unconditionally — the length guard fires before the model runs. At or
// above that threshold the recogniser may still return `nil` for ambiguous or
// purely numeric/symbolic content. Callers should treat `nil` as undetermined
// and fall back to a sensible default (e.g. the user's language hint from
// Settings, or "en").
//
// ## BCP-47 output format
//
// `NLLanguage.rawValue` returns codes like "en", "fr", "de", "zh-Hans". These
// are already in BCP-47 format — no conversion needed. The ticket requires BCP-47
// base codes for the payload `language` field.

enum LanguageDetector {

  // MARK: - Public API

  /// Detect the dominant language in `text`.
  ///
  /// Returns a BCP-47 language code string (e.g. `"en"`, `"fr"`, `"de"`) or
  /// `nil` if the language cannot be determined (text is empty, too short,
  /// ambiguous, or purely non-linguistic content).
  ///
  /// **Guaranteed nil cases:**
  /// - Inputs shorter than `minimumDetectableLength` (currently 4 characters)
  ///   return `nil` unconditionally. Below this threshold `NLLanguageRecognizer`
  ///   routinely mis-identifies short tokens (e.g. `"I"` → `"hr"`), so the guard
  ///   is enforced in code rather than relying on the model's confidence score.
  /// - Inputs at or above that threshold may still return `nil` when the model
  ///   returns `.undetermined` (ambiguous or non-linguistic text).
  ///
  /// **Thread safety:** A fresh `NLLanguageRecognizer` is created per call.
  /// `NLLanguageRecognizer` is not documented as thread-safe; creating per call
  /// avoids data races when `detect(_:)` is called from concurrent contexts
  /// (e.g. Swift Testing parallel test runners). `NLLanguageRecognizer` is cheap
  /// to instantiate, so the per-call overhead is negligible.
  ///
  /// - Parameter text: The text to analyse. May be empty.
  /// - Returns: A BCP-47 code, or `nil` for undetermined.

  // Minimum character count for reliable language detection.  Below this
  // threshold `NLLanguageRecognizer` routinely mis-identifies single common
  // characters as a random language (e.g. "I" → "hr"). The doc contract
  // guarantees nil for inputs below this threshold.
  static let minimumDetectableLength = 4

  static func detect(_ text: String) -> String? {
    guard text.count >= minimumDetectableLength else { return nil }

    let recogniser = NLLanguageRecognizer()
    recogniser.processString(text)

    let language = recogniser.dominantLanguage
    guard let language, language != .undetermined else {
      return nil
    }
    return language.rawValue
  }
}
