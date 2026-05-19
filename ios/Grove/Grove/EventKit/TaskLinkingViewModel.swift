import Foundation
import GroveCore

/// View state and logic for linking a `TaskDTO` to an Apple Reminder via EventKit.
///
/// ## Lifecycle
///
/// One instance is created per task row that is rendered in Ask results or the
/// memory detail view. It holds the live `TaskDTO` (updated in place after a
/// successful PATCH) and drives the "Create Reminder" / status-display UI.
///
/// ## State machine
///
/// ```
/// unlinked → [user taps "Create Reminder"]
///   → requesting EventKit permission
///     → denied → show error (stays unlinked)
///   → creating EKReminder
///     → save failed → show error (stays unlinked)
///   → PATCH /v1/tasks/{id}
///     → 200 → linked (update task.eventkitIdentifier)
///     → 409 → self-heal: adopt existing_identifier → linked
///     → 404/422/other → show error (stays unlinked)
/// ```
///
/// ## Dependency injection
///
/// - `eventKitProvider`: mockable boundary around `EKEventStore`. Production
///   code uses `LiveEventKitProvider`. Tests inject `StubEventKitProvider`.
/// - `patchProvider`: async closure that calls `GroveAPI.patchTaskEventKit`.
///   Default wires to the live API. Tests inject a stub.
@Observable
@MainActor
final class TaskLinkingViewModel {

  // MARK: - State

  /// The current task data. Updated in place after a successful PATCH or
  /// 409 self-heal so the view reflects the server's current state.
  private(set) var task: TaskDTO

  /// `true` while an EventKit permission request or reminder-save or PATCH is
  /// in flight.
  private(set) var isCreatingReminder: Bool = false

  /// Non-nil when an error occurred during the link flow. The view surfaces
  /// this as an inline error label. Cleared on the next `createReminder()` call.
  private(set) var linkError: String? = nil

  /// Live completion state fetched from EventKit at render time.
  ///
  /// `nil` — task is unlinked, or lookup not yet attempted.
  /// `false` — linked, reminder exists, not yet completed.
  /// `true` — linked, reminder exists, completed in Reminders.
  private(set) var reminderCompleted: Bool? = nil

  // MARK: - Computed

  var isLinked: Bool { task.eventkitIdentifier != nil }

  // MARK: - Dependencies

  private var eventKitProvider: any EventKitProviding
  var patchProvider: (UUID, String) async throws -> TaskDTO

  // MARK: - Init

  init(
    task: TaskDTO,
    eventKitProvider: (any EventKitProviding)? = nil,
    patchProvider: ((UUID, String) async throws -> TaskDTO)? = nil
  ) {
    self.task = task
    self.eventKitProvider = eventKitProvider ?? LiveEventKitProvider()
    self.patchProvider = patchProvider ?? { taskID, identifier in
      try await GroveAPI.shared.patchTaskEventKit(
        taskID: taskID,
        eventkitIdentifier: identifier
      )
    }
  }

  // MARK: - Actions

  /// Tapped "Create Reminder". Runs the full permission → create → PATCH flow.
  func createReminder() async {
    guard !isCreatingReminder else { return }
    isCreatingReminder = true
    linkError = nil

    // 1. Permission.
    let granted = await eventKitProvider.requestAccess()
    guard granted else {
      isCreatingReminder = false
      linkError = TaskLinkingError.permissionDenied.localizedDescription
      return
    }

    // 2. Create EKReminder.
    let identifier: String
    do {
      identifier = try await eventKitProvider.createReminder(
        title: task.description,
        dueDateComponents: task.dueDateComponents
      )
    } catch {
      isCreatingReminder = false
      linkError = TaskLinkingError.saveFailed.localizedDescription
      return
    }

    // 3. PATCH the server.
    do {
      let updated = try await patchProvider(task.id, identifier)
      task = updated
      reminderCompleted = eventKitProvider.fetchCompletion(
        for: updated.eventkitIdentifier ?? identifier
      )
    } catch let e as TaskLinkingError {
      if case .alreadyLinked(let existingID) = e {
        // 409 self-heal: the server already has a different identifier.
        // Adopt it so our local state matches the server.
        task = TaskDTO(
          id: task.id,
          memoryID: task.memoryID,
          description: task.description,
          dueDate: task.dueDate,
          status: task.status,
          relatedPeople: task.relatedPeople,
          eventkitIdentifier: existingID,
          eventkitLinkedAt: task.eventkitLinkedAt
        )
        reminderCompleted = eventKitProvider.fetchCompletion(for: existingID)
      } else {
        linkError = e.localizedDescription
      }
    } catch {
      linkError = error.localizedDescription
    }

    isCreatingReminder = false
  }

  /// Refresh the live completion state from EventKit.
  ///
  /// Call this when the view appears or comes back to the foreground. It is a
  /// no-op when the task is unlinked. If the reminder was deleted from the
  /// Reminders app, `reminderCompleted` is set to nil and `linkError` is set
  /// to the "Reminder deleted" description.
  func refreshCompletionStatus() {
    guard let identifier = task.eventkitIdentifier else {
      reminderCompleted = nil
      return
    }
    let result = eventKitProvider.fetchCompletion(for: identifier)
    reminderCompleted = result
    if result == nil {
      // nil means the identifier no longer resolves — user deleted the reminder.
      linkError = TaskLinkingError.reminderDeleted.localizedDescription
    }
  }
}
