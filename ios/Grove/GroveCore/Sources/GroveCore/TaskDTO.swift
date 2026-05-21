import Foundation

// MARK: - TaskDTO

/// A single extracted task from a Grove memory.
///
/// Returned by `GET /v1/tasks` (the server-native task list endpoint).
///
/// Fields mirror `TaskSchema` on the server (`grove/schemas/task.py`):
///   - `id`, `memoryID`, `description`, `dueDate`, `status`, `relatedPeople`
///
/// `dueDate` is a server-formatted date string (`"YYYY-MM-DD"`) rather than a
/// `Date`, because the server stores only the date component (no time, no
/// timezone). Callers that need a `DateComponents` value for EventKit should
/// use `dueDateComponents`.
///
/// The server may still include `eventkit_identifier` / `eventkit_linked_at` in
/// responses during the Part 3 → Part 4 transition window — Swift's `Codable`
/// default behaviour ignores unknown keys, so no decoder configuration is needed.
public struct TaskDTO: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let memoryID: UUID
  public let description: String
  /// Date-only string in `"YYYY-MM-DD"` format, or nil if no due date was set.
  public let dueDate: String?
  /// `"open"` in V1, or `nil` when the enricher has not yet populated this field.
  public let status: String?
  /// Names of people related to this task, or `nil` when not yet enriched.
  public let relatedPeople: [String]?

  public init(
    id: UUID,
    memoryID: UUID,
    description: String,
    dueDate: String?,
    status: String?,
    relatedPeople: [String]?
  ) {
    self.id = id
    self.memoryID = memoryID
    self.description = description
    self.dueDate = dueDate
    self.status = status
    self.relatedPeople = relatedPeople
  }

  public enum CodingKeys: String, CodingKey {
    case id
    case memoryID = "memory_id"
    case description
    case dueDate = "due_date"
    case status
    case relatedPeople = "related_people"
  }

  // MARK: - Derived helpers

  /// Returns `DateComponents` (year, month, day only) parsed from `dueDate`,
  /// or nil if `dueDate` is nil or unparseable.
  ///
  /// Use this when creating an `EKReminder` via EventKit — reminders accept
  /// `DateComponents` for due date, not a `Date`, which avoids timezone drift
  /// for date-only values.
  public var dueDateComponents: DateComponents? {
    guard let dueDate else { return nil }
    // Server format is ISO 8601 date-only: "YYYY-MM-DD".
    let parts = dueDate.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var comps = DateComponents()
    comps.year = parts[0]
    comps.month = parts[1]
    comps.day = parts[2]
    return comps
  }
}

