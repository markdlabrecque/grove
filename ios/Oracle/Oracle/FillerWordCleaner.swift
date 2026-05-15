import Foundation

// MARK: - FillerWordCleaner
//
// Client-side filler-word stripping for dictated captures (#187).
//
// ## Conservative ruleset
//
// Filler detection is intentionally conservative to avoid mangling real
// content. We only strip patterns that are unambiguously filler:
//
//   1. Sentence-initial fillers followed by a comma: "Um, ..." "Uh, ..."
//      "Like, ..." "You know, ..."
//   2. Mid-sentence ", filler," patterns: "I went, um, to the store."
//
// ## "like" ambiguity
//
// "like" is a common filler ("Like, I was just standing there.") but also a
// valid verb ("I like coffee"), preposition ("something like that"), and
// conjunction. We strip it ONLY when followed directly by a comma — this
// preserves uses like "I like coffee" and "something like that" while catching
// the clear filler pattern "Like, ..." and ", like, ...".
//
// ## "you know" ambiguity
//
// "you know this already" is a statement; "you know, ..." is a filler. We
// strip only the comma-following form.
//
// ## Output trimming
//
// After stripping, leading/trailing whitespace and orphaned leading commas or
// periods are removed. The first character is capitalised if it is a letter.
//
// ## Scope
//
// Only the *outgoing payload* is cleaned (via `CaptureViewModel.buildPayload`).
// The user's text field always shows the original typed/dictated text.

enum FillerWordCleaner {

  // MARK: - Public API

  /// Strip common filler words from `text` and return the cleaned string.
  ///
  /// The input `text` is not mutated; a new string is returned. If no fillers
  /// are found, the original string is returned unchanged (same value, no
  /// allocation beyond the regex).
  static func clean(_ text: String) -> String {
    guard !text.isEmpty else { return text }

    var result = text

    // Pass 1a — "um" and "uh" sentence-initial: match when followed by comma
    // or whitespace. These are always filler in this position.
    // Applied in a loop to handle chaining, e.g. "um, uh, let's go."
    let umUhPattern = #"(?i)^\s*(um|uh)\s*,\s*"#
    var previous: String
    repeat {
      previous = result
      result = result.replacingOccurrences(
        of: umUhPattern,
        with: "",
        options: .regularExpression
      )
    } while result != previous

    // Pass 1b — "like" and "you know" sentence-initial: only strip when
    // followed by a comma, to avoid false positives like
    // "I like coffee" or "You know this already".
    let likeYouKnowPattern = #"(?i)^\s*(like|you know)\s*,\s*"#
    repeat {
      previous = result
      result = result.replacingOccurrences(
        of: likeYouKnowPattern,
        with: "",
        options: .regularExpression
      )
    } while result != previous

    // Pass 2 — mid-sentence ", filler," pattern: ", um," | ", uh," | ", like,"
    // | ", you know,". Replaces the whole ", filler," with just "," to avoid a
    // double-comma or orphaned comma.
    let midSentencePattern = #"(?i),\s*(um|uh|like|you know)\s*,"#
    result = result.replacingOccurrences(
      of: midSentencePattern,
      with: ",",
      options: .regularExpression
    )

    // Pass 3 — sentence-boundary after period: ". Um, " | ". Uh, " etc.
    // Catches cases like "Okay. Um, let's continue." → "Okay. Let's continue."
    let afterPeriodPattern = #"(?i)\.\s+(um|uh|like|you know)[,\s]+"#
    result = result.replacingOccurrences(
      of: afterPeriodPattern,
      with: ". ",
      options: .regularExpression
    )

    // Pass 4 — cleanup: remove orphaned leading punctuation (commas, periods)
    // after the above passes strip a sentence-initial filler that was followed
    // by punctuation, e.g. "Um. Let's go." where Pass 1 strips "Um. " but
    // could leave ". Let's go." if there's no trailing comma. Handle both
    // ". " and ", " at position 0.
    let leadingPunctuationPattern = #"^\s*[.,]\s*"#
    result = result.replacingOccurrences(
      of: leadingPunctuationPattern,
      with: "",
      options: .regularExpression
    )

    // Pass 5 — capitalise the first letter of the cleaned string, since
    // stripping a sentence-initial filler may expose a lower-case word.
    result = capitaliseFirst(result)

    // Pass 6 — trim any leading/trailing whitespace introduced by the above.
    return result.trimmingCharacters(in: .whitespaces)
  }

  // MARK: - Private helpers

  private static func capitaliseFirst(_ s: String) -> String {
    guard let first = s.unicodeScalars.first,
          CharacterSet.letters.contains(first) else {
      return s
    }
    return s.prefix(1).uppercased() + s.dropFirst()
  }
}
