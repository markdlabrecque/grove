import Foundation
import SwiftUI
import GroveCore

// MARK: - DictationCaptureViewModel

/// Drives ``DictationCaptureView``.
///
/// The view model owns the ``DictationController`` lifecycle and bridges
/// dictation events to observable state that SwiftUI can render.
///
/// ## State machine
///
/// ```
/// .idle  →  .requesting  →  .recording  →  .stopped
///                  ↓              ↓              ↓
///              .permissionDenied  .error    [editable transcript]
/// ```
///
/// - `.idle` — nothing happening.
/// - `.requesting` — permission prompts pending.
/// - `.recording` — mic active, partial transcripts arriving.
/// - `.stopped` — session ended; transcript is editable before Save.
/// - `.permissionDenied(DictationError)` — user must open Settings.
/// - `.error(DictationError)` — any other non-recoverable error.
@Observable
@MainActor
final class DictationCaptureViewModel {

  // MARK: - Recording state

  enum RecordingState: Equatable {
    case idle
    case requesting
    case recording
    case stopped
    case permissionDenied(DictationError)
    case error(DictationError)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
      switch (lhs, rhs) {
      case (.idle, .idle), (.requesting, .requesting),
           (.recording, .recording), (.stopped, .stopped):
        return true
      case (.permissionDenied, .permissionDenied), (.error, .error):
        return true
      default:
        return false
      }
    }
  }

  // MARK: - Inputs

  /// The transcript text — updated live during recording, fully editable after stop.
  var transcript: String = ""

  // MARK: - Outputs

  var recordingState: RecordingState = .idle

  var isSaveEnabled: Bool {
    !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && recordingState == .stopped
  }

  var saveStatus: SaveStatus = .idle

  enum SaveStatus: Equatable {
    case idle, loading, success, failure(String)
  }

  var showErrorAlert: Bool = false
  var errorMessage: String = ""

  // MARK: - Dependencies

  private let controller: DictationController
  private let uploadQueue: UploadQueue

  /// Active dictation task; cancelled on `stopDictation()` or `deinit`.
  private var dictationTask: Task<Void, Never>? = nil

  // MARK: - Init

  /// Designated init for production use — creates a default `DictationController`.
  init(uploadQueue: UploadQueue = GroveApp.uploadQueue) {
    self.controller = DictationController()
    self.uploadQueue = uploadQueue
  }

  /// Test init — injects a pre-configured controller and upload queue.
  init(controller: DictationController, uploadQueue: UploadQueue = GroveApp.uploadQueue) {
    self.controller = controller
    self.uploadQueue = uploadQueue
  }

  // MARK: - Dictation lifecycle

  /// Request permissions and begin dictation.
  func startDictation() async {
    recordingState = .requesting
    do {
      try await controller.requestAuthorization()
    } catch let err as DictationError {
      switch err {
      case .microphonePermissionDenied, .speechPermissionDenied:
        recordingState = .permissionDenied(err)
      default:
        recordingState = .error(err)
      }
      return
    } catch {
      recordingState = .error(.unknown(error.localizedDescription))
      return
    }

    recordingState = .recording
    transcript = ""

    dictationTask = Task { [weak self] in
      guard let self else { return }
      for await event in self.controller.start() {
        switch event {
        case .partial(let text):
          self.transcript = text
        case .final_(let text):
          self.transcript = text
          self.recordingState = .stopped
        case .error(let err):
          self.recordingState = .error(err)
          self.errorMessage = err.localizedDescription
          self.showErrorAlert = true
        }
      }
      // Stream ended — if still recording, transition to stopped.
      if self.recordingState == .recording {
        self.recordingState = .stopped
      }
    }
  }

  /// End the current dictation session.
  func stopDictation() {
    controller.stop()
  }

  // MARK: - Save

  /// Saves the current transcript through the existing capture pipeline.
  func save(applyFillerCleanup: Bool = false, languageHint: String? = nil) async {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    saveStatus = .loading

    let payload = CaptureViewModel.buildPayload(
      content: trimmed,
      sourceModality: "dictated",
      applyFillerCleanup: applyFillerCleanup,
      detectedLanguage: LanguageDetector.detect(trimmed),
      languageHint: languageHint ?? "en"
    )

    let payloadData: Data
    do {
      payloadData = try CaptureViewModel.encodePayload(payload)
    } catch {
      saveStatus = .idle
      errorMessage = error.localizedDescription
      showErrorAlert = true
      return
    }

    do {
      try await uploadQueue.enqueue(
        clientID: payload.clientID.uuidString,
        payload: payloadData
      )
    } catch {
      saveStatus = .idle
      errorMessage = error.localizedDescription
      showErrorAlert = true
      return
    }

    saveStatus = .success
    Task { await uploadQueue.tryDrain() }

    try? await Task.sleep(for: .seconds(1.5))
    saveStatus = .idle
  }

  // MARK: - Background draft

  /// Returns a ``DictationDraft`` capturing the current partial transcript,
  /// or `nil` if there is no in-progress dictation worth resuming.
  func makeDraftIfNeeded() -> DictationDraft? {
    let isActive = recordingState == .recording || recordingState == .stopped
    guard isActive,
          !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return DictationDraft(transcript: transcript)
  }

  /// Prepopulates the transcript for a resumed dictation session.
  func resume(from draft: DictationDraft) {
    transcript = draft.transcript
    recordingState = .stopped  // Pre-filled; user decides whether to re-arm.
  }
}

// MARK: - DictationDraft

/// A lightweight value type carrying a partial transcript that was in progress
/// when the app was backgrounded.  In-memory only (V1).
struct DictationDraft: Sendable {
  let transcript: String
  /// Wall-clock duration of the capture in seconds, used in the banner copy.
  let approximateDuration: TimeInterval

  init(transcript: String, approximateDuration: TimeInterval = 0) {
    self.transcript = transcript
    self.approximateDuration = approximateDuration
  }
}
