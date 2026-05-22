// StubNetworkFixtures.swift
// Shared test fixtures for UploadQueueTests, AuthRequiredTests, and
// SyncEdgeCaseTests inside StubNetworkTests.swift.
//
// These are top-level free functions rather than a namespaced struct to avoid
// any risk of shared mutable static state across test runs (#260 reminder).
// Each call site owns its own ModelContainer and UploadQueue instances.
import Foundation
import SwiftData
import GroveCore
import GroveTestSupport
@testable import GroveCore
@testable import Grove

// MARK: - Common constants

/// The base URL used by all stub-network test suites.
let stubNetworkBaseURL = URL(string: "https://grove.example.ts.net")!

// MARK: - makeContainer

/// Build an in-memory `ModelContainer` scoped to a single test.
func makeContainer() throws -> ModelContainer {
  let schema = Schema([QueuedCapture.self])
  let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
  return try ModelContainer(for: schema, configurations: [config])
}

// MARK: - makeQueueWithStub

/// The return value of `makeQueueWithStub`. Bundles the queue, API, and a
/// per-test responder setter so tests can swap what the stub returns without
/// touching global state.
struct QueueWithStub {
  let queue: UploadQueue
  let api: GroveAPI

  /// A unique identifier for the session registered with `StubURLProtocol`.
  /// Retained so tests that need it (e.g. to call `updateResponder(for:to:)`)
  /// have it to hand; the `setResponder` helper is more ergonomic for common cases.
  let stubID: UUID

  /// Replace the success responder for this session.
  ///
  /// Thread-safe: delegates to `StubURLProtocol.updateResponder(for:to:)` which
  /// is lock-protected.
  func setResponder(_ responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
    StubURLProtocol.updateResponder(for: stubID, to: responder)
  }

  /// Tear down the stub session (remove from the `StubURLProtocol` registry).
  ///
  /// Call this at the end of each test (e.g. from `defer`). After teardown
  /// any in-flight requests will precondition-fail in `StubURLProtocol`.
  let teardown: () -> Void
}

/// Build an `UploadQueue` with a per-test-isolated `StubURLProtocol` session.
///
/// Unlike `makeQueue`, this variant uses `StubURLProtocol.makeSession` so each
/// test gets its own registry slot and there is no cross-test static mutation.
///
/// Pattern:
/// ```swift
/// let stub = makeQueueWithStub(container: container, bearerToken: token)
/// defer { stub.teardown() }
///
/// stub.setResponder { _ in (stubResponse(statusCode: 201), responseData) }
/// await stub.queue.tryDrain()
/// ```
func makeQueueWithStub(
  container: ModelContainer,
  bearerToken: String,
  initialToken: String = ""
) -> QueueWithStub {
  // Seed an empty responder — tests call setResponder() before any network activity.
  // The closure is a placeholder; if a request fires before setResponder is called
  // the test has a logic error (will hit the registry entry and return a blank 500).
  let placeholder: (URLRequest) -> (HTTPURLResponse, Data) = { request in
    let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
    return (resp, Data())
  }
  let (config, teardown) = StubURLProtocol.makeSession(responder: placeholder)
  let stubIDString = config.httpAdditionalHeaders?[StubURLProtocol.stubIDHeaderKey] as? String
  let stubID = UUID(uuidString: stubIDString ?? "") ?? UUID()

  let api = GroveAPI(
    baseURL: stubNetworkBaseURL,
    bearerToken: bearerToken,
    configuration: config
  )
  let queue = UploadQueue(modelContainer: container, api: api, initialToken: initialToken)
  return QueueWithStub(queue: queue, api: api, stubID: stubID, teardown: teardown)
}

// MARK: - makeQueueWithErrorStub

/// The return value of `makeQueueWithErrorStub`. Bundles the queue and a teardown
/// closure; unlike `QueueWithStub` there is no `setResponder` because an error
/// session uses `StubURLProtocol.makeSession(errorResponder:)` which always fails.
struct QueueWithErrorStub {
  let queue: UploadQueue
  let api: GroveAPI
  let teardown: () -> Void
}

