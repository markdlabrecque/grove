import Testing
import Foundation
@testable import OracleCore

/// Unit tests for the `OracleAPI` delegate bridge internals.
///
/// These tests exercise `appendData`, `completeTask`,
/// `storeBackgroundCompletionHandler`, `drainBackgroundCompletionHandlers`,
/// and `sweepOrphanedTempFiles` in isolation — no real URLSession, no network.
/// The bridge methods are driven directly on the actor, simulating the sequence
/// of callbacks the OS would deliver via `UploadSessionDelegate`.
///
/// # Relationship to OracleAPISmokeTests
///
/// `OracleAPISmokeTests` owns full `postCapture` round-trip integration tests
/// using `StubURLProtocol`. This suite focuses on bridge internals: continuation
/// map bookkeeping, data accumulation, HTTP and network error propagation, and
/// temp-file cleanup. The suites are complementary, not overlapping.
///
/// # Temp file deletion and the continuation race
///
/// Tests that drive `completeTask` via `withCheckedThrowingContinuation` cannot
/// reliably assert on temp file deletion from the outer context: `resume()` may
/// schedule the outer continuation on a different thread before the `defer` in
/// `completeTask` runs, creating a benign but real race. Temp file cleanup is
/// therefore verified in the dedicated `TempFileLifecycle` section, which does
/// not use live continuations.
///
/// Serialised to prevent concurrent access to shared static state.
@Suite("OracleAPI delegate bridge", .serialized)
struct OracleAPIBridgeTests {

  private static let baseURL = URL(string: "https://oracle.example.ts.net")!
  private static let token = "bridge-test-token"

  private func makeAPI() -> OracleAPI {
    OracleAPI(baseURL: Self.baseURL, bearerToken: Self.token)
  }

