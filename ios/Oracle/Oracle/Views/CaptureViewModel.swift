import Foundation
import OracleCore

/// View state and save logic for the capture screen.
///
/// Marked `@Observable` so SwiftUI observes only the properties that change,
/// without any `@Published` boilerplate. Requires iOS 17+.
@Observable
@MainActor
final class CaptureViewModel {

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

    let payload = CapturePayload(
      clientID: UUID(),
      content: trimmed,
      sourceModality: "text",
      sourceDevice: "iphone",
      language: "en",
      capturedAt: Date()
    )

    do {
      let response = try await OracleAPI.shared.postCapture(payload)
      _ = response  // id available if needed for future use
      saveStatus = .success
      content = ""

      // Dismiss the success indicator after 1.5 s then return to idle.
      try? await Task.sleep(for: .seconds(1.5))
      saveStatus = .idle
    } catch {
      // TODO(offline): V2 should persist this payload locally in SwiftData,
      // retry when NWPathMonitor reports "satisfied", and reuse the same
      // client_id — the server deduplicates via its UNIQUE constraint on
      // memories.client_id, so retries are safe no-ops.
      let message: String
      if let apiError = error as? APIError {
        message = apiError.localizedDescription
      } else {
        message = error.localizedDescription
      }
      saveStatus = .idle
      errorMessage = message
      showErrorAlert = true
      // Content is deliberately NOT cleared on failure — preserving user input.
    }
  }
}
