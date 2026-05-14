import Testing
import Foundation
import SwiftData
import OracleCore
import OracleTestSupport
@testable import OracleCore
@testable import Oracle

// MARK: - StubNetworkTests

/// Outer serialised wrapper for all test suites that share `StubURLProtocol`.
///
/// `StubURLProtocol.responder` and `StubURLProtocol.errorResponder` are static
/// properties. Swift Testing's `.serialized` trait only prevents concurrent
/// execution of tests *within* a single `@Suite` — it does not prevent two
/// separate top-level suites from running in parallel with each other.
///
/// Moving `UploadQueueTests` and `CaptureViewModelTests` here as nested suites
/// under this outer `.serialized` suite ensures that no two tests from either
/// suite can run concurrently, eliminating the cross-suite static-mutation race
/// that caused `tryDrainSuccessDeletesRow` to fail non-deterministically when
/// `CaptureViewModelTests` clobbered the responder mid-test.
///
/// See: GitHub issue #228.
@Suite("StubNetwork", .serialized)
struct StubNetworkTests {

  // MARK: - UploadQueueTests

  /// Unit tests for `UploadQueue` and `QueuedCapture`.
  ///
  /// All tests use an in-memory `ModelContainer` so nothing touches disk.
  ///
  /// # Idempotency note
  ///
  /// The server de-dupes by `clientID` (`INSERT … ON CONFLICT DO NOTHING`), so
  /// retrying the same `QueuedCapture` row is always safe. These tests verify the
  /// client-side queue bookkeeping only — they do not exercise server deduplication.
  @Suite("UploadQueue")
  struct UploadQueueTests {

    // MARK: - Fixtures

    private static let baseURL = URL(string: "https://oracle.example.ts.net")!
    private static let token = "queue-test-token"

    /// Build an in-memory `ModelContainer` scoped to a single test.
    private func makeContainer() throws -> ModelContainer {
      let schema = Schema([QueuedCapture.self])
      let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      return try ModelContainer(for: schema, configurations: [config])
    }

    /// Build an `UploadQueue` using an in-memory container + a stub API session.
    private func makeQueue(container: ModelContainer) -> (UploadQueue, OracleAPI) {
      let config = URLSessionConfiguration.default
      config.protocolClasses = [StubURLProtocol.self]
      let api = OracleAPI(
        baseURL: Self.baseURL,
        bearerToken: Self.token,
        configuration: config
      )
      let queue = UploadQueue(modelContainer: container, api: api)
      return (queue, api)
    }

