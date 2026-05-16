import Testing
import Foundation
import OracleTestSupport
@testable import GroveCore

/// Tests for `OracleAPI.submitFeedback(queryID:feedback:)` —
/// POST /v1/queries/{id}/feedback.
///
/// Uses `FeedbackStubURLProtocol` — a dedicated protocol class with its own
/// static `responder` state, isolated from `StubURLProtocol` and
/// `DeleteStubURLProtocol` used by other suites. This prevents inter-suite
/// global-state contamination when Swift Testing runs suites concurrently.
///
/// The suite is `.serialized` to prevent concurrent access within the suite.
@Suite("OracleAPI submitFeedback", .serialized)
struct OracleAPIFeedbackTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://oracle.example.ts.net")!
  private static let token = "feedback-test-token"
  private static let queryID = UUID(uuidString: "FEEDB000-0000-0000-0000-000000000001")!

  private func makeAPI() -> OracleAPI {
    let config = URLSessionConfiguration.default
    config.protocolClasses = [FeedbackStubURLProtocol.self]
    return OracleAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: config
    )
  }

  private func feedbackURL(for id: UUID) -> URL {
    Self.baseURL.appendingPathComponent("v1/queries/\(id.uuidString.lowercased())/feedback")
  }

  // MARK: - Happy path: 204 No Content

  @Test("submitFeedback returns void on 204 No Content (positive)")
  func submitFeedbackPositiveHappyPath() async throws {
    let url = feedbackURL(for: Self.queryID)

    FeedbackStubURLProtocol.responder = { [url] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { FeedbackStubURLProtocol.responder = nil }

    let api = makeAPI()
    // Should complete without throwing.
    try await api.submitFeedback(queryID: Self.queryID, feedback: .positive)
  }

  @Test("submitFeedback returns void on 204 No Content (negative)")
  func submitFeedbackNegativeHappyPath() async throws {
    let url = feedbackURL(for: Self.queryID)

    FeedbackStubURLProtocol.responder = { [url] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { FeedbackStubURLProtocol.responder = nil }

    let api = makeAPI()
    try await api.submitFeedback(queryID: Self.queryID, feedback: .negative)
  }

  // MARK: - 404: query not found

  @Test("submitFeedback throws httpError(404, _) when query is not found")
  func submitFeedback404() async throws {
    let url = feedbackURL(for: Self.queryID)
    let body = #"{"detail":"query not found"}"#.data(using: .utf8)!

    FeedbackStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { FeedbackStubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      try await api.submitFeedback(queryID: Self.queryID, feedback: .positive)
      Issue.record("Expected APIError.httpError(404, _) but submitFeedback succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, let detail) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 404)
      #expect(detail == "query not found")
    }
  }

  // MARK: - 401: unauthorized

  @Test("submitFeedback throws httpError(401, _) when token is invalid")
  func submitFeedback401() async throws {
    let url = feedbackURL(for: Self.queryID)
    let body = #"{"detail":"unauthorized"}"#.data(using: .utf8)!

    FeedbackStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { FeedbackStubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      try await api.submitFeedback(queryID: Self.queryID, feedback: .negative)
      Issue.record("Expected APIError.httpError(401, _) but submitFeedback succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, _) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 401)
    }
  }

  // MARK: - 5xx: server error (ViewModel is responsible for swallowing)

  @Test("submitFeedback throws httpError(500, _) on generic server error")
  func submitFeedback5xx() async throws {
    let url = feedbackURL(for: Self.queryID)
    let body = #"{"detail":"internal server error"}"#.data(using: .utf8)!

    FeedbackStubURLProtocol.responder = { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 500,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { FeedbackStubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      try await api.submitFeedback(queryID: Self.queryID, feedback: .positive)
      Issue.record("Expected APIError.httpError(500, _) but submitFeedback succeeded.")
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

  @Test("submitFeedback sends POST to /v1/queries/{id}/feedback with correct headers and body")
  func submitFeedbackRequestShape() async throws {
    let url = feedbackURL(for: Self.queryID)
    var capturedRequest: URLRequest?

    FeedbackStubURLProtocol.responder = { [url] request in
      capturedRequest = request
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { FeedbackStubURLProtocol.responder = nil }

    let api = makeAPI()
    try await api.submitFeedback(queryID: Self.queryID, feedback: .positive)

    let req = try #require(capturedRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url == url)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

    // Body must encode {"feedback": "positive"}.
    // URLSession may convert httpBody → httpBodyStream on the delegate-session
    // path, so read whichever is non-nil.
    let bodyData = try #require(req.httpBody ?? req.httpBodyStream.flatMap { stream in
      stream.open()
      defer { stream.close() }
      var data = Data()
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 4096)
        if read > 0 { data.append(buffer, count: read) }
      }
      return data.isEmpty ? nil : data
    })
    let json = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    )
    #expect(json["feedback"] as? String == "positive")
  }

  @Test("submitFeedback encodes 'negative' in request body")
  func submitFeedbackNegativeBody() async throws {
    let url = feedbackURL(for: Self.queryID)
    var capturedRequest: URLRequest?

    FeedbackStubURLProtocol.responder = { [url] request in
      capturedRequest = request
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { FeedbackStubURLProtocol.responder = nil }

    let api = makeAPI()
    try await api.submitFeedback(queryID: Self.queryID, feedback: .negative)

    let req = try #require(capturedRequest)
    let bodyData = try #require(req.httpBody ?? req.httpBodyStream.flatMap { stream in
      stream.open()
      defer { stream.close() }
      var data = Data()
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 4096)
        if read > 0 { data.append(buffer, count: read) }
      }
      return data.isEmpty ? nil : data
    })
    let json = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    )
    #expect(json["feedback"] as? String == "negative")
  }
}

// MARK: - FeedbackStubURLProtocol

/// A dedicated `URLProtocol` subclass for feedback tests that carries its own
/// static `responder` state, isolated from `StubURLProtocol` (used by
/// `OracleAPISmokeTests`) and `DeleteStubURLProtocol` (used by
/// `OracleAPIDeleteTests`). Prevents inter-suite global-state contamination.
private final class FeedbackStubURLProtocol: URLProtocol {

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
    guard let responder = FeedbackStubURLProtocol.responder else {
      preconditionFailure(
        "FeedbackStubURLProtocol.responder must be set before making a request."
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
