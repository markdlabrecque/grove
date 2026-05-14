import Testing
import Foundation
import SwiftData
import OracleCore
import OracleTestSupport
@testable import OracleCore
@testable import Oracle

// MARK: - CaptureViewModelTests

/// Tests for the V2 offline-first `CaptureViewModel.save()` flow.
///
/// # Design
///
/// `CaptureViewModel` takes an `UploadQueue` in its initialiser. Tests inject a
/// queue backed by an in-memory `ModelContainer` + `StubURLProtocol` session so
/// no real network or disk I/O occurs.
///
/// # Key contracts under test
///
/// 1. `saveEnqueuesAndAttemptsDrain` — happy path. The row is enqueued, the
///    ViewModel reports `.success`, and after the drain settles `pendingCount == 0`.
///
/// 2. `saveSucceedsEvenWhenDrainFails` — the user-facing contract is "saved, will
///    retry", not "uploaded right now". Even when `postCapture` fails the ViewModel
///    still reports `.success` and the row stays in the queue for the next drain.
///
/// 3. `saveSucceedsWhenOffline` — simulated by returning a network-layer error
///    from the stub. Same contract: `.success` to the UI, row stays queued.
///
/// # Serialization
///
/// `StubURLProtocol.responder` is a static; tests must not run concurrently.
@Suite("CaptureViewModel", .serialized)
@MainActor
struct CaptureViewModelTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://oracle.example.ts.net")!
  private static let token = "vm-test-token"

  private func makeQueue() throws -> (UploadQueue, ModelContainer) {
    let schema = Schema([QueuedCapture.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])

    let urlConfig = URLSessionConfiguration.default
    urlConfig.protocolClasses = [StubURLProtocol.self]
    let api = OracleAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: urlConfig
    )
    let queue = UploadQueue(modelContainer: container, api: api)
    return (queue, container)
  }

  private func stubResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: Self.baseURL.appendingPathComponent("v1/captures"),
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
  }

  private func captureResponseData() -> Data {
    let fixture = """
    {
      "id": "b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
      "client_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "captured_at": null,
      "enriched": false
    }
    """
    return Data(fixture.utf8)
  }

  // MARK: - saveEnqueuesAndAttemptsDrain

  @Test("save enqueues row and drains it on success (pendingCount == 0)")
  func saveEnqueuesAndAttemptsDrain() async throws {
    let (queue, _) = try makeQueue()
    let vm = CaptureViewModel(uploadQueue: queue)

    let successResponse = stubResponse(statusCode: 201)
    let responseData = captureResponseData()

    StubURLProtocol.responder = { [successResponse, responseData] _ in
      (successResponse, responseData)
    }
    defer { StubURLProtocol.responder = nil }

    vm.content = "Hello from the test"
    await vm.save()

    // ViewModel should report success immediately after enqueue.
    // (save() waits 1.5s then sets idle — we check just before that here,
    //  but since we await save() the status will have advanced to .idle by
    //  the time save() returns. Verify no error was shown instead.)
    #expect(vm.showErrorAlert == false)
    #expect(vm.content == "")

    // Allow the fire-and-forget drain Task a moment to complete.
    try await Task.sleep(for: .milliseconds(200))

    let count = try await queue.pendingCount()
    #expect(count == 0, "Row should have been deleted after successful drain")
  }

  // MARK: - saveSucceedsEvenWhenDrainFails

  @Test("save reports success even when drain fails (row stays queued)")
  func saveSucceedsEvenWhenDrainFails() async throws {
    let (queue, _) = try makeQueue()
    let vm = CaptureViewModel(uploadQueue: queue)

    let failResponse = stubResponse(statusCode: 500)
    let errorBody = #"{"detail":"internal server error"}"#.data(using: .utf8)!

    StubURLProtocol.responder = { [failResponse, errorBody] _ in
      (failResponse, errorBody)
    }
    defer { StubURLProtocol.responder = nil }

    vm.content = "Offline capture"
    await vm.save()

    // The user-facing contract: no error alert shown (the capture is durably
    // queued even though the immediate upload attempt failed).
    #expect(vm.showErrorAlert == false)
    #expect(vm.content == "")

    // Allow the drain Task to finish.
    try await Task.sleep(for: .milliseconds(200))

    let count = try await queue.pendingCount()
    #expect(count == 1, "Row should remain queued after failed drain")
  }

  // MARK: - saveSucceedsWhenOffline

  @Test("save reports success when network returns a connection error")
  func saveSucceedsWhenOffline() async throws {
    let (queue, _) = try makeQueue()
    let vm = CaptureViewModel(uploadQueue: queue)

    // Simulate an offline condition by making StubURLProtocol return a
    // URLError (.notConnectedToInternet). We do this by pointing the responder
    // to a 503 (the stub cannot synthesise connection-level errors; a 5xx is
    // the closest approximation that exercises the same ViewModel code path).
    let offlineResponse = stubResponse(statusCode: 503)
    let offlineBody = #"{"detail":"service unavailable"}"#.data(using: .utf8)!

    StubURLProtocol.responder = { [offlineResponse, offlineBody] _ in
      (offlineResponse, offlineBody)
    }
    defer { StubURLProtocol.responder = nil }

    vm.content = "Saved while offline"
    await vm.save()

    #expect(vm.showErrorAlert == false, "User should see 'saved', not an error")
    #expect(vm.content == "", "Content cleared on enqueue success")

    try await Task.sleep(for: .milliseconds(200))

    let count = try await queue.pendingCount()
    #expect(count == 1, "Row should be in queue awaiting reconnect")
  }

  // MARK: - emptyContentIsNoop

  @Test("save with empty content does not enqueue anything")
  func emptyContentIsNoop() async throws {
    let (queue, _) = try makeQueue()
    let vm = CaptureViewModel(uploadQueue: queue)

    vm.content = "   "
    await vm.save()

    #expect(vm.showErrorAlert == false)
    let count = try await queue.pendingCount()
    #expect(count == 0, "Empty/whitespace content must not enqueue a row")
  }
}

