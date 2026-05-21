import Foundation
import GroveCore
import os

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

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.markdlabrecque.grove",
    category: "reconciler"
  )

  private let pendingStore: any PendingReminderStoring

  /// Async closure that calls `PATCH /v1/tasks/{id}`.
  ///
  /// Production code wires to `GroveAPI.shared.patchTaskEventKit`.
  /// Tests inject a stub closure to avoid a live network.
  var patchProvider: (UUID, String) async throws -> TaskDTO

  /// Async closure that calls `GET /v1/tasks?memory_ids=…`.
  ///
  /// Production code wires to `GroveAPI.shared.listTasksByMemoryIDs`.
  /// Tests inject a stub closure to avoid a live network.
  var listTasksProvider: ([UUID]) async throws -> [TaskDTO]

  // MARK: - Init

  init(
    pendingStore: any PendingReminderStoring,
    patchProvider: ((UUID, String) async throws -> TaskDTO)? = nil,
    listTasksProvider: (([UUID]) async throws -> [TaskDTO])? = nil
  ) {
    self.pendingStore = pendingStore
    self.patchProvider = patchProvider ?? { taskID, identifier in
      try await GroveAPI.shared.patchTaskEventKit(
        taskID: taskID,
        eventkitIdentifier: identifier
      )
    }
    self.listTasksProvider = listTasksProvider ?? { memoryIDs in
      try await GroveAPI.shared.listTasksByMemoryIDs(memoryIDs)
    }
  }

  // MARK: - Foreground sweep

  /// Fetch all pending-reminder entries from the store, batch-fetch their
  /// corresponding server tasks, and reconcile.
  ///
  /// Called on `scenePhase == .active` so tasks whose memory the user has never
  /// navigated to (e.g. captured offline, enriched in the background) are still
  /// linked without relying on `TaskRowView.onAppear`.
  ///
  /// Early-return when the store is empty — avoids a network call when there is
  /// nothing to do (the common case after all pending reminders are resolved).
  func reconcileAllPending() async {
    let entries = pendingStore.all()
    guard !entries.isEmpty else { return }

    let memoryIDs = entries.map { $0.memoryID }
    do {
      let tasks = try await listTasksProvider(memoryIDs)
      await reconcile(tasks: tasks)
    } catch {
      logger.error("reconcileAllPending failed to fetch tasks: \(error, privacy: .public)")
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
        logger.info("linked task \(task.id, privacy: .public) to reminder \(entry.calendarItemIdentifier, privacy: .public)")
      } catch let e as TaskLinkingError {
        switch e {
        case .alreadyLinked:
          // 409 — server is right, remove the entry.
          pendingStore.remove(memoryID: task.memoryID)
          logger.info("409 for task \(task.id, privacy: .public) — removing entry, server is authoritative")
        default:
          // Other TaskLinkingError — retain.
          logger.error("TaskLinkingError for task \(task.id, privacy: .public): \(e, privacy: .public) — retaining entry")
        }
      } catch let e as APIError {
        if case .httpError(let code, _) = e, code == 404 {
          // 404 — retain; the task row may appear later.
          logger.info("404 for task \(task.id, privacy: .public) — retaining entry for retry")
        } else {
          // Other API errors (5xx, network) — retain.
          logger.error("APIError for task \(task.id, privacy: .public): \(e, privacy: .public) — retaining entry")
        }
      } catch {
        // Unknown error — retain.
        logger.error("unknown error for task \(task.id, privacy: .public): \(error, privacy: .public) — retaining entry")
      }
    }
  }
}
