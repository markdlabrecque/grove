import Foundation
import Speech

// MARK: - SpeechRecognizing protocol

/// An abstraction over `SFSpeechRecognizer` that lets unit tests inject a
/// mock recogniser without touching the real Speech framework.
///
/// The protocol is intentionally thin — it exposes only the surface that
/// ``DictationController`` actually calls, not the full `SFSpeechRecognizer`
/// API.
///
/// Uses the closure-based `recognitionTask(with:resultHandler:)` signature
/// which is the real API present in all iOS versions, rather than the
/// non-existent no-callback variant.
protocol SpeechRecognizing: AnyObject {
  /// Whether the recogniser is available for use.
  var isAvailable: Bool { get }

  /// Whether on-device recognition is supported by this recogniser.
  ///
  /// Maps to `SFSpeechRecognizer.supportsOnDeviceRecognition`.
  var supportsOnDeviceRecognition: Bool { get }

  /// Request authorisation and return the resulting status.
  static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus

  /// Start a recognition task for the given audio request, calling
  /// `resultHandler` as partial and final results arrive.
  ///
  /// - Returns: A cancellable `SFSpeechRecognitionTask`.
  func recognitionTask(
    with request: SFSpeechAudioBufferRecognitionRequest,
    resultHandler: @escaping @Sendable (SFSpeechRecognitionResult?, Error?) -> Void
  ) -> SFSpeechRecognitionTask
}

// MARK: - Production conformance

extension SFSpeechRecognizer: SpeechRecognizing {
  func recognitionTask(
    with request: SFSpeechAudioBufferRecognitionRequest,
    resultHandler: @escaping @Sendable (SFSpeechRecognitionResult?, Error?) -> Void
  ) -> SFSpeechRecognitionTask {
    // Widen to base class to call the ObjC-bridged overload.
    return recognitionTask(with: request as SFSpeechRecognitionRequest, resultHandler: resultHandler)
  }

  static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}
