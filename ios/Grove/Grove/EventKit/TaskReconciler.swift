import Foundation
import GroveCore

// MARK: - TaskReconciler

/// Reconciles locally-created Apple Reminders with server `tasks` rows.
///
/// ## When to call
///
/// Call `reconcile(tasks:)` whenever the app receives a memory body that
/// includes a `tasks` array — for example after `GET /v1/memories/{id}` or
/// in a memory-detail refresh. The reconciler checks each task against the
/// pending-reminder store and fires `PATCH /v1/tasks/{id}` for any match.
///
/// ## Failure handling
///
/// - **200 OK** — PATCH succeeded; entry removed from the local store.
/// - **409 Conflict** — task already linked (shouldn't happen in this V1 flow,
///   but defend against it). Entry is removed; the server is authoritative.
/// - **404 Not Found** — task row vanished; entry is retained for a future
///   retry. Do not lose the reminder identifier on a transient/delayed response.
/// - **Other errors** — entry is retained.
///
/// ## Thread-safety
///
/// `@MainActor` because `PendingReminderStoring` is `@MainActor`. The PATCH
/// calls cross actor boundaries via async await on the background session.
@MainActor
final class TaskReconciler {

  // MARK: - Dependencies

  private let pendingStore: any PendingReminderStoring

  /// Async closure that calls `PATCH /v1/tasks/{id}`.
  ///
  /// Production code wires to `GroveAPI.shared.patchTaskEventKit`.
  /// Tests inject a stub closure to avoid a live network.
  var patchProvider: (UUID, String) async throws -> TaskDTO

  // MARK: - Init

  init(
    pendingStore: any PendingReminderStoring,
    patchProvider: ((UUID, String) async throws -> TaskDTO)? = nil
  ) {
    self.pendingStore = pendingStore
    self.patchProvider = patchProvider ?? { taskID, identifier in
      try await GroveAPI.shared.patchTaskEventKit(
        taskID: taskID,
        eventkitIdentifier: identifier
      )
    }
  }

  // MARK: - Reconcile

  /// Check each task in the given array against the pending-reminder store.
  ///
  /// For each `TaskDTO` whose `memoryID` has a pending entry, fire the PATCH
  /// and handle the response as described in the class-level comment.
  ///
  /// - Parameter tasks: The tasks array from a memory body. Typically contains
  ///   exactly one item for captures tagged with `client_intent: "task"`.
  func reconcile(tasks: [TaskDTO]) async {
    for task in tasks {
      guard let entry = pendingStore.entry(for: task.memoryID) else {
        // No pending reminder for this task's memory — nothing to reconcile.
        continue
      }

      // Skip tasks that are already linked on the server side.
      guard task.eventkitIdentifier == nil else {
        // Already linked — remove the local entry so we don't re-attempt.
        pendingStore.remove(memoryID: task.memoryID)
        continue
      }

      do {
        _ = try await patchProvider(task.id, entry.calendarItemIdentifier)
        // 200 OK — remove the entry.
        pendingStore.remove(memoryID: task.memoryID)
        print("[reconciler] linked task \(task.id) to reminder \(entry.calendarItemIdentifier)")
      } catch let e as TaskLinkingError {
        switch e {
        case .alreadyLinked:
          // 409 — server is right, remove the entry.
          pendingStore.remove(memoryID: task.memoryID)
          print("[reconciler] 409 for task \(task.id) — removing entry, server is authoritative")
        default:
          // Other TaskLinkingError — retain.
          print("[reconciler] TaskLinkingError for task \(task.id): \(e) — retaining entry")
        }
      } catch let e as APIError {
        if case .httpError(let code, _) = e, code == 404 {
          // 404 — retain; the task row may appear later.
          print("[reconciler] 404 for task \(task.id) — retaining entry for retry")
        } else {
          // Other API errors (5xx, network) — retain.
          print("[reconciler] APIError for task \(task.id): \(e) — retaining entry")
        }
      } catch {
        // Unknown error — retain.
        print("[reconciler] unknown error for task \(task.id): \(error) — retaining entry")
      }
    }
  }
}
