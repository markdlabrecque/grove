import Testing
import Foundation
@testable import Oracle

// MARK: - DictationResumeBannerStateTests
//
// State-pin invariant tests for the Resume-tap path in RootView.
//
// Background: SwiftUI coalesces state mutations that occur in the same
// synchronous closure into a single render pass.  The original implementation
// set `showDictationSheet = true` and `pendingDictation = nil` in the same
// closure, which meant the sheet content closure always saw a nil
// `pendingDictation` — opening a fresh mic-armed sheet instead of the
// pre-filled resume sheet.
//
// The fix introduces `dictationResumeTranscript: String?` that is assigned
// *before* `pendingDictation` is cleared.  These tests assert the ordering
// invariant at the logic level, without a SwiftUI rendering harness.

// MARK: - Simulated state machine

/// A minimal simulation of the three state variables and the Resume closure
/// that mirrors the logic in `RootView`.  This is NOT a SwiftUI view; it
/// captures the raw ordering invariant so the test is deterministic.
@MainActor
private struct ResumeStateMachine {

  var pendingDictation: DictationDraft? = nil
  var dictationResumeTranscript: String? = nil
  var showDictationSheet: Bool = false

  /// Simulates exactly what the Resume button's `onResume` closure does.
  mutating func tapResume() {
    guard let draft = pendingDictation else { return }
    // Pin transcript BEFORE clearing pendingDictation.
    dictationResumeTranscript = draft.transcript
    pendingDictation = nil
    showDictationSheet = true
  }

  /// Simulates what the sheet's `onDismiss` callback does.
  mutating func dismissSheet() {
    showDictationSheet = false
    dictationResumeTranscript = nil
  }
}

// MARK: - Tests

@Suite("DictationResumeBanner state-pin invariant")
@MainActor
struct DictationResumeBannerStateTests {

  @Test("resume transcript is non-nil when sheet becomes visible")
  func resumeTranscriptNonNilWhenSheetShown() {
    var machine = ResumeStateMachine()
    machine.pendingDictation = DictationDraft(transcript: "Buy oat milk")

    machine.tapResume()

    // The sheet must be shown.
    #expect(machine.showDictationSheet == true)
    // The transcript must still be available for the sheet content closure.
    #expect(
      machine.dictationResumeTranscript == "Buy oat milk",
      "dictationResumeTranscript must be set before showDictationSheet becomes true"
    )
    // The banner must be gone (pendingDictation cleared).
    #expect(machine.pendingDictation == nil)
  }

  @Test("pendingDictation is nil by the time sheet content evaluates")
  func pendingDictationClearedBeforeSheetContentEvaluates() {
    var machine = ResumeStateMachine()
    machine.pendingDictation = DictationDraft(transcript: "Call dentist")

    machine.tapResume()

    // Simulate the sheet content closure reading state.
    // The old (broken) implementation used pendingDictation here;
    // the fix uses dictationResumeTranscript.  We assert both:
    // - dictationResumeTranscript carries the transcript (resume path taken)
    // - pendingDictation is nil (banner already dismissed)
    #expect(machine.dictationResumeTranscript != nil)
    #expect(machine.pendingDictation == nil)
  }

  @Test("fresh Action Button press after dismiss gives clean empty sheet")
  func freshPressAfterDismissGivesCleanSheet() {
    var machine = ResumeStateMachine()
    machine.pendingDictation = DictationDraft(transcript: "Some thought")

    // User resumes, then dismisses the sheet.
    machine.tapResume()
    machine.dismissSheet()

    // A subsequent fresh press (no pending draft) must not re-use the old transcript.
    #expect(machine.showDictationSheet == false)
    #expect(machine.dictationResumeTranscript == nil)
    #expect(machine.pendingDictation == nil)

    // Simulate a fresh Action Button press (sets showDictationSheet = true, no draft).
    machine.showDictationSheet = true
    #expect(
      machine.dictationResumeTranscript == nil,
      "Fresh Action Button press must give a nil transcript (mic-armed fresh sheet)"
    )
  }

  @Test("tapping Resume with no pending draft is a no-op")
  func tapResumeWithNoDraftIsNoOp() {
    var machine = ResumeStateMachine()
    // pendingDictation is nil — guard in tapResume() should bail early.
    machine.tapResume()

    #expect(machine.showDictationSheet == false)
    #expect(machine.dictationResumeTranscript == nil)
  }
}
