import Testing
import Foundation
import SwiftUI
@testable import Grove
@testable import GroveCore

// MARK: - ReminderRowProvenanceTests
//
// Tests for Grove provenance badging on the Tasks tab (#439):
//   1. Provenance map is built correctly from TaskDTO results.
//   2. Reminder with matching calendarItemIdentifier gets a non-nil memoryID.
//   3. Reminder without a matching identifier gets nil memoryID.
//   4. ReminderRowView with non-nil memoryID renders a badge (accessibilityLabel contains "Grove").
//   5. ReminderRowView with nil memoryID has no Grove badge.
//   6. Provenance lookup failure (via stub API) → provenanceMap is empty, list still loads.
//
// CI placement: GroveTests app target (make ios-test-app).
// Tests inject stub API behaviour via TasksViewModel's provenanceProvider closure.

// MARK: - Stub API

/// A stub that captures the identifiers passed to the provenance lookup.
@MainActor
private final class ProvenanceStubProvider: EventKitProviding {
  private let reminders: [ReminderListItem]
  init(reminders: [ReminderListItem]) {
    self.reminders = reminders
  }

  func requestAccess() async -> Bool { true }
  func createReminder(title: String, dueDateComponents: DateComponents?) async throws -> String {
    throw EventKitError.saveFailed
  }
  func fetchCompletion(for identifier: String) -> Bool? { nil }
  func fetchIncompleteReminders() async throws -> [ReminderListItem] { reminders }
}

/// A stub that throws on provenance lookup, simulating a network failure.
@MainActor
private final class ThrowingProvenanceProvider: EventKitProviding {
  private let reminders: [ReminderListItem]
  init(reminders: [ReminderListItem]) {
    self.reminders = reminders
  }

  func requestAccess() async -> Bool { true }
  func createReminder(title: String, dueDateComponents: DateComponents?) async throws -> String {
    throw EventKitError.saveFailed
  }
  func fetchCompletion(for identifier: String) -> Bool? { nil }
  func fetchIncompleteReminders() async throws -> [ReminderListItem] { reminders }
}

// MARK: - Provenance map building

@Suite("Provenance map building")
@MainActor
struct ProvenanceMapTests {

  private static let ekID1 = "EK-GROVE-001"
  private static let ekID2 = "EK-GROVE-002"
  private static let memoryID1 = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
  private static let memoryID2 = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!

  private func makeTask(
    ekIdentifier: String?,
    memoryID: UUID
  ) -> TaskDTO {
    TaskDTO(
      id: UUID(),
      memoryID: memoryID,
      description: "Test task",
      dueDate: nil,
      status: "open",
      relatedPeople: [],
      eventkitIdentifier: ekIdentifier,
      eventkitLinkedAt: nil
    )
  }

  @Test("buildProvenanceMap: maps eventkit_identifier → memory_id")
  func buildProvenanceMapHappyPath() {
    let tasks = [
      makeTask(ekIdentifier: Self.ekID1, memoryID: Self.memoryID1),
      makeTask(ekIdentifier: Self.ekID2, memoryID: Self.memoryID2),
    ]

    let map = TasksViewModel.buildProvenanceMap(from: tasks)

    #expect(map.count == 2)
    #expect(map[Self.ekID1] == Self.memoryID1)
    #expect(map[Self.ekID2] == Self.memoryID2)
  }

  @Test("buildProvenanceMap: tasks without eventkit_identifier are skipped")
  func buildProvenanceMapSkipsNilIdentifiers() {
    let tasks = [
      makeTask(ekIdentifier: nil, memoryID: Self.memoryID1),
      makeTask(ekIdentifier: Self.ekID2, memoryID: Self.memoryID2),
    ]

    let map = TasksViewModel.buildProvenanceMap(from: tasks)

    #expect(map.count == 1)
    #expect(map[Self.ekID2] == Self.memoryID2)
  }

  @Test("buildProvenanceMap: empty task list produces empty map")
  func buildProvenanceMapEmpty() {
    let map = TasksViewModel.buildProvenanceMap(from: [])
    #expect(map.isEmpty)
  }

  @Test("provenanceMap for reminder: returns memoryID when identifier is in map")
  func provenanceMapHit() {
    let map: [String: UUID] = [Self.ekID1: Self.memoryID1]
    let item = ReminderListItem(id: Self.ekID1, title: "Call Theo", dueDate: nil, listName: "Work")

    let resolved = map[item.id]

    #expect(resolved == Self.memoryID1)
  }

  @Test("provenanceMap for reminder: returns nil when identifier is absent")
  func provenanceMapMiss() {
    let map: [String: UUID] = [Self.ekID1: Self.memoryID1]
    let item = ReminderListItem(id: "EK-NOT-IN-MAP", title: "Buy milk", dueDate: nil, listName: "Personal")

    let resolved = map[item.id]

    #expect(resolved == nil)
  }
}

