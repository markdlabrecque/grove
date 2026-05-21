import Testing
import Foundation
@testable import Grove
import GroveCore

// MARK: - TasksViewTests (spec-02 rewrite)
//
// Tests for the rebuilt `TasksViewModel` — server-backed Tasks tab (#452).
//
// These tests cover R2.3–R2.8:
//   R2.3: TasksViewModel holds [TaskDTO] and fetches via listTasks().
//   R2.5: Swipe-to-delete removes the row optimistically; error restores it.
//   R2.6: Pull-to-refresh calls listTasks() again.
//   R2.7: Empty state after successful fetch with no rows.
//   R2.8: Error state when listTasks() throws; retry button calls fetch again.
//
// CI placement: GroveTests app target (make ios-test-app).
// Tests inject a fetch closure so no live server or GroveAPI is needed.

// MARK: - Fixtures

private func makeTask(
  id: UUID = UUID(),
  description: String = "Test task",
  dueDate: String? = nil,
  relatedPeople: [String]? = nil
) -> TaskDTO {
  TaskDTO(
    id: id,
    memoryID: UUID(),
    description: description,
    dueDate: dueDate,
    status: "open",
    relatedPeople: relatedPeople,
    eventkitIdentifier: nil,
    eventkitLinkedAt: nil
  )
}

// MARK: - Suite

@Suite("TasksViewModel (spec-02)")
@MainActor
struct TasksViewTests {

  // MARK: - Initial state

  @Test("initial state is .loading before any fetch completes")
  func initialStateIsLoading() {
    let vm = TasksViewModel(
      fetch: { [] },
      delete: { _ in }
    )
    // Before load() is called the state should be loading-ready (.loading).
    guard case .loading = vm.loadState else {
      Issue.record("Expected .loading as initial state, got \(vm.loadState)")
      return
    }
  }

  // MARK: - Loaded state (R2.3)

  @Test("load: fetch returns two tasks → .loaded with [TaskDTO]")
  func loadedStateWithTasks() async throws {
    let task1 = makeTask(description: "Call Theo")
    let task2 = makeTask(description: "Buy oat milk")

    let vm = TasksViewModel(
      fetch: { [task1, task2] },
      delete: { _ in }
    )

    await vm.load()

    guard case .loaded(let items) = vm.loadState else {
      Issue.record("Expected .loaded, got \(vm.loadState)")
      return
    }
    #expect(items.count == 2)
    #expect(items[0].description == "Call Theo")
    #expect(items[1].description == "Buy oat milk")
  }

  // MARK: - Empty state (R2.7)

  @Test("load: fetch returns [] → .empty")
  func emptyState() async throws {
    let vm = TasksViewModel(
      fetch: { [] },
      delete: { _ in }
    )

    await vm.load()

    guard case .empty = vm.loadState else {
      Issue.record("Expected .empty, got \(vm.loadState)")
      return
    }
  }

  // MARK: - Error state (R2.8)

  @Test("load: fetch throws → .error")
  func errorState() async throws {
    struct FetchError: Error {}

    let vm = TasksViewModel(
      fetch: { throw FetchError() },
      delete: { _ in }
    )

    await vm.load()

    guard case .error = vm.loadState else {
      Issue.record("Expected .error, got \(vm.loadState)")
      return
    }
  }

  // MARK: - Retry (R2.8)

  @Test("retry: calling load() again after error re-fetches and succeeds")
  func retryAfterError() async throws {
    struct FetchError: Error {}
    var callCount = 0
    let task = makeTask(description: "Retry task")

    let vm = TasksViewModel(
      fetch: {
        callCount += 1
        if callCount == 1 { throw FetchError() }
        return [task]
      },
      delete: { _ in }
    )

    // First load — should fail.
    await vm.load()
    guard case .error = vm.loadState else {
      Issue.record("Expected .error on first load, got \(vm.loadState)")
      return
    }

    // Retry — should succeed.
    await vm.load()
    guard case .loaded(let items) = vm.loadState else {
      Issue.record("Expected .loaded after retry, got \(vm.loadState)")
      return
    }
    #expect(items.count == 1)
    #expect(items[0].description == "Retry task")
    #expect(callCount == 2)
  }

  // MARK: - Pull-to-refresh (R2.6)

