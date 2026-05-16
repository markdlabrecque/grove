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

  @Test("returns nil when stopped (not mid-recording)")
  func returnsNilWhenStopped() throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(
      controller: controller,
      uploadQueue: try makeQueue()
    )
    vm.recordingState = .stopped
    vm.transcript = "Some completed transcript"
    // .stopped means the session ended — no resume banner needed.
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
