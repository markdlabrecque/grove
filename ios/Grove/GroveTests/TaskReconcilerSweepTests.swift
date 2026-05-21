import Testing
import Foundation
import GroveCore
@testable import Grove

// MARK: - TaskReconcilerSweepTests
//
// Tests for `TaskReconciler.reconcileAllPending()` (#404):
//   1. PendingStore has 2 entries + list fetcher returns matching TaskDTOs
//      → reconcile(tasks:) is exercised → entries are removed.
//   2. PendingStore is empty → list fetcher is NOT called.
//
// CI placement: GroveTests app target (make ios-test-app).

@Suite("TaskReconciler — reconcileAllPending sweep")
@MainActor
struct TaskReconcilerSweepTests {

  // MARK: - Fixtures

  private static let memoryID1  = UUID(uuidString: "CCCC1111-0000-0000-0000-000000000001")!
  private static let memoryID2  = UUID(uuidString: "CCCC2222-0000-0000-0000-000000000002")!
  private static let taskID1    = UUID(uuidString: "BBBB1111-0000-0000-0000-000000000001")!
  private static let taskID2    = UUID(uuidString: "BBBB2222-0000-0000-0000-000000000002")!
  private static let reminderID1 = "EK-sweep-reminder-001"
  private static let reminderID2 = "EK-sweep-reminder-002"

  private func makeTask(
    id: UUID,
    memoryID: UUID,
    eventkitIdentifier: String? = nil
  ) -> TaskDTO {
    TaskDTO(
      id: id,
      memoryID: memoryID,
      description: "Stub task",
      dueDate: nil,
      status: "open",
      relatedPeople: [],
      eventkitIdentifier: eventkitIdentifier,
      eventkitLinkedAt: nil
    )
  }

  // MARK: - Suite 1: two entries reconciled

  @Test("reconcileAllPending: 2 pending entries + list fetcher returns matching DTOs → entries removed")
  func twoEntriesReconciled() async throws {
    let store = InMemoryPendingReminderStore()
    store.store(memoryID: Self.memoryID1, calendarItemIdentifier: Self.reminderID1)
    store.store(memoryID: Self.memoryID2, calendarItemIdentifier: Self.reminderID2)

    // Track which memory IDs were passed to the list fetcher.
    var fetchedMemoryIDs: [UUID]?

    // Track all PATCH calls.
    var patchedPairs: [(UUID, String)] = []

    let reconciler = TaskReconciler(
      pendingStore: store,
      patchProvider: { taskID, ekIdentifier in
        patchedPairs.append((taskID, ekIdentifier))
        return self.makeTask(
          id: taskID,
          memoryID: taskID == Self.taskID1 ? Self.memoryID1 : Self.memoryID2,
          eventkitIdentifier: ekIdentifier
        )
      },
      listTasksProvider: { memoryIDs in
        fetchedMemoryIDs = memoryIDs
        return [
          self.makeTask(id: Self.taskID1, memoryID: Self.memoryID1),
          self.makeTask(id: Self.taskID2, memoryID: Self.memoryID2),
        ]
      }
    )

    await reconciler.reconcileAllPending()

    // List fetcher was called with both memory IDs (order-agnostic).
    let fetched = try #require(fetchedMemoryIDs)
    #expect(fetched.count == 2)
    #expect(Set(fetched) == Set([Self.memoryID1, Self.memoryID2]))

    // Both entries were PATCHed.
    #expect(patchedPairs.count == 2)

    // Store is empty after successful reconciliation.
    #expect(store.all().isEmpty, "All pending entries should be removed after successful sweep")
  }

  // MARK: - Suite 2: empty store → no network call

  @Test("reconcileAllPending: empty pendingStore → list fetcher is NOT called")
  func emptyStoreShouldNotCallFetcher() async throws {
    let store = InMemoryPendingReminderStore()
    // Nothing stored.

    var fetcherCalled = false

    let reconciler = TaskReconciler(
      pendingStore: store,
      listTasksProvider: { _ in
        fetcherCalled = true
        return []
      }
    )

    await reconciler.reconcileAllPending()

    #expect(fetcherCalled == false, "List fetcher must not be called when pendingStore is empty")
  }
}