    /// Encode a minimal `CaptureRequestBody` as the `payload` bytes for testing.
    private func makePayload(
      clientID: UUID = UUID(),
      content: String = "test capture"
    ) throws -> (UUID, Data) {
      let body = CaptureRequestBody(
        clientID: clientID,
        content: content,
        sourceModality: "text",
        sourceDevice: "iphone",
        language: "en",
        capturedAt: Date()
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(body)
      return (clientID, data)
    }

    /// Build a `HTTPURLResponse` for a given status code.
    private func stubResponse(statusCode: Int) -> HTTPURLResponse {
      HTTPURLResponse(
        url: Self.baseURL.appendingPathComponent("v1/captures"),
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
    }

    private func captureResponseFixture() -> Data {
      // Inline fixture — same values as OracleTests/Fixtures/capture_response.json.
      // Using a literal here avoids bundle-lookup complexity (Bundle(for:) requires
      // a class; Swift Testing suites are structs).
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

    // MARK: - enqueueInsertsRow

    @Test("enqueue inserts a row and increments pendingCount")
    func enqueueInsertsRow() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      let (id, data) = try makePayload()

      let before = try await queue.pendingCount()
      try await queue.enqueue(clientID: id.uuidString, payload: data)
      let after = try await queue.pendingCount()

      #expect(before == 0)
      #expect(after == 1)
    }

    // MARK: - tryDrainSuccessDeletesRow

    @Test("tryDrain on success deletes the row (pendingCount == 0)")
    func tryDrainSuccessDeletesRow() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      let (id, data) = try makePayload(clientID: UUID(uuidString: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")!)
      let responseData = captureResponseFixture()
      let successResponse = stubResponse(statusCode: 201)

      StubURLProtocol.responder = { [successResponse, responseData] _ in
        (successResponse, responseData)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      #expect(try await queue.pendingCount() == 1)

      await queue.tryDrain()

      #expect(try await queue.pendingCount() == 0)
    }

    // MARK: - tryDrainFailureKeepsRow

    @Test("tryDrain on failure keeps the row, increments attemptCount, sets lastError")
    func tryDrainFailureKeepsRow() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      let (id, data) = try makePayload()
      let errorBody = #"{"detail":"internal server error"}"#.data(using: .utf8)!
      let failResponse = stubResponse(statusCode: 500)

      StubURLProtocol.responder = { [failResponse, errorBody] _ in
        (failResponse, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()

      #expect(try await queue.pendingCount() == 1)

      // Inspect the row directly via a fresh context on the same container.
      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)
      #expect(row.attemptCount == 1)
      #expect(row.lastError != nil)
    }

    // MARK: - tryDrainMultipleRows

    @Test("tryDrain with mixed success/failure drains successes and keeps failures")
    func tryDrainMultipleRows() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      // Three rows — we'll succeed for the first two and fail the third based on
      // payload content. Since `StubURLProtocol` is global, we cycle the response
      // per-call using a counter.
      let (id1, data1) = try makePayload(content: "first")
      let (id2, data2) = try makePayload(content: "second")
      let (id3, data3) = try makePayload(content: "third")

      try await queue.enqueue(clientID: id1.uuidString, payload: data1)
      try await queue.enqueue(clientID: id2.uuidString, payload: data2)
      try await queue.enqueue(clientID: id3.uuidString, payload: data3)

      #expect(try await queue.pendingCount() == 3)

      let responseData = captureResponseFixture()
      let successResponse = stubResponse(statusCode: 201)
      let failResponse = stubResponse(statusCode: 500)
      let errorBody = #"{"detail":"fail"}"#.data(using: .utf8)!

      // Respond success for first two calls, failure for the third.
      // Use a reference-type counter so the escaping closure can mutate it.
      // The suite is .serialized so there is no concurrent access.
      final class Counter: @unchecked Sendable { var value = 0 }
      let counter = Counter()
      StubURLProtocol.responder = { [successResponse, responseData, failResponse, errorBody, counter] _ in
        counter.value += 1
        if counter.value <= 2 {
          return (successResponse, responseData)
        } else {
          return (failResponse, errorBody)
        }
      }
      defer { StubURLProtocol.responder = nil }

      await queue.tryDrain()

      // 2 succeeded → deleted; 1 failed → still in queue
      #expect(try await queue.pendingCount() == 1)
    }

    // MARK: - concurrentDrainIsCollapsed

    /// Fires two `tryDrain()` calls concurrently and verifies that only N network
    /// requests are made (not 2×N).
    ///
    /// # How the guard works under `@ModelActor`
    ///
    /// `@ModelActor` gives `UploadQueue` a serial executor. When two tasks race to
    /// call `tryDrain()`, the first enters the actor and sets `isDraining = true`
    /// before suspending at the initial `await drainRow(...)`. The second task gets
    /// its turn at that suspension point, sees `isDraining == true`, and returns
    /// immediately. The total number of HTTP requests therefore equals N, not 2×N.
    ///
    /// # Synchronisation
    ///
    /// `async let` concurrent binding is used to start both drains simultaneously.
    /// No `Task.sleep` is needed — `await (drain1, drain2)` waits on both actor
    /// tasks to complete via Swift Concurrency's structured-concurrency graph.
    @Test("concurrent tryDrain calls collapse to a single drain pass")
    func concurrentDrainIsCollapsed() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      // Enqueue 3 rows so each successful drain makes 3 HTTP calls.
      let rowCount = 3
      for i in 0..<rowCount {
        let (id, data) = try makePayload(content: "concurrent-\(i)")
        try await queue.enqueue(clientID: id.uuidString, payload: data)
      }
      #expect(try await queue.pendingCount() == rowCount)

      let responseData = captureResponseFixture()
      let successResponse = stubResponse(statusCode: 201)

      // Count every HTTP request the stub services.
      final class Counter: @unchecked Sendable { var value = 0 }
      let counter = Counter()
      StubURLProtocol.responder = { [successResponse, responseData, counter] _ in
        counter.value += 1
        return (successResponse, responseData)
      }
      defer { StubURLProtocol.responder = nil }

      // Fire two drains concurrently via async let.  Both are submitted to the
      // actor before either completes; the second should be suppressed by isDraining.
      async let drain1: Void = queue.tryDrain()
      async let drain2: Void = queue.tryDrain()
      _ = await (drain1, drain2)

      // All rows should be gone (the one drain that ran succeeded).
      #expect(try await queue.pendingCount() == 0)

      // Exactly N HTTP requests — not 2×N.
      #expect(counter.value == rowCount)
    }

    // MARK: - retryCapDeletesRowAfterMaxAttempts

    /// Verifies that a row stuck on persistent 503 responses is deleted once
    /// `attemptCount` reaches the cap (10).
    ///
    /// Each `tryDrain()` call corresponds to one attempt. After 10 calls the row
    /// must be gone. No `Task.sleep` — drain calls are driven explicitly.
    @Test("retry cap: row deleted after 10 consecutive 5xx failures")
    func retryCapDeletesRowAfterMaxAttempts() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      let (id, data) = try makePayload()
      let failResponse = stubResponse(statusCode: 503)
      let errorBody = #"{"detail":"service unavailable"}"#.data(using: .utf8)!

      StubURLProtocol.responder = { [failResponse, errorBody] _ in
        (failResponse, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      #expect(try await queue.pendingCount() == 1)

      // Drive 9 drains — row should still be present after each.
      for attempt in 1..<10 {
        await queue.tryDrain()
        let count = try await queue.pendingCount()
        #expect(count == 1, "row should still exist after attempt \(attempt)")
      }

      // 10th drain hits the cap — row must be deleted.
      await queue.tryDrain()
      #expect(try await queue.pendingCount() == 0)
    }

    // MARK: - retryCapSingleSaveOnCapHit

    /// Verifies that the retry-cap eviction path issues exactly one `modelContext.save()`
    /// call (not two). A second save would indicate the redundant intermediate bump+save
    /// that issue #153 eliminated.
    ///
    /// The test drives the queue to attempt 9 (below cap) and then one final drain that
    /// hits the cap. On that 10th call `onModelContextSave` must fire exactly once.
    @Test("retry cap eviction: exactly one modelContext.save() on cap-hit drain")
    func retryCapSingleSaveOnCapHit() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      let (id, data) = try makePayload()
      let failResponse = stubResponse(statusCode: 503)
      let errorBody = #"{"detail":"service unavailable"}"#.data(using: .utf8)!

      StubURLProtocol.responder = { [failResponse, errorBody] _ in
        (failResponse, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)

      // Drive 9 drains to reach attemptCount == 9 without triggering the cap.
      for _ in 1..<10 {
        await queue.tryDrain()
      }
      // Row still present after 9 attempts.
      #expect(try await queue.pendingCount() == 1)

      // Arm the save counter for the 10th (cap-hit) drain only.
      final class Counter: @unchecked Sendable { var value = 0 }
      let saveCounter = Counter()
      await queue.setTestHooks(UploadQueueTestHooks(onModelContextSave: { saveCounter.value += 1 }))
      defer { Task { await queue.setTestHooks(nil) } }

      // 10th drain — hits the cap, row is deleted.
      await queue.tryDrain()

      #expect(try await queue.pendingCount() == 0)
      // Exactly one save: the delete+save. No intermediate bump+save.
      #expect(saveCounter.value == 1)
    }

    // MARK: - fourXxDeletesImmediately

    /// A 422 response is a permanent failure. The row must be deleted after a
    /// single `tryDrain()` call, without incrementing `attemptCount`.
    @Test("4xx (422): row deleted immediately, not retried")
    func fourXxDeletesImmediately() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      let (id, data) = try makePayload()
      let failResponse = stubResponse(statusCode: 422)
      let errorBody = #"{"detail":"unprocessable entity"}"#.data(using: .utf8)!

      StubURLProtocol.responder = { [failResponse, errorBody] _ in
        (failResponse, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      #expect(try await queue.pendingCount() == 1)

      await queue.tryDrain()

      #expect(try await queue.pendingCount() == 0)
    }

    // MARK: - fiveXxThenFourXxDeletesRow

    /// Exercises the interplay between the transient (5xx) and permanent (4xx)
    /// routing paths in `drainRow`.
    ///
    /// A 503 on the first drain must leave the row alive with `attemptCount == 1`.
    /// A subsequent 422 must trigger the permanent-failure path and delete the row,
    /// so `pendingCount == 0` after the second drain.
    ///
    /// Red-on-revert confirmation: reverting `isPermanentFailure` so that 422 falls
    /// through to the transient path (i.e. removing the 4xx branch) causes the
    /// `pendingCount == 0` assertion to fail, because the row is kept for retry
    /// instead of deleted.
    @Test("5xx then 4xx: row retried on 503, then deleted immediately on 422")
    func fiveXxThenFourXxDeletesRow() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      let (id, data) = try makePayload()
      let transientResponse = stubResponse(statusCode: 503)
      let permanentResponse = stubResponse(statusCode: 422)
      let errorBody503 = #"{"detail":"service unavailable"}"#.data(using: .utf8)!
      let errorBody422 = #"{"detail":"unprocessable entity"}"#.data(using: .utf8)!

      // --- First drain: 503 (transient) ---
      StubURLProtocol.responder = { [transientResponse, errorBody503] _ in
        (transientResponse, errorBody503)
      }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()

      // Row must still be present with attemptCount == 1.
      #expect(try await queue.pendingCount() == 1)
      let readContext = ModelContext(container)
      let rowsAfterTransient = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rowsAfterTransient.first)
      #expect(row.attemptCount == 1)

      // --- Second drain: 422 (permanent) ---
      StubURLProtocol.responder = { [permanentResponse, errorBody422] _ in
        (permanentResponse, errorBody422)
      }
      defer { StubURLProtocol.responder = nil }

      await queue.tryDrain()

      // Row must be deleted — 422 is a permanent failure, no retry.
      #expect(try await queue.pendingCount() == 0)
    }

    // MARK: - transientNetworkErrorRetries

    /// A `URLError(.notConnectedToInternet)` is a non-HTTP transient error.
    /// After one `tryDrain()` the row must still be present with `attemptCount == 1`.
    @Test("non-HTTP URLError: row kept, attemptCount incremented to 1")
    func transientNetworkErrorRetries() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      let (id, data) = try makePayload()

      StubURLProtocol.errorResponder = { _ in
        URLError(.notConnectedToInternet)
      }
      defer { StubURLProtocol.errorResponder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()

      #expect(try await queue.pendingCount() == 1)

      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)
      #expect(row.attemptCount == 1)
    }

    // MARK: - resetClearsAll

    @Test("reset deletes all rows (pendingCount == 0)")
    func resetClearsAll() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container)

