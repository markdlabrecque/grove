import Foundation
import OracleCore

/// View state and query logic for the Ask screen.
///
/// Marked `@Observable` so SwiftUI observes only the properties that change,
/// without any `@Published` boilerplate. Requires iOS 17+.
///
/// The `queryProvider` closure is the only network touchpoint. Production code
/// uses `OracleAPI.shared.postQuery(_:)` (the default). Tests inject a stub
/// closure to exercise cancel/result/error paths without a live server.
///
/// The `feedbackProvider` closure is injected the same way for feedback submission.
/// In production it calls `OracleAPI.shared.submitFeedback(queryID:feedback:)`.
/// The call is fire-and-forget: errors are swallowed silently; the chip stays
/// selected regardless of server response.
@Observable
@MainActor
final class QueryViewModel {

  // MARK: - Inputs

  var query: String = ""

  // MARK: - Injectable query provider

  /// The async function that executes the query. Defaults to the production
  /// `OracleAPI.shared.postQuery` path; override in tests via the designated
  /// initialiser.
  var queryProvider: (String) async throws -> QueryResponseBody

  // MARK: - Injectable feedback provider

  /// The async function that submits feedback for a query. Defaults to the
  /// production `OracleAPI.shared.submitFeedback(queryID:feedback:)` path.
  /// Tests inject a stub to verify the fire-and-forget error-swallow path.
  var feedbackProvider: (UUID, Feedback) async throws -> Void

  // MARK: - Derived state

  /// Ask is enabled when there is non-whitespace text to send.
  ///
  /// Unlike the old behaviour, this is **not** gated on `isLoading`. The Ask
  /// button stays enabled while a request is in flight so that the user can
  /// cancel the current request and fire a new one with the revised query by
  /// tapping Ask again (or hitting the keyboard return key). An empty query
  /// while loading is still disabled — cancel+resend with no content is a
  /// no-op and would leave the spinner in an undefined state.
  var isAskEnabled: Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - Output state

  enum QueryStatus {
    case idle
    case loading
    /// Holds the optional RAG-synthesised answer alongside the ranked sources.
    ///
    /// `answer` is `nil` when the server skipped synthesis (no API key,
    /// empty sources, etc.). `sources` may be empty when the answer is present
    /// (e.g. synthesis ran but no sources passed the similarity threshold).
    /// `queryID` is the server-assigned UUID for this query (added in #209);
    /// used to key feedback state and submit `POST /v1/queries/{id}/feedback`.
    /// It is `nil` when the server did not return a `query_id` (e.g. older
    /// server version), in which case the feedback chips are hidden.
    case results(answer: String?, sources: [QueryResult], queryID: UUID?)
    case failure(String)
  }

  var queryStatus: QueryStatus = .idle

  var isLoading: Bool {
    if case .loading = queryStatus { return true }
    return false
  }

  /// The ranked sources from the most recent successful query, or `nil` if none.
  var currentSources: [QueryResult]? {
    if case .results(_, let sources, _) = queryStatus { return sources }
    return nil
  }

  // MARK: - Delete source

  /// Remove a source from the current results list after a successful delete.
  ///
  /// Called by `MemoryDetailViewModel.onDeleteSuccess` when `DELETE /v1/memories/{id}`
  /// succeeds. Removes the matching `QueryResult` from the visible sources so the
  /// deleted memory no longer appears in the Ask results. If there are no remaining
  /// sources (and no synthesised answer), transitions back to `.idle`.
  func removeSource(memoryID: UUID) {
    guard case .results(let answer, let sources, let queryID) = queryStatus else { return }
    let updated = sources.filter { $0.memoryID != memoryID }
    // Preserve the answer card even when all sources are removed — the RAG
    // answer is still valid; the user just chose to delete the underlying memory.
    queryStatus = .results(answer: answer, sources: updated, queryID: queryID)
    // Mirror the removal in lastResponse so a cancel-and-restore after this
    // point doesn't resurface the deleted source.
    if var prior = lastResponse {
      prior.sources = prior.sources.filter { $0.memoryID != memoryID }
      lastResponse = (answer: prior.answer, sources: prior.sources, queryID: prior.queryID)
    }
  }

  var showErrorAlert: Bool = false
  var errorMessage: String = ""

  // MARK: - Feedback state

  /// Per-query feedback state, keyed by the server-assigned query UUID.
  ///
  /// Entries are inserted on tap; tapping the alternate chip overwrites.
  /// A 5xx from the server does NOT remove the entry — the chip stays
  /// selected (fire-and-forget contract per #208/#209).
  ///
  /// `private(set)` — external code reads via `feedback(for:)` and mutates
  /// via `submitFeedback(_:for:)`.
  private(set) var feedbackByQueryID: [UUID: Feedback] = [:]

  /// Returns the current feedback state for the given query ID, or `nil`
  /// if no feedback has been submitted for this query in this session.
  func feedback(for queryID: UUID) -> Feedback? {
    feedbackByQueryID[queryID]
  }

  // MARK: - Init

