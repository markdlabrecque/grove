import Foundation

/// A value-type adapter for a single incomplete EKReminder, suitable for use
/// in SwiftUI views and unit tests without requiring a real EKEventStore.
///
/// `LiveEventKitProvider` maps `EKReminder` → `ReminderListItem` inside
/// `fetchIncompleteReminders()`. Views and view models consume this struct
/// exclusively — they never hold `EKReminder` references.
///
/// ## Identifiable
///
/// `id` is the reminder's `calendarItemIdentifier`, which Apple guarantees is
/// stable across `EKEventStore` sessions on the same device.
struct ReminderListItem: Identifiable, Equatable {
  /// The reminder's `EKReminder.calendarItemIdentifier`.
  let id: String
  /// The reminder's title.
  let title: String
  /// Optional due date (nil when no due date is set).
  let dueDate: Date?
  /// The name of the EKCalendar (Reminders list) the reminder belongs to.
  let listName: String
}
