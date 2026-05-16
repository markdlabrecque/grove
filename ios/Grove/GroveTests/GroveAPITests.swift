import Testing
import Foundation
import GroveCore
@testable import Grove

/// Tests for GroveAPI — specifically the URLRequest builder for
/// POST /v1/captures.
///
/// These tests do NOT make live network calls. They construct an GroveAPI
/// instance via the public `init(baseURL:bearerToken:)` and assert on the
/// resulting URLRequest produced by `captureRequest(for:)`.
///
/// # Note on request body
///
/// V2 `captureRequest(for:)` does not set `httpBody` — the body is written to a
/// temp file and passed to `uploadTask(with:fromFile:)` in `postCapture`.
/// Body encoding is tested in `CaptureRequestBody` encoding tests below, and
/// the full end-to-end round-trip is covered by the `GroveCore` smoke tests.
@Suite("GroveAPI")
struct GroveAPITests {

  // Shared test fixtures
  private static let baseURL = URL(string: "https://oracle.example.ts.net")!
  private static let token = "test-bearer-token"

  private func makeAPI() -> GroveAPI {
    GroveAPI(
      baseURL: GroveAPITests.baseURL,
      bearerToken: GroveAPITests.token
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
    let expected = GroveAPITests.baseURL
      .appendingPathComponent("v1/captures")
    #expect(request.url == expected)
  }

  // MARK: - Headers

  @Test("captureRequest sets Authorization header")
  func captureRequestAuthorizationHeader() async throws {
    let api = makeAPI()
    let request = try await api.captureRequest(for: makePayload())
    let header = request.value(forHTTPHeaderField: "Authorization")
    #expect(header == "Bearer \(GroveAPITests.token)")
  }

  @Test("captureRequest sets Content-Type header")
  func captureRequestContentTypeHeader() async throws {
    let api = makeAPI()
    let request = try await api.captureRequest(for: makePayload())
    let header = request.value(forHTTPHeaderField: "Content-Type")
    #expect(header == "application/json")
  }
}
