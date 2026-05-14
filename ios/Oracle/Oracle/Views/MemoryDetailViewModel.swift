import Foundation
import OracleCore

// MARK: - MemoryDetailViewModel (stub — see #207 green commit for full implementation)
//
// This file is intentionally minimal. The tests in MemoryDetailViewModelTests
// reference this type; the full implementation follows in the green commit.

@Observable
@MainActor
final class MemoryDetailViewModel {
  let result: QueryResult

  var isShowingDeleteConfirmation: Bool = false
  var isDeleting: Bool = false
  var deleteError: String? = nil
  var isDismissed: Bool = false

  private let deleteProvider: (UUID) async throws -> Void
  private let onDeleteSuccess: ((UUID) -> Void)?

  init(
    result: QueryResult,
    deleteProvider: @escaping (UUID) async throws -> Void,
    onDeleteSuccess: ((UUID) -> Void)? = nil
  ) {
    self.result = result
    self.deleteProvider = deleteProvider
    self.onDeleteSuccess = onDeleteSuccess
  }

  func requestDelete() {
    // TODO(#207): implement
  }

  func cancelDelete() {
    // TODO(#207): implement
  }

  func confirmDelete() async {
    // TODO(#207): implement
  }
}
