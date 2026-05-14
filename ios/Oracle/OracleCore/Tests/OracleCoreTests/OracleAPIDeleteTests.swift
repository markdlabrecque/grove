import Testing
import Foundation
import OracleTestSupport
@testable import OracleCore

/// Tests for `OracleAPI.deleteMemory(id:)` — DELETE /v1/memories/{id}.
///
/// All tests use `StubURLProtocol` injected via the internal
/// `OracleAPI.init(baseURL:bearerToken:configuration:)` initialiser so no
/// live network is needed. The suite is serialised because `StubURLProtocol`
/// carries global state.
@Suite("OracleAPI deleteMemory", .serialized)
struct OracleAPIDeleteTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://oracle.example.ts.net")!
  private static let token = "delete-test-token"
  private static let memoryID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!

  private func makeAPI() -> OracleAPI {
    let config = URLSessionConfiguration.default
    config.protocolClasses = [StubURLProtocol.self]
    return OracleAPI(
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

    StubURLProtocol.responder = { [url] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
    // Should complete without throwing.
    try await api.deleteMemory(id: Self.memoryID)
  }

  // MARK: - 404: memory already gone

  @Test("deleteMemory throws httpError(404, _) when memory is not found")
  func deleteMemory404() async throws {
    let url = deleteURL(for: Self.memoryID)
    let body = #"{"detail":"memory not found"}"#.data(using: .utf8)!

    StubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { StubURLProtocol.responder = nil }

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

    StubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { StubURLProtocol.responder = nil }

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

    StubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 500,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { StubURLProtocol.responder = nil }

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

    StubURLProtocol.responder = { [url] request in
      capturedRequest = request
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
    try await api.deleteMemory(id: Self.memoryID)

    let req = try #require(capturedRequest)
    #expect(req.httpMethod == "DELETE")
    #expect(req.url == url)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
  }
}
