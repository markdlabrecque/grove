import Foundation
import SwiftData
import OracleCore

// MARK: - UploadQueue

/// A Swift actor that wraps a SwiftData `ModelContext` to provide a durable,
/// offline-safe queue for capture uploads.
///
/// # Lifecycle
///
/// 1. `CaptureViewModel` calls `enqueue(clientID:payload:)` at save time — before
///    any network call. The row is inserted synchronously (relative to the actor's
///    serial executor) and the local UI confirms save.
/// 2. `tryDrain()` iterates pending rows and calls `OracleAPI.postCapture` for
///    each. On success the row is deleted immediately. On failure the row is kept
///    with `attemptCount` and `lastError` updated.
/// 3. PR 4 will wire `NWPathMonitor` so that `tryDrain()` is called whenever
///    connectivity is re-established. PR 5 wires `CaptureViewModel` and sweeps
///    on launch.
///
/// # Concurrency
///
/// `UploadQueue` is an actor so all `ModelContext` mutations are serialised.
/// SwiftData `ModelContext` is not `Sendable` and must not cross actor boundaries;
/// it is created and used exclusively within this actor.
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
public actor UploadQueue {

  // MARK: - Dependencies

  private let context: ModelContext
  private let api: OracleAPI

  // MARK: - Init

  /// Create an `UploadQueue` backed by the provided model context and API.
  ///
  /// - Parameters:
  ///   - modelContext: A SwiftData `ModelContext` scoped to the caller — the
  ///     actor owns it exclusively and must not be shared with other contexts.
  ///   - api: The `OracleAPI` instance used to post captures.
  public init(modelContext: ModelContext, api: OracleAPI) {
    self.context = modelContext
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
    context.insert(row)
    try context.save()
  }

  // MARK: - Pending count

  /// Return the number of rows currently in the queue.
  ///
  /// Used by tests and may be surfaced in a future debug UI.
  public func pendingCount() throws -> Int {
    let descriptor = FetchDescriptor<QueuedCapture>()
    return try context.fetchCount(descriptor)
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
  public func tryDrain() async {
    let rows: [QueuedCapture]
    do {
      var descriptor = FetchDescriptor<QueuedCapture>(
        sortBy: [SortDescriptor(\.createdAt, order: .forward)]
      )
      descriptor.fetchLimit = 50  // safety cap per drain cycle; queue re-drains on next trigger
      rows = try context.fetch(descriptor)
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
    try context.delete(model: QueuedCapture.self)
    try context.save()
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
      // Malformed payload — cannot retry. Record the error and leave the row.
      row.attemptCount += 1
      row.lastError = "payload decode failed: \(error.localizedDescription)"
      try? context.save()
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
      context.delete(row)
      try context.save()
      print("[UploadQueue] drained clientID=\(row.clientID)")
    } catch {
      // Failure — keep the row, record the error.
      row.attemptCount += 1
      // Truncate to 256 chars to avoid unbounded growth.
      let description = String(error.localizedDescription.prefix(256))
      row.lastError = description
      try? context.save()
      print("[UploadQueue] drain failed clientID=\(row.clientID) attempt=\(row.attemptCount) error=\(description)")
    }
  }
}
