import Foundation
import Speech
import AVFoundation

// MARK: - DictationController

/// Wraps `SFSpeechRecognizer` and `AVAudioEngine` to provide a clean
/// `AsyncStream`-based dictation API.
///
/// ## Usage
///
/// ```swift
/// let controller = DictationController()
/// try await controller.requestAuthorization()
/// for await event in controller.start() {
///   switch event {
///   case .partial(let text):  liveTranscript = text
///   case .final_(let text):   finalTranscript = text
///   case .error(let err):     handleError(err)
///   }
/// }
/// ```
///
/// Call `stop()` to end the session early.  The stream always yields a final
/// `.final_` or `.error` before terminating.
///
/// ## Trailing-silence auto-stop
///
/// When the recogniser has not produced a new hypothesis for
/// ``DictationController/silenceTimeout`` seconds, `stop()` is called
/// automatically.  The constant is named so it can be tuned post-ship
/// without touching call sites.
///
/// ## Audio session
///
/// On `start()`, the audio session category is set to `.record`.  On stop or
/// error, the session is deactivated with `notifyOthersOnDeactivation` so
/// that music apps and other audio can resume.
///
/// ## Thread safety
///
/// All public methods are `@MainActor`-isolated.  The recognition-result
/// callback arrives on an internal `SFSpeechRecognizer` queue and hops to
/// the main actor via `Task { @MainActor in … }` before touching any state.
@MainActor
final class DictationController {

  // MARK: - Constants

  /// Seconds of trailing silence after the last recognised word before the
  /// session auto-stops.  Tune this value post-ship as needed.
  static let silenceTimeout: TimeInterval = 3.0

  // MARK: - Dependencies (injectable for tests)

  private let recognizer: any SpeechRecognizing

  // MARK: - Private state

  private var audioEngine: AVAudioEngine?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var silenceTimer: Task<Void, Never>?
  private var continuation: AsyncStream<DictationEvent>.Continuation?

  // MARK: - Init

  /// Creates a controller with a live `SFSpeechRecognizer`.
  ///
  /// Use ``init(recognizer:)`` to inject a mock for unit testing.
  convenience init() {
    let live = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    self.init(recognizer: live)
  }

  /// Creates a controller with the given recogniser.
  ///
  /// - Parameter recognizer: The recogniser to use.  Inject a
  ///   ``MockSpeechRecognizer`` in unit tests.
  init(recognizer: any SpeechRecognizing) {
    self.recognizer = recognizer
  }

  // MARK: - Authorization

  /// Requests microphone and speech-recognition authorisation.
  ///
  /// Throws a `DictationError` if either permission is denied.
  func requestAuthorization() async throws {
    // Microphone
    let micGranted = await AVAudioApplication.requestRecordPermission()
    guard micGranted else {
      throw DictationError.microphonePermissionDenied
    }

    // Speech recognition
    let speechStatus = await type(of: recognizer).requestAuthorization()
    switch speechStatus {
    case .authorized:
      break
    case .denied, .restricted:
      throw DictationError.speechPermissionDenied
    case .notDetermined:
      throw DictationError.speechPermissionDenied
    @unknown default:
      throw DictationError.speechPermissionDenied
    }
  }

  // MARK: - Start

