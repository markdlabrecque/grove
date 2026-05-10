import Testing
import Foundation
@testable import OracleCore

/// Tests for OracleAPI — specifically the URLRequest builder for
/// POST /v1/captures.
///
/// These tests do NOT make live network calls. They construct an OracleAPI
/// instance via the internal `init(baseURL:bearerToken:session:)` and assert
/// on the resulting URLRequest produced by `captureRequest(for:)`.
@Suite("OracleAPI")
struct OracleAPITests {

  // Shared test fixtures
  private static let baseURL = URL(string: "https://oracle.example.ts.net")!
  private static let token = "test-bearer-token"

  private func makeAPI() -> OracleAPI {
    OracleAPI(
      baseURL: OracleAPITests.baseURL,
      bearerToken: OracleAPITests.token
    )
  }

  private func makePayload(
    clientID: UUID = UUID(),
    content: String = "Remember to call Theo about the demo.",
    sourceModality: String = "typed",
    capturedAt: Date = Date()
  ) -> CapturePayload {
    CapturePayload(
      clientID: clientID,
      content: content,
      sourceModality: sourceModality,
      capturedAt: capturedAt
    )
  }

  // MARK: - Method

  @Test("captureRequest uses HTTP POST method")
  func captureRequestIsPost() async throws {
    let api = makeAPI()
    let request = try await api.captureRequest(for: makePayload())
    #expect(request.httpMethod == "POST")
  }

  // MARK: - URL

  @Test("captureRequest URL is baseURL/v1/captures")
  func captureRequestURL() async throws {
    let api = makeAPI()
    let request = try await api.captureRequest(for: makePayload())
    let expected = OracleAPITests.baseURL
      .appendingPathComponent("v1/captures")
    #expect(request.url == expected)
  }

  // MARK: - Headers

  @Test("captureRequest sets Authorization header")
  func captureRequestAuthorizationHeader() async throws {
    let api = makeAPI()
    let request = try await api.captureRequest(for: makePayload())
    let header = request.value(forHTTPHeaderField: "Authorization")
    #expect(header == "Bearer \(OracleAPITests.token)")
  }

  @Test("captureRequest sets Content-Type header")
  func captureRequestContentTypeHeader() async throws {
    let api = makeAPI()
    let request = try await api.captureRequest(for: makePayload())
    let header = request.value(forHTTPHeaderField: "Content-Type")
    #expect(header == "application/json")
  }

  // MARK: - Body

  @Test("captureRequest body is valid JSON matching CaptureRequestBody schema")
  func captureRequestBodyIsValidJSON() async throws {
    let clientID = UUID()
    let capturedAt = Date(timeIntervalSince1970: 1_778_423_400) // 2026-05-10T14:30:00Z
    let payload = makePayload(
      clientID: clientID,
      content: "Remember to call Theo about the demo.",
      sourceModality: "typed",
      capturedAt: capturedAt
    )

    let api = makeAPI()
    let request = try await api.captureRequest(for: payload)

    let body = try #require(request.httpBody)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // CaptureRequestBody uses explicit CodingKeys; no key strategy needed.
    let decoded = try decoder.decode(CaptureRequestBody.self, from: body)

    #expect(decoded.clientID == clientID)
    #expect(decoded.content == payload.content)
    #expect(decoded.sourceModality == payload.sourceModality)
    #expect(!decoded.sourceDevice.isEmpty)
    // Timestamp round-trip: allow up to 1 s of floating-point drift.
    #expect(abs(decoded.capturedAt.timeIntervalSince(capturedAt)) < 1.0)
  }
}
