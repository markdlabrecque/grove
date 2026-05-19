import Foundation

/// Abstracts the `EKEventStore` boundary for testability.
///
/// Production code uses `LiveEventKitProvider` (backed by a real `EKEventStore`).
/// Tests inject `StubEventKitProvider` (defined in `TaskLinkingViewModelTests.swift`),
/// which returns canned values without touching the device's Reminders database.
///
/// ## Why a protocol?
///
/// `EKEventStore` is not final and could theoretically be subclassed, but its
/// initialiser triggers a permission dialog in some test harness configurations.
/// A thin protocol is the safest boundary for all test-time injection.
@MainActor
protocol EventKitProviding: AnyObject {
  /// Request Reminders full access. Returns `true` if granted.
  func requestAccess() async -> Bool

  /// Create a reminder and return its `calendarItemIdentifier`.
  ///
  /// - Parameters:
  ///   - title: The reminder's title (from `TaskDTO.description`).
  ///   - dueDateComponents: Date-only components for the reminder's due date,
  ///     or nil when the task has no due date.
  /// - Throws: `EventKitError.saveFailed` if the EventKit save fails.
  func createReminder(title: String, dueDateComponents: DateComponents?) async throws -> String

  /// Fetch the `isCompleted` state of a reminder by its `calendarItemIdentifier`.
  ///
  /// Returns `nil` when the identifier resolves to no calendar item (e.g. the
  /// user deleted the reminder from the Reminders app). Returns the
  /// `isCompleted` boolean otherwise.
  func fetchCompletion(for identifier: String) -> Bool?
}

/// Errors produced by EventKit operations.
public enum EventKitError: Error {
  /// The `EKEventStore` save call failed (non-permission error).
  case saveFailed
}
