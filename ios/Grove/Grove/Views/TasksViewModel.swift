import Foundation
import GroveCore
import os

/// State machine for the rebuilt Tasks tab (#452).
///
/// Drives `TasksView` through loading, empty, error, and loaded states.
/// Fetches tasks from the server via `GroveAPI.listTasks()`. No EventKit
/// dependency — the only in-app action is swipe-to-delete.
///
/// ## Load state transitions
///
///   .loading
///       ↓  load() → fetch throws
///   .error(Error)
///       ↓  load() retry
///   .loading
///       ↓  fetch succeeds with []
///   .empty
///       ↓  load() refresh
///   .loading
///       ↓  fetch succeeds with [TaskDTO]
///   .loaded([TaskDTO])
///
/// ## Swipe-to-delete (R2.5)
///
/// `deleteTask(_:)` removes the row optimistically from the in-memory array,
/// calls the delete closure, and restores the row on failure. On failure,
/// `deleteError` is set so the view can surface a banner or per-row indicator.
///
/// ## Dependency injection
///
/// `fetch` and `delete` closures are injected so unit tests can stub the
/// network without a live server or GroveAPI instance.
@Observable
@MainActor
final class TasksViewModel {

  // MARK: - Load state

  enum LoadState {
    /// Fetch in progress (or initial state before first load).
    case loading
    /// Fetch succeeded and returned zero tasks.
    case empty
    /// Fetch succeeded and returned at least one task.
    case loaded([TaskDTO])
    /// Fetch failed.
    case error(Error)
  }

  // MARK: - State

  private(set) var loadState: LoadState = .loading

  /// Non-nil when a swipe-to-delete call threw. Cleared on the next
  /// successful delete or on the next `load()` call.
  private(set) var deleteError: Error? = nil

  // MARK: - Dependencies

  /// Calls GET /v1/tasks and returns the array.
  private let fetch: () async throws -> [TaskDTO]

  /// Calls DELETE /v1/tasks/{id}. Throws on non-204.
  private let delete: (UUID) async throws -> Void

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.markdlabrecque.grove",
    category: "tasks-view-model"
  )

  // MARK: - Init (production)

  /// Convenience initialiser that wires `GroveAPI.shared` for production use.
  convenience init() {
    self.init(
      fetch: { try await GroveAPI.shared.listTasks() },
      delete: { id in try await GroveAPI.shared.deleteTask(id: id) }
    )
  }

  // MARK: - Init (testable)

  init(
    fetch: @escaping () async throws -> [TaskDTO],
    delete: @escaping (UUID) async throws -> Void
  ) {
    self.fetch = fetch
    self.delete = delete
  }

  // MARK: - Load / refresh

  /// Fetch all tasks from the server.
  ///
  /// Safe to call on `.onAppear` and on pull-to-refresh. Transitions through
  /// `.loading` before settling on `.empty`, `.loaded`, or `.error`.
  func load() async {
    loadState = .loading
    deleteError = nil

    do {
      let tasks = try await fetch()
      loadState = tasks.isEmpty ? .empty : .loaded(tasks)
    } catch {
      logger.error("listTasks failed: \(error, privacy: .public)")
      loadState = .error(error)
    }
  }

  // MARK: - Delete (R2.5)

  /// Optimistically remove `task` from the list, call the delete closure,
  /// and restore the row on failure.
  ///
  /// On failure, `deleteError` is set with the thrown error.
  func deleteTask(_ task: TaskDTO) async {
    // Capture the current list so we can restore it on failure.
    guard case .loaded(let current) = loadState else { return }

    // Optimistic removal.
    let updated = current.filter { $0.id != task.id }
    loadState = updated.isEmpty ? .empty : .loaded(updated)
    deleteError = nil

    do {
      try await delete(task.id)
    } catch {
      logger.error("deleteTask failed for id=\(task.id.uuidString.lowercased(), privacy: .public): \(error, privacy: .public)")
      // Restore the original list.
      loadState = .loaded(current)
      deleteError = error
    }
  }
}