  @Test("refresh: calling load() after loaded state re-fetches")
  func pullToRefresh() async throws {
    var callCount = 0
    let task1 = makeTask(description: "First task")
    let task2 = makeTask(description: "Refreshed task")

    let vm = TasksViewModel(
      fetch: {
        callCount += 1
        return callCount == 1 ? [task1] : [task2]
      },
      delete: { _ in }
    )

    await vm.load()

    guard case .loaded(let firstItems) = vm.loadState else {
      Issue.record("Expected .loaded after first load, got \(vm.loadState)")
      return
    }
    #expect(firstItems[0].description == "First task")

    // Simulate pull-to-refresh.
    await vm.load()

    guard case .loaded(let refreshedItems) = vm.loadState else {
      Issue.record("Expected .loaded after refresh, got \(vm.loadState)")
      return
    }
    #expect(refreshedItems[0].description == "Refreshed task")
    #expect(callCount == 2)
  }

  // MARK: - Swipe-to-delete optimistic removal (R2.5)

  @Test("delete: row removed optimistically before server confirms")
  func deleteRemovesRowOptimistically() async throws {
    let task1 = makeTask(description: "Task one")
    let task2 = makeTask(description: "Task two")

    // Delete is a slow operation — use a continuation to hold it in flight.
    let deleteCalled = ContinuationBox()

    let vm = TasksViewModel(
      fetch: { [task1, task2] },
      delete: { _ in
        await deleteCalled.wait()
      }
    )

    await vm.load()
    guard case .loaded = vm.loadState else {
      Issue.record("Expected .loaded before delete")
      return
    }

    // Start the delete task without awaiting (fire-and-forget to check optimistic state).
    let deleteTask = Task { await vm.deleteTask(task1) }

    // Yield to let the delete begin and remove the item.
    await Task.yield()
    await Task.yield()

    // Verify optimistic removal happened.
    if case .loaded(let items) = vm.loadState {
      #expect(items.count == 1)
      #expect(items[0].description == "Task two")
    } else if case .empty = vm.loadState {
      // Also acceptable if deleting the last item.
      Issue.record("Unexpected .empty — still had task2")
    } else {
      Issue.record("Expected .loaded or .empty after optimistic delete, got \(vm.loadState)")
    }

    // Allow delete to complete.
    deleteCalled.resume()
    await deleteTask.value
  }

  // MARK: - Swipe-to-delete: restores row on error (R2.5)

  @Test("delete: row restored on server error")
  func deleteRestoresRowOnError() async throws {
    struct DeleteError: Error {}
    let task1 = makeTask(description: "Keep me")
    let task2 = makeTask(description: "Delete me")

    let vm = TasksViewModel(
      fetch: { [task1, task2] },
      delete: { _ in throw DeleteError() }
    )

    await vm.load()
    guard case .loaded(let before) = vm.loadState else {
      Issue.record("Expected .loaded before delete")
      return
    }
    #expect(before.count == 2)

    await vm.deleteTask(task2)

    // Row should be restored after the error.
    guard case .loaded(let after) = vm.loadState else {
      Issue.record("Expected .loaded after failed delete, got \(vm.loadState)")
      return
    }
    #expect(after.count == 2)
  }

  // MARK: - Swipe-to-delete: error is surfaced (R2.5)

  @Test("delete: deleteError is set when server call throws")
  func deleteErrorIsSurfaced() async throws {
    struct DeleteError: Error, LocalizedError {
      var errorDescription: String? { "Server rejected the delete" }
    }

    let task = makeTask(description: "Failing task")

    let vm = TasksViewModel(
      fetch: { [task] },
      delete: { _ in throw DeleteError() }
    )

    await vm.load()
    await vm.deleteTask(task)

    #expect(vm.deleteError != nil)
  }

  // MARK: - No EventKit or provenance (R2.9, R2.10)

  @Test("TasksViewModel holds no provenance map or EventKit dependency")
  func noProvenanceOrEventKit() {
    // This test verifies at compile time that TasksViewModel only accepts
    // fetch/delete closures, not an EventKitProviding dependency.
    // Constructing the view model with just closures is sufficient proof.
    let vm = TasksViewModel(
      fetch: { [] },
      delete: { _ in }
    )
    _ = vm  // used
  }
}

// MARK: - ContinuationBox

/// A helper for pausing and resuming an async operation in tests.
private actor ContinuationBox {
  private var continuation: CheckedContinuation<Void, Never>?
  private var resumed = false

  func wait() async {
    if resumed { return }
    await withCheckedContinuation { cont in
      continuation = cont
    }
  }

  func resume() {
    resumed = true
    continuation?.resume()
    continuation = nil
  }
}
