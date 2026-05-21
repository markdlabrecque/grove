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
//   * `remapUnknownClientIDNoOp` calls `store.remap(clientID:to:)` directly
//     rather than going through the notification observer. The no-op invariant
//     lives inside `remap()`, so calling it directly is both deterministic and
//     the canonical way to exercise it — no timing primitives needed.

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

    // Yield once to let the observer Task in init reach its first `for await`
    // suspension before we post. NotificationCenter's AsyncSequence only
    // delivers notifications posted AFTER subscription starts; without this
    // yield the post can race ahead of the subscription and be dropped,
    // forcing the polling loop to wait for the 2 s timeout.
    await Task.yield()

    center.post(
      name: .captureUploadedNotification,
      object: nil,
      userInfo: [
        "clientID": clientID.uuidString,
        "serverMemoryID": serverMemoryID.uuidString,
      ]
    )

    // Poll until the remap lands, bounded by a 2 s deadline.
    // `Task.checkCancellation()` lets `withBridgeTimeout`'s `group.cancelAll()`
    // actually unwind this loop — otherwise it spins on main actor forever
    // and starves every other test in the process.
    try await withBridgeTimeout(seconds: 2) {
      while await store.entry(for: serverMemoryID) == nil {
        try Task.checkCancellation()
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

  /// Calling `remap(clientID:to:)` with an unknown `clientID` is a no-op —
  /// existing entries must remain unchanged.
  ///
  /// The no-op invariant lives in `remap()` itself, so calling it directly
  /// is the canonical way to test it. This avoids the notification observer
  /// round-trip and eliminates any need for timing primitives.
  @Test("remap with unknown clientID is a no-op")
  func remapUnknownClientIDNoOp() {
    let suiteName = UUID().uuidString
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removeSuite(named: suiteName) }

    let center = NotificationCenter()
    let store = UserDefaultsPendingReminderStore(defaults: suite, notificationCenter: center)

    let knownClientID = UUID()
    let unknownClientID = UUID()
    let serverMemoryID = UUID()

    store.store(memoryID: knownClientID, calendarItemIdentifier: Self.calendarID)

    // Call remap() directly with a clientID that is not in the cache.
    // remap() is @MainActor and runs synchronously on the current actor.
    store.remap(clientID: unknownClientID, to: serverMemoryID)

    #expect(store.all().count == 1, "remap with unknown clientID must not remove existing entries")
    #expect(store.entry(for: knownClientID) != nil, "Original entry must still be present")
  }
}
