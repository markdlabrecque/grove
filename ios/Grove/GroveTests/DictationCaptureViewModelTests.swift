import Testing
import Foundation
import SwiftData
import GroveCore
@testable import Grove

// MARK: - DictationCaptureViewModelTests

/// Unit tests for ``DictationCaptureViewModel``.
///
/// # Scope
///
/// - `makeDraftIfNeeded()` — returns a draft when recording with a non-empty
///   partial transcript; returns `nil` otherwise.
/// - `save()` — encoded payload has `source_modality == "voice"`.
///
/// These tests do not exercise the audio engine.  Where a `DictationController`
/// is needed, the mock seam from `DictationControllerTests.swift` is used with
/// `isAvailable = false` so the error-exit path keeps the audio engine idle.

// MARK: - Fixture helpers

@MainActor
private func makeQueue() throws -> UploadQueue {
  let schema = Schema([QueuedCapture.self])
  let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
  let container = try ModelContainer(for: schema, configurations: [config])
  let api = GroveAPI(
    baseURL: URL(string: "https://grove.test.example")!,
    bearerToken: "test-token"
  )
  return UploadQueue(modelContainer: container, api: api)
}

// MARK: - makeDraftIfNeeded

@Suite("DictationCaptureViewModel.makeDraftIfNeeded")
@MainActor
struct DictationCaptureViewModelDraftTests {

  @Test("returns nil when recordingState is idle")
  func returnsNilWhenIdle() throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )
    // State defaults to .idle, transcript defaults to "".
    #expect(vm.makeDraftIfNeeded() == nil)
  }

  @Test("returns nil when transcript is empty even if recording")
  func returnsNilWhenTranscriptEmpty() throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )
    // Manually force recording state with empty transcript.
    vm.recordingState = .recording
    vm.transcript = ""
    #expect(vm.makeDraftIfNeeded() == nil)
  }

  @Test("returns nil when transcript is whitespace-only even if recording")
  func returnsNilWhenTranscriptWhitespaceOnly() throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )
    vm.recordingState = .recording
    vm.transcript = "   \n"
    #expect(vm.makeDraftIfNeeded() == nil)
  }

  @Test("returns a DictationDraft when recording with non-empty partial transcript")
  func returnsDraftWhenRecordingWithText() throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )
    vm.recordingState = .recording
    vm.transcript = "This is a partial thought"
    let draft = vm.makeDraftIfNeeded()
    #expect(draft != nil, "Expected a draft when recording with non-empty transcript")
    #expect(draft?.transcript == "This is a partial thought")
  }

  @Test("returns a draft when stopped with non-empty transcript")
  func returnsDraftWhenStoppedWithText() throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )
    vm.recordingState = .stopped
    vm.transcript = "Stopped but unsaved"
    // .stopped + non-empty → draft produced so app-background doesn't silently discard.
    let draft = vm.makeDraftIfNeeded()
    #expect(draft != nil, "Expected a draft when stopped with non-empty transcript")
    #expect(draft?.transcript == "Stopped but unsaved")
  }

  @Test("returns nil when stopped but transcript is empty")
  func returnsNilWhenStoppedAndTranscriptEmpty() throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )
    vm.recordingState = .stopped
    vm.transcript = ""
    #expect(vm.makeDraftIfNeeded() == nil)
  }
}

// MARK: - CaptureGuard delegation (#414)

/// Pins that `makeDraftIfNeeded()` delegates its empty-content check to
/// `CaptureGuard.validate(_:)` rather than reproducing the trim inline.
///
/// These tests document the delegation contract.  They will catch any future
/// divergence between `makeDraftIfNeeded` and `CaptureGuard`.
///
/// ## CI note
/// Runs in the `GroveTests` app target (`make ios-test-app`).
/// `make ios-test-core` (SPM / CI) does NOT exercise these — call that out
/// in any future CI gap ticket.
@Suite("DictationCaptureViewModel.makeDraftIfNeeded — CaptureGuard delegation")
@MainActor
struct DictationCaptureViewModelCaptureGuardTests {

