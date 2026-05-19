import EventKit
import Foundation

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

  // MARK: - Permission

  func requestAccess() async -> Bool {
    do {
      return try await store.requestFullAccessToReminders()
    } catch {
      print("[eventkit] requestFullAccessToReminders failed: \(error)")
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
      print("[eventkit] save reminder failed: \(error)")
      throw EventKitError.saveFailed
    }

    return reminder.calendarItemIdentifier
  }

  // MARK: - Fetch

  func fetchCompletion(for identifier: String) -> Bool? {
    guard let item = store.calendarItem(withIdentifier: identifier),
          let reminder = item as? EKReminder
    else {
      return nil
    }
    return reminder.isCompleted
  }
}
