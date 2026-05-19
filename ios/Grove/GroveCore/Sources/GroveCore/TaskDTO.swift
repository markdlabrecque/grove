import Foundation

// MARK: - TaskDTO

/// A single extracted task from a Grove memory.
///
/// Returned by `GET /v1/memories/{id}` (embedded in `TaskSchema`) and by
/// `PATCH /v1/tasks/{id}` (the full updated row after EventKit linking).
///
/// Fields mirror `TaskSchema` on the server (grove/schemas/task.py):
///   - `id`, `memoryID`, `description`, `dueDate`, `status`, `relatedPeople`
///     are present in V1.
///   - `eventkitIdentifier`, `eventkitLinkedAt` are added in #391.
///
/// `dueDate` is a server-formatted date string (`"YYYY-MM-DD"`) rather than a
/// `Date`, because the server stores only the date component (no time, no
/// timezone). Callers that need a `DateComponents` value for EventKit should
/// use `dueDateComponents`.
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
  /// The `calendarItemIdentifier` of the linked `EKReminder`, or nil if not yet linked.
  public let eventkitIdentifier: String?
  /// ISO 8601 string of when the EventKit link was created, or nil.
  public let eventkitLinkedAt: String?

  public init(
    id: UUID,
    memoryID: UUID,
    description: String,
    dueDate: String?,
    status: String?,
    relatedPeople: [String]?,
    eventkitIdentifier: String?,
    eventkitLinkedAt: String?
  ) {
    self.id = id
    self.memoryID = memoryID
    self.description = description
    self.dueDate = dueDate
    self.status = status
    self.relatedPeople = relatedPeople
    self.eventkitIdentifier = eventkitIdentifier
    self.eventkitLinkedAt = eventkitLinkedAt
  }

  public enum CodingKeys: String, CodingKey {
    case id
    case memoryID = "memory_id"
    case description
    case dueDate = "due_date"
    case status
    case relatedPeople = "related_people"
    case eventkitIdentifier = "eventkit_identifier"
    case eventkitLinkedAt = "eventkit_linked_at"
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

// MARK: - TaskLinkingError

/// Errors specific to the EventKit-linking flow for tasks.
public enum TaskLinkingError: Error, LocalizedError, Equatable {
  /// The task is already linked to a different `EKReminder`.
  ///
  /// Thrown by `GroveAPI.patchTaskEventKit` when the server returns 409.
  /// The associated value is the `existing_identifier` from the 409 body —
  /// callers should self-heal by adopting this identifier instead of the one
  /// they attempted to write.
  case alreadyLinked(existingIdentifier: String)

  /// The EventKit permission request was denied by the user.
  case permissionDenied

  /// The `EKReminder` save failed (EventKit-level error).
  case saveFailed

  /// The reminder lookup returned nil — the user deleted the reminder in
  /// the Reminders app.
  case reminderDeleted

  public var errorDescription: String? {
    switch self {
    case .alreadyLinked:
      return "This task is already linked to an Apple Reminder."
    case .permissionDenied:
      return "Grove needs access to Reminders to create tasks. Enable Reminders access in Settings."
    case .saveFailed:
      return "Could not save the reminder. Please try again."
    case .reminderDeleted:
      return "The linked reminder was deleted in the Reminders app."
    }
  }
}