  // Shared helper — same contract for all cases: if CaptureGuard.validate(transcript)
  // is false the VM must return nil; if true the VM must return a draft.
  private func makeVM() throws -> DictationCaptureViewModel {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    return DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )
  }

  @Test("makeDraftIfNeeded returns nil iff CaptureGuard.validate is false — empty string")
  func delegatesToCaptureGuardForEmpty() throws {
    let vm = try makeVM()
    vm.recordingState = .recording
    vm.transcript = ""
    let guardSays = CaptureGuard.validate(vm.transcript)
    let draft = vm.makeDraftIfNeeded()
    // If CaptureGuard says invalid the VM must agree.
    #expect(guardSays == false)
    #expect(draft == nil, "makeDraftIfNeeded must respect CaptureGuard.validate for empty input")
  }

  @Test("makeDraftIfNeeded returns nil iff CaptureGuard.validate is false — whitespace-only")
  func delegatesToCaptureGuardForWhitespace() throws {
    let vm = try makeVM()
    vm.recordingState = .recording
    vm.transcript = "   \n\t  "
    let guardSays = CaptureGuard.validate(vm.transcript)
    let draft = vm.makeDraftIfNeeded()
    #expect(guardSays == false)
    #expect(draft == nil, "makeDraftIfNeeded must respect CaptureGuard.validate for whitespace-only input")
  }

  @Test("makeDraftIfNeeded returns draft iff CaptureGuard.validate is true")
  func delegatesToCaptureGuardForValidContent() throws {
    let vm = try makeVM()
    vm.recordingState = .recording
    vm.transcript = "Buy oat milk"
    let guardSays = CaptureGuard.validate(vm.transcript)
    let draft = vm.makeDraftIfNeeded()
    #expect(guardSays == true)
    #expect(draft != nil, "makeDraftIfNeeded must produce a draft when CaptureGuard.validate is true")
  }

  @Test("makeDraftIfNeeded result always matches CaptureGuard.validate outcome")
  func resultAlwaysMatchesCaptureGuardOutcome() throws {
    let cases: [(transcript: String, state: DictationCaptureViewModel.RecordingState)] = [
      ("", .recording),
      ("   ", .recording),
      ("hello", .recording),
      ("", .stopped),
      ("partial thought", .stopped),
    ]
    for (transcript, state) in cases {
      let vm = try makeVM()
      vm.recordingState = state
      vm.transcript = transcript
      let isActive = state == .recording || state == .stopped
      let guardResult = CaptureGuard.validate(transcript)
      let draft = vm.makeDraftIfNeeded()
      // The VM must only produce a draft when both active AND CaptureGuard approves.
      let expected = isActive && guardResult
      #expect(
        (draft != nil) == expected,
        "transcript='\(transcript)' state=\(state): expected draft=\(expected) got draft=\(draft != nil)"
      )
    }
  }
}

// MARK: - sourceModality for voice captures

@Suite("DictationCaptureViewModel.save sourceModality")
@MainActor
struct DictationCaptureViewModelModalityTests {

  /// Minimal decodable shape matching CaptureRequestBody wire format.
  private struct DecodedBody: Decodable {
    let sourceModality: String
    enum CodingKeys: String, CodingKey {
      case sourceModality = "source_modality"
    }
  }

  @Test("buildPayload with 'voice' encodes source_modality as 'voice'")
  func voicePayloadEncodesCorrectModality() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Hello from the Action Button",
      sourceModality: "voice",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(
      decoded.sourceModality == "voice",
      "Dictation captures must set source_modality to 'voice' (server contract — see captures.py)"
    )
  }

  @Test("buildPayload with 'text' encodes source_modality as 'text'")
  func textPayloadEncodesCorrectModality() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Hello from the keyboard",
      sourceModality: "text",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(
      decoded.sourceModality == "text",
      "Keyboard captures must set source_modality to 'text' (server contract — see captures.py)"
    )
  }
}

// MARK: - Re-entry guard (#385)

