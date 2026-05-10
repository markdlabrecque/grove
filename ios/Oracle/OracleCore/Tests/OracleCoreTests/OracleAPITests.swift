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
    sourceModality: String = "text",
    sourceDevice: String = "iphone",
    language: String = "en",
    capturedAt: Date = Date()
  ) -> CapturePayload {
    CapturePayload(
      clientID: clientID,
      content: content,
      sourceModality: sourceModality,
      sourceDevice: sourceDevice,
      language: language,
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
      sourceModality: "text",
      sourceDevice: "iphone",
      language: "en",
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
    #expect(decoded.sourceModality == "text")
    #expect(decoded.sourceDevice == "iphone")
    #expect(decoded.language == "en")
    // Timestamp round-trip: allow up to 1 s of floating-point drift.
    #expect(abs(decoded.capturedAt.timeIntervalSince(capturedAt)) < 1.0)
  }

  // MARK: - Schema completeness

  @Test("captureRequest body includes all fields required by server CaptureRequest schema")
  func captureRequestBodyMatchesServerSchema() async throws {
    // Verifies that CaptureRequestBody encodes every field the server
    // validates via its Pydantic CaptureRequest model:
    //   client_id, content, source_modality, source_device, language, captured_at
    let clientID = UUID()
    let capturedAt = Date(timeIntervalSince1970: 1_778_423_400) // 2026-05-10T14:30:00Z
    let payload = CapturePayload(
      clientID: clientID,
      content: "A representative capture used to verify the wire schema.",
      sourceModality: "text",
      sourceDevice: "iphone",
      language: "en",
      capturedAt: capturedAt
    )

    let api = makeAPI()
    let request = try await api.captureRequest(for: payload)

    let body = try #require(request.httpBody)
    let json = try #require(
      try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )

    // Every field the server's CaptureRequest schema requires must be present.
    #expect(json["client_id"] != nil)
    #expect(json["content"] != nil)
    #expect(json["source_modality"] != nil)
    #expect(json["source_device"] != nil)
    #expect(json["language"] != nil)
    #expect(json["captured_at"] != nil)

    // Spot-check concrete values. UUID strings are compared case-insensitively
    // because JSONEncoder uppercases them by default; the server accepts both.
    let encodedClientID = try #require(json["client_id"] as? String)
    #expect(encodedClientID.lowercased() == clientID.uuidString.lowercased())
    #expect(json["source_modality"] as? String == "text")
    #expect(json["source_device"] as? String == "iphone")
    #expect(json["language"] as? String == "en")
  }
}
