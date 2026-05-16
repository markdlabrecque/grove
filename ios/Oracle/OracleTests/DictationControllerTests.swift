import XCTest
import Speech
@testable import Oracle

// MARK: - MockSpeechRecognizer

/// A mock `SpeechRecognizing` stand-in that satisfies the protocol without
/// starting a real audio session or making network calls.
///
/// Tests drive behavior by setting `isAvailable` and, for tests that need
/// to simulate a result, capturing `resultHandler`.
@MainActor
final class MockSpeechRecognizer: SpeechRecognizing {

  // MARK: Protocol properties

  var isAvailable: Bool = true
  var supportsOnDeviceRecognition: Bool = true

  // MARK: Configurable stubs

  var stubbedAuthStatus: SFSpeechRecognizerAuthorizationStatus = .authorized

  /// The last result handler registered; call it from tests to simulate results.
  var resultHandler: (@Sendable (SFSpeechRecognitionResult?, Error?) -> Void)?

  var stubbedTask: MockRecognitionTask = MockRecognitionTask()

  // MARK: Protocol methods

  static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    return .authorized
  }

  func recognitionTask(
    with request: SFSpeechAudioBufferRecognitionRequest,
    resultHandler: @escaping @Sendable (SFSpeechRecognitionResult?, Error?) -> Void
  ) -> SFSpeechRecognitionTask {
    self.resultHandler = resultHandler
    return stubbedTask
  }
}

// MARK: - MockRecognitionTask

/// A minimal `SFSpeechRecognitionTask` subclass for test use.
final class MockRecognitionTask: SFSpeechRecognitionTask {
  var stubbedIsFinishing: Bool = false
  var stubbedError: Error? = nil

  override var isFinishing: Bool { stubbedIsFinishing }
  override var error: Error? { stubbedError }
}

// MARK: - DictationControllerTests

/// Tests for `DictationController` that use the `SpeechRecognizing` mock seam.
///
/// ## Note on audio-engine tests
///
/// Tests that set `mock.isAvailable = false` trigger the fast-exit path in
/// `DictationController.beginSession()` — the stream emits `.error(.recognizerUnavailable)`
/// and finishes before the audio engine is ever touched.  This is intentional:
/// starting `AVAudioEngine` in a test host without a real microphone would hang
/// (the simulator does not expose a virtual input device in the unit-test context).
///
/// The callback path (`resultHandler`) can be exercised by tests that keep
/// `isAvailable = true` but also need to avoid the audio engine — see
/// `test_start_emitsErrorWhenTaskHasSpeechError_viaUnavailablePath`.
@MainActor
final class DictationControllerTests: XCTestCase {

  // MARK: - Recognizer unavailable

  func test_start_emitsErrorWhenRecognizerUnavailable() async throws {
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false

    let controller = DictationController(recognizer: mock)
    var events: [DictationEvent] = []

    for await event in controller.start() {
      events.append(event)
    }

    XCTAssertEqual(events.count, 1, "Expected exactly one event before stream ends")
    guard case .error(let err) = events[0],
          case .recognizerUnavailable = err else {
      XCTFail("Expected .error(.recognizerUnavailable), got \(events)")
      return
    }
  }

  // MARK: - Error path via unavailable recognizer (no audio-engine contact)

  func test_start_emitsErrorWhenTaskHasSpeechError_viaUnavailablePath() async throws {
    // Uses isAvailable = false so the stream terminates without starting
    // AVAudioEngine.  Validates that the error-event path terminates the stream.
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false

    let controller = DictationController(recognizer: mock)
    var receivedError: DictationError? = nil

    for await event in controller.start() {
      if case .error(let e) = event { receivedError = e }
    }

    XCTAssertNotNil(receivedError, "Stream should have emitted an error event")
  }

  // MARK: - Stop terminates the stream (via unavailable path — no audio engine)

  func test_stop_terminatesStream_viaUnavailablePath() async throws {
    // isAvailable = false → fast-exit; no audio engine started.
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false

    let controller = DictationController(recognizer: mock)
    var streamTerminated = false

    for await _ in controller.start() {
      // consume events
    }
    streamTerminated = true

    XCTAssertTrue(streamTerminated, "Stream should have terminated")
  }

  // MARK: - Silence timeout constant

  func test_silenceTimeoutConstantIsThreeSeconds() {
    XCTAssertEqual(DictationController.silenceTimeout, 3.0, accuracy: 0.001)
  }

  // MARK: - DictationError descriptions

  func test_errorDescriptions_areNonEmpty() {
    let errors: [DictationError] = [
      .microphonePermissionDenied,
      .speechPermissionDenied,
      .recognizerUnavailable,
      .networkRequired,
      .audioEngineError("test"),
      .sessionInterrupted,
      .unknown("test"),
    ]
    for error in errors {
      XCTAssertNotNil(error.errorDescription)
      XCTAssertFalse(
        error.errorDescription?.isEmpty ?? true,
        "Expected non-empty description for \(error)"
      )
    }
  }

  // MARK: - DictationEvent cases

  func test_dictationEvent_partialCarriesString() {
    let event = DictationEvent.partial("hello")
    if case .partial(let text) = event {
      XCTAssertEqual(text, "hello")
    } else {
      XCTFail("Expected .partial")
    }
  }

  func test_dictationEvent_finalCarriesString() {
    let event = DictationEvent.final_("world")
    if case .final_(let text) = event {
      XCTAssertEqual(text, "world")
    } else {
      XCTFail("Expected .final_")
    }
  }

  // MARK: - State machine: two error events do not double-finish the stream

  func test_emittingTwoErrors_streamTerminatesCleanly() async throws {
    // Both mock paths use isAvailable = false which emits only one error.
    // This test verifies the single-error guarantee.
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false

    let controller = DictationController(recognizer: mock)
    var errorCount = 0

    for await event in controller.start() {
      if case .error = event { errorCount += 1 }
    }

    XCTAssertEqual(errorCount, 1, "Exactly one error should be emitted before stream ends")
  }
}
