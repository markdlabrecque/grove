import Foundation

// MARK: - CaptureGuard
//
// Pure, stateless validation for capture content.
//
// Extracted from CaptureViewModel and DictationCaptureViewModel so the
// trim-and-validate rule is testable from GroveCoreTests (SPM / CI) without
// requiring @testable import Grove. Ticket #399.
//
// Rules
// -----
// A capture is valid when it contains at least one non-whitespace character
// after trimming leading and trailing whitespace and newlines.
//
// Usage in view models
// --------------------
//   guard let trimmed = CaptureGuard.trimmedContent(raw) else { return }
//   // trimmed is guaranteed non-empty from here.

public enum CaptureGuard {

  /// Returns `true` when `raw` contains at least one non-whitespace character.
  public static func validate(_ raw: String) -> Bool {
    !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Returns the trimmed string when it is non-empty, or `nil` otherwise.
  ///
  /// Prefer this over `validate` in save paths so the trimmed value can be
  /// used directly without a second trim call.
  public static func trimmedContent(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
