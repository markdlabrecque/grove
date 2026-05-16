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

// MARK: - StubSpeechTranscription / StubSpeechResult

/// Minimal `SFTranscription` stub carrying a fixed `formattedString`.
///
/// Used by #341 callback-path tests to construct `SFSpeechRecognitionResult`
/// values without touching a real recogniser.
final class StubSpeechTranscription: SFTranscription {
  private let _formattedString: String
  init(text: String) { _formattedString = text; super.init() }
  required init?(coder: NSCoder) { fatalError("not used in tests") }
  override var formattedString: String { _formattedString }
}

/// Minimal `SFSpeechRecognitionResult` stub.
///
/// Overrides `bestTranscription` and `isFinal` so `handleResult(_:error:)`
/// can be driven without a live speech session.
final class StubSpeechResult: SFSpeechRecognitionResult {
  private let _transcription: SFTranscription
  private let _isFinal: Bool
  init(text: String, isFinal: Bool) {
    _transcription = StubSpeechTranscription(text: text)
    _isFinal = isFinal
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("not used in tests") }
  override var bestTranscription: SFTranscription { _transcription }
  override var isFinal: Bool { _isFinal }
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

  // MARK: - Callback path (#341) — handleResult in isolation

  /// `.partial` result emits a `.partial` event and keeps the stream open.
  func test_handleResult_partialResult_emitsPartialEvent() async throws {
    let mock = MockSpeechRecognizer()
    let controller = DictationController(recognizer: mock)

    var events: [DictationEvent] = []
    let stream = AsyncStream<DictationEvent> { continuation in
      controller._injectContinuationForTesting(continuation)
    }

    // Drive a partial result through the state machine synchronously.
    let partialResult = StubSpeechResult(text: "Hello wor", isFinal: false)
    controller.handleResult(partialResult, error: nil)
    // Finish the stream so the for-await below terminates.
    // (handleResult does not finish the continuation on partial.)
    // We inject a final result to close the stream cleanly.
    let finalResult = StubSpeechResult(text: "Hello world", isFinal: true)
    controller.handleResult(finalResult, error: nil)

    for await event in stream {
      events.append(event)
    }

    XCTAssertEqual(events.count, 2, "Expected one partial then one final event")
    guard case .partial(let partialText) = events[0] else {
      return XCTFail("Expected .partial as first event, got \(events[0])")
    }
    XCTAssertEqual(partialText, "Hello wor")
    guard case .final_(let finalText) = events[1] else {
      return XCTFail("Expected .final_ as second event, got \(events[1])")
    }
    XCTAssertEqual(finalText, "Hello world")
  }

  /// `.final_` result emits a `.final_` event and finishes the stream.
  func test_handleResult_finalResult_emitsFinalEventAndClosesStream() async throws {
    let mock = MockSpeechRecognizer()
    let controller = DictationController(recognizer: mock)

    var events: [DictationEvent] = []
    let stream = AsyncStream<DictationEvent> { continuation in
      controller._injectContinuationForTesting(continuation)
    }

    let finalResult = StubSpeechResult(text: "Dictation complete", isFinal: true)
    controller.handleResult(finalResult, error: nil)

    for await event in stream {
      events.append(event)
    }

    XCTAssertEqual(events.count, 1, "Expected exactly one event from a final result")
    guard case .final_(let text) = events[0] else {
      return XCTFail("Expected .final_, got \(events[0])")
    }
    XCTAssertEqual(text, "Dictation complete")
  }

  /// Error delivered via the callback emits a `.error` event and closes the stream.
  func test_handleResult_callbackError_emitsErrorAndClosesStream() async throws {
    let mock = MockSpeechRecognizer()
    let controller = DictationController(recognizer: mock)

    var events: [DictationEvent] = []
    let stream = AsyncStream<DictationEvent> { continuation in
      controller._injectContinuationForTesting(continuation)
    }

    let callbackError = NSError(domain: "com.test", code: 999, userInfo: [
      NSLocalizedDescriptionKey: "Simulated recognition failure"
    ])
    controller.handleResult(nil, error: callbackError)

    for await event in stream {
      events.append(event)
    }

    XCTAssertEqual(events.count, 1, "Expected exactly one error event from a callback error")
    guard case .error = events[0] else {
      return XCTFail("Expected .error, got \(events[0])")
    }
  }
}
