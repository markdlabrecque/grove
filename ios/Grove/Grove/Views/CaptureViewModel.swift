import Foundation
import SwiftUI
import GroveCore

/// View state and save logic for the capture screen.
///
/// Marked `@Observable` so SwiftUI observes only the properties that change,
/// without any `@Published` boilerplate. Requires iOS 17+.
///
/// # V2 offline-first save flow
///
/// Saving no longer blocks on the network. The sequence is:
///   1. Build the `CapturePayload` via `buildPayload(content:applyFillerCleanup:detectedLanguage:languageHint:)`.
///   2. Encode it to JSON and call `uploadQueue.enqueue(clientID:payload:)` — durably persists
///      the row to SwiftData before any network call. If this succeeds the user's content
///      is safe regardless of network state.
///   3. Report `.success` to the UI immediately — the user sees "Saved" as soon
///      as persistence succeeds, not when the server confirms.
///   4. Fire a background `Task` calling `uploadQueue.tryDrain()` — attempts to
///      flush the queue right now. If the device is offline the row stays in the
///      queue and `NetworkMonitor` will drain it on reconnect.
///
/// If `enqueue` itself fails (e.g. disk full) the error is surfaced to the user
/// so they know the capture was NOT saved.
///
/// # Capture polish (#187)
///
/// Three quality-of-life features are wired into the save path:
///
///   - **Filler-word cleanup**: when `@AppStorage(SettingsViewModel.fillerWordCleanupKey)`
///     is `true`, `FillerWordCleaner.clean(_:)` is applied to the content *before*
///     encoding the payload. The text field is never mutated — only the outgoing
///     payload bytes are cleaned.
///   - **Language detection**: `LanguageDetector.detect(_:)` runs (debounced, 200 ms)
///     on the current text as the user types. The detected BCP-47 code is shown in
///     the UI and sent in the payload's `language` field. If the user has a language
///     hint set in Settings and it differs from the detected language, the detected
///     language wins (see `buildPayload` for the exact logic).
///   - **Char/token count**: `charCount` and `tokenCount` are derived from `content`
///     on every keystroke. Token count uses the heuristic `max(1, chars / 4)`.
@Observable
@MainActor
final class CaptureViewModel {

  // MARK: - Dependencies

  private let uploadQueue: UploadQueue

  // MARK: - Init

  /// Designated initialiser.
  ///
  /// - Parameter uploadQueue: The shared `UploadQueue` instance. Defaults to
  ///   `GroveApp.uploadQueue` for production use. Tests inject a stub queue
  ///   backed by an in-memory `ModelContainer`.
  init(uploadQueue: UploadQueue = GroveApp.uploadQueue) {
    self.uploadQueue = uploadQueue
  }

  // MARK: - Inputs

  var content: String = "" {
    didSet {
      scheduleLanguageDetection()
    }
  }

  // MARK: - Derived state

  var isSaveEnabled: Bool {
    !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
  }

  /// Live character count of the current `content`.
  var charCount: Int {
    content.count
  }

  /// Estimated token count using the heuristic `max(1, chars / 4)`.
  ///
  /// Returns 1 for empty input (0 / 4 = 0, but max(1, 0) = 1).
  var tokenCount: Int {
    max(1, content.count / 4)
  }

  // MARK: - Language detection state

  /// The detected BCP-47 language code from `NLLanguageRecognizer`, or `nil`
  /// when the text is too short or language is undetermined.
  ///
  /// Updated by `scheduleLanguageDetection()` with a 200 ms debounce.
  var detectedLanguage: String? = nil

  // MARK: - Output state

  enum SaveStatus {
    case idle
    case loading
    case success
    case failure(String)
  }

  var saveStatus: SaveStatus = .idle

  var isLoading: Bool {
    if case .loading = saveStatus { return true }
    return false
  }

  var showErrorAlert: Bool = false
  var errorMessage: String = ""

  // MARK: - Test seam

  /// The last drain task spawned by `save()`.
  ///
  /// **Test-only.** Production code must never read or `await` this property —
  /// the drain task is intentionally fire-and-forget in production so that
  /// `save()` never blocks on the network.
  ///
  /// Tests that need a deterministic signal for drain completion (rather than
  /// relying on the 1.5 s `Task.sleep` in `save()`) can `await` this after
  /// calling `await vm.save()`:
  ///
  /// ```swift
  /// await vm.save()
  /// await vm._lastDrainTask?.value  // waits for the drain task to finish
  /// #expect(try await queue.pendingCount() == 0)
  /// ```
  ///
  /// The property is set to `nil` before each `save()` call so stale values
  /// from a prior call never accidentally satisfy a later test's `await`.
  var _lastDrainTask: Task<Void, Never>? = nil

  // MARK: - Language detection (debounced)

  private var languageDetectionTask: Task<Void, Never>? = nil

