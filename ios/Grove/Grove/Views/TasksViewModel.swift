import Foundation
import os

/// State machine for the Tasks tab (#438).
///
/// Drives `TasksView` through EventKit permission, loading, and data states.
/// Tests inject a stub `EventKitProviding` to exercise state transitions
/// without touching a real `EKEventStore`.
///
/// ## Load state transitions
///
///   .notDetermined
///       ↓  requestAccess() → denied
///   .denied
///       ↓  requestAccess() → granted
///   .loading
///       ↓  fetchIncompleteReminders()
///   .empty   /   .loaded([ReminderListItem])
///
/// Refresh (pull-to-refresh or EKEventStoreChanged) re-enters .loading from
/// .empty or .loaded.
@Observable
@MainActor
final class TasksViewModel {

  // MARK: - Load state

  enum LoadState {
    case notDetermined
    case denied
    case loading
    case empty
    case loaded([ReminderListItem])
  }

  // MARK: - State

  private(set) var loadState: LoadState = .notDetermined

  // MARK: - Dependencies

  private let provider: EventKitProviding
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.markdlabrecque.grove",
    category: "tasks-view-model"
  )

  // MARK: - Init

  init(provider: EventKitProviding) {
    self.provider = provider
  }

  // MARK: - Load

  /// Request EventKit access and, if granted, fetch all incomplete reminders.
  ///
  /// Sets `loadState` through the full permission → loading → data cycle.
  /// Safe to call on each tab appear and on pull-to-refresh.
  func load() async {
    let granted = await provider.requestAccess()

    guard granted else {
      loadState = .denied
      return
    }

    loadState = .loading

    do {
      let items = try await provider.fetchIncompleteReminders()
      let sorted = Self.sorted(items)
      loadState = sorted.isEmpty ? .empty : .loaded(sorted)
    } catch {
      logger.error("fetchIncompleteReminders failed: \(error, privacy: .public)")
      loadState = .empty
    }
  }

  // MARK: - Sort

  /// Sorts reminder list items by due date ascending, nil due dates last,
  /// with alphabetical title as a tiebreak.
  static func sorted(_ items: [ReminderListItem]) -> [ReminderListItem] {
    items.sorted { lhs, rhs in
      switch (lhs.dueDate, rhs.dueDate) {
      case let (.some(l), .some(r)):
        if l == r { return lhs.title.localizedCompare(rhs.title) == .orderedAscending }
        return l < r
      case (.some, .none):
        // lhs has a due date, rhs does not → lhs comes first
        return true
      case (.none, .some):
        // lhs has no due date, rhs does → rhs comes first
        return false
      case (.none, .none):
        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
      }
    }
  }

  // MARK: - Deep-link URL

  /// Constructs the Reminders.app deep-link URL for a given
  /// `calendarItemIdentifier`.
  ///
  /// Scheme: `x-apple-reminderkit://REMCDReminder/<identifier>`
  ///
  /// Returns `nil` if the URL string is malformed.
  static func reminderDeepLinkURL(for identifier: String) -> URL? {
    URL(string: "x-apple-reminderkit://REMCDReminder/\(identifier)")
  }
}