/// Build an `UploadQueue` whose every request fails with `URLError(.notConnectedToInternet)`.
///
/// Use this for tests that verify queue behaviour when the network layer throws
/// an error before any HTTP response is received (e.g. `transientNetworkErrorRetries`).
///
/// Pattern:
/// ```swift
/// let stub = makeQueueWithErrorStub(container: container, bearerToken: token)
/// defer { stub.teardown() }
/// await stub.queue.tryDrain()
/// ```
func makeQueueWithErrorStub(
  container: ModelContainer,
  bearerToken: String,
  error: Error = URLError(.notConnectedToInternet),
  initialToken: String = ""
) -> QueueWithErrorStub {
  let err = error
  let (config, teardown) = StubURLProtocol.makeSession(errorResponder: { _ in err })
  let api = GroveAPI(
    baseURL: stubNetworkBaseURL,
    bearerToken: bearerToken,
    configuration: config
  )
  let queue = UploadQueue(modelContainer: container, api: api, initialToken: initialToken)
  return QueueWithErrorStub(queue: queue, api: api, teardown: teardown)
}

// MARK: - makeCaptureViewModelWithStub

/// The return value of `makeCaptureViewModelWithStub`. Bundles the view model, its
/// upload queue, and the per-test stub handle so tests can swap responses.
struct CaptureViewModelWithStub {
  let vm: CaptureViewModel
  let queue: UploadQueue
  let stub: QueueWithStub
}

/// Build a `CaptureViewModel` backed by a per-test-isolated stub queue.
///
/// The returned `stub` handle exposes `setResponder(_:)` for success responses.
/// For error-path tests (network throws), use `makeCaptureViewModelWithErrorStub`.
///
/// Pattern:
/// ```swift
/// let s = try makeCaptureViewModelWithStub()
/// defer { s.stub.teardown() }
/// s.stub.setResponder { _ in (stubResponse(statusCode: 201), responseData) }
/// await s.vm.save()
/// ```
@MainActor
func makeCaptureViewModelWithStub(
  baseURL: URL = URL(string: "https://grove.example.ts.net")!,
  bearerToken: String = "vm-test-token"
) throws -> CaptureViewModelWithStub {
  let schema = Schema([QueuedCapture.self])
  let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
  let container = try ModelContainer(for: schema, configurations: [config])

  let stub = makeQueueWithStub(container: container, bearerToken: bearerToken)
  let vm = CaptureViewModel(uploadQueue: stub.queue)
  return CaptureViewModelWithStub(vm: vm, queue: stub.queue, stub: stub)
}

/// The return value of `makeCaptureViewModelWithErrorStub`.
struct CaptureViewModelWithErrorStub {
  let vm: CaptureViewModel
  let queue: UploadQueue
  let teardown: () -> Void
}

/// Build a `CaptureViewModel` whose every network request fails with the given error.
@MainActor
func makeCaptureViewModelWithErrorStub(
  baseURL: URL = URL(string: "https://grove.example.ts.net")!,
  bearerToken: String = "vm-test-token",
  error: Error = URLError(.notConnectedToInternet)
) throws -> CaptureViewModelWithErrorStub {
  let schema = Schema([QueuedCapture.self])
  let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
  let container = try ModelContainer(for: schema, configurations: [config])

  let err = error
  let (urlConfig, teardown) = StubURLProtocol.makeSession(errorResponder: { _ in err })
  let api = GroveAPI(baseURL: baseURL, bearerToken: bearerToken, configuration: urlConfig)
  let queue = UploadQueue(modelContainer: container, api: api)
  let vm = CaptureViewModel(uploadQueue: queue)
  return CaptureViewModelWithErrorStub(vm: vm, queue: queue, teardown: teardown)
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
