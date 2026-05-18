import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

/// Tests for `GroveAPI.deleteMemory(id:)` — DELETE /v1/memories/{id}.
///
/// Uses `DeleteStubURLProtocol` — a dedicated protocol class that carries its
/// own static `responder` state, isolated from `StubURLProtocol` used by other
/// suites. This prevents inter-suite global-state contamination when Swift
/// Testing runs multiple suites concurrently.
///
/// The suite is also serialised to prevent concurrent access within the suite.
@Suite("GroveAPI deleteMemory", .serialized)
struct GroveAPIDeleteTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "delete-test-token"
  private static let memoryID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!

  private func makeAPI() -> GroveAPI {
    let config = URLSessionConfiguration.default
    config.protocolClasses = [DeleteStubURLProtocol.self]
    return GroveAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: config
    )
  }

  private func deleteURL(for id: UUID) -> URL {
    Self.baseURL.appendingPathComponent("v1/memories/\(id.uuidString.lowercased())")
  }

  // MARK: - Happy path: 204 No Content

  @Test("deleteMemory returns void on 204 No Content")
  func deleteMemoryHappyPath() async throws {
    let url = deleteURL(for: Self.memoryID)

    DeleteStubURLProtocol.responder = { [url] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { DeleteStubURLProtocol.responder = nil }

    let api = makeAPI()
    // Should complete without throwing.
    try await api.deleteMemory(id: Self.memoryID)
  }

  // MARK: - 404: memory already gone

  @Test("deleteMemory throws httpError(404, _) when memory is not found")
  func deleteMemory404() async throws {
    let url = deleteURL(for: Self.memoryID)
    let body = #"{"detail":"memory not found"}"#.data(using: .utf8)!

    DeleteStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { DeleteStubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      try await api.deleteMemory(id: Self.memoryID)
      Issue.record("Expected APIError.httpError(404, _) but deleteMemory succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, let detail) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 404)
      #expect(detail == "memory not found")
    }
  }

  // MARK: - 401: unauthorized

  @Test("deleteMemory throws httpError(401, _) when token is invalid")
  func deleteMemory401() async throws {
    let url = deleteURL(for: Self.memoryID)
    let body = #"{"detail":"unauthorized"}"#.data(using: .utf8)!

    DeleteStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { DeleteStubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      try await api.deleteMemory(id: Self.memoryID)
      Issue.record("Expected APIError.httpError(401, _) but deleteMemory succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, _) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 401)
    }
  }

  // MARK: - 5xx: generic server error

  @Test("deleteMemory throws httpError(500, _) on generic server error")
  func deleteMemory5xx() async throws {
    let url = deleteURL(for: Self.memoryID)
    let body = #"{"detail":"internal server error"}"#.data(using: .utf8)!

    DeleteStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 500,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { DeleteStubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      try await api.deleteMemory(id: Self.memoryID)
      Issue.record("Expected APIError.httpError(500, _) but deleteMemory succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, let detail) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 500)
      #expect(detail == "internal server error")
    }
  }

  // MARK: - Request shape

  @Test("deleteMemory sends DELETE to /v1/memories/{id} with correct Authorization header")
  func deleteMemoryRequestShape() async throws {
    let url = deleteURL(for: Self.memoryID)
    var capturedRequest: URLRequest?

    DeleteStubURLProtocol.responder = { [url] request in
      capturedRequest = request
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { DeleteStubURLProtocol.responder = nil }

    let api = makeAPI()
    try await api.deleteMemory(id: Self.memoryID)

    let req = try #require(capturedRequest)
    #expect(req.httpMethod == "DELETE")
    #expect(req.url == url)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
  }
}

// MARK: - DeleteStubURLProtocol

/// A dedicated `URLProtocol` subclass for delete tests that carries its own
/// static `responder` state, isolated from `StubURLProtocol` (which is used by
/// `GroveAPISmokeTests` and `GroveAPIBridgeTests`). This prevents inter-suite
/// global-state contamination when Swift Testing runs multiple suites concurrently.
///
/// Pattern mirrors `SlowURLProtocol` in `GroveAPICancelTests`.
private final class DeleteStubURLProtocol: URLProtocol {

  /// Configure this before each test. The suite is `.serialized` so access is
  /// externally synchronised.
  nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    guard let responder = DeleteStubURLProtocol.responder else {
      preconditionFailure(
        "DeleteStubURLProtocol.responder must be set before making a request."
      )
    }
    let (response, data) = responder(request)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    // Synchronous stub — nothing to cancel.
  }
}
