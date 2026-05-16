import Foundation
import SwiftData
import OracleCore

// MARK: - UploadQueueTestHooks

/// Test-only callbacks for observing internal `UploadQueue` events.
///
/// Production code never populates this struct. Tests assign an instance to
/// `UploadQueue.testHooks` before triggering any actor work. All hooks are
/// read exclusively from within the actor's serial executor (`drainRow`), and
/// tests never mutate `testHooks` concurrently — the `nonisolated(unsafe)`
/// annotation on the containing property is therefore safe.
internal struct UploadQueueTestHooks {
  /// Called once per row after every drain-row completion path (success,
  /// transient failure, permanent failure, retry-cap eviction, decode error).
  /// Inject to synchronise on drain completion without `Task.sleep`.
  var onDrainRowComplete: ((Result<Void, Error>) -> Void)?

  /// Called each time `modelContext.save()` is invoked inside `drainRow`.
  /// Inject a counter closure to assert that `drainRow` performs exactly one
  /// SwiftData write per call, even on the retry-cap eviction path.
  var onModelContextSave: (() -> Void)?
}

// MARK: - UploadQueue

/// A `@ModelActor` that provides a durable, offline-safe queue for capture uploads.
///
/// # Lifecycle
///
/// 1. `CaptureViewModel` calls `enqueue(clientID:payload:)` at save time — before
///    any network call. The row is inserted synchronously (relative to the actor's
///    serial executor) and the local UI confirms save.
/// 2. `tryDrain()` iterates pending rows and calls `OracleAPI.postCapture` for
///    each. On success the row is deleted immediately. On failure the row is kept
///    with `attemptCount` and `lastError` updated, subject to the retry cap.
/// 3. `NWPathMonitor` calls `tryDrain()` whenever connectivity is re-established.
///    `GroveApp.init()` also calls it on every launch to sweep rows left from
///    previous sessions.
///
/// # Concurrency
///
/// `@ModelActor` gives `UploadQueue` its own serial executor backed by SwiftData's
/// model-concurrency domain. The macro provides `modelContext` and `modelExecutor`
/// automatically; there is no explicit `ModelContext` property. All `ModelContext`
/// access is therefore properly isolated without any `MainActor`-bridging hops.
///
/// # Idempotency on retry
///
/// The server enforces `UNIQUE(client_id)` with `ON CONFLICT DO NOTHING`. Every
/// retry of the same row is a no-op on the server side; the client receives a
/// 200 response for an already-stored capture. This means `tryDrain` can safely
/// retry rows any number of times without risk of duplicates.
///
/// Reference: `server/oracle/api/captures.py` — idempotency pre-check plus
/// `insert().on_conflict_do_nothing(index_elements=["client_id"])`.
///
/// # Retry policy (#186)
///
/// `drainRow` distinguishes between four failure categories:
///
/// - **401 Unauthorized:** The bearer token is invalid or expired.  The row is
///   marked `isAuthRequired = true` and skipped by future drains until the user
///   provides a new token via `reenqueueAuthRequired(newToken:)`.
/// - **Other 4xx (400, 403, 404, 409, 422 …):** The payload is permanently
///   rejected by the server.  The row transitions to `isFailed = true` with
///   the server error stored in `lastError`.  It is skipped by `tryDrain` until
///   the user manually retries or discards it from the debug screen.
/// - **5xx + network errors:** Transient failures.  `attemptCount` is incremented,
///   `nextAttemptAt` is set using `BackoffScheduler` (base 5s, doubling, capped
///   at 1h), and the row is kept.  `tryDrain` skips rows whose `nextAttemptAt`
///   is still in the future.  There is no maximum-attempt cap — the row stays
///   in `pending` indefinitely until it succeeds or the user discards it from
///   the debug screen.
/// - **Decode errors (malformed stored payload):** Treated as a permanent error;
///   the row is deleted immediately.
@ModelActor
public actor UploadQueue {

  // MARK: - Dependencies

  /// The API client used to post captures to the server.
  ///
  /// Declared `nonisolated(unsafe)` so that the `@ModelActor` macro's generated
  /// `init(modelContainer:)` compiles without needing to initialise this property.
  /// The property is written once during `init` before any concurrent access is
  /// possible, so the `unsafe` annotation is safe here.
  nonisolated(unsafe) private var api: OracleAPI!

  // MARK: - Drain guard

  /// Guards against redundant concurrent drain calls.
  ///
  /// At launch, `GroveApp.init()` enqueues an eager `Task { await tryDrain() }`
  /// and `NWPathMonitor` may fire a `.satisfied` callback before that task
  /// completes (if the device is already connected). Without this guard both
  /// callers would snapshot the same pending rows, post each one twice, and rely
  /// on `ON CONFLICT DO NOTHING` to absorb the duplicates. The guard eliminates
  /// the extra network round-trips.
  ///
  /// Actor isolation serialises reads and writes to this property; no atomic
  /// wrapper is needed.
  private var isDraining = false

  // MARK: - Token tracking (idempotency for auth_required re-enqueue)

  /// The bearer token the queue currently uses when posting captures.
  ///
  /// Kept in sync with `OracleAPI` via `updateToken(_:)`. Stored here so
  /// `drainRow` can record which token produced a 401, and so
  /// `reenqueueAuthRequired(newToken:)` can compare the incoming token against
  /// `lastKnownBadToken` without crossing the `OracleAPI` actor boundary.
  ///
  /// `nonisolated(unsafe)` for the same reason as `api` — written once during
  /// `init` before concurrent access begins; subsequently mutated only from
  /// within the actor's serial executor.
  nonisolated(unsafe) private var currentToken: String = ""

  /// The most recent bearer token value that produced a 401 from the server.
  ///
  /// `reenqueueAuthRequired(newToken:)` compares `newToken` against this value
  /// before clearing `isAuthRequired` flags.  If they are equal the caller
  /// supplied the same credential that already failed — the re-enqueue is
  /// skipped so rows do not loop: auth_required → re-enqueue → 401 → auth_required
  /// → re-enqueue → … indefinitely.
  ///
  /// Reset to `nil` by `reenqueueAuthRequired` after a successful clear.
  private var lastKnownBadToken: String? = nil

  /// Update the bearer token tracked by this queue.
  ///
  /// Called by `GroveApp` after `OracleAPI.shared.updateCredentials` succeeds,
  /// so the queue always knows the live token value for idempotency comparison
  /// in `reenqueueAuthRequired`.
  public func updateToken(_ token: String) {
    currentToken = token
  }

  // MARK: - Test hooks

  /// Callbacks injected by tests to observe internal `drainRow` events.
  ///
  /// Production code never sets `testHooks`. Tests assign a populated struct
  /// before triggering any actor work and never mutate it concurrently —
  /// the actor reads the hooks only from within its serial executor, so the
  /// `nonisolated(unsafe)` annotation is safe here.
  nonisolated(unsafe) var testHooks: UploadQueueTestHooks?

  /// Actor-isolated setter for `testHooks`, for use from async test contexts
  /// where direct property assignment is not available.
  func setTestHooks(_ hooks: UploadQueueTestHooks?) {
    testHooks = hooks
  }

  // MARK: - Init

  /// Create an `UploadQueue` backed by the provided model container and API.
  ///
  /// - Parameters:
  ///   - modelContainer: The `ModelContainer` whose concurrency domain backs
  ///     this actor's serial executor (provided via the `@ModelActor` macro).
  ///   - api: The `OracleAPI` instance used to post captures.
  public init(modelContainer: ModelContainer, api: OracleAPI, initialToken: String = "") {
    let context = ModelContext(modelContainer)
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    self.modelContainer = modelContainer
    self.api = api
    self.currentToken = initialToken
  }

  // MARK: - Enqueue

  /// Insert a new row into the persistent queue.
  ///
  /// This is the only mutation that throws — if SwiftData cannot save (e.g. disk
  /// full), the caller learns about it. All other mutations swallow errors to
  /// ensure a single bad row never blocks the queue.
  public func enqueue(clientID: String, payload: Data) throws {
    let row = QueuedCapture(clientID: clientID, payload: payload)
    modelContext.insert(row)
    try modelContext.save()
  }

  // MARK: - Pending count

  /// Return the number of rows currently in the queue.
  ///
  /// Used by tests and may be surfaced in a future debug UI.
  public func pendingCount() throws -> Int {
    let descriptor = FetchDescriptor<QueuedCapture>()
    return try modelContext.fetchCount(descriptor)
  }

  // MARK: - Drain

  /// Attempt to upload every pending row to the server.
  ///
  /// - Iterates all `QueuedCapture` rows in insertion order (by `createdAt`).
  /// - Rows with `isAuthRequired == true` are **skipped** — they are waiting
  ///   for a credential update via `reenqueueAuthRequired(newToken:)`.
  /// - On success (the server returns 200 or 201): deletes the row immediately.
  /// - On failure: increments `attemptCount` and sets `lastError`; the row stays
  ///   for the next drain. One bad row never blocks subsequent rows.
  ///
  /// This method never throws. All errors are absorbed per-row so a network
  /// disruption mid-drain does not unwind work already completed.
  ///
  /// Concurrent callers receive a fast no-op return while a drain is already
  /// in flight. See `isDraining`.
  public func tryDrain() async {
    guard !isDraining else { return }
    isDraining = true
    defer { isDraining = false }

    let rows: [QueuedCapture]
    do {
      var descriptor = FetchDescriptor<QueuedCapture>(
        sortBy: [SortDescriptor(\.createdAt, order: .forward)]
      )
      descriptor.fetchLimit = 50  // safety cap per drain cycle; queue re-drains on next trigger
      rows = try modelContext.fetch(descriptor)
    } catch {
      print("[UploadQueue] fetch failed: \(error)")
      return
    }

    let now = Date()
    for row in rows {
      // Skip rows waiting for a credential update — they must not be re-uploaded
      // until the user provides a new token via reenqueueAuthRequired(newToken:).
      guard !row.isAuthRequired else {
        print("[UploadQueue] skipping auth_required row clientID=\(row.clientID)")
        continue
      }

      // Skip rows that have permanently failed — user must retry or discard via
      // the debug screen.
      guard !row.isFailed else {
        print("[UploadQueue] skipping failed row clientID=\(row.clientID)")
        continue
      }

      // Skip rows in backoff whose next attempt is still in the future.
      if let nextAttemptAt = row.nextAttemptAt, nextAttemptAt > now {
        print("[UploadQueue] skipping backoff row clientID=\(row.clientID) nextAttemptAt=\(nextAttemptAt)")
        continue
      }

      await drainRow(row)
    }
  }

  // MARK: - Auth-required count

  /// Return the number of rows currently in the `auth_required` state.
  ///
  /// Used by the banner in `RootView` to decide whether to show the
  /// "re-enter your token" prompt, and by tests to assert state-machine
  /// transitions.
  public func authRequiredCount() throws -> Int {
    // Note: SwiftData's `#Predicate` on Bool properties can be unreliable for
    // in-memory stores with newly-added default properties. We fetch all rows
    // and filter in Swift to avoid that edge case.
    let descriptor = FetchDescriptor<QueuedCapture>()
    let rows = try modelContext.fetch(descriptor)
    return rows.filter { $0.isAuthRequired }.count
  }

  // MARK: - Failed count

  /// Return the number of rows currently in the `failed` state (`isFailed == true`).
  ///
  /// Used by the upload-queue debug screen and by tests to assert state-machine
  /// transitions.
  public func failedCount() throws -> Int {
    let descriptor = FetchDescriptor<QueuedCapture>()
    let rows = try modelContext.fetch(descriptor)
    return rows.filter { $0.isFailed }.count
  }

  // MARK: - Manual retry from debug screen

  /// Reset a failed row back to the pending state.
  ///
  /// Clears `isFailed`, `nextAttemptAt`, and `attemptCount` so the row will be
  /// picked up by the next `tryDrain` call.  Persists to SwiftData immediately.
  ///
  /// - Parameter clientID: The `clientID` of the row to retry.
  /// - Throws: If the row is not found or if SwiftData cannot save.
  public func retryFailed(clientID: String) throws {
    let descriptor = FetchDescriptor<QueuedCapture>()
    let rows = try modelContext.fetch(descriptor)
    guard let row = rows.first(where: { $0.clientID == clientID }) else {
      print("[UploadQueue] retryFailed: row not found clientID=\(clientID)")
      return
    }
    row.isFailed = false
    row.nextAttemptAt = nil
    row.attemptCount = 0
    row.lastError = nil
    try modelContext.save()
    print("[UploadQueue] retryFailed: reset row clientID=\(clientID) → pending")
  }

  // MARK: - Manual discard from debug screen

  /// Permanently delete a row from the queue.
  ///
  /// Used by the debug screen's "Discard" action.  The capture will not be
  /// re-uploaded — any server-side state (if it ever reached the server) is
  /// unaffected.
  ///
  /// - Parameter clientID: The `clientID` of the row to discard.
  /// - Throws: If the row is not found or if SwiftData cannot save.
  public func discardFailed(clientID: String) throws {
    let descriptor = FetchDescriptor<QueuedCapture>()
    let rows = try modelContext.fetch(descriptor)
    guard let row = rows.first(where: { $0.clientID == clientID }) else {
      print("[UploadQueue] discardFailed: row not found clientID=\(clientID)")
      return
    }
    modelContext.delete(row)
    try modelContext.save()
    print("[UploadQueue] discardFailed: deleted row clientID=\(clientID)")
  }

  // MARK: - Test helper: set nextAttemptAt directly

  /// Directly set `nextAttemptAt` on a row by clientID.
  ///
  /// Exposed for tests only — allows tests to advance or rewind the backoff
  /// clock without sleeping.  Production code never calls this.
  ///
  /// - Parameters:
  ///   - clientID: The `clientID` of the row to update.
  ///   - date: The new `nextAttemptAt` value.
  /// - Throws: If SwiftData cannot save.
  func setNextAttemptAt(clientID: String, date: Date) throws {
    let descriptor = FetchDescriptor<QueuedCapture>()
    let rows = try modelContext.fetch(descriptor)
    guard let row = rows.first(where: { $0.clientID == clientID }) else { return }
    row.nextAttemptAt = date
    try modelContext.save()
  }

  // MARK: - Re-enqueue after token update

  /// Clear the `isAuthRequired` flag on all qualifying rows and trigger a
  /// drain sweep — but only when `newToken` differs from the last known bad
  /// token.
  ///
  /// # Idempotency
  ///
  /// If `newToken` equals `lastKnownBadToken` (the value that caused the
  /// original 401), this method is a no-op.  This prevents an infinite loop:
  ///
  ///   auth_required → re-enqueue (same bad token) → 401 → auth_required → …
  ///
  /// # Trigger
  ///
  /// Called by `SettingsViewModel.commitToken()` (via the `onCredentialUpdate`
  /// closure set in `GroveApp`) after the user saves a new token in Settings
  /// and the Keychain has been updated.  Also called from the
  /// `credentialsDidUpdate` notification observer wired in `GroveApp`.
  ///
  /// - Parameter newToken: The new bearer token value that has just been
  ///   written to the Keychain and pushed to `OracleAPI.shared`.
  public func reenqueueAuthRequired(newToken: String) async {
    // Idempotency check — same bad token means nothing will change.
    if newToken == lastKnownBadToken {
      print("[UploadQueue] reenqueueAuthRequired: token unchanged (\(newToken.prefix(8))…), skipping")
      return
    }

    // Clear isAuthRequired on all flagged rows.
    // Note: We fetch all rows and filter in Swift rather than using a
    // SwiftData #Predicate on `isAuthRequired`, because Bool predicates on
    // in-memory stores with additive default properties can be unreliable.
    let rows: [QueuedCapture]
    do {
      let descriptor = FetchDescriptor<QueuedCapture>()
      let all = try modelContext.fetch(descriptor)
      rows = all.filter { $0.isAuthRequired }
    } catch {
      print("[UploadQueue] reenqueueAuthRequired: fetch failed: \(error)")
      return
    }

    guard !rows.isEmpty else {
      print("[UploadQueue] reenqueueAuthRequired: no auth_required rows to clear")
      return
    }

    for row in rows {
      row.isAuthRequired = false
    }
    do {
      try modelContext.save()
    } catch {
      print("[UploadQueue] reenqueueAuthRequired: save failed: \(error)")
      return
    }

    // Clear the bad-token memory now that we have a new credential.
    lastKnownBadToken = nil
    print("[UploadQueue] reenqueueAuthRequired: cleared \(rows.count) row(s), triggering drain")

    // Drain immediately — the new token is already live in OracleAPI.shared
    // because SettingsViewModel called updateCredentials before calling us.
    await tryDrain()
  }

  // MARK: - Reset (tests + debug menu)

  /// Delete all rows in the queue.
  ///
  /// - Note: This is intended for unit tests (in-memory container) and a future
  ///   "Clear Queue" option in a developer debug menu. Do not call in production
  ///   user flows — captures that haven't reached the server will be permanently
  ///   lost.
  public func reset() throws {
    try modelContext.delete(model: QueuedCapture.self)
    try modelContext.save()
  }

  // MARK: - Private helpers

  private func drainRow(_ row: QueuedCapture) async {
    // Decode the stored payload bytes back into a CaptureRequestBody.
    let body: CaptureRequestBody
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      body = try decoder.decode(CaptureRequestBody.self, from: row.payload)
    } catch {
      // Malformed payload — a decode failure is a permanent error; delete immediately.
      let description = String(error.localizedDescription.prefix(256))
      print("[UploadQueue] WARN permanent failure (decode error) clientID=\(row.clientID) error=\(description) — deleting")
      modelContext.delete(row)
      try? modelContext.save()
      testHooks?.onModelContextSave?()
      testHooks?.onDrainRowComplete?(.failure(error))
      return
    }

    let payload = CapturePayload(
      clientID: body.clientID,
      content: body.content,
      sourceModality: body.sourceModality,
      sourceDevice: body.sourceDevice,
      language: body.language,
      capturedAt: body.capturedAt
    )

    do {
      _ = try await api.postCapture(payload)
      // Success — delete eagerly in this actor turn before yielding.
      modelContext.delete(row)
      try modelContext.save()
      testHooks?.onModelContextSave?()
      print("[UploadQueue] drained clientID=\(row.clientID)")
      testHooks?.onDrainRowComplete?(.success(()))
    } catch {
      // 401 is a special case: credentials have expired/changed.
      // Mark the row as auth_required rather than deleting it or treating it
      // as a generic transient failure.  The row will be re-uploaded after the
      // user provides a new token via reenqueueAuthRequired(newToken:).
      if isAuthRequiredError(error) {
        let description = String(error.localizedDescription.prefix(256))
        print("[UploadQueue] 401 auth_required clientID=\(row.clientID) — marking, not deleting")
        row.isAuthRequired = true
        row.lastError = description
        // Record the bad token so reenqueueAuthRequired can detect same-token calls.
        lastKnownBadToken = currentToken
        try? modelContext.save()
        testHooks?.onModelContextSave?()
        testHooks?.onDrainRowComplete?(.failure(error))
        // Post notification so foreground observers (RootView) can show banner.
        NotificationCenter.default.post(name: .authRequiredDidChange, object: nil)
        return
      }

      // Distinguish permanent (non-401 4xx) from transient (5xx / network) failures.
      if isPermanentFailure(error) {
        // Permanent 4xx failure — mark as failed, preserve error, keep for user action.
        // Do NOT delete: the user must explicitly retry or discard from the debug screen.
        let description = errorDescription(error, maxLength: 500)
        print("[UploadQueue] WARN permanent failure (4xx) clientID=\(row.clientID) error=\(description) — marking failed")
        row.isFailed = true
        row.lastError = description
        try? modelContext.save()
        testHooks?.onModelContextSave?()
        testHooks?.onDrainRowComplete?(.failure(error))
      } else {
        // Transient failure (5xx / network error) — increment attempt count,
        // schedule next attempt via exponential backoff, and keep the row.
        // There is no maximum-attempt cap: the row stays in pending indefinitely
        // until it succeeds or the user discards it.
        let description = errorDescription(error, maxLength: 500)
        let prospectiveCount = row.attemptCount + 1
        let delay = BackoffScheduler.delay(forAttempt: prospectiveCount)
        row.attemptCount = prospectiveCount
        row.lastError = description
        row.nextAttemptAt = Date().addingTimeInterval(delay)
        try? modelContext.save()
        testHooks?.onModelContextSave?()
        print("[UploadQueue] drain failed clientID=\(row.clientID) attempt=\(row.attemptCount) delay=\(delay)s error=\(description)")
        testHooks?.onDrainRowComplete?(.failure(error))
      }
    }
  }

  // MARK: - Error description helper

  /// Build a human-readable error description for storage in `lastError`.
  ///
  /// For `APIError.httpError` responses the description leads with the HTTP
  /// status code so the debug screen can surface it clearly, followed by the
  /// server response body (trimmed to `maxLength` to keep SwiftData rows small).
  ///
  /// For all other errors (URLError, decode failures, etc.) the description is
  /// `error.localizedDescription` trimmed to `maxLength`.
  ///
  /// - Parameters:
  ///   - error: The error to describe.
  ///   - maxLength: Maximum character count of the returned string.
  /// - Returns: A non-empty description, at most `maxLength` characters.
  private func errorDescription(_ error: Error, maxLength: Int) -> String {
    if case .httpError(let statusCode, let detail) = error as? APIError {
      let detailText = detail ?? ""
      let combined = "HTTP \(statusCode): \(detailText)"
      return String(combined.prefix(maxLength))
    }
    return String(error.localizedDescription.prefix(maxLength))
  }

  // MARK: - Retry-policy helpers

  /// Returns `true` when `error` is a 401 Unauthorized response.
  ///
  /// A 401 means the bearer token is invalid or expired.  Unlike other 4xx
  /// errors, we do not delete the row immediately — instead we mark it
  /// `isAuthRequired = true` and wait for the user to update the token.
  private func isAuthRequiredError(_ error: Error) -> Bool {
    guard case .httpError(let statusCode, _) = error as? APIError else {
      return false
    }
    return statusCode == 401
  }

  /// Returns `true` when `error` indicates a permanent failure that should
  /// transition the row to `isFailed = true` rather than scheduling a retry.
  ///
  /// Note: 401 is handled separately (before this check) by `isAuthRequiredError`.
  ///
  /// # Status-code mapping
  ///
  /// | Status | Treatment | Rationale |
  /// |--------|-----------|-----------|
  /// | 4xx (except 401, 408, 429) | failed | Bad payload; retrying won't help |
  /// | 401 | auth_required | Handled separately — marks row, does not fail it |
  /// | 403 | failed | Forbidden — retrying won't help in V1 |
  /// | 408 | transient | Request timeout — transient |
  /// | 429 | transient | Rate-limited — transient |
  /// | 5xx | transient | Server-side error — transient |
  /// | Non-HTTP (URLError, etc.) | transient | Network layer error — transient |
  private func isPermanentFailure(_ error: Error) -> Bool {
    guard case .httpError(let statusCode, _) = error as? APIError else {
      // Non-APIError (URLError, decode failure, etc.) — treat as transient.
      return false
    }
    // 401 is handled separately — it is not a "permanent delete" failure.
    if statusCode == 401 { return false }
    // 408 Request Timeout and 429 Too Many Requests are transient.
    if statusCode == 408 || statusCode == 429 { return false }
    // All other 4xx (403, 400, 422, …) are permanent.
    return statusCode >= 400 && statusCode < 500
  }
}

// MARK: - Notification name

extension Notification.Name {
  /// Posted by `UploadQueue.drainRow` when a row transitions to `auth_required`
  /// state (server returned 401).  Observers (e.g. `RootView` via `scenePhase`)
  /// use this to show the "re-enter your token" banner.
  static let authRequiredDidChange = Notification.Name(
    "com.oracle.upload-queue.auth-required-did-change"
  )
}
