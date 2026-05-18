import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

/// Tests for `GroveAPI.recentQueries(limit:)` — GET /v1/queries/recent.
///
/// Uses `RecentQueriesStubURLProtocol` — a dedicated protocol class with its
/// own static `responder` state, isolated from other stub protocols to prevent
/// inter-suite global-state contamination.
///
/// The suite is `.serialized` to prevent concurrent access within the suite.
@Suite("GroveAPI recentQueries", .serialized)
struct GroveAPIRecentQueriesTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "recent-queries-test-token"

  private func makeAPI() -> GroveAPI {
    let config = URLSessionConfiguration.default
    config.protocolClasses = [RecentQueriesStubURLProtocol.self]
    return GroveAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: config
    )
  }

  private func recentURL(limit: Int = 10) -> URL {
    var comps = URLComponents(
      url: Self.baseURL.appendingPathComponent("v1/queries/recent"),
      resolvingAgainstBaseURL: false
    )!
    comps.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
    return comps.url!
  }

  /// Build a minimal JSON array fixture for `limit` items.
  private func makeRecentQueriesJSON(count: Int) -> Data {
    var items: [[String: Any]] = []
    for i in 0..<count {
      items.append([
        "id": "A0000000-0000-0000-0000-\(String(format: "%012d", i + 1))",
        "query_text": "query \(i + 1)",
        "created_at": "2026-05-14T12:0\(i):00Z"
      ])
    }
    return try! JSONSerialization.data(withJSONObject: items)
  }

  // MARK: - Happy path: 200 with array

  @Test("recentQueries returns decoded array on 200")
  func recentQueriesHappyPath() async throws {
    let url = recentURL()
    let body = makeRecentQueriesJSON(count: 3)

    RecentQueriesStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { RecentQueriesStubURLProtocol.responder = nil }

    let api = makeAPI()
    let items = try await api.recentQueries(limit: 10)

    #expect(items.count == 3)
    #expect(items[0].queryText == "query 1")
    #expect(items[1].queryText == "query 2")
    #expect(items[2].queryText == "query 3")
  }

  // MARK: - Empty list (zero recent queries)

  @Test("recentQueries returns empty array on 200 with empty list")
  func recentQueriesEmptyList() async throws {
    let url = recentURL()
    let body = "[]".data(using: .utf8)!

    RecentQueriesStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { RecentQueriesStubURLProtocol.responder = nil }

    let api = makeAPI()
    let items = try await api.recentQueries(limit: 10)

    #expect(items.isEmpty)
  }

  // MARK: - 401: unauthorized

  @Test("recentQueries throws httpError(401, _) when token is invalid")
  func recentQueries401() async throws {
    let url = recentURL()
    let body = #"{"detail":"unauthorized"}"#.data(using: .utf8)!

    RecentQueriesStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { RecentQueriesStubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      _ = try await api.recentQueries(limit: 10)
      Issue.record("Expected APIError.httpError(401, _) but recentQueries succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, _) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 401)
    }
  }

  // MARK: - 422: out-of-range limit

  @Test("recentQueries throws httpError(422, _) when limit is out of range")
  func recentQueries422() async throws {
    let url = recentURL(limit: 0)
    let body = #"{"detail":"limit must be >= 1"}"#.data(using: .utf8)!

    RecentQueriesStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 422,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { RecentQueriesStubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      _ = try await api.recentQueries(limit: 0)
      Issue.record("Expected APIError.httpError(422, _) but recentQueries succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, _) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 422)
    }
  }

  // MARK: - 5xx: server error

  @Test("recentQueries throws httpError(500, _) on generic server error")
  func recentQueries5xx() async throws {
    let url = recentURL()
    let body = #"{"detail":"internal server error"}"#.data(using: .utf8)!

    RecentQueriesStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 500,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { RecentQueriesStubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      _ = try await api.recentQueries(limit: 10)
      Issue.record("Expected APIError.httpError(500, _) but recentQueries succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, let detail) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 500)
      #expect(detail == "internal server error")
    }
  }

  // MARK: - Request shape: URL must include ?limit=N

  @Test("recentQueries sends GET to /v1/queries/recent?limit=10 with correct headers")
  func recentQueriesRequestShape() async throws {
    let url = recentURL(limit: 10)
    var capturedRequest: URLRequest?

    RecentQueriesStubURLProtocol.responder = { [url] request in
      capturedRequest = request
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, "[]".data(using: .utf8)!)
    }
    defer { RecentQueriesStubURLProtocol.responder = nil }

    let api = makeAPI()
    _ = try await api.recentQueries(limit: 10)

    let req = try #require(capturedRequest)
    #expect(req.httpMethod == "GET")

    // URL must have query parameter limit=10.
    let components = try #require(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
    let limitItem = components.queryItems?.first(where: { $0.name == "limit" })
    #expect(limitItem?.value == "10")

    // Path must be /v1/queries/recent.
    #expect(components.path.hasSuffix("/v1/queries/recent"))

    // Authorization header must be present.
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
  }

  @Test("recentQueries sends GET with limit=5 in URL")
  func recentQueriesRequestShapeLimit5() async throws {
    let url = recentURL(limit: 5)
    var capturedRequest: URLRequest?

    RecentQueriesStubURLProtocol.responder = { [url] request in
      capturedRequest = request
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, "[]".data(using: .utf8)!)
    }
    defer { RecentQueriesStubURLProtocol.responder = nil }

    let api = makeAPI()
    _ = try await api.recentQueries(limit: 5)

    let req = try #require(capturedRequest)
    let components = try #require(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
    let limitItem = components.queryItems?.first(where: { $0.name == "limit" })
    #expect(limitItem?.value == "5")
  }
}

// MARK: - RecentQueriesStubURLProtocol

/// A dedicated `URLProtocol` subclass for recent-queries tests that carries its
/// own static `responder` state, isolated from other stub protocols. Prevents
/// inter-suite global-state contamination.
private final class RecentQueriesStubURLProtocol: URLProtocol {

  /// Configure this before each test. The suite is `.serialized` so access is
  /// externally synchronised without a Swift concurrency primitive.
  nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    guard let responder = RecentQueriesStubURLProtocol.responder else {
      preconditionFailure(
        "RecentQueriesStubURLProtocol.responder must be set before making a request."
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
