import Foundation
import GroveCore
import os

/// State machine for the Tasks tab (#438, #439).
///
/// Drives `TasksView` through EventKit permission, loading, and data states.
/// After a successful EKReminder fetch, calls a provenance lookup to build
/// a `[String: UUID]` map from `calendarItemIdentifier` → memory UUID. This
/// map is used by `ReminderRowView` to badge Grove-originated rows.
///
/// Tests inject a stub `EventKitProviding` and a stub `provenanceLookup`
/// closure to exercise state transitions without a live server or EKEventStore.
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
///
/// ## Provenance (R3.2, R3.5, R3.6)
///
/// After a successful fetch, `provenanceLookup` is called with the collected
/// `calendarItemIdentifier` strings. On success, `provenanceMap` is updated.
/// On failure, `provenanceMap` is cleared and the failure is logged; the list
/// renders without badges (silent degradation per R3.5).
///
/// The map is recomputed on every fetch cycle (R3.6).
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

  /// Maps `calendarItemIdentifier` → `memory_id` for Grove-originated reminders.
  ///
  /// Built after each successful EKReminder fetch. Empty when provenance lookup
  /// has not run, returned no matches, or failed (R3.5 silent degradation).
  private(set) var provenanceMap: [String: UUID] = [:]

  // MARK: - Dependencies

  private let provider: EventKitProviding

  /// Async closure that performs the provenance batch lookup.
  ///
  /// Production: calls `GroveAPI.shared.listTasksByEventKitIdentifiers(_:)`.
  /// Tests: inject a stub that returns fixture `TaskDTO`s or throws.
  let provenanceLookup: ([String]) async throws -> [TaskDTO]

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.markdlabrecque.grove",
    category: "tasks-view-model"
  )

  // MARK: - Init

  init(
    provider: EventKitProviding,
    provenanceLookup: (([String]) async throws -> [TaskDTO])? = nil
  ) {
    self.provider = provider
    self.provenanceLookup = provenanceLookup ?? { ids in
      try await GroveAPI.shared.listTasksByEventKitIdentifiers(ids)
    }
  }

  // MARK: - Load

  /// Request EventKit access and, if granted, fetch all incomplete reminders.
  ///
  /// Sets `loadState` through the full permission → loading → data cycle.
  /// Safe to call on each tab appear and on pull-to-refresh.
  ///
  /// After a successful fetch, performs the provenance lookup and updates
  /// `provenanceMap`. Lookup failure is logged and silently absorbed (R3.5).
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

      // R3.2: collect identifiers and perform provenance lookup.
      let identifiers = items.map { $0.id }
      await loadProvenance(for: identifiers)
    } catch {
      logger.error("fetchIncompleteReminders failed: \(error, privacy: .public)")
      loadState = .empty
    }
  }

  // MARK: - Provenance lookup (R3.2, R3.5, R3.6)

  /// Calls the provenance lookup for the given identifiers and updates
  /// `provenanceMap`. On failure, clears the map and logs (R3.5).
  private func loadProvenance(for identifiers: [String]) async {
    // Short-circuit: no reminders → no network call needed.
    guard !identifiers.isEmpty else {
      provenanceMap = [:]
      return
    }

    do {
      let tasks = try await provenanceLookup(identifiers)
      provenanceMap = Self.buildProvenanceMap(from: tasks)
    } catch {
      logger.error("provenance lookup failed: \(error, privacy: .public)")
      provenanceMap = [:]
    }
  }

  // MARK: - Provenance map builder (R3.2)

  /// Builds a `[calendarItemIdentifier: memoryID]` map from a list of `TaskDTO`s.
  ///
  /// Tasks without an `eventkitIdentifier` are skipped.
  static func buildProvenanceMap(from tasks: [TaskDTO]) -> [String: UUID] {
    var map = [String: UUID]()
    for task in tasks {
      guard let ekID = task.eventkitIdentifier else { continue }
      map[ekID] = task.memoryID
    }
    return map
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