  /// Write a stub temp file and return its URL.
  private func makeTempFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).upload-body")
    try "stub".data(using: .utf8)!.write(to: url)
    return url
  }

  // MARK: - appendData accumulates chunks

  @Test("appendData accumulates multiple data chunks for a task")
  func appendDataAccumulates() async throws {
    let api = makeAPI()
    let fakeID = 42
    let tmpURL = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    let jsonString = """
      {"id":"b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
       "client_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890",
       "captured_at":"2026-05-10T14:30:00Z","enriched":false}
      """
    let jsonData = jsonString.data(using: .utf8)!
    let half = jsonData.count / 2
    let chunk1 = jsonData.prefix(half)
    let chunk2 = jsonData.suffix(from: half)

    let result = try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<CaptureResponseBody, Error>) in
      Task {
        await api.insertTestPendingUploadWithContinuation(
          taskID: fakeID,
          tempFileURL: tmpURL,
          continuation: cont
        )
        // Deliver in two chunks — simulates OS splitting the response body.
        await api.appendData(Data(chunk1), forTaskIdentifier: fakeID)
        await api.appendData(Data(chunk2), forTaskIdentifier: fakeID)
        let response = HTTPURLResponse(
          url: Self.baseURL,
          statusCode: 201,
          httpVersion: nil,
          headerFields: nil
        )!
        await api.completeTask(identifier: fakeID, response: response, error: nil)
      }
    }

    // If both chunks arrived and were correctly accumulated, decoding succeeds.
    #expect(result.id == UUID(uuidString: "b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f"))
    #expect(result.enriched == false)
  }

  // MARK: - completeTask: 201 success

  @Test("completeTask with 201 decodes body and resumes continuation")
  func completeTask201() async throws {
    let api = makeAPI()
    let fakeID = 1
    let tmpURL = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    let expectedID = UUID(uuidString: "b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f")!
    let expectedClientID = UUID(uuidString: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")!
    let json = """
      {"id":"\(expectedID.uuidString)","client_id":"\(expectedClientID.uuidString)",
       "captured_at":"2026-05-10T14:30:00Z","enriched":false}
      """.data(using: .utf8)!

    let result = try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<CaptureResponseBody, Error>) in
      Task {
        await api.insertTestPendingUploadWithContinuation(
          taskID: fakeID,
          tempFileURL: tmpURL,
          continuation: cont
        )
        await api.appendData(json, forTaskIdentifier: fakeID)
        let response = HTTPURLResponse(
          url: Self.baseURL, statusCode: 201, httpVersion: nil, headerFields: nil
        )!
        await api.completeTask(identifier: fakeID, response: response, error: nil)
      }
    }

    #expect(result.id == expectedID)
    #expect(result.clientID == expectedClientID)
    #expect(result.enriched == false)
  }

  // MARK: - completeTask: 200 (idempotent re-upload)

  @Test("completeTask with 200 is also treated as success")
  func completeTask200() async throws {
    let api = makeAPI()
    let fakeID = 2
    let tmpURL = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    let json = """
      {"id":"b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
       "client_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890",
       "captured_at":"2026-05-10T14:30:00Z","enriched":true}
      """.data(using: .utf8)!

    let result = try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<CaptureResponseBody, Error>) in
      Task {
        await api.insertTestPendingUploadWithContinuation(
          taskID: fakeID,
          tempFileURL: tmpURL,
          continuation: cont
        )
        await api.appendData(json, forTaskIdentifier: fakeID)
        let response = HTTPURLResponse(
          url: Self.baseURL, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        await api.completeTask(identifier: fakeID, response: response, error: nil)
      }
    }

    #expect(result.enriched == true)
  }

  // MARK: - completeTask: URLError propagation

  @Test("completeTask with URLError resumes continuation by throwing URLError")
  func completeTaskURLError() async throws {
    let api = makeAPI()
    let fakeID = 3
    let tmpURL = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    do {
      _ = try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<CaptureResponseBody, Error>) in
        Task {
          await api.insertTestPendingUploadWithContinuation(
            taskID: fakeID,
            tempFileURL: tmpURL,
            continuation: cont
          )
          await api.completeTask(
            identifier: fakeID,
            response: nil,
            error: URLError(.notConnectedToInternet)
          )
        }
      }
      Issue.record("Expected URLError but completeTask returned successfully.")
    } catch let error as URLError {
      #expect(error.code == .notConnectedToInternet)
    }
  }

  // MARK: - completeTask: HTTP 500 error

  @Test("completeTask with HTTP 500 throws APIError.httpError(500, _)")
  func completeTaskHTTP500() async throws {
    let api = makeAPI()
    let fakeID = 4
    let tmpURL = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    let errorBody = #"{"detail":"internal server error"}"#.data(using: .utf8)!

    do {
      _ = try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<CaptureResponseBody, Error>) in
        Task {
          await api.insertTestPendingUploadWithContinuation(
            taskID: fakeID,
            tempFileURL: tmpURL,
            continuation: cont
          )
          await api.appendData(errorBody, forTaskIdentifier: fakeID)
          let response = HTTPURLResponse(
            url: Self.baseURL, statusCode: 500, httpVersion: nil, headerFields: nil
          )!
          await api.completeTask(identifier: fakeID, response: response, error: nil)
        }
      }
      Issue.record("Expected APIError.httpError but completeTask returned successfully.")
    } catch let error as APIError {
      guard case .httpError(let code, let detail) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(code == 500)
      #expect(detail == "internal server error")
    }
  }

  // MARK: - completeTask: nil response (no error, no response)

  @Test("completeTask with nil response and nil error throws APIError.unexpectedResponse")
  func completeTaskNilResponse() async throws {
    let api = makeAPI()
    let fakeID = 5
    let tmpURL = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    do {
      _ = try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<CaptureResponseBody, Error>) in
        Task {
          await api.insertTestPendingUploadWithContinuation(
            taskID: fakeID,
            tempFileURL: tmpURL,
            continuation: cont
          )
          await api.completeTask(identifier: fakeID, response: nil, error: nil)
        }
      }
      Issue.record("Expected APIError.unexpectedResponse but completeTask returned successfully.")
    } catch let error as APIError {
      guard case .unexpectedResponse = error else {
        Issue.record("Expected APIError.unexpectedResponse but got \(error).")
        return
      }
    }
  }

  // MARK: - completeTask: unknown task ID is a no-op

  @Test("completeTask with unknown task ID is a no-op")
  func completeTaskUnknownID() async {
    // Simulates the OS replaying a completion for a task already resolved.
    // Should silently return — no crash, no leaked continuation.
    let api = makeAPI()
    await api.completeTask(identifier: 999_999, response: nil, error: nil)
  }

  // MARK: - Temp file lifecycle (race-free)

  /// Verifies that `completeTask` deletes the temp file on terminal completion.
  ///
  /// This test avoids the race condition in continuation-based tests (where
  /// `resume()` can schedule the outer context before the `defer` completes) by
  /// using `withCheckedContinuation` where the continuation is driven from a
  /// sequenced task and the file-existence check happens AFTER the inner task
  /// explicitly signals that `completeTask` has returned.
  @Test("completeTask deletes the temp file on success")
  func completeTaskDeletesTempFileOnSuccess() async throws {
    let api = makeAPI()
    let fakeID = 100

    let tmpURL = try makeTempFile()
    #expect(FileManager.default.fileExists(atPath: tmpURL.path))

    let json = """
      {"id":"b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
       "client_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890",
       "captured_at":"2026-05-10T14:30:00Z","enriched":false}
      """.data(using: .utf8)!

    // Use a separate actor to synchronise the "completeTask returned" signal
    // without relying on the outer continuation racing the defer.
    actor Signal {
      var fired = false
      var cont: CheckedContinuation<Void, Never>?
      func fire() { cont?.resume(); fired = true }
      func wait() async { await withCheckedContinuation { cont = $0 } }
    }
    let signal = Signal()

    _ = try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<CaptureResponseBody, Error>) in
      Task {
        await api.insertTestPendingUploadWithContinuation(
          taskID: fakeID,
          tempFileURL: tmpURL,
          continuation: cont
        )
        await api.appendData(json, forTaskIdentifier: fakeID)
        let response = HTTPURLResponse(
          url: Self.baseURL, statusCode: 201, httpVersion: nil, headerFields: nil
        )!
        await api.completeTask(identifier: fakeID, response: response, error: nil)
        // Signal AFTER completeTask (and its defer) has returned.
        await signal.fire()
      }
    }

    // Wait for the inner task to signal that completeTask has fully returned.
    await signal.wait()

    #expect(!FileManager.default.fileExists(atPath: tmpURL.path))
  }

  @Test("completeTask deletes the temp file on network error")
  func completeTaskDeletesTempFileOnError() async throws {
    let api = makeAPI()
    let fakeID = 101

    let tmpURL = try makeTempFile()
    #expect(FileManager.default.fileExists(atPath: tmpURL.path))

    actor Signal {
      var cont: CheckedContinuation<Void, Never>?
      func fire() { cont?.resume() }
      func wait() async { await withCheckedContinuation { cont = $0 } }
    }
    let signal = Signal()

    do {
      _ = try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<CaptureResponseBody, Error>) in
        Task {
          await api.insertTestPendingUploadWithContinuation(
            taskID: fakeID,
            tempFileURL: tmpURL,
            continuation: cont
          )
          await api.completeTask(
            identifier: fakeID,
            response: nil,
            error: URLError(.notConnectedToInternet)
          )
          await signal.fire()
        }
      }
      Issue.record("Expected URLError but completeTask returned successfully.")
    } catch is URLError {}

    await signal.wait()

    #expect(!FileManager.default.fileExists(atPath: tmpURL.path))
  }

  // MARK: - Background completion handler lifecycle

  @Test("drainBackgroundCompletionHandlers calls all stored handlers on main thread")
  func drainHandlersCalled() async throws {
    let api = makeAPI()

    // Use a class box so @Sendable closures can mutate shared state safely.
    // The test itself is serialized via @Suite(.serialized).
    final class CallBox: @unchecked Sendable {
      var calledA = false
      var calledB = false
    }
    let box = CallBox()

    await api.storeBackgroundCompletionHandler(
      { box.calledA = true },
      forIdentifier: "com.the-oracle.capture-upload"
    )
    await api.storeBackgroundCompletionHandler(
      { box.calledB = true },
      forIdentifier: "com.the-oracle.capture-upload-alt"
    )

    await api.drainBackgroundCompletionHandlers()

    // Allow the Task @MainActor inside drainBackgroundCompletionHandlers to run.
    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 s

    #expect(box.calledA)
    #expect(box.calledB)
  }

  @Test("drainBackgroundCompletionHandlers clears the handler map so a second drain is a no-op")
  func drainHandlersClearsMap() async throws {
    let api = makeAPI()

    final class Counter: @unchecked Sendable { var count = 0 }
    let counter = Counter()

    await api.storeBackgroundCompletionHandler(
      { counter.count += 1 },
      forIdentifier: "com.the-oracle.capture-upload"
    )

    await api.drainBackgroundCompletionHandlers()
    try await Task.sleep(nanoseconds: 100_000_000)

    // Drain again — handler must not fire a second time.
    await api.drainBackgroundCompletionHandlers()
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(counter.count == 1)

    let count = await api.backgroundHandlerCount
    #expect(count == 0)
  }

  // MARK: - Temp file sweep

  @Test("sweepOrphanedTempFiles removes upload-body files older than 1 hour")
  func sweepRemovesOldFiles() async throws {
    let api = makeAPI()
    let tmpDir = FileManager.default.temporaryDirectory

    // Create a fake orphaned file.
    let orphanURL = tmpDir.appendingPathComponent("\(UUID().uuidString).upload-body")
    try "orphan".data(using: .utf8)!.write(to: orphanURL)

    // Backdate its creation to 2 hours ago.
    let twoHoursAgo = Date().addingTimeInterval(-7200)
    try FileManager.default.setAttributes(
      [.creationDate: twoHoursAgo],
      ofItemAtPath: orphanURL.path
    )

    // Create a recent file that should NOT be removed.
    let recentURL = tmpDir.appendingPathComponent("\(UUID().uuidString).upload-body")
    try "recent".data(using: .utf8)!.write(to: recentURL)
    defer { try? FileManager.default.removeItem(at: recentURL) }

    await api.sweepOrphanedTempFiles()

    #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    #expect(FileManager.default.fileExists(atPath: recentURL.path))
  }

  @Test("sweepOrphanedTempFiles leaves recent upload-body files untouched")
  func sweepLeavesRecentFiles() async throws {
    let api = makeAPI()

    let recentURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).upload-body")
    try "recent".data(using: .utf8)!.write(to: recentURL)
    defer { try? FileManager.default.removeItem(at: recentURL) }

    await api.sweepOrphanedTempFiles()

    #expect(FileManager.default.fileExists(atPath: recentURL.path))
  }
}
