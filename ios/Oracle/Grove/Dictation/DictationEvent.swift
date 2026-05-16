import Foundation

// MARK: - DictationEvent

/// Events emitted by ``DictationController`` over its `AsyncStream`.
///
/// The caller receives a sequence of `.partial` updates as the recogniser
/// refines its hypothesis, followed by exactly one `.final` when the session
/// ends (either via an explicit `stop()` call or the trailing-silence timer).
/// `.error` is emitted when the session cannot start or is interrupted
/// unrecoverably; the stream then terminates.
public enum DictationEvent: Sendable {
  /// An in-progress hypothesis that may still change.
  case partial(String)
  /// The settled, final transcript.  Emitted once, just before the stream ends.
  case final_(String)
  /// An unrecoverable error; the stream ends after this event.
  case error(DictationError)
}

// MARK: - DictationError

/// Errors surfaced through ``DictationEvent/error``.
public enum DictationError: Error, Sendable, LocalizedError {
  /// The user denied microphone access.
  case microphonePermissionDenied
  /// The user denied speech-recognition access.
  case speechPermissionDenied
  /// The speech recogniser is not available for the current locale.
  case recognizerUnavailable
  /// The recogniser requires a network connection but none is available.
  case networkRequired
  /// An audio session or engine error (raw description forwarded for
  /// diagnostics).
  case audioEngineError(String)
  /// The session was interrupted by a phone call, Siri, or similar.
  case sessionInterrupted
  /// Any other unexpected error.
  case unknown(String)

  public var errorDescription: String? {
    switch self {
    case .microphonePermissionDenied:
      return "Microphone access was denied. Open Settings to allow access."
    case .speechPermissionDenied:
      return "Speech recognition was denied. Open Settings to allow access."
    case .recognizerUnavailable:
      return "Speech recognition is not available for your language."
    case .networkRequired:
      return "On-device speech recognition is unavailable. A network connection is required."
    case .audioEngineError(let msg):
      return "Audio engine error: \(msg)"
    case .sessionInterrupted:
      return "Dictation was interrupted by another audio source."
    case .unknown(let msg):
      return "Dictation failed: \(msg)"
    }
  }
}
