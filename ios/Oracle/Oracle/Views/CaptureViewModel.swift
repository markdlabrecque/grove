import Foundation
import OracleCore
import SwiftData

/// View state and save logic for the capture screen.
///
/// Marked `@Observable` so SwiftUI observes only the properties that change,
/// without any `@Published` boilerplate. Requires iOS 17+.
///
/// # V2 offline-first save flow
///
/// Saving no longer blocks on the network. The sequence is:
///   1. Build the `CapturePayload` and encode it to JSON.
///   2. Call `uploadQueue.enqueue(clientID:payload:)` — durably persists the row
///      to SwiftData before any network call. If this succeeds the user's content
///      is safe regardless of network state.
///   3. Report `.success` to the UI immediately — the user sees "Saved" as soon
///      as persistence succeeds, not when the server confirms.
///   4. Fire a background `Task` calling `uploadQueue.tryDrain()` — attempts to
///      flush the queue right now. If the device is offline the row stays in the
///      queue and `NetworkMonitor` will drain it on reconnect.
///
/// If `enqueue` itself fails (e.g. disk full) the error is surfaced to the user
/// so they know the capture was NOT saved.
@Observable
@MainActor
final class CaptureViewModel {

  // MARK: - Dependencies

  private let uploadQueue: UploadQueue

  // MARK: - Init

  /// Designated initialiser.
  ///
  /// - Parameter uploadQueue: The shared `UploadQueue` instance. Defaults to
  ///   `OracleApp.uploadQueue` for production use. Tests inject a stub queue
  ///   backed by an in-memory `ModelContainer`.
  init(uploadQueue: UploadQueue = OracleApp.uploadQueue) {
    self.uploadQueue = uploadQueue
  }

  // MARK: - Inputs

  var content: String = ""

  // MARK: - Derived state

  var isSaveEnabled: Bool {
    !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
  }

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

  // MARK: - Save

  func save() async {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    saveStatus = .loading

    let clientID = UUID()
    let payload = CapturePayload(
      clientID: clientID,
      content: trimmed,
      sourceModality: "text",
      sourceDevice: "iphone",
      language: "en",
      capturedAt: Date()
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
        clientID: clientID.uuidString,
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
    Task {
      await uploadQueue.tryDrain()
    }

    // Dismiss the success indicator after 1.5 s then return to idle.
    try? await Task.sleep(for: .seconds(1.5))
    saveStatus = .idle
  }

  // MARK: - Payload encoding helper

  /// Encodes the capture payload to JSON bytes for persistence in the
  /// SwiftData queue. The bytes are decoded back to `CaptureRequestBody`
  /// inside `UploadQueue.drainRow`, then re-encoded by
  /// `OracleAPI.writeBodyToTempFile` before the POST. Both encoders must
  /// agree on the wire format; if you change one, update the other.
  static func encodePayload(_ payload: CapturePayload) throws -> Data {
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
