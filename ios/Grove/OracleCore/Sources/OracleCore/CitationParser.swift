import Foundation

// MARK: - AnswerSegment

/// A segment of a RAG-synthesised answer, split at `[#<UUID>]` citation tokens.
///
/// - `text`: a run of prose (may include literal `[#…]` tokens that did not
///   resolve to a source in the response, or that were malformed).
/// - `citation`: a resolved reference — the associated `Int` is the 0-based
///   index into the `QueryResponseBody.sources` array.
///
/// Use `CitationParser.parse(answer:sources:)` to produce a segment array from
/// a raw answer string and a sources list.
public enum AnswerSegment: Equatable, Sendable {
  case text(String)
  case citation(Int)
}

// MARK: - CitationParser

/// Splits a RAG-synthesised answer string into `AnswerSegment` values.
///
/// ### Token format
///
/// The server emits inline citations as `[#<UUID>]` where `<UUID>` is the
/// lowercase or uppercase canonical UUID string of the referenced memory.
/// Example:
/// ```
/// "SwiftData is the local store. [#c1d2e3f4-a5b6-7890-cdef-012345678901]"
/// ```
///
/// ### Resolution rules
///
/// 1. A token whose UUID matches a source in `sources` becomes `.citation(idx)`
///    where `idx` is the 0-based position of the first matching source.
/// 2. A token whose UUID does **not** match any source is treated as literal
///    text and folded into the surrounding `.text` run.
/// 3. A token that is syntactically `[#…]` but whose content is not a valid
///    UUID is also left as literal text — malformed tokens are not cited.
///
/// ### Empty segments
///
/// Empty text runs (e.g. the string starts with a citation) are omitted from
/// the output rather than producing `.text("")` entries.
public enum CitationParser {

  // Matches the literal pattern [#<candidate>] where <candidate> is one or
  // more non-] characters. UUID validity is checked separately so non-UUID
  // tokens fall through cleanly.
  private static let pattern = try! NSRegularExpression(
    pattern: #"\[#([^\]]+)\]"#,
    options: []
  )

  /// Parse `answer` into an ordered list of `AnswerSegment` values.
  ///
  /// - Parameters:
  ///   - answer: The raw answer string from `QueryResponseBody.answer`.
  ///   - sources: The ordered `QueryResponseBody.sources` array. Used to
  ///     resolve citation UUIDs to their 0-based index.
  /// - Returns: An array of segments; never empty if `answer` is non-empty.
  public static func parse(
    answer: String,
    sources: [QueryResult]
  ) -> [AnswerSegment] {
    // Build a UUID → index lookup from the sources list. First occurrence wins
    // when there are duplicate memory IDs (defensive; shouldn't happen in practice).
    var indexByUUID: [UUID: Int] = [:]
    for (idx, source) in sources.enumerated() {
      if indexByUUID[source.memoryID] == nil {
        indexByUUID[source.memoryID] = idx
      }
    }

    let nsAnswer = answer as NSString
    let fullRange = NSRange(location: 0, length: nsAnswer.length)
    let matches = pattern.matches(in: answer, options: [], range: fullRange)

    var segments: [AnswerSegment] = []
    var cursor = 0  // current position in the string (NSString index)

    for match in matches {
      let tokenRange = match.range         // the [#…] token's range
      let captureRange = match.range(at: 1) // the content inside [#…]

      guard captureRange.location != NSNotFound,
            let candidateStr = nsAnswer.substring(with: captureRange) as String?,
            let uuid = UUID(uuidString: candidateStr),
            let sourceIndex = indexByUUID[uuid]
      else {
        // Not a valid/resolvable citation — skip; leave for the text run below
        // by NOT updating cursor here. The token will be included verbatim in
        // the text up to the next real citation (or end of string).
        continue
      }

      // Append text run from cursor up to the start of this token.
      let textBefore = nsAnswer.substring(with: NSRange(location: cursor, length: tokenRange.location - cursor))
      if !textBefore.isEmpty {
        segments.append(.text(textBefore))
      }

      // Append the resolved citation.
      segments.append(.citation(sourceIndex))

      // Advance cursor past the token.
      cursor = tokenRange.location + tokenRange.length
    }

    // Append any trailing text after the last resolved citation.
    if cursor < nsAnswer.length {
      let trailing = nsAnswer.substring(from: cursor)
      if !trailing.isEmpty {
        segments.append(.text(trailing))
      }
    }

    // If there were no resolved citations at all (all tokens were unresolvable
    // or the answer was pure prose), the whole string ends up as one .text run.
    return segments
  }
}
