import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

/// Tests for `GroveAPI.deleteMemory(id:)` — DELETE /v1/memories/{id}.
///
/// Uses `StubURLProtocol.makeSession(responder:)` (#422) for per-test isolation.
/// Each test obtains its own `URLSessionConfiguration` with a unique stub ID
/// embedded, so concurrent suites cannot corrupt each other's responders.
/// Tests in this suite run in parallel to verify the isolation is race-free.
@Suite("GroveAPI deleteMemory")
struct GroveAPIDeleteTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "delete-test-token"
  private static let memoryID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!

  private func makeAPI(
    responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)
  ) -> (GroveAPI, () -> Void) {
    let (config, teardown) = StubURLProtocol.makeSession(responder: responder)
    let api = GroveAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: config
    )
    return (api, teardown)
  }

  private func deleteURL(for id: UUID) -> URL {
    Self.baseURL.appendingPathComponent("v1/memories/\(id.uuidString.lowercased())")
  }

  // MARK: - Happy path: 204 No Content

  @Test("deleteMemory returns void on 204 No Content")
  func deleteMemoryHappyPath() async throws {
    let url = deleteURL(for: Self.memoryID)

    let (api, teardown) = makeAPI { [url] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { teardown() }

    // Should complete without throwing.
    try await api.deleteMemory(id: Self.memoryID)
  }

  // MARK: - 404: memory already gone

  @Test("deleteMemory throws httpError(404, _) when memory is not found")
  func deleteMemory404() async throws {
    let url = deleteURL(for: Self.memoryID)
    let body = #"{"detail":"memory not found"}"#.data(using: .utf8)!

    let (api, teardown) = makeAPI { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { teardown() }

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

    let (api, teardown) = makeAPI { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { teardown() }

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

    let (api, teardown) = makeAPI { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 500,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { teardown() }

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
    let box = CaptureBox<URLRequest>()

    let (api, teardown) = makeAPI { [url] request in
      box.value = request
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { teardown() }

    try await api.deleteMemory(id: Self.memoryID)

    let req = try #require(box.value)
    #expect(req.httpMethod == "DELETE")
    #expect(req.url == url)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
  }
}
