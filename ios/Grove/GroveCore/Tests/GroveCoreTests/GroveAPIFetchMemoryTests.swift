import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

/// Tests for `GroveAPI.fetchMemory(id:)` — GET /v1/memories/{id}.
///
/// Uses `StubURLProtocol.makeSession(responder:)` for per-test isolation.
/// Tests cover:
///   - Happy path: 200 returns a decoded `MemoryDetailDTO` with correct fields.
///   - URL shape: GET to /v1/memories/{id} with correct Authorization header.
///   - 404: throws `APIError.httpError(404, _)`.
///   - 401: throws `APIError.httpError(401, _)`.
@Suite("GroveAPI fetchMemory")
struct GroveAPIFetchMemoryTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "fetch-test-token"
  private static let memoryID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")!

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

  private func fetchURL(for id: UUID) -> URL {
    Self.baseURL.appendingPathComponent("v1/memories/\(id.uuidString.lowercased())")
  }

  // MARK: - Happy path: 200 returns decoded MemoryDetailDTO

  @Test("fetchMemory returns MemoryDetailDTO on 200 OK")
  func fetchMemoryHappyPath() async throws {
    let url = fetchURL(for: Self.memoryID)
    let capturedAt = "2025-05-21T10:00:00+00:00"
    let body = """
    {
      "id": "\(Self.memoryID.uuidString.lowercased())",
      "content": "Remember to buy oat milk.",
      "captured_at": "\(capturedAt)",
      "source_modality": "text"
    }
    """.data(using: .utf8)!

    let (api, teardown) = makeAPI { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { teardown() }

    let dto = try await api.fetchMemory(id: Self.memoryID)

    #expect(dto.id == Self.memoryID)
    #expect(dto.content == "Remember to buy oat milk.")
    #expect(dto.sourceModality == "text")
    #expect(dto.capturedAt != nil)
  }

  // MARK: - Request shape

  @Test("fetchMemory sends GET to /v1/memories/{id} with correct Authorization header")
  func fetchMemoryRequestShape() async throws {
    let url = fetchURL(for: Self.memoryID)
    let box = CaptureBox<URLRequest>()
    let body = """
    {
      "id": "\(Self.memoryID.uuidString.lowercased())",
      "content": "Shape test content.",
      "captured_at": null,
      "source_modality": null
    }
    """.data(using: .utf8)!

    let (api, teardown) = makeAPI { [url, body] request in
      box.value = request
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { teardown() }

    _ = try await api.fetchMemory(id: Self.memoryID)

    let req = try #require(box.value)
    // Default HTTP method is GET (URLRequest does not set the method for GETs explicitly,
    // so it remains nil or "GET"; both indicate a GET request.)
    let method = req.httpMethod ?? "GET"
    #expect(method == "GET")
    #expect(req.url == url)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
  }

  // MARK: - 404: memory not found

  @Test("fetchMemory throws httpError(404, _) when memory is not found")
  func fetchMemory404() async throws {
    let url = fetchURL(for: Self.memoryID)
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
      _ = try await api.fetchMemory(id: Self.memoryID)
      Issue.record("Expected APIError.httpError(404, _) but fetchMemory succeeded.")
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

  @Test("fetchMemory throws httpError(401, _) when token is invalid")
  func fetchMemory401() async throws {
    let url = fetchURL(for: Self.memoryID)
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
      _ = try await api.fetchMemory(id: Self.memoryID)
      Issue.record("Expected APIError.httpError(401, _) but fetchMemory succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, _) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 401)
    }
  }
}