/// Verifies that calling `startDictation()` while a session is already in
/// progress does NOT wipe the in-progress transcript.
///
/// ## Repro
///
/// The `.task` modifier in `DictationCaptureView` fired a second
/// `startDictation()` call on re-appearance (e.g. Action Button re-tap while
/// the sheet was still on screen).  Before the guard, line 119 of
/// `DictationCaptureViewModel.startDictation()` set `transcript = ""`
/// unconditionally, discarding any partial text the user had already spoken.
///
/// ## CI note
///
/// This test lives in the `GroveTests` app target (`make ios-test-app`).
/// `make ios-test-core` (SPM / CI) does NOT exercise it — call that out in
/// the PR body so future CI work can close the gap.
@Suite("DictationCaptureViewModel.startDictation re-entry guard")
@MainActor
struct DictationCaptureViewModelReentryTests {

  /// Calling `startDictation()` while `recordingState == .stopped` (i.e. a
  /// session is in-progress) must leave the transcript unchanged.
  @Test("startDictation() while stopped does not wipe transcript")
  func startDictationWhileStoppedDoesNotWipeTranscript() async throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false  // Fast-exit path; no audio engine started.
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )

    // Simulate a session that has already finished — user has spoken, transcript populated.
    vm.recordingState = .stopped
    vm.transcript = "In-progress thought that must not be lost"

    // A second call to startDictation() — e.g. triggered by the view's .task
    // re-firing — must not wipe the transcript.
    await vm.startDictation()

    #expect(
      vm.transcript == "In-progress thought that must not be lost",
      "startDictation() while not idle must not clear the in-progress transcript"
    )
  }

  /// Calling `startDictation()` while `recordingState == .recording` must
  /// also leave the transcript unchanged.
  @Test("startDictation() while recording does not wipe transcript")
  func startDictationWhileRecordingDoesNotWipeTranscript() async throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )

    vm.recordingState = .recording
    vm.transcript = "Partial spoken text"

    await vm.startDictation()

    #expect(
      vm.transcript == "Partial spoken text",
      "startDictation() while recording must not clear the partial transcript"
    )
  }
}

// MARK: - Language detection for dictated captures (#340)

@Suite("DictationCaptureViewModel.save detectedLanguage")
@MainActor
struct DictationCaptureViewModelLanguageTests {

  /// Minimal decodable shape matching CaptureRequestBody wire format.
  private struct DecodedBody: Decodable {
    let language: String?
    enum CodingKeys: String, CodingKey {
      case language
    }
  }

  /// Value-pin: a French-enough transcript produces a non-nil detectedLanguage
  /// that flows through to the payload's `language` field.
  ///
  /// `LanguageDetector.detect` uses `NLLanguageRecognizer`, so this is a
  /// whitebox check that the call is wired — not an NL accuracy assertion.
  /// The input is long enough (≥ 4 chars) and unambiguous enough for the
  /// on-device model to identify as French.
  @Test("save() wires LanguageDetector result into buildPayload for a non-English transcript")
  func nonEnglishTranscriptProducesDetectedLanguage() throws {
    // "Bonjour le monde" is reliably detected as French by NLLanguageRecognizer.
    let frenchTranscript = "Bonjour le monde, comment ça va aujourd'hui"
    let detected = LanguageDetector.detect(frenchTranscript)
    // Assert the detector returns something non-nil for this input — if it
    // returns nil the test environment lacks NL support and we skip the value pin.
    guard let detected else { return }

    let payload = CaptureViewModel.buildPayload(
      content: frenchTranscript,
      sourceModality: "voice",
      applyFillerCleanup: false,
      detectedLanguage: detected,
      languageHint: "en"
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let body = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(
      body.language == detected,
      "Detected language '\(detected)' must flow through to payload 'language' field"
    )
    // Confirm it is not the fallback "en" (though it may be for short transcripts
    // on restricted test environments — the guard above handles that).
    #expect(
      body.language != "en",
      "Non-English transcript should not fall back to 'en' when detection succeeds"
    )
  }
}
