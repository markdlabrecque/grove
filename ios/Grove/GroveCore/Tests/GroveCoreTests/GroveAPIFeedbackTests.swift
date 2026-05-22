import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

/// Tests for `GroveAPI.submitFeedback(queryID:feedback:)` —
/// POST /v1/queries/{id}/feedback.
///
/// Uses `StubURLProtocol.makeSession(responder:)` (#422) for per-test
/// isolation. Each test obtains its own `URLSessionConfiguration` with a
/// unique stub ID embedded, so concurrent suites cannot corrupt each other's
/// responders. Tests in this suite run in parallel to verify the isolation is
/// race-free.
@Suite("GroveAPI submitFeedback")
struct GroveAPIFeedbackTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "feedback-test-token"
  private static let queryID = UUID(uuidString: "FEEDB000-0000-0000-0000-000000000001")!

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

  private func feedbackURL(for id: UUID) -> URL {
    Self.baseURL.appendingPathComponent("v1/queries/\(id.uuidString.lowercased())/feedback")
  }

  // MARK: - Happy path: 204 No Content

  @Test("submitFeedback returns void on 204 No Content (positive)")
  func submitFeedbackPositiveHappyPath() async throws {
    let url = feedbackURL(for: Self.queryID)

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
    try await api.submitFeedback(queryID: Self.queryID, feedback: .positive)
  }

  @Test("submitFeedback returns void on 204 No Content (negative)")
  func submitFeedbackNegativeHappyPath() async throws {
    let url = feedbackURL(for: Self.queryID)

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

    try await api.submitFeedback(queryID: Self.queryID, feedback: .negative)
  }

  // MARK: - 404: query not found

  @Test("submitFeedback throws httpError(404, _) when query is not found")
  func submitFeedback404() async throws {
    let url = feedbackURL(for: Self.queryID)
    let body = #"{"detail":"query not found"}"#.data(using: .utf8)!

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

    try await api.submitFeedback(queryID: Self.queryID, feedback: .positive)

    let req = try #require(box.value)
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

    try await api.submitFeedback(queryID: Self.queryID, feedback: .negative)

    let req = try #require(box.value)
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