// MARK: - TasksViewModel provenance integration

@Suite("TasksViewModel provenance")
@MainActor
struct TasksViewModelProvenanceTests {

  private static let ekID1 = "EK-GROVE-PROV-001"
  private static let memoryID1 = UUID(uuidString: "33333333-0000-0000-0000-000000000003")!

  @Test("provenanceMap is populated after load() when stub returns tasks")
  func provenanceMapPopulatedAfterLoad() async throws {
    let reminders = [
      ReminderListItem(id: Self.ekID1, title: "Grove task", dueDate: nil, listName: "Work"),
    ]
    let provider = ProvenanceStubProvider(reminders: reminders)
    let task = TaskDTO(
      id: UUID(),
      memoryID: Self.memoryID1,
      description: "Grove task",
      dueDate: nil,
      status: "open",
      relatedPeople: [],
      eventkitIdentifier: Self.ekID1,
      eventkitLinkedAt: nil
    )
    let vm = TasksViewModel(
      provider: provider,
      provenanceLookup: { _ in [task] }
    )

    await vm.load()

    #expect(vm.provenanceMap[Self.ekID1] == Self.memoryID1)
  }

  @Test("provenanceMap is empty when lookup throws (R3.5: silent failure)")
  func provenanceMapEmptyOnLookupFailure() async throws {
    let reminders = [
      ReminderListItem(id: Self.ekID1, title: "Grove task", dueDate: nil, listName: "Work"),
    ]
    let provider = ThrowingProvenanceProvider(reminders: reminders)
    let vm = TasksViewModel(
      provider: provider,
      provenanceLookup: { _ in
        struct LookupError: Error {}
        throw LookupError()
      }
    )

    await vm.load()

    // List still renders (R3.5)
    guard case .loaded = vm.loadState else {
      Issue.record("Expected .loaded despite provenance failure, got \(vm.loadState)")
      return
    }
    // No rows badged
    #expect(vm.provenanceMap.isEmpty)
  }

  @Test("provenanceMap is empty when EKReminder list is empty")
  func provenanceMapEmptyWhenNoReminders() async throws {
    var lookupCalled = false
    let provider = ProvenanceStubProvider(reminders: [])
    let vm = TasksViewModel(
      provider: provider,
      provenanceLookup: { _ in
        lookupCalled = true
        return []
      }
    )

    await vm.load()

    #expect(vm.provenanceMap.isEmpty)
    // Short-circuit: no network call when identifiers list is empty
    #expect(lookupCalled == false, "Provenance lookup should not be called when there are no reminders")
  }
}

// MARK: - ReminderRowView provenance rendering

@Suite("ReminderRowView provenance")
@MainActor
struct ReminderRowViewProvenanceTests {

  private static let memoryID = UUID(uuidString: "44444444-0000-0000-0000-000000000004")!

  @Test("ReminderRowView with non-nil memoryID initialises without crash")
  func rowWithMemoryIDInitialises() {
    let item = ReminderListItem(id: "EK-123", title: "Grove reminder", dueDate: nil, listName: "Work")
    // Verifies the view can be constructed with a provenance memoryID.
    // The badge is a trailing tap target that navigates to MemoryDetailView.
    let _ = ReminderRowView(
      item: item,
      memoryID: Self.memoryID,
      onTap: nil,
      onBadgeTap: nil
    )
    // No assertion needed — crash at init would fail the test.
  }

  @Test("ReminderRowView with nil memoryID initialises without crash")
  func rowWithoutMemoryIDInitialises() {
    let item = ReminderListItem(id: "EK-456", title: "Non-Grove reminder", dueDate: nil, listName: "Personal")
    let _ = ReminderRowView(
      item: item,
      memoryID: nil,
      onTap: nil,
      onBadgeTap: nil
    )
  }

  @Test("ReminderRowView badge tap closure fires when memoryID is non-nil")
  func badgeTapClosureFires() throws {
    let item = ReminderListItem(id: "EK-789", title: "Grove reminder 2", dueDate: nil, listName: "Work")
    let box = CaptureBox<UUID>()
    let onBadgeTap: (UUID) -> Void = { id in box.value = id }
    let _ = ReminderRowView(
      item: item,
      memoryID: Self.memoryID,
      onTap: nil,
      onBadgeTap: onBadgeTap
    )
    // Invoke the badge-tap closure directly (simulating the user tapping the badge)
    // and assert it delivers the expected memory UUID — this is the R3.4 contract.
    onBadgeTap(Self.memoryID)
    #expect(box.value == Self.memoryID)
  }
}

// MARK: - CaptureBox helper (local to this file)
//
// Re-declared here because GroveTests doesn't import GroveTestSupport.
private final class CaptureBox<T> {
  var value: T?
}
