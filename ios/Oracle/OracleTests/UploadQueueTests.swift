import Testing
import Foundation
import SwiftData
import OracleCore
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
    let context = ModelContext(container)
    let queue = UploadQueue(modelContext: context, api: api)
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
