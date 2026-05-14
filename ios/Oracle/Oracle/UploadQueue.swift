import Foundation
import SwiftData
import OracleCore

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
///    `OracleApp.init()` also calls it on every launch to sweep rows left from
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
/// # Retry policy
///
/// `drainRow` distinguishes between permanent and transient failures:
///
/// - **4xx (including 401/403):** The payload or credentials are bad and won't
///   improve with retries. The row is deleted immediately and a warning is logged.
/// - **5xx, network errors, and other transients:** `attemptCount` is incremented
///   and the row is kept for the next drain. Once `attemptCount` reaches
///   `maxAttempts` the row is deleted to prevent infinite retry loops.
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

  // MARK: - Retry policy

  /// Maximum number of drain attempts before a row is deleted.
  ///
  /// After `maxAttempts` consecutive failures the row is treated as permanently
  /// unsalvageable and removed from the queue. This prevents malformed payloads
  /// or unrecoverable server-side rejections from retrying indefinitely.
  ///
  /// Note: 4xx responses trigger immediate deletion regardless of this cap.
  private let maxAttempts = 10

  // MARK: - Drain guard

  /// Guards against redundant concurrent drain calls.
  ///
  /// At launch, `OracleApp.init()` enqueues an eager `Task { await tryDrain() }`
  /// and `NWPathMonitor` may fire a `.satisfied` callback before that task
  /// completes (if the device is already connected). Without this guard both
  /// callers would snapshot the same pending rows, post each one twice, and rely
  /// on `ON CONFLICT DO NOTHING` to absorb the duplicates. The guard eliminates
  /// the extra network round-trips.
  ///
  /// Actor isolation serialises reads and writes to this property; no atomic
  /// wrapper is needed.
  private var isDraining = false

  // MARK: - Test hooks

  /// Called once per row after every drain-row completion path (success,
  /// transient failure, permanent failure, retry-cap eviction, decode error).
  ///
  /// Production code never sets this. Tests inject it to synchronise on drain
  /// completion without `Task.sleep`. Declared `internal` so `@testable import`
  /// can reach it; the `nonisolated(unsafe)` annotation is safe because the
  /// property is written by the test before the drain Task starts and read only
  /// within the actor-isolated `drainRow` — no concurrent writes occur.
  nonisolated(unsafe) var onDrainRowComplete: ((Result<Void, Error>) -> Void)?

  /// Called each time `modelContext.save()` is invoked inside `drainRow`.
  ///
  /// Production code never sets this. Tests can inject a counter closure to
  /// assert that `drainRow` performs exactly one SwiftData write per call,
  /// even on the retry-cap eviction path.
  nonisolated(unsafe) var onModelContextSave: (() -> Void)?

  /// Actor-isolated setter for `onModelContextSave`, for use from async test
  /// contexts where direct property assignment is not available.
  func setOnModelContextSave(_ handler: (() -> Void)?) {
    onModelContextSave = handler
  }

  // MARK: - Init

  /// Create an `UploadQueue` backed by the provided model container and API.
  ///
  /// - Parameters:
  ///   - modelContainer: The `ModelContainer` whose concurrency domain backs
  ///     this actor's serial executor (provided via the `@ModelActor` macro).
  ///   - api: The `OracleAPI` instance used to post captures.
  public init(modelContainer: ModelContainer, api: OracleAPI) {
    let context = ModelContext(modelContainer)
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    self.modelContainer = modelContainer
    self.api = api
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

    for row in rows {
      await drainRow(row)
    }
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
      onModelContextSave?()
      onDrainRowComplete?(.failure(error))
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
      onModelContextSave?()
      print("[UploadQueue] drained clientID=\(row.clientID)")
      onDrainRowComplete?(.success(()))
    } catch {
      // Distinguish permanent (4xx) from transient (5xx / network) failures.
      if isPermanentFailure(error) {
        // Permanent failure — delete immediately, no retry.
        let description = String(error.localizedDescription.prefix(256))
        print("[UploadQueue] WARN permanent failure (4xx) clientID=\(row.clientID) error=\(description) — deleting")
        modelContext.delete(row)
        try? modelContext.save()
        onModelContextSave?()
        onDrainRowComplete?(.failure(error))
      } else {
        // Transient failure — check cap before deciding whether to bump+keep or delete.
        // Truncate to 256 chars to avoid unbounded growth.
        let description = String(error.localizedDescription.prefix(256))
        let prospectiveCount = row.attemptCount + 1

        if prospectiveCount >= maxAttempts {
          // Cap reached on this attempt: skip the bump+save and go straight to
          // deletion. This collapses what was two consecutive saves into one.
          print("[UploadQueue] drain failed clientID=\(row.clientID) attempt=\(prospectiveCount) error=\(description)")
          print("[UploadQueue] WARN retry cap reached clientID=\(row.clientID) attempt=\(prospectiveCount) lastError=\(description) — deleting")
          modelContext.delete(row)
          try? modelContext.save()
          onModelContextSave?()
          onDrainRowComplete?(.failure(error))
        } else {
          // Below cap — bump attemptCount, persist, and leave the row for the next drain.
          row.attemptCount = prospectiveCount
          row.lastError = description
          try? modelContext.save()
          onModelContextSave?()
          print("[UploadQueue] drain failed clientID=\(row.clientID) attempt=\(row.attemptCount) error=\(description)")
          onDrainRowComplete?(.failure(error))
        }
      }
    }
  }

  // MARK: - Retry-policy helpers

  /// Returns `true` when `error` indicates a permanent failure that should not
  /// be retried. A permanent failure causes the queued row to be deleted
  /// immediately rather than kept for the next drain.
  ///
  /// # Status-code mapping
  ///
  /// | Status | Treatment | Rationale |
  /// |--------|-----------|-----------|
  /// | 4xx (except 408, 429) | permanent | Bad payload or credentials; retrying won't help |
  /// | 401, 403 | permanent | Invalid bearer token in V1 |
  /// | 408 | transient | Request timeout — transient |
  /// | 429 | transient | Rate-limited — transient |
  /// | 5xx | transient | Server-side error — transient |
  /// | Non-HTTP (URLError, etc.) | transient | Network layer error — transient |
  private func isPermanentFailure(_ error: Error) -> Bool {
    guard case .httpError(let statusCode, _) = error as? APIError else {
      // Non-APIError (URLError, decode failure, etc.) — treat as transient.
      return false
    }
    // 408 Request Timeout and 429 Too Many Requests are transient.
    if statusCode == 408 || statusCode == 429 {
      return false
    }
    // All other 4xx (including 401, 403, 400, 422, …) are permanent.
    return statusCode >= 400 && statusCode < 500
  }
}
