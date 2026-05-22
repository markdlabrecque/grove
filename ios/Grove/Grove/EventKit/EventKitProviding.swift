import Foundation

/// Abstracts the `EKEventStore` boundary for testability.
///
/// Production code uses `LiveEventKitProvider` (backed by a real `EKEventStore`).
/// Tests inject a stub conforming type without touching the device's Reminders database.
///
/// ## Why a protocol?
///
/// `EKEventStore` is not final and could theoretically be subclassed, but its
/// initialiser triggers a permission dialog in some test harness configurations.
/// A thin protocol is the safest boundary for all test-time injection.
///
/// ## Scope (spec-02 cleanup)
///
/// This protocol now only covers the capture-flow surface: requesting access and
/// creating a reminder. The returned identifier is fire-and-forget — Grove does
/// not store it or read EventKit after creation.
@MainActor
protocol EventKitProviding: AnyObject {
  /// Request Reminders full access. Returns `true` if granted.
  func requestAccess() async -> Bool

  /// Create a reminder and return its `calendarItemIdentifier`.
  ///
  /// - Parameters:
  ///   - title: The reminder's title (from the capture content).
  ///   - dueDateComponents: Date-only components for the reminder's due date,
  ///     or nil when the task has no due date.
  /// - Throws: `EventKitError.saveFailed` if the EventKit save fails.
  func createReminder(title: String, dueDateComponents: DateComponents?) async throws -> String
}

/// Errors produced by EventKit operations.
public enum EventKitError: Error {
  /// The `EKEventStore` save call failed (non-permission error).
  case saveFailed
}