  /// Schedule a debounced language detection pass.
  ///
  /// Cancels any pending task and starts a new one after a 200 ms delay.
  /// This ensures the detector is not hammered on every keystroke for long text.
  private func scheduleLanguageDetection() {
    languageDetectionTask?.cancel()
    languageDetectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .milliseconds(200))
      } catch {
        // Task was cancelled — another keystroke came in, bail.
        return
      }
      self.detectedLanguage = LanguageDetector.detect(self.content)
    }
  }

  // MARK: - Save

  func save(applyFillerCleanup: Bool = false, languageHint: String? = nil) async {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    saveStatus = .loading

    let payload = CaptureViewModel.buildPayload(
      content: trimmed,
      sourceModality: "typed",
      applyFillerCleanup: applyFillerCleanup,
      detectedLanguage: detectedLanguage,
      languageHint: languageHint
    )

    // Encode the payload to the same bytes the queue will POST, so there is a
    // single encoding path used for both persistence and upload.
    let payloadData: Data
    do {
      payloadData = try CaptureViewModel.encodePayload(payload)
    } catch {
      saveStatus = .idle
      errorMessage = error.localizedDescription
      showErrorAlert = true
      return
    }

    // Step 1 — durable persist. If this fails (disk full, etc.) surface the
    // error immediately. Content is deliberately NOT cleared on failure.
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

    // Step 2 — report success to the UI. The capture is now safe on disk.
    saveStatus = .success
    content = ""

    // Step 3 — fire-and-forget drain. Attempt an immediate upload; if the
    // network is unavailable the row stays in the queue and NetworkMonitor
    // will drain on reconnect.
    //
    // The task handle is stored in `_lastDrainTask` (test seam) so tests can
    // await it deterministically instead of relying on the 1.5 s sleep below.
    // Production code ignores `_lastDrainTask`.
    _lastDrainTask = nil
    _lastDrainTask = Task {
      await uploadQueue.tryDrain()
    }

    // Dismiss the success indicator after 1.5 s then return to idle.
    try? await Task.sleep(for: .seconds(1.5))
    saveStatus = .idle
  }

  // MARK: - Payload factory

  /// Build a `CapturePayload` for the given content with optional filler
  /// cleanup and language detection applied.
  ///
  /// ## Language resolution
  ///
  /// - If `detectedLanguage` is non-nil and differs from `languageHint`, the
  ///   detected language wins (more reliable than a static preference).
  /// - If they agree (or hint is nil), the detected language is used.
  /// - If detection returned `nil` (text too short), fall back to `languageHint`
  ///   if set, otherwise default to `"en"`.
  ///
  /// ## Filler cleanup
  ///
  /// When `applyFillerCleanup` is `true`, `FillerWordCleaner.clean(_:)` is
  /// applied to `content` before building the payload. The caller's text field
  /// is never modified — only the returned payload carries cleaned content.
  ///
  /// - Parameters:
  ///   - content: The raw text from the capture text field (already trimmed).
  ///   - sourceModality: `"typed"` for keyboard captures; `"dictated"` for
  ///     Action Button / dictation captures. Maps to `source_modality` on
  ///     the server (PRD §6.2 / §8.3: valid values are `'typed' | 'dictated'`).
  ///   - applyFillerCleanup: When `true`, run `FillerWordCleaner.clean(_:)`.
  ///   - detectedLanguage: BCP-47 code from `LanguageDetector`, or `nil`.
  ///   - languageHint: User-set language preference from Settings, or `nil`.
  /// - Returns: A `CapturePayload` ready to encode.
  nonisolated static func buildPayload(
    content: String,
    sourceModality: String,
    applyFillerCleanup: Bool,
    detectedLanguage: String?,
    languageHint: String?
  ) -> CapturePayload {
    let finalContent = applyFillerCleanup
      ? FillerWordCleaner.clean(content)
      : content

    // Language resolution: detected wins when set; hint as fallback; "en" default.
    let language: String
    if let detected = detectedLanguage, !detected.isEmpty {
      language = detected
    } else if let hint = languageHint, !hint.isEmpty {
      language = hint
    } else {
      language = "en"
    }

    return CapturePayload(
      clientID: UUID(),
      content: finalContent,
      sourceModality: sourceModality,
      sourceDevice: "iphone",
      language: language,
      capturedAt: Date()
    )
  }

  // MARK: - Payload encoding helper

  /// Encodes the capture payload to JSON bytes for persistence in the
  /// SwiftData queue. The bytes are decoded back to `CaptureRequestBody`
  /// inside `UploadQueue.drainRow`, then re-encoded by
  /// `OracleAPI.writeBodyToTempFile` before the POST. Both encoders must
  /// agree on the wire format; if you change one, update the other.
  nonisolated static func encodePayload(_ payload: CapturePayload) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let body = CaptureRequestBody(
      clientID: payload.clientID,
      content: payload.content,
      sourceModality: payload.sourceModality,
      sourceDevice: payload.sourceDevice,
      language: payload.language,
      capturedAt: payload.capturedAt
    )
    return try encoder.encode(body)
  }
}
