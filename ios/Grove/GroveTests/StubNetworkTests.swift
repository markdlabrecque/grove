import Testing
import Foundation
import SwiftData
import GroveCore
import GroveTestSupport
@testable import GroveCore
@testable import Grove

// MARK: - StubNetworkTests

/// Outer serialised wrapper for all test suites that share `StubURLProtocol`.
///
/// `StubURLProtocol.responder` and `StubURLProtocol.errorResponder` are static
/// properties on the legacy path (see `StubURLProtocol.swift`). Swift Testing's
/// `.serialized` trait only prevents concurrent execution of tests *within* a
/// single `@Suite` — it does not prevent two separate top-level suites from
/// running in parallel with each other.
///
/// Moving `UploadQueueTests` and `CaptureViewModelTests` here as nested suites
/// under this outer `.serialized` suite ensures that no two tests from either
/// suite can run concurrently, eliminating the cross-suite static-mutation race
/// that caused `tryDrainSuccessDeletesRow` to fail non-deterministically when
/// `CaptureViewModelTests` clobbered the responder mid-test.
///
/// New tests should use `StubURLProtocol.makeSession(responder:)` instead —
/// it is race-free without `.serialized`. The static-responder path is retained
/// for the existing suites here that cannot embed a per-test ID because the
/// URLSession is owned by the system under test (`UploadQueue`, `CaptureViewModel`).
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

    private static let token = "queue-test-token"

    // makeContainer(), makePayload(), and stubResponse() are provided by
    // Support/StubNetworkFixtures.swift as top-level free functions.

    private func captureResponseFixture() -> Data {
      // Inline fixture — same values as GroveTests/Fixtures/capture_response.json.
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
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

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
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

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
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

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
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

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
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

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

    // MARK: - fiveXxRetainsRowIndefinitely (#186: no retry cap)

    /// Verifies that a row stuck on persistent 5xx responses is retained indefinitely
    /// (#186 removed the 10-attempt cap — rows now stay in backoff until they succeed
    /// or are manually discarded by the user).
    ///
    /// The test drives 15 drain cycles (backdating nextAttemptAt between each) and
    /// confirms the row is still present after all of them.
    @Test("5xx: row retained indefinitely (no attempt cap), backoff delay increases")
    func fiveXxRetainsRowIndefinitely() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let failResponse = stubResponse(statusCode: 503)
      let errorBody = #"{"detail":"service unavailable"}"#.data(using: .utf8)!

      StubURLProtocol.responder = { [failResponse, errorBody] _ in
        (failResponse, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      #expect(try await queue.pendingCount() == 1)

      // Drive 15 drain cycles — row must remain present after each.
      for attempt in 1...15 {
        await queue.tryDrain()
        let count = try await queue.pendingCount()
        #expect(count == 1, "row should still exist after attempt \(attempt)")
        // Backdate nextAttemptAt so the next drain picks up the row.
        try await queue.setNextAttemptAt(
          clientID: id.uuidString,
          date: Date().addingTimeInterval(-1)
        )
      }

      // After 15 failures the row must still be in the queue (not deleted).
      #expect(try await queue.pendingCount() == 1)
      #expect(try await queue.failedCount() == 0, "5xx rows are not failed — they are pending backoff")
    }

    // MARK: - fiveXxSingleSavePerDrain

    /// Verifies that each transient-failure drain path issues exactly one
    /// `modelContext.save()` call (bump + save in a single write).
    @Test("5xx transient failure: exactly one modelContext.save() per drain")
    func fiveXxSingleSavePerDrain() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let failResponse = stubResponse(statusCode: 503)
      let errorBody = #"{"detail":"service unavailable"}"#.data(using: .utf8)!

      StubURLProtocol.responder = { [failResponse, errorBody] _ in
        (failResponse, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)

      // Arm the save counter for one drain.
      final class Counter: @unchecked Sendable { var value = 0 }
      let saveCounter = Counter()
      await queue.setTestHooks(UploadQueueTestHooks(onModelContextSave: { saveCounter.value += 1 }))
      defer { Task { await queue.setTestHooks(nil) } }

      await queue.tryDrain()

      // Row still present (transient, not deleted).
      #expect(try await queue.pendingCount() == 1)
      // Exactly one save: the bump+save.
      #expect(saveCounter.value == 1)
    }

    // MARK: - fourXxTransitionsToFailed

    /// A 422 response is a permanent failure. After a single `tryDrain()` call
    /// the row must be marked `isFailed = true` and remain in the queue — it is
    /// NOT deleted. The user must retry or discard from the debug screen.
    ///
    /// Updated from the old "4xx deletes immediately" behaviour (#186): deleting
    /// was silent and lost the capture context. `failed` state makes it visible.
    @Test("4xx (422): row transitions to failed state (not deleted)")
    func fourXxTransitionsToFailed() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

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

      // Row stays in queue with isFailed = true.
      #expect(try await queue.pendingCount() == 1)
      #expect(try await queue.failedCount() == 1)
    }

    // MARK: - fiveXxThenFourXxMarksRowFailed

    /// Exercises the interplay between the transient (5xx) and permanent (4xx)
    /// routing paths in `drainRow`.
    ///
    /// A 503 on the first drain must leave the row alive with `attemptCount == 1`
    /// and `nextAttemptAt` set (backoff).  After backdating `nextAttemptAt` to
    /// the past a second drain sees the 422 and transitions the row to `failed`.
    @Test("5xx then 4xx: row in backoff on 503, then transitions to failed on 422")
    func fiveXxThenFourXxMarksRowFailed() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

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

      // Row must still be present with attemptCount == 1 and nextAttemptAt set.
      #expect(try await queue.pendingCount() == 1)
      let readContext = ModelContext(container)
      let rowsAfterTransient = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rowsAfterTransient.first)
      #expect(row.attemptCount == 1)
      #expect(row.nextAttemptAt != nil)
      #expect(row.isFailed == false)

      // Backdate nextAttemptAt so the second drain will pick up the row.
      try await queue.setNextAttemptAt(clientID: id.uuidString, date: Date().addingTimeInterval(-1))

      // --- Second drain: 422 (permanent) ---
      StubURLProtocol.responder = { [permanentResponse, errorBody422] _ in
        (permanentResponse, errorBody422)
      }
      defer { StubURLProtocol.responder = nil }

      await queue.tryDrain()

      // Row stays, now in failed state.
      #expect(try await queue.pendingCount() == 1)
      #expect(try await queue.failedCount() == 1)
    }

    // MARK: - transientNetworkErrorRetries

    /// A `URLError(.notConnectedToInternet)` is a non-HTTP transient error.
    /// After one `tryDrain()` the row must still be present with `attemptCount == 1`.
    @Test("non-HTTP URLError: row kept, attemptCount incremented to 1")
    func transientNetworkErrorRetries() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

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
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

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

    private static let baseURL = URL(string: "https://grove.example.ts.net")!
    private static let token = "vm-test-token"

    private func makeQueue() throws -> (UploadQueue, ModelContainer) {
      let schema = Schema([QueuedCapture.self])
      let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      let container = try ModelContainer(for: schema, configurations: [config])

      let urlConfig = URLSessionConfiguration.default
      urlConfig.protocolClasses = [StubURLProtocol.self]
      let api = GroveAPI(
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

      // Await the drain task via the test seam so the assertion is
      // deterministic, rather than relying on the 1.5 s sleep in save().
      await vm._lastDrainTask?.value

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

      // Await the drain task via the test seam so the assertion is
      // deterministic, rather than relying on the 1.5 s sleep in save().
      await vm._lastDrainTask?.value

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

      // Await the drain task via the test seam so the assertion is
      // deterministic, rather than relying on the 1.5 s sleep in save().
      await vm._lastDrainTask?.value

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

  // MARK: - AuthRequiredTests (#185)

  /// Tests for 401 token-expiry handling.
  ///
  /// Scope:
  ///  - A simulated 401 transitions a queued item to `isAuthRequired = true`
  ///    (NOT deleted, NOT left as a generic transient failure).
  ///  - `authRequiredCount()` counts only rows that are `isAuthRequired`.
  ///  - `reenqueueAuthRequired(newToken:)` clears `isAuthRequired` on qualifying
  ///    rows and triggers a drain sweep — but only when the token changes.
  ///  - Idempotency: same bad token → no re-enqueue.
  ///  - Edge cases: prior-state transition, multiple rows, non-auth rows unaffected.
  ///
  /// Nested here so these tests participate in the outer `.serialized` constraint
  /// and do not race other suites on `StubURLProtocol`'s static responder.
  @Suite("AuthRequired")
  struct AuthRequiredTests {

    // MARK: - Fixtures

    private static let token = "auth-test-token"

    // makeContainer(), makePayload(), and stubResponse() are provided by
    // Support/StubNetworkFixtures.swift as top-level free functions.
    // makeQueue(container:bearerToken:initialToken:) is called with
    // initialToken: Self.token so the queue tracks the current token for
    // idempotency checks in the auth-required re-enqueue tests.

    private func captureFixture() -> Data {
      """
      {"id":"b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
       "client_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890",
       "captured_at":null,"enriched":false}
      """.data(using: .utf8)!
    }

    // MARK: - 401 transitions row to auth_required (not deleted, not generic failure)

    @Test("401 response: row marked isAuthRequired=true, not deleted")
    func fourOhOneMarksAuthRequired() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token, initialToken: Self.token)

      let (id, data) = try makePayload()
      let response401 = stubResponse(statusCode: 401)
      let errorBody = #"{"detail":"Invalid authentication credentials"}"#.data(using: .utf8)!

      StubURLProtocol.responder = { [response401, errorBody] _ in
        (response401, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      #expect(try await queue.pendingCount() == 1)

      await queue.tryDrain()

      // Row must still exist (not deleted like other 4xx).
      #expect(try await queue.pendingCount() == 1)
      #expect(try await queue.authRequiredCount() == 1)

      // Verify the row itself has isAuthRequired set.
      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)
      #expect(row.isAuthRequired == true)
      // attemptCount stays at 0 — auth_required is not a "failed attempt" in the
      // retry-cap sense; it is a distinct state awaiting credential update.
      #expect(row.attemptCount == 0)
    }

    // MARK: - 401 on a previously-failed row still marks isAuthRequired

    @Test("401 on a previously-failed row: isAuthRequired=true overrides prior state")
    func fourOhOneAfterTransientFailure() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token, initialToken: Self.token)

      let (id, data) = try makePayload()

      // First: a 503 (transient) — row stays with attemptCount == 1.
      StubURLProtocol.responder = { _ in
        let r = HTTPURLResponse(
          url: stubNetworkBaseURL.appendingPathComponent("v1/captures"),
          statusCode: 503,
          httpVersion: nil,
          headerFields: nil
        )!
        return (r, #"{"detail":"unavailable"}"#.data(using: .utf8)!)
      }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()

      #expect(try await queue.pendingCount() == 1)
      #expect(try await queue.authRequiredCount() == 0)

      // Backdate nextAttemptAt so the second drain will pick up the row
      // (the 503 set nextAttemptAt to ~now+5s; without this the 401 drain skips it).
      try await queue.setNextAttemptAt(clientID: id.uuidString, date: Date().addingTimeInterval(-1))

      // Second: a 401 — row should now be isAuthRequired=true.
      let response401 = stubResponse(statusCode: 401)
      let body401 = #"{"detail":"Invalid authentication credentials"}"#.data(using: .utf8)!
      StubURLProtocol.responder = { [response401, body401] _ in
        (response401, body401)
      }
      defer { StubURLProtocol.responder = nil }

      await queue.tryDrain()

      #expect(try await queue.pendingCount() == 1)
      #expect(try await queue.authRequiredCount() == 1)

      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)
      #expect(row.isAuthRequired == true)
    }

    // MARK: - tryDrain skips auth_required rows

    @Test("tryDrain skips rows marked isAuthRequired (no network call, row unchanged)")
    func drainSkipsAuthRequiredRows() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token, initialToken: Self.token)

      // Enqueue a row and force it into auth_required state.
      let (id, data) = try makePayload()
      let response401 = stubResponse(statusCode: 401)
      let body401 = #"{"detail":"bad token"}"#.data(using: .utf8)!

      StubURLProtocol.responder = { [response401, body401] _ in
        (response401, body401)
      }
      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()  // Transition to auth_required.
      StubURLProtocol.responder = nil

      #expect(try await queue.authRequiredCount() == 1)

      // Now drain again — auth_required rows must be skipped, no HTTP call made.
      final class Counter: @unchecked Sendable { var value = 0 }
      let httpCallCount = Counter()
      StubURLProtocol.responder = { [httpCallCount] _ in
        httpCallCount.value += 1
        let r = HTTPURLResponse(
          url: stubNetworkBaseURL.appendingPathComponent("v1/captures"),
          statusCode: 201, httpVersion: nil, headerFields: nil
        )!
        return (r, Data())
      }
      defer { StubURLProtocol.responder = nil }

      await queue.tryDrain()

      #expect(httpCallCount.value == 0)
      #expect(try await queue.authRequiredCount() == 1)
    }

    // MARK: - authRequiredCount counts only flagged rows

    @Test("authRequiredCount returns only rows with isAuthRequired=true")
    func authRequiredCountIsSelective() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token, initialToken: Self.token)

      let (id1, data1) = try makePayload(content: "first")
      let (id2, data2) = try makePayload(content: "second")
      let (id3, data3) = try makePayload(content: "third")

      try await queue.enqueue(clientID: id1.uuidString, payload: data1)
      try await queue.enqueue(clientID: id2.uuidString, payload: data2)
      try await queue.enqueue(clientID: id3.uuidString, payload: data3)

      #expect(try await queue.authRequiredCount() == 0)

      let response401 = stubResponse(statusCode: 401)
      let body401 = #"{"detail":"bad token"}"#.data(using: .utf8)!
      StubURLProtocol.responder = { [response401, body401] _ in
        (response401, body401)
      }
      defer { StubURLProtocol.responder = nil }

      await queue.tryDrain()

      #expect(try await queue.pendingCount() == 3)
      #expect(try await queue.authRequiredCount() == 3)
    }

    // MARK: - reenqueueAuthRequired clears flag and drains

    @Test("reenqueueAuthRequired: clears isAuthRequired, rows re-drain successfully")
    func reenqueueClearsAndDrains() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token, initialToken: Self.token)

      let (id1, data1) = try makePayload(content: "alpha")
      let (id2, data2) = try makePayload(content: "beta")

      let response401 = stubResponse(statusCode: 401)
      let body401 = #"{"detail":"bad token"}"#.data(using: .utf8)!
      StubURLProtocol.responder = { [response401, body401] _ in (response401, body401) }

      try await queue.enqueue(clientID: id1.uuidString, payload: data1)
      try await queue.enqueue(clientID: id2.uuidString, payload: data2)
      await queue.tryDrain()

      StubURLProtocol.responder = nil
      #expect(try await queue.authRequiredCount() == 2)

      let successResponse = HTTPURLResponse(
        url: stubNetworkBaseURL.appendingPathComponent("v1/captures"),
        statusCode: 201, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let fix = captureFixture()
      StubURLProtocol.responder = { [successResponse, fix] _ in
        (successResponse, fix)
      }
      defer { StubURLProtocol.responder = nil }

      await queue.reenqueueAuthRequired(newToken: "new-valid-token")

      #expect(try await queue.pendingCount() == 0)
      #expect(try await queue.authRequiredCount() == 0)
    }

    // MARK: - reenqueueAuthRequired is idempotent on same-token re-call

    @Test("reenqueueAuthRequired: same bad token does not re-enqueue (idempotent)")
    func reenqueueIdempotentOnSameToken() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token, initialToken: Self.token)

      let (id, data) = try makePayload()
      let response401 = stubResponse(statusCode: 401)
      let body401 = #"{"detail":"bad token"}"#.data(using: .utf8)!
      StubURLProtocol.responder = { [response401, body401] _ in (response401, body401) }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()  // → auth_required; lastKnownBadToken = Self.token
      StubURLProtocol.responder = nil

      #expect(try await queue.authRequiredCount() == 1)

      final class Counter: @unchecked Sendable { var value = 0 }
      let httpCallCount = Counter()
      StubURLProtocol.responder = { [httpCallCount, response401, body401] _ in
        httpCallCount.value += 1
        return (response401, body401)
      }
      defer { StubURLProtocol.responder = nil }

      // Same token that caused the 401 — must be a no-op.
      await queue.reenqueueAuthRequired(newToken: Self.token)

      #expect(httpCallCount.value == 0)
      #expect(try await queue.authRequiredCount() == 1)
    }

    // MARK: - multiple auth_required rows all re-enqueued

    @Test("multiple auth_required rows: all re-enqueued when token changes")
    func multipleRowsAllReenqueued() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token, initialToken: Self.token)

      let count = 5
      for i in 0..<count {
        let (id, data) = try makePayload(content: "item-\(i)")
        try await queue.enqueue(clientID: id.uuidString, payload: data)
      }

      let response401 = stubResponse(statusCode: 401)
      let body401 = #"{"detail":"bad token"}"#.data(using: .utf8)!
      StubURLProtocol.responder = { [response401, body401] _ in (response401, body401) }
      await queue.tryDrain()
      StubURLProtocol.responder = nil

      #expect(try await queue.authRequiredCount() == count)

      let successResponse = HTTPURLResponse(
        url: stubNetworkBaseURL.appendingPathComponent("v1/captures"),
        statusCode: 201, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let fix = captureFixture()
      StubURLProtocol.responder = { [successResponse, fix] _ in (successResponse, fix) }
      defer { StubURLProtocol.responder = nil }

      await queue.reenqueueAuthRequired(newToken: "brand-new-valid-token")
      #expect(try await queue.pendingCount() == 0)
    }

    // MARK: - reenqueueAuthRequired only clears auth_required rows

    /// Verifies that `reenqueueAuthRequired` only clears `isAuthRequired` on
    /// rows that are actually in the `auth_required` state, and does not touch
    /// rows that are pending for other reasons (e.g. transient network failure).
    ///
    /// After `reenqueueAuthRequired`, the internal `tryDrain()` processes all
    /// non-auth-required rows (that's correct — they were pending anyway).  This
    /// test verifies that only the formerly-auth-required row can become
    /// auth_required again (not the always-pending row).
    @Test("reenqueueAuthRequired: only clears rows with isAuthRequired=true")
    func reenqueueOnlyClearsAuthRequiredRows() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token, initialToken: Self.token)

      // Row A → auth_required (401).
      let (idA, dataA) = try makePayload(content: "auth-required row")
      let response401 = stubResponse(statusCode: 401)
      let body401 = #"{"detail":"bad token"}"#.data(using: .utf8)!
      StubURLProtocol.responder = { [response401, body401] _ in (response401, body401) }
      try await queue.enqueue(clientID: idA.uuidString, payload: dataA)
      await queue.tryDrain()
      StubURLProtocol.responder = nil

      // Row B → transient failure (503), NOT auth_required.
      let (idB, dataB) = try makePayload(content: "transient-failure row")
      let response503 = stubResponse(statusCode: 503)
      let body503 = #"{"detail":"unavailable"}"#.data(using: .utf8)!
      StubURLProtocol.responder = { [response503, body503] _ in (response503, body503) }
      try await queue.enqueue(clientID: idB.uuidString, payload: dataB)
      await queue.tryDrain()
      StubURLProtocol.responder = nil

      #expect(try await queue.pendingCount() == 2)
      #expect(try await queue.authRequiredCount() == 1)  // Only row A.

      // Confirm row-level state before calling reenqueueAuthRequired.
      let ctxBefore = ModelContext(container)
      let rowsBefore = try ctxBefore.fetch(FetchDescriptor<QueuedCapture>())
      let rowABefore = try #require(rowsBefore.first { $0.clientID == idA.uuidString })
      let rowBBefore = try #require(rowsBefore.first { $0.clientID == idB.uuidString })
      #expect(rowABefore.isAuthRequired == true)
      #expect(rowBBefore.isAuthRequired == false)  // Row B was never auth_required.

      // After reenqueueAuthRequired:
      //   - Row A's flag is cleared → drain → 503 (now transient, stays in queue)
      //   - Row B's flag stays false → drain → 503 (stays in queue)
      // Using 503 for both ensures neither ends up auth_required again.
      StubURLProtocol.responder = { [response503, body503] _ in (response503, body503) }
      defer { StubURLProtocol.responder = nil }

      await queue.reenqueueAuthRequired(newToken: "new-token")

      // Both rows are still in queue (both got 503).
      #expect(try await queue.pendingCount() == 2)
      // Neither is auth_required — 503 is transient, not auth_required.
      #expect(try await queue.authRequiredCount() == 0)

      // Verify row B's isAuthRequired is still false (it was never touched by
      // reenqueueAuthRequired, which only clears rows that were auth_required).
      let ctxAfter = ModelContext(container)
      let rowsAfter = try ctxAfter.fetch(FetchDescriptor<QueuedCapture>())
      let rowBAfter = try #require(rowsAfter.first { $0.clientID == idB.uuidString })
      #expect(rowBAfter.isAuthRequired == false)
    }
  }

  // MARK: - SyncEdgeCaseTests (#186)

  /// Tests for permanent 4xx → `failed` state, exponential backoff for 5xx / network
  /// errors, and the manual Retry / Discard operations exposed by the upload-queue
  /// debug screen.
  ///
  /// Nested here so these tests participate in the outer `.serialized` constraint
  /// and do not race other suites on `StubURLProtocol`'s static responder.
  ///
  /// # State machine (as of #186)
  ///
  /// ```
  /// pending ──(5xx/network)──► pending (backoff, nextAttemptAt set)
  ///         ──(401)──────────► auth_required   (handled by #185, not touched here)
  ///         ──(4xx ≠ 401)────► failed          (NEW — this ticket)
  ///         ──(success)──────► (deleted)
  ///
  /// failed ──(Retry)─────────► pending  (nextAttemptAt cleared, attemptCount reset)
  ///        ──(Discard)──────► (deleted)
  /// ```
  @Suite("SyncEdgeCases")
  struct SyncEdgeCaseTests {

    // MARK: - Fixtures

    private static let token = "edge-case-test-token"

    // makeContainer(), makePayload(), and stubResponse() are provided by
    // Support/StubNetworkFixtures.swift as top-level free functions.

    // MARK: - 4xx → failed (not deleted, not transient)

    /// A 422 response must transition the row to `isFailed = true`, set `lastError`
    /// to the server's error body, and leave the row in the queue (not delete it).
    @Test("422 response: row transitions to failed state, lastError set, row persists")
    func fourTwoTwoTransitionToFailed() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let errorBody = #"{"detail":"unprocessable entity"}"#.data(using: .utf8)!
      let response422 = stubResponse(statusCode: 422)

      StubURLProtocol.responder = { [response422, errorBody] _ in
        (response422, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      #expect(try await queue.pendingCount() == 1)

      await queue.tryDrain()

      // Row must still exist — `failed` is a distinct state, not deleted.
      #expect(try await queue.pendingCount() == 1)

      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)
      #expect(row.isFailed == true)
      #expect(row.lastError != nil)
      #expect(row.lastError?.isEmpty == false)
      // Error string must contain the HTTP status code.
      #expect(row.lastError?.contains("422") == true)
    }

    /// All explicitly-permanent 4xx codes (400, 403, 404, 409, 422) must each
    /// transition to `failed`.  This table-driven test runs once per code.
    @Test(
      "each permanent 4xx code maps to failed state",
      arguments: [400, 403, 404, 409, 422]
    )
    func eachPermanentFourXxMapToFailed(statusCode: Int) async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let errorBody = "{\"detail\":\"error \(statusCode)\"}".data(using: .utf8)!
      let response = stubResponse(statusCode: statusCode)

      StubURLProtocol.responder = { [response, errorBody] _ in
        (response, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()

      #expect(try await queue.pendingCount() == 1)
      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)
      #expect(row.isFailed == true, "status \(statusCode) must produce isFailed=true")
      #expect(row.lastError != nil, "status \(statusCode) must produce a lastError")
    }

    /// The error string stored in `lastError` must reference the HTTP status code.
    /// A huge response body is truncated at ≤ 500 chars.
    @Test("422 lastError: status code preserved; huge body truncated at 500 chars")
    func fourTwoTwoErrorStringPreserved() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let knownBody = #"{"detail":"validation failed: field 'content' is required"}"#
      let errorBody = knownBody.data(using: .utf8)!
      let response422 = stubResponse(statusCode: 422)

      StubURLProtocol.responder = { [response422, errorBody] _ in
        (response422, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()

      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)
      // The error string must be non-empty and reference the HTTP status.
      #expect(row.lastError?.isEmpty == false)
      #expect(row.lastError?.contains("422") == true)

      // Now test truncation: enqueue a second item and return a very long body.
      // `extractDetail` in GroveAPI parses JSON; a non-JSON blob returns nil detail.
      // The combined "HTTP 422: " prefix is still within 500 chars regardless.
      let (id2, data2) = try makePayload(content: "truncation test")
      // Build a 600-char JSON body whose "detail" value is 580 chars.
      let longDetail = String(repeating: "x", count: 580)
      let longJSON = "{\"detail\":\"\(longDetail)\"}".data(using: .utf8)!
      let response422b = stubResponse(statusCode: 422)
      StubURLProtocol.responder = { [response422b, longJSON] _ in
        (response422b, longJSON)
      }
      try await queue.enqueue(clientID: id2.uuidString, payload: data2)
      await queue.tryDrain()

      let readContext2 = ModelContext(container)
      let rows2 = try readContext2.fetch(FetchDescriptor<QueuedCapture>())
      let row2 = try #require(rows2.first { $0.clientID == id2.uuidString })
      #expect((row2.lastError?.count ?? 0) <= 500)
    }

    // MARK: - failed state is skipped by tryDrain

    /// Rows in the `failed` state must not be retried automatically by `tryDrain`.
    /// Only manual Retry can clear the failed state.
    @Test("tryDrain: failed rows are skipped (no network call)")
    func tryDrainSkipsFailedRows() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let errorBody = #"{"detail":"bad entity"}"#.data(using: .utf8)!
      let response422 = stubResponse(statusCode: 422)

      StubURLProtocol.responder = { [response422, errorBody] _ in
        (response422, errorBody)
      }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()  // → failed
      StubURLProtocol.responder = nil

      #expect(try await queue.failedCount() == 1)

      // Now arm a counter to detect any HTTP calls during the next drain.
      final class Counter: @unchecked Sendable { var value = 0 }
      let httpCallCount = Counter()
      StubURLProtocol.responder = { [httpCallCount] _ in
        httpCallCount.value += 1
        let r = HTTPURLResponse(
          url: stubNetworkBaseURL.appendingPathComponent("v1/captures"),
          statusCode: 201, httpVersion: nil, headerFields: nil
        )!
        return (r, Data())
      }
      defer { StubURLProtocol.responder = nil }

      await queue.tryDrain()

      #expect(httpCallCount.value == 0, "tryDrain must not retry failed rows")
      #expect(try await queue.failedCount() == 1)
    }

    // MARK: - Retry resets failed state

    /// `retryFailed(clientID:)` must clear `isFailed`, clear `nextAttemptAt`,
    /// reset `attemptCount`, and put the row back into the drainable pending pool.
    @Test("retryFailed: clears isFailed, resets attemptCount, row becomes pending")
    func retryFailedResetsToPending() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let errorBody = #"{"detail":"bad"}"#.data(using: .utf8)!
      let response422 = stubResponse(statusCode: 422)

      StubURLProtocol.responder = { [response422, errorBody] _ in
        (response422, errorBody)
      }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()  // → failed
      StubURLProtocol.responder = nil

      #expect(try await queue.failedCount() == 1)

      // Retry the failed row.
      try await queue.retryFailed(clientID: id.uuidString)

      #expect(try await queue.failedCount() == 0)

      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)
      #expect(row.isFailed == false)
      #expect(row.nextAttemptAt == nil)
      #expect(row.attemptCount == 0)
    }

    // MARK: - Discard removes the row

    /// `discardFailed(clientID:)` must delete the row from the queue permanently.
    @Test("discardFailed: row is removed from queue (pendingCount == 0)")
    func discardFailedRemovesRow() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let errorBody = #"{"detail":"bad"}"#.data(using: .utf8)!
      let response422 = stubResponse(statusCode: 422)

      StubURLProtocol.responder = { [response422, errorBody] _ in
        (response422, errorBody)
      }

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()  // → failed
      StubURLProtocol.responder = nil

      #expect(try await queue.failedCount() == 1)

      try await queue.discardFailed(clientID: id.uuidString)

      #expect(try await queue.pendingCount() == 0)
      #expect(try await queue.failedCount() == 0)
    }

    // MARK: - Backoff schedule

    /// The backoff schedule must be: 5s, 10s, 20s, 40s, 80s, 160s, 320s, 640s,
    /// 1280s, 2560s, then capped at 3600s indefinitely.
    @Test("backoff schedule: base=5s, doubling, capped at 3600s (1h)")
    func backoffSchedule() {
      let expected: [(attempt: Int, delay: TimeInterval)] = [
        (1, 5),
        (2, 10),
        (3, 20),
        (4, 40),
        (5, 80),
        (6, 160),
        (7, 320),
        (8, 640),
        (9, 1280),
        (10, 2560),
        (11, 3600),  // would be 5120s but capped at 3600s
        (12, 3600),  // sticky cap
        (13, 3600),  // still capped
        (50, 3600),  // large attempt — always capped
      ]

      for (attempt, expectedDelay) in expected {
        let actual = BackoffScheduler.delay(forAttempt: attempt)
        #expect(
          actual == expectedDelay,
          "attempt \(attempt): expected \(expectedDelay)s, got \(actual)s"
        )
      }
    }

    /// The cap is sticky: no attempt index, however large, can produce a delay
    /// exceeding 3600s.
    @Test("backoff schedule: cap is sticky — no delay exceeds 3600s regardless of attempt")
    func backoffCapIsSticky() {
      for attempt in [11, 20, 100, 1000] {
        let delay = BackoffScheduler.delay(forAttempt: attempt)
        #expect(delay <= 3600, "attempt \(attempt): delay \(delay) exceeds cap")
      }
    }

    // MARK: - 5xx sets nextAttemptAt via backoff

    /// After a 503 response, `nextAttemptAt` must be set to approximately
    /// `now + BackoffScheduler.delay(forAttempt: 1)`.
    @Test("5xx: nextAttemptAt set to ~now + delay(forAttempt: 1) = 5s")
    func fiveXxSetsNextAttemptAt() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let errorBody = #"{"detail":"unavailable"}"#.data(using: .utf8)!
      let response503 = stubResponse(statusCode: 503)

      StubURLProtocol.responder = { [response503, errorBody] _ in
        (response503, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      let before = Date()
      try await queue.enqueue(clientID: id.uuidString, payload: data)
      await queue.tryDrain()
      let after = Date()

      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)

      // Row must still be pending (not failed, not deleted).
      #expect(row.isFailed == false)
      #expect(row.attemptCount == 1)

      // nextAttemptAt must be set.
      let nextAttempt = try #require(row.nextAttemptAt)

      // Expected: before + 5s ≤ nextAttemptAt ≤ after + 5s + tolerance.
      let expectedMin = before.addingTimeInterval(5)
      let expectedMax = after.addingTimeInterval(5 + 5)  // +5s tolerance
      #expect(
        nextAttempt >= expectedMin,
        "nextAttemptAt \(nextAttempt) is earlier than expected minimum \(expectedMin)"
      )
      #expect(
        nextAttempt <= expectedMax,
        "nextAttemptAt \(nextAttempt) is later than expected maximum \(expectedMax)"
      )
    }

    /// Rows whose `nextAttemptAt` is in the future must be skipped by `tryDrain`.
    @Test("tryDrain: rows with nextAttemptAt in future are skipped")
    func tryDrainSkipsFutureBackoffRows() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()

      // Enqueue and set nextAttemptAt to far future directly.
      try await queue.enqueue(clientID: id.uuidString, payload: data)
      try await queue.setNextAttemptAt(
        clientID: id.uuidString,
        date: Date().addingTimeInterval(3600)
      )

      // Arm a counter — we must see zero HTTP calls.
      final class Counter: @unchecked Sendable { var value = 0 }
      let httpCallCount = Counter()
      StubURLProtocol.responder = { [httpCallCount] _ in
        httpCallCount.value += 1
        let r = HTTPURLResponse(
          url: stubNetworkBaseURL.appendingPathComponent("v1/captures"),
          statusCode: 201, httpVersion: nil, headerFields: nil
        )!
        return (r, Data())
      }
      defer { StubURLProtocol.responder = nil }

      await queue.tryDrain()

      #expect(httpCallCount.value == 0, "Row with future nextAttemptAt must be skipped")
      #expect(try await queue.pendingCount() == 1)
    }

    /// When `nextAttemptAt` is in the past, the row must be processed normally.
    @Test("tryDrain: rows with nextAttemptAt in past are processed")
    func tryDrainProcessesPastBackoffRows() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload(
        clientID: UUID(uuidString: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")!
      )

      try await queue.enqueue(clientID: id.uuidString, payload: data)
      // Set nextAttemptAt to 10s in the past.
      try await queue.setNextAttemptAt(
        clientID: id.uuidString,
        date: Date().addingTimeInterval(-10)
      )

      let successResponse = HTTPURLResponse(
        url: stubNetworkBaseURL.appendingPathComponent("v1/captures"),
        statusCode: 201, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let fixture = """
      {"id":"b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
       "client_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890",
       "captured_at":null,"enriched":false}
      """.data(using: .utf8)!

      StubURLProtocol.responder = { [successResponse, fixture] _ in
        (successResponse, fixture)
      }
      defer { StubURLProtocol.responder = nil }

      await queue.tryDrain()

      // Row should be deleted on success.
      #expect(try await queue.pendingCount() == 0)
    }

    // MARK: - Backoff attempt count increments correctly across drains

    /// After N 5xx failures the backoff delay at attempt N must match the schedule.
    @Test("backoff: attempt count after two 5xx failures matches delay(forAttempt: 2) = 10s")
    func backoffAttemptCountTracksSchedule() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id, data) = try makePayload()
      let errorBody = #"{"detail":"unavailable"}"#.data(using: .utf8)!
      let response503 = stubResponse(statusCode: 503)

      StubURLProtocol.responder = { [response503, errorBody] _ in
        (response503, errorBody)
      }
      defer { StubURLProtocol.responder = nil }

      try await queue.enqueue(clientID: id.uuidString, payload: data)

      // First drain — attempt 1, delay = 5s. Force past nextAttemptAt by backdating.
      await queue.tryDrain()
      try await queue.setNextAttemptAt(clientID: id.uuidString, date: Date().addingTimeInterval(-1))

      // Second drain — attempt 2, delay = 10s.
      let before = Date()
      await queue.tryDrain()
      let after = Date()

      let readContext = ModelContext(container)
      let rows = try readContext.fetch(FetchDescriptor<QueuedCapture>())
      let row = try #require(rows.first)
      #expect(row.attemptCount == 2)

      let nextAttempt = try #require(row.nextAttemptAt)
      let expectedMin = before.addingTimeInterval(10)
      let expectedMax = after.addingTimeInterval(10 + 5)
      #expect(nextAttempt >= expectedMin)
      #expect(nextAttempt <= expectedMax)
    }

    // MARK: - failedCount

    /// `failedCount()` must return only rows with `isFailed == true`.
    @Test("failedCount: only counts rows with isFailed=true")
    func failedCountIsSelective() async throws {
      let container = try makeContainer()
      let (queue, _) = makeQueue(container: container, bearerToken: Self.token)

      let (id1, data1) = try makePayload(content: "failed-one")
      let (id2, data2) = try makePayload(content: "failed-two")
      let (id3, data3) = try makePayload(content: "pending-one")

      let errorBody = #"{"detail":"bad entity"}"#.data(using: .utf8)!
      let response422 = stubResponse(statusCode: 422)

      // Enqueue all three, then drain id1 and id2 into failed.
      try await queue.enqueue(clientID: id1.uuidString, payload: data1)
      try await queue.enqueue(clientID: id2.uuidString, payload: data2)

      StubURLProtocol.responder = { [response422, errorBody] _ in
        (response422, errorBody)
      }
      await queue.tryDrain()
      StubURLProtocol.responder = nil

      // Now enqueue id3 (still pending, no drain attempt).
      try await queue.enqueue(clientID: id3.uuidString, payload: data3)

      #expect(try await queue.failedCount() == 2)
      #expect(try await queue.pendingCount() == 3)
    }
  }
}
