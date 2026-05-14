import Testing
import Foundation
import SwiftData
import OracleCore
import OracleTestSupport
@testable import OracleCore
@testable import Oracle

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
///
/// # Serialization
///
/// `StubURLProtocol.responder` is a static property, so tests must not run in
/// parallel. The `.serialized` trait opts out of Swift Testing's concurrent runner.
@Suite("UploadQueue", .serialized)
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
    await queue.setOnModelContextSave { saveCounter.value += 1 }
    defer { Task { await queue.setOnModelContextSave(nil) } }

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
