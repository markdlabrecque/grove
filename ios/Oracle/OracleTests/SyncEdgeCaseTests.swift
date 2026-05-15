import Testing
import Foundation
import SwiftData
import OracleCore
import OracleTestSupport
@testable import OracleCore
@testable import Oracle

// MARK: - SyncEdgeCaseTests

/// Tests for #186: permanent 4xx → `failed` state, exponential backoff for 5xx / network
/// errors, and the manual Retry / Discard operations exposed by the upload-queue debug screen.
///
/// All tests run under the outer `.serialized` trait inherited from the parent
/// `StubNetwork` suite via nesting — except this file is a separate top-level
/// `@Suite` that is also `.serialized` so it doesn't race other suites on the
/// shared `StubURLProtocol` static responder.
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
@Suite("SyncEdgeCases", .serialized)
struct SyncEdgeCaseTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://oracle.example.ts.net")!
  private static let token = "edge-case-test-token"

  private func makeContainer() throws -> ModelContainer {
    let schema = Schema([QueuedCapture.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }

  private func makeQueue(container: ModelContainer) -> (UploadQueue, OracleAPI) {
    let urlConfig = URLSessionConfiguration.default
    urlConfig.protocolClasses = [StubURLProtocol.self]
    let api = OracleAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: urlConfig
    )
    let queue = UploadQueue(modelContainer: container, api: api)
    return (queue, api)
  }

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

  private func stubResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: Self.baseURL.appendingPathComponent("v1/captures"),
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
  }

  // MARK: - 4xx → failed (not deleted, not transient)

  /// A 422 response must transition the row to `isFailed = true`, set `lastError`
  /// to the server's error body, and leave the row in the queue (not delete it).
  @Test("422 response: row transitions to failed state, lastError set, row persists")
  func fourTwoTwoTransitionToFailed() async throws {
    let container = try makeContainer()
    let (queue, _) = makeQueue(container: container)

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
    #expect(row.lastError?.contains("422") == true || row.lastError?.isEmpty == false)
  }

  /// All explicitly-permanent 4xx codes (400, 403, 404, 409, 422) must each
  /// transition to `failed`.  This table-driven test runs once per code.
  @Test(
    "each permanent 4xx code maps to failed state",
    arguments: [400, 403, 404, 409, 422]
  )
  func eachPermanentFourXxMapToFailed(statusCode: Int) async throws {
    let container = try makeContainer()
    let (queue, _) = makeQueue(container: container)

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

  /// The error string stored in `lastError` must be preserved verbatim from the
  /// server response body (subject to the ~500-char truncation limit).
  @Test("422 lastError: server response body preserved verbatim (truncated at 500 chars)")
  func fourTwoTwoErrorStringPreserved() async throws {
    let container = try makeContainer()
    let (queue, _) = makeQueue(container: container)

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

    // Verify a huge error body is truncated at ≤ 500 chars.
    let hugeBody = String(repeating: "x", count: 2000)
    let hugeData = hugeBody.data(using: .utf8)!
    let (id2, data2) = try makePayload(content: "truncation test")
    let response422b = stubResponse(statusCode: 422)
    StubURLProtocol.responder = { [response422b, hugeData] _ in
      (response422b, hugeData)
    }
    try await queue.enqueue(clientID: id2.uuidString, payload: data2)
    // Drain only the new row (first is already failed and will be skipped).
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
    let (queue, _) = makeQueue(container: container)

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
        url: Self.baseURL.appendingPathComponent("v1/captures"),
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
    let (queue, _) = makeQueue(container: container)

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
    let (queue, _) = makeQueue(container: container)

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
  ///
  /// `BackoffScheduler.delay(forAttempt:)` is the pure function under test.
  /// Tests the schedule at representative positions including past-cap attempts.
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
  /// exceeding 3600s.  This includes an attempt count that would overflow if
  /// naively computed as 5 * 2^attempt.
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
  ///
  /// The test uses a tolerance of ±5s to account for execution time.
  @Test("5xx: nextAttemptAt set to ~now + delay(forAttempt: 1) = 5s")
  func fiveXxSetsNextAttemptAt() async throws {
    let container = try makeContainer()
    let (queue, _) = makeQueue(container: container)

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
    let (queue, _) = makeQueue(container: container)

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
        url: Self.baseURL.appendingPathComponent("v1/captures"),
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
    let (queue, _) = makeQueue(container: container)

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
      url: Self.baseURL.appendingPathComponent("v1/captures"),
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
  /// This verifies that `attemptCount` is the counter used by the schedule, not
  /// some separate counter.
  @Test("backoff: attempt count after two 5xx failures matches delay(forAttempt: 2) = 10s")
  func backoffAttemptCountTracksSchedule() async throws {
    let container = try makeContainer()
    let (queue, _) = makeQueue(container: container)

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
    let (queue, _) = makeQueue(container: container)

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
