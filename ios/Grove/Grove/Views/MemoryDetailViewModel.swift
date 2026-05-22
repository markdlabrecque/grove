import Foundation
import GroveCore

/// View state and delete logic for the memory detail screen.
///
/// Marked `@Observable` so SwiftUI observes only the properties that change,
/// without any `@Published` boilerplate. Requires iOS 17+.
///
/// ## Delete state machine
///
/// `idle → confirming (requestDelete) → [cancel → idle]`
/// `confirming → deleting (confirmDelete) → success → dismissed`
/// `confirming → deleting (confirmDelete) → failure → error surfaced (stays on screen)`
///
/// A 404 response ("already gone") is treated as success — the memory is no
/// longer on the server either way, so the view dismisses and the caller
/// removes it from the results list.
///
/// ## Content loading
///
/// `loadContent()` is called on every `.onAppear`. It always fetches the full
/// memory from `GET /v1/memories/{id}` — there is no excerpt-based short-circuit.
/// `capturedAt` and `sourceModality` come from the `MemoryDetailDTO` returned
/// by the fetch, not from any caller-supplied metadata.
///
/// ## Dependency injection
///
/// `deleteProvider` is the async function that performs the DELETE network call.
/// `fetchProvider` is the async function that performs the GET network call.
/// Production code uses the `GroveAPI.shared` defaults. Tests inject stubs.
///
/// `onDeleteSuccess` is called with the `memoryID` on a successful delete.
/// The parent view (typically `QueryView`) removes the corresponding source
/// from its visible list. Defaults to a no-op when not provided (e.g. previews).
@Observable
@MainActor
final class MemoryDetailViewModel {

  // MARK: - Identity

  let memoryID: UUID

  // MARK: - Injectable dependencies

  var deleteProvider: (UUID) async throws -> Void
  var fetchProvider: (UUID) async throws -> MemoryDetailDTO
  var onDeleteSuccess: (UUID) -> Void

  // MARK: - Delete state

  /// `true` while the confirmation alert should be presented.
  var isShowingDeleteConfirmation: Bool = false

  /// `true` while the DELETE request is in flight.
  var isDeleting: Bool = false

  /// Non-nil when a delete attempt failed with a surfaceable error.
  /// Cleared when the user dismisses the error or retries.
  var deleteError: String? = nil

  /// Set to `true` after a successful delete. The presenting view dismisses
  /// when this becomes `true`.
  var isDismissed: Bool = false

  // MARK: - Fetched content

  /// Non-nil after a successful `loadContent()` call.
  var fetchedContent: String? = nil

  /// Capture timestamp populated from the `MemoryDetailDTO` after a successful fetch.
  var capturedAt: Date? = nil

  /// Source modality populated from the `MemoryDetailDTO` after a successful fetch.
  var sourceModality: String? = nil

  /// `true` while the GET /v1/memories/{id} request is in flight.
  var isFetchingContent: Bool = false

  /// Non-nil when a content fetch attempt failed.
  var fetchError: String? = nil

  // MARK: - Init

  init(
    memoryID: UUID,
    deleteProvider: @escaping (UUID) async throws -> Void = { id in
      try await GroveAPI.shared.deleteMemory(id: id)
    },
    fetchProvider: @escaping (UUID) async throws -> MemoryDetailDTO = { id in
      try await GroveAPI.shared.fetchMemory(id: id)
    },
    onDeleteSuccess: @escaping (UUID) -> Void = { _ in }
  ) {
    self.memoryID = memoryID
    self.deleteProvider = deleteProvider
    self.fetchProvider = fetchProvider
    self.onDeleteSuccess = onDeleteSuccess
  }

  // MARK: - Content loading

  /// Fetch the full memory content from the server.
  ///
  /// Called from `MemoryDetailView.task` on every appear. Always performs a
  /// network fetch — there is no short-circuit based on cached data.
  func loadContent() async {
    isFetchingContent = true
    fetchError = nil

    do {
      let dto = try await fetchProvider(memoryID)
      fetchedContent = dto.content
      capturedAt = dto.capturedAt
      sourceModality = dto.sourceModality
      isFetchingContent = false
    } catch {
      isFetchingContent = false
      fetchError = error.localizedDescription
    }
  }

  // MARK: - Delete actions

  /// Transition to the confirming state: presents the confirmation alert.
  func requestDelete() {
    isShowingDeleteConfirmation = true
  }

  /// Cancel from the confirming state: dismiss the alert, return to idle.
  func cancelDelete() {
    isShowingDeleteConfirmation = false
  }

  /// User confirmed the delete. Executes the network call and transitions
  /// through the deleting → success/failure states.
  func confirmDelete() async {
    isShowingDeleteConfirmation = false
    isDeleting = true
    deleteError = nil

    do {
      try await deleteProvider(memoryID)
      // Success: call out to the parent so it can update its source list,
      // then dismiss this view.
      onDeleteSuccess(memoryID)
      isDeleting = false
      isDismissed = true
    } catch let apiError as APIError {
      if case .httpError(let code, _) = apiError, code == 404 {
        // 404 means the memory was already deleted — treat as success.
        onDeleteSuccess(memoryID)
        isDeleting = false
        isDismissed = true
        return
      }
      // Other API error — surface to the user.
      isDeleting = false
      deleteError = apiError.localizedDescription
    } catch {
      // Non-API network error — surface localised description.
      isDeleting = false
      deleteError = error.localizedDescription
    }
  }
}
