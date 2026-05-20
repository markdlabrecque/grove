import Testing
import Foundation
@testable import GroveCore
import GroveTestSupport

// MARK: - PendingReminderStoreRemapTests
//
// CI-gated coverage for `UserDefaultsPendingReminderStore`'s
// notification-driven remap behaviour (#410).
//
// These tests mirror Suite 5 from GroveTests/TrackAsTaskTests.swift but
// live here so `make ios-test-core` (SPM) exercises them on every PR.
// The production types (`UserDefaultsPendingReminderStore`,
// `PendingReminderEntry`, `Notification.Name.captureUploadedNotification`)
// must be in GroveCore — if they are not, this file fails to compile,
// which is the intended red state.
//
// Async robustness (#411):
//   The previous `Task.yield()` pattern was cooperative-scheduler-dependent:
//   two yields were assumed to be enough to (a) let the observer reach its
//   first `next()` suspension and (b) wake it after the notification was
//   posted. That holds today but is not formally guaranteed.
//
//   * `notificationRemapsClientIDToServerMemoryID` now polls with a bounded
//     `while` loop inside `withBridgeTimeout` so the assertion fires as soon
//     as the remap completes rather than after an arbitrary yield count.
//   * `notificationUnknownClientIDNoOp` only needs to assert *absence*, so it
//     uses a single bounded `Task.sleep` to give the observer a fixed window
//     before checking — cooperative enough to catch the mutation if it
//     incorrectly occurred, but without a tight yield budget.

@Suite("PendingReminderStore — notification-driven remap")
@MainActor
struct PendingReminderStoreRemapTests {

  private static let calendarID = "EK-remap-ci-abc"

  /// Posting `captureUploadedNotification` causes the store to remap the
  /// entry from `clientID` to `serverMemoryID`.
  ///
  /// A hermetic `UserDefaults` suite and a private `NotificationCenter` are
  /// used so this test is fully isolated from other test stores. The suite
  /// is removed in `defer`.
  ///
  /// The assertion polls until the remap is observed (or `withBridgeTimeout`
  /// fires after 2 s), making it robust against scheduler variations.
  @Test("captureUploadedNotification remaps clientID → serverMemoryID")
  func notificationRemapsClientIDToServerMemoryID() async throws {
    let suiteName = UUID().uuidString
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removeSuite(named: suiteName) }

    let center = NotificationCenter()
    let store = UserDefaultsPendingReminderStore(defaults: suite, notificationCenter: center)

    let clientID = UUID()
    let serverMemoryID = UUID()

    store.store(memoryID: clientID, calendarItemIdentifier: Self.calendarID)
    #expect(store.entry(for: clientID) != nil, "Precondition: entry exists under clientID before remap")

    center.post(
      name: .captureUploadedNotification,
      object: nil,
      userInfo: [
        "clientID": clientID.uuidString,
        "serverMemoryID": serverMemoryID.uuidString,
      ]
    )

    // Poll until the remap lands, bounded by a 2 s deadline.
    // This is robust against scheduler interleaving — the assertion fires
    // as soon as `remap()` is called rather than after a fixed yield count.
    try await withBridgeTimeout(seconds: 2) {
      while await store.entry(for: serverMemoryID) == nil {
        await Task.yield()
      }
    }

    #expect(store.entry(for: serverMemoryID) != nil, "Entry must exist under serverMemoryID after remap")
    #expect(store.entry(for: clientID) == nil, "Old clientID key must be gone after remap")

    let remapped = store.entry(for: serverMemoryID)
    #expect(
      remapped?.calendarItemIdentifier == Self.calendarID,
      "Remapped entry must retain the original calendarItemIdentifier"
    )
  }

  /// Posting `captureUploadedNotification` for an unknown `clientID` is a
  /// no-op — existing entries must remain unchanged.
  ///
  /// Because this test asserts *absence* of a mutation, polling is not
  /// suitable. Instead a bounded `Task.sleep` gives the observer a fixed
  /// 100 ms window to (incorrectly) mutate the store, then the assertions
  /// run. The window is long enough to catch a spurious remap without
  /// making the test suite meaningfully slower.
  @Test("captureUploadedNotification with unknown clientID is a no-op")
  func notificationUnknownClientIDNoOp() async throws {
    let suiteName = UUID().uuidString
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removeSuite(named: suiteName) }

    let center = NotificationCenter()
    let store = UserDefaultsPendingReminderStore(defaults: suite, notificationCenter: center)

    let knownClientID = UUID()
    let unknownClientID = UUID()
    let serverMemoryID = UUID()

    store.store(memoryID: knownClientID, calendarItemIdentifier: Self.calendarID)

    center.post(
      name: .captureUploadedNotification,
      object: nil,
      userInfo: [
        "clientID": unknownClientID.uuidString,
        "serverMemoryID": serverMemoryID.uuidString,
      ]
    )

    // Give the observer a bounded window to process the notification.
    // If the implementation incorrectly mutates the store for an unknown
    // clientID this sleep ensures the mutation has had time to land before
    // the assertions below run.
    try await withBridgeTimeout(seconds: 2) {
      try await Task.sleep(for: .milliseconds(100))
    }

    #expect(store.all().count == 1, "Unrelated notification must not remove existing entries")
    #expect(store.entry(for: knownClientID) != nil, "Original entry must still be present")
  }
}
