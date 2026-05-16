import Foundation

// MARK: - Pending upload tracking

/// Bookkeeping for a single in-flight upload task.
///
/// Holds the `withCheckedThrowingContinuation` that `postCapture` is suspended
/// on, accumulated response body data, and the URL of the temp file written
/// before the task was enqueued. The temp file is deleted in
/// `GroveAPI.completeTask(identifier:response:error:)` once the task reaches
/// a terminal state (success or non-retryable error).
struct PendingUpload {
  var continuation: CheckedContinuation<CaptureResponseBody, Error>
  var accumulatedData: Data
  let tempFileURL: URL
}

// MARK: - UploadSessionDelegate

/// `URLSessionDataDelegate` + `URLSessionDelegate` bridge between the OS
/// background URLSession and `GroveAPI`.
///
/// Background sessions cannot use the async `data(for:)` convenience — they
/// require delegate-based `uploadTask(with:fromFile:)`. This class is the
/// delegate, receiving raw callbacks and dispatching them back to the
/// `GroveAPI` actor via `Task { await api?.handle… }`.
///
/// The `api` reference is `weak` so it doesn't extend the actor's lifetime
/// beyond its natural scope. In practice `GroveAPI.shared` is a singleton
/// and will never be deallocated, but the `guard let api` pattern in each
/// delegate method is cheap insurance — it turns a potential crash into a
/// silent no-op, and the `guard` is there to document the assumption.
///
/// This class is intentionally non-isolated from Swift concurrency: it is an
/// `NSObject` (required by `URLSessionDelegate`) and cannot conform to `actor`.
/// Isolation is restored by crossing back to the actor on every dispatch.
final class UploadSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionDelegate {

  // Set immediately after GroveAPI.shared initialises itself. A weak ref
  // avoids a retain cycle (the actor holds the delegate strongly).
  //
  // `nonisolated(unsafe)` because this class conforms to NSObject (Sendable)
  // but the property is mutable. Writes happen only in the GroveAPI init
  // (before any concurrent access is possible) and reads happen only from
  // URLSession delegate callbacks — both well-ordered in practice. A formal
  // lock would add complexity with no practical safety gain for a singleton.
  nonisolated(unsafe) weak var api: GroveAPI?

  // MARK: - URLSessionDataDelegate

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    let id = dataTask.taskIdentifier
    Task { await self.api?.appendData(data, forTaskIdentifier: id) }
  }

  // MARK: - URLSessionTaskDelegate (via URLSessionDataDelegate conformance)

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let id = task.taskIdentifier
    let response = task.response as? HTTPURLResponse
    Task { await self.api?.completeTask(identifier: id, response: response, error: error) }
  }

  // MARK: - URLSessionDelegate

  /// Called by the OS after all queued background events have been delivered.
  ///
  /// Dispatches to `GroveAPI` so it can call the stored background-session
  /// completion handler on the main thread (required by Apple's documentation).
  /// PR 2 wires the `AppDelegate` that stores that handler; until then, this
  /// method is a no-op because no handler will have been stored.
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { await self.api?.drainBackgroundCompletionHandlers() }
  }
}