  init(
    queryProvider: @escaping (String) async throws -> QueryResponseBody = { text in
      try await OracleAPI.shared.postQuery(text)
    },
    feedbackProvider: @escaping (UUID, Feedback) async throws -> Void = { queryID, feedback in
      try await OracleAPI.shared.submitFeedback(queryID: queryID, feedback: feedback)
    }
  ) {
    self.queryProvider = queryProvider
    self.feedbackProvider = feedbackProvider
  }

  // MARK: - In-flight task

  /// The currently running ask `Task`, if any. Stored so `cancel()` can drop
  /// the in-flight URLSession request. Assigned and cleared on `@MainActor`.
  ///
  /// `internal` (not `private`) so `@testable` imports can assert it is `nil`
  /// after `ask()` completes — locking the regression introduced in #100.
  /// `private(set)` prevents external writes that would bypass the lifecycle
  /// managed in `ask()` and `cancel()`.
  private(set) var activeTask: Task<Void, Never>?

  /// The last successfully returned response. Preserved across loading cycles
  /// so that when a new request is cancelled, the prior results are restored
  /// rather than blanked to `.idle`.
  private var lastResponse: (answer: String?, sources: [QueryResult], queryID: UUID?)?

  // MARK: - Cancel

  /// Cancel any in-flight query, restoring the display to the last known
  /// results (if any) or idle.
  ///
  /// The spinner clears immediately because the cancelled task's `catch`
  /// block detects `CancellationError` / `URLError.cancelled`, skips the
  /// error-alert path, and restores `queryStatus` to the pre-flight state.
  func cancel() {
    activeTask?.cancel()
    activeTask = nil
  }

  // MARK: - Feedback

  /// Record the user's feedback for a query result and fire-and-forget the
  /// server call.
  ///
  /// The chip selection is committed locally **before** the network call so
  /// the UI is immediately responsive. The server call runs in a detached Task.
  /// If the server returns a 5xx (or any error), the error is swallowed
  /// silently — the chip stays selected. Last-write-wins on the server per
  /// the idempotency contract from #208.
  ///
  /// Tapping the alternate chip while a prior server call is in-flight is fine:
  /// both calls fire, and the server's UPSERT handles ordering. The local chip
  /// always reflects the most recent tap.
  func submitFeedback(_ feedback: Feedback, for queryID: UUID) {
    // Commit the chip selection immediately (before network).
    feedbackByQueryID[queryID] = feedback

    // Fire-and-forget: errors are swallowed, chip stays selected.
    Task {
      do {
        try await feedbackProvider(queryID, feedback)
      } catch {
        // Intentional swallow — 5xx must not mutate chip state or surface
        // an error to the user (fire-and-forget per #208/#209 contract).
        print("[feedback] swallowed error for query_id=\(queryID.uuidString.lowercased()): \(error)")
      }
    }
  }

  // MARK: - Ask

  /// Cancel any running query and start a new one with the current field value.
  ///
  /// The old `Task` is cancelled before the new one is created. If the field
  /// is empty after trimming, this is a no-op (the button is disabled in that
  /// case, but the guard is retained for defence).
  func ask() {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Cancel any prior in-flight request before starting a new one.
    cancel()

    activeTask = Task {
      await performQuery(trimmed)
    }
  }

  // MARK: - Private helpers

  private func performQuery(_ trimmed: String) async {
    // Snapshot the pre-flight response so we can restore on cancellation.
    let preFlight = lastResponse
    queryStatus = .loading

    do {
      let response = try await queryProvider(trimmed)
      // Only update if this task wasn't cancelled between the await and here.
      guard !Task.isCancelled else { return }
      lastResponse = (answer: response.answer, sources: response.sources, queryID: response.queryID)
      queryStatus = .results(
        answer: response.answer,
        sources: response.sources,
        queryID: response.queryID
      )
    } catch {
      // Cancellation is not a user-visible failure: the user deliberately
      // tapped Ask again (or the request was superseded by a new query).
      // Restore the display to whatever was showing before the spinner.
      if isCancellation(error) {
        // Only restore if we are still in loading state — if a racing task
        // already moved us to .results or .failure, leave it alone.
        if case .loading = queryStatus {
          if let prior = preFlight {
            queryStatus = .results(
              answer: prior.answer,
              sources: prior.sources,
              queryID: prior.queryID
            )
          } else {
            queryStatus = .idle
          }
        }
        return
      }

      // Real network / HTTP failure — surface to the user.
      let message: String
      if let apiError = error as? APIError {
        message = apiError.localizedDescription
      } else {
        message = error.localizedDescription
      }
      queryStatus = .idle
      errorMessage = message
      showErrorAlert = true
      // query is deliberately NOT cleared on failure — preserving user input
      // for editing/retry.
    }
    // Clear the handle so activeTask is non-nil only while a request is truly
    // in flight. Calling cancel() on a finished Task is a safe no-op, but
    // leaving the handle set creates misleading state for future readers.
    activeTask = nil
  }

  /// Returns `true` for `CancellationError` and `URLError.cancelled`, which
  /// both indicate the request was deliberately dropped rather than a real
  /// network failure.
  private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
  }
}
