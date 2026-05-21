import Foundation
import os

/// State machine for the Tasks tab.
///
/// Drives `TasksView` through permission, loading, and data states.
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

  /// Request EventKit access and, if granted, fetch incomplete reminders.
  ///
  /// Sets `loadState` through the full permission → loading → data cycle.
  /// Safe to call on each tab appear and on pull-to-refresh.
  func load() async {
    // TODO(#438): implement
  }

  // MARK: - Helpers

  /// Constructs the Reminders.app deep-link URL for a given
  /// `calendarItemIdentifier`.
  ///
  /// Returns `nil` if the URL string is malformed (should never happen in
  /// practice given the opaque-string identifier format).
  static func reminderDeepLinkURL(for identifier: String) -> URL? {
    // TODO(#438): implement
    return nil
  }
}
