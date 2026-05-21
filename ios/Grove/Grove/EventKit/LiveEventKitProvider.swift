import EventKit
import Foundation
import os

/// Production implementation of `EventKitProviding` backed by a real `EKEventStore`.
///
/// Access to this type is restricted to the app target — it imports EventKit,
/// which requires the `NSRemindersFullAccessUsageDescription` Info.plist entry
/// and is not available in the GroveCore SPM target (which also targets macOS).
///
/// ## Singleton vs. per-use
///
/// A single `EKEventStore` instance is preferred per Apple's guidance —
/// creating multiple instances within the same process is wasteful and can
/// produce stale data. `LiveEventKitProvider` is created once in
/// `TaskLinkingViewModel` and held for the view's lifetime.
@MainActor
final class LiveEventKitProvider: EventKitProviding {

  private let store = EKEventStore()
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.markdlabrecque.grove",
    category: "eventkit"
  )

  // MARK: - Permission

  func requestAccess() async -> Bool {
    do {
      return try await store.requestFullAccessToReminders()
    } catch {
      logger.error("requestFullAccessToReminders failed: \(error, privacy: .public)")
      return false
    }
  }

  // MARK: - Create

  /// Creates an `EKReminder` in the user's default Reminders list and returns
  /// its `calendarItemIdentifier`.
  ///
  /// The reminder's `notes` field is set to `"From Grove"` so the origin is
  /// visible in the Reminders app.
  func createReminder(
    title: String,
    dueDateComponents: DateComponents?
  ) async throws -> String {
    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.dueDateComponents = dueDateComponents
    reminder.notes = "From Grove"
    reminder.calendar = store.defaultCalendarForNewReminders()

    do {
      try store.save(reminder, commit: true)
    } catch {
      logger.error("save reminder failed: \(error, privacy: .public)")
      throw EventKitError.saveFailed
    }

    return reminder.calendarItemIdentifier
  }

  // MARK: - Fetch completion

  func fetchCompletion(for identifier: String) -> Bool? {
    guard let item = store.calendarItem(withIdentifier: identifier),
          let reminder = item as? EKReminder
    else {
      return nil
    }
    return reminder.isCompleted
  }

  // MARK: - Fetch incomplete reminders

  /// Fetches all incomplete reminders from all calendars and maps them to
  /// `ReminderListItem` value types.
  ///
  /// Uses `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)`
  /// with all-nil bounds to return every incomplete reminder on the device.
  func fetchIncompleteReminders() async throws -> [ReminderListItem] {
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil,
      ending: nil,
      calendars: nil
    )
    let reminders = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<[EKReminder], Error>) in
      store.fetchReminders(matching: predicate) { fetched in
        continuation.resume(returning: fetched ?? [])
      }
    }
    return reminders.map { reminder in
      ReminderListItem(
        id: reminder.calendarItemIdentifier,
        title: reminder.title ?? "",
        dueDate: reminder.dueDateComponents?.date,
        listName: reminder.calendar?.title ?? ""
      )
    }
  }
}
