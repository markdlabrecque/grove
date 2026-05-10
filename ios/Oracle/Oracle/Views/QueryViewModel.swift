import Foundation
import OracleCore

/// View state and query logic for the Ask screen.
///
/// Marked `@Observable` so SwiftUI observes only the properties that change,
/// without any `@Published` boilerplate. Requires iOS 17+.
@Observable
@MainActor
final class QueryViewModel {

  // MARK: - Inputs

  var query: String = ""

  // MARK: - Derived state

  var isAskEnabled: Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
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

  // MARK: - Ask

  func ask() async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    queryStatus = .loading

    do {
      let response = try await OracleAPI.shared.postQuery(trimmed)
      queryStatus = .results(response.results)
    } catch {
      let message: String
      if let apiError = error as? APIError {
        message = apiError.localizedDescription
      } else {
        message = error.localizedDescription
      }
      queryStatus = .idle
      errorMessage = message
      showErrorAlert = true
      // query is deliberately NOT cleared on failure — preserving user input for editing/retry.
    }
  }
}
