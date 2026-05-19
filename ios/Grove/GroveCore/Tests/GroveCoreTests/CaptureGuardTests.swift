import Testing
import Foundation
@testable import GroveCore

// MARK: - CaptureGuardTests
//
// Pure-logic coverage for CaptureGuard.validate(_:).
// These run under `make ios-test-core` (SPM / CI) — no app target needed.
// Ticket #399.

@Suite("CaptureGuard — validate")
struct CaptureGuardTests {

  // MARK: Rejects empty / whitespace

  @Test("empty string is invalid")
  func emptyStringIsInvalid() {
    #expect(CaptureGuard.validate("") == false)
  }

  @Test("whitespace-only string is invalid")
  func whitespaceOnlyIsInvalid() {
    #expect(CaptureGuard.validate("   ") == false)
  }

  @Test("tab and newline only is invalid")
  func tabAndNewlineIsInvalid() {
    #expect(CaptureGuard.validate("\t\n") == false)
  }

  @Test("mixed whitespace only is invalid")
  func mixedWhitespaceIsInvalid() {
    #expect(CaptureGuard.validate("   \n\t  ") == false)
  }

  // MARK: Accepts non-empty content

  @Test("single non-whitespace character is valid")
  func singleCharIsValid() {
    #expect(CaptureGuard.validate("x") == true)
  }

  @Test("content with surrounding whitespace is valid")
  func contentWithSurroundingWhitespaceIsValid() {
    #expect(CaptureGuard.validate(" x ") == true)
  }

  @Test("normal sentence is valid")
  func normalSentenceIsValid() {
    #expect(CaptureGuard.validate("Remember to call dentist") == true)
  }

  // MARK: trimmedContent

  @Test("trimmedContent returns nil for empty string")
  func trimmedContentNilForEmpty() {
    #expect(CaptureGuard.trimmedContent("") == nil)
  }

  @Test("trimmedContent returns nil for whitespace-only")
  func trimmedContentNilForWhitespace() {
    #expect(CaptureGuard.trimmedContent("   \n\t  ") == nil)
  }

  @Test("trimmedContent returns trimmed string for valid content")
  func trimmedContentTrims() {
    #expect(CaptureGuard.trimmedContent("  hello  ") == "hello")
  }

  @Test("trimmedContent returns non-nil for content without surrounding whitespace")
  func trimmedContentNoChange() {
    #expect(CaptureGuard.trimmedContent("hello") == "hello")
  }
}