  /// Begins a dictation session and returns an `AsyncStream` of events.
  ///
  /// The stream emits `.partial` updates as speech is recognised, followed by
  /// exactly one `.final_` (on clean stop) or `.error` (on failure).
  /// Cancelling the consuming `Task` calls `stop()` automatically.
  ///
  /// - Returns: A stream of ``DictationEvent`` values.
  func start() -> AsyncStream<DictationEvent> {
    AsyncStream<DictationEvent> { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      self.continuation = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.teardown()
        }
      }
      Task { @MainActor [weak self] in
        await self?.beginSession()
      }
    }
  }

  // MARK: - Stop

  /// Finalises the current session.
  ///
  /// Safe to call multiple times; subsequent calls are no-ops.
  func stop() {
    recognitionRequest?.endAudio()
    // The recognition task result handler will call `teardown()` once it
    // receives the final result (isFinal == true) or an error.
  }

  // MARK: - Private helpers

  private func beginSession() async {
    guard recognizer.isAvailable else {
      emit(.error(.recognizerUnavailable))
      teardown()
      return
    }

    // Configure audio session.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      emit(.error(.audioEngineError(error.localizedDescription)))
      teardown()
      return
    }

    // Register for interruption notifications.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: session
    )

    // Build the audio buffer recognition request.
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // Default to on-device recognition; fall back to cloud if unsupported.
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    recognitionRequest = request

    // Wire the audio engine.
    let engine = AVAudioEngine()
    audioEngine = engine
    let inputNode = engine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      emit(.error(.audioEngineError(error.localizedDescription)))
      teardown()
      return
    }

    // Start the recognition task via the closure-based API.
    recognitionTask = recognizer.recognitionTask(
      with: request,
      resultHandler: { [weak self] result, error in
        // This callback arrives on SFSpeechRecognizer's internal queue.
        // Hop to the main actor before touching any state.
        Task { @MainActor [weak self] in
          self?.handleResult(result, error: error)
        }
      }
    )

    // Arm the trailing-silence timer.
    armSilenceTimer()
  }

  // MARK: - Test seam (#341)

  /// Arms the continuation directly without starting `AVAudioEngine`.
  ///
  /// Call this from unit tests to set up the emission path, then drive the
  /// state machine by calling `handleResult(_:error:)`. This bypasses
  /// `beginSession()` entirely so no real audio hardware is touched.
  ///
  /// - Parameter continuation: The `AsyncStream` continuation created by the caller.
  func _injectContinuationForTesting(_ continuation: AsyncStream<DictationEvent>.Continuation) {
    self.continuation = continuation
  }

  // MARK: - Result handling (always on @MainActor)

  /// Processes one recogniser callback.
  ///
  /// Exposed as `internal` (rather than `private`) so that `DictationControllerTests`
  /// can drive the callback path directly without touching `AVAudioEngine`. Call
  /// sites outside the test target should not use this method; it is an
  /// implementation detail of the `start()` stream (#341).
  func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
    if let error {
      emit(.error(mapSpeechError(error)))
      teardown()
      return
    }

    guard let result else { return }

    let text = result.bestTranscription.formattedString

    if result.isFinal {
      silenceTimer?.cancel()
      emit(.final_(text))
      teardown()
    } else {
      emit(.partial(text))
      // Re-arm the silence timer on every new partial hypothesis.
      armSilenceTimer()
    }
  }

  // MARK: - Silence timer

  private func armSilenceTimer() {
    silenceTimer?.cancel()
    silenceTimer = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .seconds(DictationController.silenceTimeout))
      } catch {
        // Cancelled — a new partial result arrived.
        return
      }
      // Silence threshold reached — stop gracefully.
      self.stop()
    }
  }

  // MARK: - Emit helpers

  private func emit(_ event: DictationEvent) {
    continuation?.yield(event)
    if case .final_ = event { continuation?.finish() }
    if case .error = event { continuation?.finish() }
  }

  // MARK: - Teardown

  private func teardown() {
    silenceTimer?.cancel()
    silenceTimer = nil
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine?.stop()
    audioEngine = nil
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    continuation?.finish()
    continuation = nil
    // Restore audio session.
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // MARK: - Interruption handling

  @objc private func handleAudioInterruption(_ notification: Notification) {
    guard
      let userInfo = notification.userInfo,
      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue),
      type == .began
    else { return }

    emit(.error(.sessionInterrupted))
    teardown()
  }

  // MARK: - Error mapping

  private func mapSpeechError(_ error: Error) -> DictationError {
    let nsError = error as NSError
    switch nsError.code {
    case 203: // kAFAssistantErrorDomain — no speech detected
      return .recognizerUnavailable
    case 209, 1110: // requires network / connection
      return .networkRequired
    default:
      return .unknown(error.localizedDescription)
    }
  }
}
