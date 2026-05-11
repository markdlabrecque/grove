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
    case results([QueryResult])
    case failure(String)
  }

  var queryStatus: QueryStatus = .idle

  var isLoading: Bool {
    if case .loading = queryStatus { return true }
    return false
  }

  var showErrorAlert: Bool = false
  var errorMessage: String = ""

  // MARK: - Init

  init(
    queryProvider: @escaping (String) async throws -> QueryResponseBody = { text in
      try await OracleAPI.shared.postQuery(text)
    }
  ) {
    self.queryProvider = queryProvider
  }

  // MARK: - In-flight task

  /// The currently running ask `Task`, if any. Stored so `cancel()` can drop
  /// the in-flight URLSession request. Assigned and cleared on `@MainActor`.
  ///
  /// `internal` (not `private`) so `@testable` imports can assert it is `nil`
  /// after `ask()` completes — locking the regression introduced in #100.
  var activeTask: Task<Void, Never>?

  /// The last successfully returned results. Preserved across loading cycles
  /// so that when a new request is cancelled, the prior results are restored
  /// rather than blanked to `.idle`.
  private var lastResults: [QueryResult]?

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
    // Snapshot the pre-flight results so we can restore on cancellation.
    let preFlight = lastResults
    queryStatus = .loading

    do {
      let response = try await queryProvider(trimmed)
      // Only update if this task wasn't cancelled between the await and here.
      guard !Task.isCancelled else { return }
      lastResults = response.results
      queryStatus = .results(response.results)
    } catch {
      // Cancellation is not a user-visible failure: the user deliberately
      // tapped Ask again (or the request was superseded by a new query).
      // Restore the display to whatever was showing before the spinner.
      if isCancellation(error) {
        // Only restore if we are still in loading state — if a racing task
        // already moved us to .results or .failure, leave it alone.
        if case .loading = queryStatus {
          if let prior = preFlight {
            queryStatus = .results(prior)
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
