import Testing
import Foundation
@testable import OracleCore

/// Tests for OracleAPI — specifically the URLRequest builder for
/// POST /v1/captures and POST /v1/queries.
///
/// These tests do NOT make live network calls. They construct an OracleAPI
/// instance via the public `init(baseURL:bearerToken:captureSession:querySession:)` and assert
/// on the resulting URLRequest produced by `captureRequest(for:)`.
///
/// # Note on request body
///
/// V2 `captureRequest(for:)` does not set `httpBody` — the body is written to a
/// temp file and passed to `uploadTask(with:fromFile:)` in `postCapture`. Body
/// encoding is tested separately in `CaptureRequestBodyEncodingTests` below,
/// and the full end-to-end round-trip (including the body arriving at the server)
/// is covered by `OracleAPISmokeTests`.
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
}

// MARK: - CaptureRequestBody encoding

/// Validates that `CaptureRequestBody` encodes all fields the server's
/// `CaptureRequest` Pydantic schema requires, with correct snake_case keys
/// and ISO 8601 dates.
///
/// V2 separates body encoding into `CaptureRequestBody` (written to a temp
/// file) from the URLRequest headers (built in `captureRequest(for:)`). These
/// tests target the encoding step directly, independent of how the body is
/// delivered to the server.
@Suite("CaptureRequestBody encoding")
struct CaptureRequestBodyEncodingTests {

  private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  @Test("CaptureRequestBody encodes all server-required fields with correct snake_case keys")
  func encodesAllRequiredFields() throws {
    let clientID = UUID()
    let capturedAt = Date(timeIntervalSince1970: 1_778_423_400) // 2026-05-10T14:30:00Z
    let body = CaptureRequestBody(
      clientID: clientID,
      content: "Remember to call Theo about the demo.",
      sourceModality: "text",
      sourceDevice: "iphone",
      language: "en",
      capturedAt: capturedAt
    )

    let data = try makeEncoder().encode(body)
    let json = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    // Every field the server's CaptureRequest schema requires must be present.
    #expect(json["client_id"] != nil)
    #expect(json["content"] != nil)
    #expect(json["source_modality"] != nil)
    #expect(json["source_device"] != nil)
    #expect(json["language"] != nil)
    #expect(json["captured_at"] != nil)

    // Spot-check concrete values.
    let encodedClientID = try #require(json["client_id"] as? String)
    #expect(encodedClientID.lowercased() == clientID.uuidString.lowercased())
    #expect(json["source_modality"] as? String == "text")
    #expect(json["source_device"] as? String == "iphone")
    #expect(json["language"] as? String == "en")
  }

  @Test("CaptureRequestBody round-trips through JSON decoder correctly")
  func roundTrips() throws {
    let clientID = UUID()
    let capturedAt = Date(timeIntervalSince1970: 1_778_423_400)
    let original = CaptureRequestBody(
      clientID: clientID,
      content: "A representative capture.",
      sourceModality: "text",
      sourceDevice: "iphone",
      language: "en",
      capturedAt: capturedAt
    )

    let data = try makeEncoder().encode(original)
    let decoded = try makeDecoder().decode(CaptureRequestBody.self, from: data)

    #expect(decoded.clientID == clientID)
    #expect(decoded.content == original.content)
    #expect(decoded.sourceModality == "text")
    #expect(decoded.sourceDevice == "iphone")
    #expect(decoded.language == "en")
    #expect(abs(decoded.capturedAt.timeIntervalSince(capturedAt)) < 1.0)
  }
}