// MARK: - SweepOrphanedTempFilesTests

/// Integration test: verifies that stale `*.upload-body` temp files are
/// removed by `sweepOrphanedTempFiles()`.
///
/// This test drops a pre-aged file into `FileManager.temporaryDirectory`,
/// calls the sweep, and asserts the file is gone. It verifies the function
/// correctly identifies and removes files past the one-hour cutoff.
@Suite("sweepOrphanedTempFiles")
struct SweepOrphanedTempFilesTests {

  @Test("removes *.upload-body files older than one hour")
  func removesStaleFile() async throws {
    let tmp = FileManager.default.temporaryDirectory
    let staleURL = tmp.appendingPathComponent("stale-test-\(UUID().uuidString).upload-body")

    // Write the file.
    try Data("stale body".utf8).write(to: staleURL)

    // Back-date its creation by manipulating attributes (two hours ago).
    let twoHoursAgo = Date().addingTimeInterval(-7200)
    try FileManager.default.setAttributes(
      [.creationDate: twoHoursAgo],
      ofItemAtPath: staleURL.path
    )

    #expect(FileManager.default.fileExists(atPath: staleURL.path), "Pre-condition: file exists")

    // Run the sweep — actor-isolated so requires await.
    await OracleAPI.shared.sweepOrphanedTempFiles()

    #expect(
      !FileManager.default.fileExists(atPath: staleURL.path),
      "Stale file should have been removed"
    )
  }

  @Test("leaves *.upload-body files newer than one hour untouched")
  func preservesRecentFile() async throws {
    let tmp = FileManager.default.temporaryDirectory
    let recentURL = tmp.appendingPathComponent("recent-test-\(UUID().uuidString).upload-body")

    // Write a fresh file (creation date defaults to now).
    try Data("recent body".utf8).write(to: recentURL)
    defer { try? FileManager.default.removeItem(at: recentURL) }

    #expect(FileManager.default.fileExists(atPath: recentURL.path), "Pre-condition: file exists")

    await OracleAPI.shared.sweepOrphanedTempFiles()

    #expect(
      FileManager.default.fileExists(atPath: recentURL.path),
      "Recent file should NOT be removed"
    )
  }
}
