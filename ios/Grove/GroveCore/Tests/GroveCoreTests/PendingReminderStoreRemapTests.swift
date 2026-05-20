import Testing
import Foundation
@testable import GroveCore

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

@Suite("PendingReminderStore — notification-driven remap")
@MainActor
struct PendingReminderStoreRemapTests {

  private static let calendarID = "EK-remap-ci-abc"

  /// Posting `captureUploadedNotification` causes the store to remap the
  /// entry from `clientID` to `serverMemoryID`.
  ///
  /// A hermetic `UserDefaults` suite is used so the test never touches the
  /// host process's real defaults; the suite is removed in `defer`.
  @Test("captureUploadedNotification remaps clientID → serverMemoryID")
  func notificationRemapsClientIDToServerMemoryID() async throws {
    let suiteName = UUID().uuidString
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removeSuite(named: suiteName) }

    let store = UserDefaultsPendingReminderStore(defaults: suite)

    let clientID = UUID()
    let serverMemoryID = UUID()

    store.store(memoryID: clientID, calendarItemIdentifier: Self.calendarID)
    #expect(store.entry(for: clientID) != nil, "Precondition: entry exists under clientID before remap")

    // The observer lives in a `Task { @MainActor ... }` started during init.
    // Yield once so it reaches its first `next()` suspension point.
    await Task.yield()

    NotificationCenter.default.post(
      name: .captureUploadedNotification,
      object: nil,
      userInfo: [
        "clientID": clientID.uuidString,
        "serverMemoryID": serverMemoryID.uuidString,
      ]
    )

    // Yield again so the observer wakes up and calls remap().
    await Task.yield()

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
  @Test("captureUploadedNotification with unknown clientID is a no-op")
  func notificationUnknownClientIDNoOp() async throws {
    let suiteName = UUID().uuidString
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removeSuite(named: suiteName) }

    let store = UserDefaultsPendingReminderStore(defaults: suite)

    let knownClientID = UUID()
    let unknownClientID = UUID()
    let serverMemoryID = UUID()

    store.store(memoryID: knownClientID, calendarItemIdentifier: Self.calendarID)

    await Task.yield()

    NotificationCenter.default.post(
      name: .captureUploadedNotification,
      object: nil,
      userInfo: [
        "clientID": unknownClientID.uuidString,
        "serverMemoryID": serverMemoryID.uuidString,
      ]
    )

    await Task.yield()

    #expect(store.all().count == 1, "Unrelated notification must not remove existing entries")
    #expect(store.entry(for: knownClientID) != nil, "Original entry must still be present")
  }
}
