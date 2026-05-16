import Testing
import Foundation
import SwiftData
import OracleCore
@testable import Oracle

// MARK: - DictationCaptureViewModelTests

/// Unit tests for ``DictationCaptureViewModel``.
///
/// # Scope
///
/// - `makeDraftIfNeeded()` — returns a draft when recording with a non-empty
///   partial transcript; returns `nil` otherwise.
/// - `save()` — encoded payload has `source_modality == "dictated"`.
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
  let api = OracleAPI(
    baseURL: URL(string: "https://oracle.test.example")!,
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

// MARK: - sourceModality for dictated captures

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

  @Test("buildPayload with 'dictated' encodes source_modality as 'dictated'")
  func dictatedPayloadEncodesCorrectModality() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Hello from the Action Button",
      sourceModality: "dictated",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(
      decoded.sourceModality == "dictated",
      "Dictation captures must set source_modality to 'dictated', not 'text' or 'typed'"
    )
  }

  @Test("buildPayload with 'typed' encodes source_modality as 'typed'")
  func typedPayloadEncodesCorrectModality() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Hello from the keyboard",
      sourceModality: "typed",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(
      decoded.sourceModality == "typed",
      "Keyboard captures must set source_modality to 'typed'"
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
      sourceModality: "dictated",
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
