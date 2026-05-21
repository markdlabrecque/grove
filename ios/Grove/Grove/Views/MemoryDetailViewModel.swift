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
/// ## Content loading (provenance-navigation case)
///
/// When the view is entered via provenance badge navigation (from `TasksView`),
/// the caller supplies a synthetic `QueryResult` with an empty `excerpt`. In
/// that case `loadContent()` is called on `.onAppear` to fetch the real memory
/// content from `GET /v1/memories/{id}` and populate `fetchedContent`. The
/// view renders `fetchedContent` when it is non-nil, otherwise falls back to
/// `result.excerpt`. Existing callers (the Ask flow) pass non-empty excerpts
/// and are unaffected.
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

  // MARK: - Source

  let result: QueryResult

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

  // MARK: - Fetched content (provenance-navigation case)

  /// Non-nil after a successful `loadContent()` call.
  ///
  /// The view renders this when non-nil, otherwise falls back to
  /// `result.excerpt`. This keeps existing Ask-flow callers unchanged — they
  /// pass a non-empty `result.excerpt` so `loadContent()` is a no-op for them.
  var fetchedContent: String? = nil

  /// `true` while the GET /v1/memories/{id} request is in flight.
  var isFetchingContent: Bool = false

  /// Non-nil when a content fetch attempt failed.
  var fetchError: String? = nil

  // MARK: - Init

  init(
    result: QueryResult,
    deleteProvider: @escaping (UUID) async throws -> Void = { id in
      try await GroveAPI.shared.deleteMemory(id: id)
    },
    fetchProvider: @escaping (UUID) async throws -> MemoryDetailDTO = { id in
      try await GroveAPI.shared.fetchMemory(id: id)
    },
    onDeleteSuccess: @escaping (UUID) -> Void = { _ in }
  ) {
    self.result = result
    self.deleteProvider = deleteProvider
    self.fetchProvider = fetchProvider
    self.onDeleteSuccess = onDeleteSuccess
  }

  // MARK: - Content loading (provenance-navigation case)

  /// Fetch real memory content when the result excerpt is empty.
  ///
  /// Called from `MemoryDetailView.onAppear`. When `result.excerpt` is
  /// non-empty (Ask-flow navigation), this is a no-op. When it is empty
  /// (provenance badge navigation from `TasksView`), fetches the full
  /// memory from the server and populates `fetchedContent`.
  func loadContent() async {
    guard result.excerpt.isEmpty else { return }

    isFetchingContent = true
    fetchError = nil

    do {
      let dto = try await fetchProvider(result.memoryID)
      fetchedContent = dto.content
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
      try await deleteProvider(result.memoryID)
      // Success: call out to the parent so it can update its source list,
      // then dismiss this view.
      onDeleteSuccess(result.memoryID)
      isDeleting = false
      isDismissed = true
    } catch let apiError as APIError {
      if case .httpError(let code, _) = apiError, code == 404 {
        // 404 means the memory was already deleted — treat as success.
        onDeleteSuccess(result.memoryID)
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
