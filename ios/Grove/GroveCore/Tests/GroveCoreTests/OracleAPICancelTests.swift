import Testing
import Foundation
import OracleTestSupport
@testable import GroveCore

/// Tests for in-flight cancellation of `OracleAPI.postQuery`.
///
/// Uses `SlowURLProtocol` — a `URLProtocol` subclass that blocks the response
/// indefinitely until either the task is cancelled (via `stopLoading()`) or a
/// semaphore is signalled. This lets tests exercise the
/// "Task.cancel() drops the URLSession request" path without a live server.
///
/// Serialised to prevent concurrent access to `SlowURLProtocol`'s static state.
@Suite("OracleAPI cancellation", .serialized)
struct OracleAPICancelTests {

  private static let baseURL = URL(string: "https://oracle.example.ts.net")!
  private static let token = "cancel-test-token"

  private func makeAPI() -> OracleAPI {
    let config = URLSessionConfiguration.default
    config.protocolClasses = [SlowURLProtocol.self]
    return OracleAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: config
    )
  }

  // MARK: - Cancellation test

  /// Fire `postQuery` against a slow-responding stub, cancel the wrapping
  /// `Task`, and confirm the thrown error is `CancellationError` or
  /// `URLError.cancelled` — not a real network failure and not silence.
  @Test("postQuery cancelled by Task.cancel throws CancellationError or URLError.cancelled")
  func postQueryCancelThrows() async throws {
    SlowURLProtocol.reset()
    defer { SlowURLProtocol.reset() }

    let api = makeAPI()

    // Wrap postQuery in a Task so we can cancel it from outside.
    let queryTask = Task {
      try await api.postQuery("cancel me")
    }

    // Give the URLProtocol time to start loading so the cancel races the
    // in-flight request rather than the pre-send setup.
    try await SlowURLProtocol.waitForStart()

    // Cancel the wrapping Task.
    queryTask.cancel()

    // The task must throw — either CancellationError (Swift concurrency
    // propagation) or URLError.cancelled (URLSession-level cancellation).
    do {
      _ = try await queryTask.value
      Issue.record("Expected cancellation error but postQuery returned successfully.")
    } catch is CancellationError {
      // Correct — Swift structured concurrency propagated the cancellation.
    } catch let urlError as URLError where urlError.code == .cancelled {
      // Also correct — URLSession surfaced the cancellation as URLError.
    } catch {
      Issue.record("Unexpected error type: \(error). Expected CancellationError or URLError.cancelled.")
    }
  }
}

// MARK: - SlowURLProtocol

/// A `URLProtocol` that begins loading but never delivers a response until
/// either `stopLoading()` is called (task cancelled) or `finish()` is called
/// (signal a success for other tests if needed).
///
/// `startedSemaphore` allows the test to wait until `startLoading()` has been
/// entered before issuing the cancel, ensuring the cancel races a truly in-
/// flight request.
final class SlowURLProtocol: URLProtocol {

  /// Signalled once when `startLoading()` is entered. Tests `await` this to
  /// synchronise before calling `queryTask.cancel()`.
  nonisolated(unsafe) private static var startedContinuation: CheckedContinuation<Void, Never>?
  nonisolated(unsafe) private static var startedTask: Task<Void, Never>?

  // MARK: - Public test helpers

  static func reset() {
    startedContinuation = nil
    startedTask = nil
  }

  /// Suspends the caller until `startLoading()` has been entered on any
  /// intercepted request. Must be called from an async context.
  ///
  /// Guarded by `withBridgeTimeout(seconds: 5)` so that if `startLoading()` is
  /// never called (e.g. URLProtocol registration silently fails), the test fails
  /// with a bounded `BridgeTimeoutError` rather than hanging indefinitely.
  static func waitForStart() async throws {
    try await withBridgeTimeout(seconds: 5) {
      await withCheckedContinuation { continuation in
        startedContinuation = continuation
      }
    }
  }

  // MARK: - URLProtocol overrides

  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    // Signal any waiter that the request has started.
    SlowURLProtocol.startedContinuation?.resume()
    SlowURLProtocol.startedContinuation = nil
    // Intentionally do not call client?.urlProtocol(self, ...) — the response
    // is never delivered. stopLoading() is called when the task is cancelled.
  }

  override func stopLoading() {
    // Task was cancelled. Deliver a URLError.cancelled so URLSession surfaces
    // the right error to the awaiting `data(for:)` call.
    client?.urlProtocol(
      self,
      didFailWithError: URLError(.cancelled)
    )
  }
}
