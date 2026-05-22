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
/// ## Optimistic-delete / refresh race guard (#458)
///
/// Every call to `load()` increments `loadGeneration`. On the error path of
/// `deleteTask(_:)`, the restore is skipped when `loadGeneration` has advanced
/// past the value captured at the start of the delete — meaning a fresher
/// `load()` has already landed and the stale snapshot must not overwrite it.
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

  /// Monotonically increasing counter bumped at the START of every `load()`
  /// call. Used by `deleteTask(_:)` to detect whether a fresher load has
  /// completed between the optimistic removal and the error-path restore.
  private var loadGeneration: UInt64 = 0

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
    loadGeneration &+= 1
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
  /// On failure, `deleteError` is set with the thrown error. The restore is
  /// skipped if `loadGeneration` has advanced (i.e. a `load()` call landed
  /// after the optimistic removal), preventing the stale snapshot from
  /// overwriting a fresher list.
  func deleteTask(_ task: TaskDTO) async {
    // Capture the current list and the generation so we can detect a
    // concurrent load() that completes between here and the catch block.
    guard case .loaded(let current) = loadState else { return }
    let generationAtDelete = loadGeneration

    // Optimistic removal.
    let updated = current.filter { $0.id != task.id }
    loadState = updated.isEmpty ? .empty : .loaded(updated)
    deleteError = nil

    do {
      try await delete(task.id)
    } catch {
      logger.error("deleteTask failed for id=\(task.id.uuidString.lowercased(), privacy: .public): \(error, privacy: .public)")
      // Only restore the pre-delete snapshot when no intervening load() has
      // produced a fresher list. If loadGeneration has advanced, the fresh
      // list is already in place and must not be overwritten.
      guard loadGeneration == generationAtDelete else {
        deleteError = error
        return
      }
      loadState = .loaded(current)
      deleteError = error
    }
  }
}