      let (id1, data1) = try makePayload(content: "alpha")
      let (id2, data2) = try makePayload(content: "beta")

      try await queue.enqueue(clientID: id1.uuidString, payload: data1)
      try await queue.enqueue(clientID: id2.uuidString, payload: data2)
      #expect(try await queue.pendingCount() == 2)

      try await queue.reset()
      #expect(try await queue.pendingCount() == 0)
    }
  }

  // MARK: - CaptureViewModelTests

  /// Tests for the V2 offline-first `CaptureViewModel.save()` flow.
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
  /// 3. `saveSucceedsWhenServerReturns503` — stub returns a 503 HTTP response.
  ///    Same contract: `.success` to the UI, row stays queued.
  ///
  /// 4. `saveSucceedsWhenNetworkUnavailable` — stub throws
  ///    `URLError(.notConnectedToInternet)` to simulate a true offline condition.
  ///    Same contract: `.success` to the UI, row stays queued.
  @Suite("CaptureViewModel")
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

      // Wire up the drain-completion callback before triggering save so the
      // continuation is in place when the fire-and-forget drain task fires.
      // `ContinuationHolder` bridges the async setTestHooks call (which must
      // complete before save() fires) with the CheckedContinuation that is only
      // created inside the synchronous withCheckedThrowingContinuation body.
      final class ContinuationHolder: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Error>?
      }
      let holder = ContinuationHolder()
      await queue.setTestHooks(UploadQueueTestHooks(onDrainRowComplete: { result in
        Task { await queue.setTestHooks(nil) }
        holder.continuation?.resume(with: result)
      }))
      try await withBridgeTimeout(seconds: 5) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          holder.continuation = continuation

          Task { @MainActor in
            vm.content = "Hello from the test"
            await vm.save()
          }
        }
      }

      // ViewModel should report success immediately after enqueue.
      // (save() waits 1.5s then sets idle — we check just before that here,
      //  but since we await save() the status will have advanced to .idle by
      //  the time save() returns. Verify no error was shown instead.)
      #expect(vm.showErrorAlert == false)
      #expect(vm.content == "")

      // Continuation was already signalled by onDrainRowComplete — row is gone.
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

      // enqueue() commits to SwiftData before save() returns, so pendingCount
      // is already 1 here — no sleep needed to wait for the drain attempt.
      let count = try await queue.pendingCount()
      #expect(count == 1, "Row should remain queued after failed drain")
    }

    // MARK: - saveSucceedsWhenServerReturns503

    @Test("save reports success when server returns 503")
    func saveSucceedsWhenServerReturns503() async throws {
      let (queue, _) = try makeQueue()
      let vm = CaptureViewModel(uploadQueue: queue)

      let unavailableResponse = stubResponse(statusCode: 503)
      let unavailableBody = #"{"detail":"service unavailable"}"#.data(using: .utf8)!

      StubURLProtocol.responder = { [unavailableResponse, unavailableBody] _ in
        (unavailableResponse, unavailableBody)
      }
      defer { StubURLProtocol.responder = nil }

      vm.content = "Saved while server unavailable"
      await vm.save()

      #expect(vm.showErrorAlert == false, "User should see 'saved', not an error")
      #expect(vm.content == "", "Content cleared on enqueue success")

      // enqueue() commits to SwiftData before save() returns, so pendingCount
      // is already 1 here — no sleep needed to wait for the drain attempt.
      let count = try await queue.pendingCount()
      #expect(count == 1, "Row should be in queue awaiting reconnect")
    }

    // MARK: - saveSucceedsWhenNetworkUnavailable

    @Test("save reports success when network layer throws URLError(.notConnectedToInternet)")
    func saveSucceedsWhenNetworkUnavailable() async throws {
      let (queue, _) = try makeQueue()
      let vm = CaptureViewModel(uploadQueue: queue)

      // Simulate a true offline condition: the stub fails the request at the
      // network layer rather than returning any HTTP response.
      StubURLProtocol.errorResponder = { _ in
        URLError(.notConnectedToInternet)
      }
      defer { StubURLProtocol.errorResponder = nil }

      vm.content = "Saved while offline"
      await vm.save()

      // enqueue() commits to SwiftData before save() returns, so pendingCount
      // is already 1 here — no sleep needed to "wait" for the drain attempt.
      let count = try await queue.pendingCount()
      #expect(count == 1, "Row should be in queue awaiting reconnect")
      #expect(vm.showErrorAlert == false, "User should see 'saved', not an error")
      #expect(vm.content == "", "Content cleared on enqueue success")
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
}
