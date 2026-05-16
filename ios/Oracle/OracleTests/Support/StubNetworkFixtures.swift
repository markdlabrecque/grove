// StubNetworkFixtures.swift
// Shared test fixtures for UploadQueueTests, AuthRequiredTests, and
// SyncEdgeCaseTests inside StubNetworkTests.swift.
//
// These are top-level free functions rather than a namespaced struct to avoid
// any risk of shared mutable static state across test runs (#260 reminder).
// Each call site owns its own ModelContainer and UploadQueue instances.
import Foundation
import SwiftData
import OracleCore
import OracleTestSupport
@testable import OracleCore
@testable import Oracle

// MARK: - Common constants

/// The base URL used by all stub-network test suites.
let stubNetworkBaseURL = URL(string: "https://oracle.example.ts.net")!

// MARK: - makeContainer

/// Build an in-memory `ModelContainer` scoped to a single test.
func makeContainer() throws -> ModelContainer {
  let schema = Schema([QueuedCapture.self])
  let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
  return try ModelContainer(for: schema, configurations: [config])
}

// MARK: - makeQueue

/// Build an `UploadQueue` backed by an in-memory container and a stub API session.
///
/// - Parameters:
///   - container: An in-memory `ModelContainer` created by `makeContainer()`.
///   - bearerToken: The bearer token to embed in `OracleAPI`.
///   - initialToken: Passed as `initialToken:` to `UploadQueue.init`. Suites that
///     test token-expiry flows (e.g. `AuthRequiredTests`) pass their own token here
///     so the queue tracks the "last known bad token". Defaults to `""`.
func makeQueue(
  container: ModelContainer,
  bearerToken: String,
  initialToken: String = ""
) -> (UploadQueue, OracleAPI) {
  let config = URLSessionConfiguration.default
  config.protocolClasses = [StubURLProtocol.self]
  let api = OracleAPI(
    baseURL: stubNetworkBaseURL,
    bearerToken: bearerToken,
    configuration: config
  )
  let queue = UploadQueue(modelContainer: container, api: api, initialToken: initialToken)
  return (queue, api)
}

// MARK: - makePayload

/// Encode a minimal `CaptureRequestBody` as the payload bytes for testing.
///
/// Returns `(clientID, encodedData)`.
func makePayload(
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

// MARK: - stubResponse

/// Build an `HTTPURLResponse` for the capture endpoint with a given status code.
func stubResponse(statusCode: Int) -> HTTPURLResponse {
  HTTPURLResponse(
    url: stubNetworkBaseURL.appendingPathComponent("v1/captures"),
    statusCode: statusCode,
    httpVersion: nil,
    headerFields: ["Content-Type": "application/json"]
  )!
}
