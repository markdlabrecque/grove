import Foundation
import SwiftData

// MARK: - QueuedCapture

/// A SwiftData model that persists a capture that has not yet been successfully
/// uploaded to the server.
///
/// Every capture is written here at save time. On a successful POST the row is
/// deleted eagerly (inside the same actor turn as the completion). On failure the
/// row stays so the next `UploadQueue.tryDrain()` call can retry it.
///
/// # Idempotency
///
/// `clientID` is the idempotency key. The server enforces `UNIQUE(client_id)` and
/// uses `INSERT … ON CONFLICT DO NOTHING` to make retries of the same capture a
/// no-op. Repeated `tryDrain` calls for the same row are therefore safe.
///
/// # Why this is in the app target, not OracleCore
///
/// `@Model` requires the SwiftData macro expansion infrastructure. The OracleCore
/// SPM package builds on macOS 15 (for `swift test` on CI) and has no dependency
/// on SwiftData. Adding SwiftData to the package would force a macOS 14+ platform
/// requirement and muddy the package's "pure networking layer" boundary. The
/// model and actor live here; the queue is wired into `OracleApp` and eventually
/// `CaptureViewModel` (PR 5).
@Model
final class QueuedCapture {

  // MARK: - Stored properties

  /// Stable UUID generated at capture time. Matches the `clientID` UUID passed to
  /// `OracleAPI.postCapture(_:)` and the `client_id` field the server de-dupes on.
  /// Stored as a String because SwiftData's UUID support is reliable but we want
  /// the raw string available for constructing `CapturePayload` without a
  /// failable conversion at drain time.
  var clientID: String

  /// JSON-encoded `CaptureRequestBody` bytes — the exact bytes that would be
  /// POSTed to the server. Stored so the queue can re-POST without re-encoding.
  var payload: Data

  /// When this row was first inserted. Used for display / debugging. Not used for
  /// ordering within `tryDrain` (insertion order is sufficient).
  var createdAt: Date

  /// How many times `tryDrain` has attempted this row and failed.
  /// Incremented on each failed drain attempt. Never decremented.
  var attemptCount: Int

  /// The description of the last error produced by a failed drain attempt.
  /// Set on failure; `nil` if the row has never been attempted or if trimming
  /// is needed to keep the value short.
  var lastError: String?

  /// Whether the row is waiting for a credential update before it can be
  /// retried.  Set to `true` when the server returns 401; cleared by
  /// `UploadQueue.reenqueueAuthRequired(newToken:)` once the user provides a
  /// new bearer token.
  ///
  /// A row in this state is intentionally skipped by `tryDrain` — it will not
  /// be uploaded until `reenqueueAuthRequired` resets this flag and triggers a
  /// fresh drain cycle.  This is an additive optional property; existing rows
  /// from previous app versions default to `false` without a schema migration.
  var isAuthRequired: Bool = false

  // MARK: - Init

  init(
    clientID: String,
    payload: Data,
    createdAt: Date = Date(),
    attemptCount: Int = 0,
    lastError: String? = nil,
    isAuthRequired: Bool = false
  ) {
    self.clientID = clientID
    self.payload = payload
    self.createdAt = createdAt
    self.attemptCount = attemptCount
    self.lastError = lastError
    self.isAuthRequired = isAuthRequired
  }
}
