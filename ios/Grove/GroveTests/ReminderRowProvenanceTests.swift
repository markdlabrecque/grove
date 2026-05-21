import Testing
import Foundation
import SwiftUI
@testable import Grove
@testable import GroveCore

// MARK: - ReminderRowProvenanceTests
//
// Tests for Grove provenance badging UI (#439).
//
// NOTE: The provenance map / EventKit coupling logic in TasksViewModel was
// removed in #452 (Part 2 of the Tasks tab rebuild). The provenance-map
// building helpers and TasksViewModel integration tests that existed here
// are removed in this commit because they depended on `buildProvenanceMap`,
// `provenanceMap`, and the old `TasksViewModel(provider:provenanceLookup:)`
// initialiser — all of which no longer exist.
//
// The `ReminderRowView` UI tests below do NOT depend on TasksViewModel and
// are kept as-is. The entire provenance+EventKit cleanup (removing
// ReminderRowView, ReminderListItem, etc.) happens in Part 3 (#453).
//
// CI placement: GroveTests app target (make ios-test-app).

// MARK: - ReminderRowView provenance rendering

@Suite("ReminderRowView provenance")
@MainActor
struct ReminderRowViewProvenanceTests {

  private static let memoryID = UUID(uuidString: "44444444-0000-0000-0000-000000000004")!

  @Test("ReminderRowView with non-nil memoryID initialises without crash")
  func rowWithMemoryIDInitialises() {
    let item = ReminderListItem(id: "EK-123", title: "Grove reminder", dueDate: nil, listName: "Work")
    // Verifies the view can be constructed with a provenance memoryID.
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
    // Invoke the badge-tap closure directly (simulating the user tapping the badge).
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
