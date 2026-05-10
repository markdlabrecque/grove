import Foundation

/// Async HTTP client for the Oracle backend.
///
/// V1 stubs: `postCapture` and `postQuery` return placeholder responses.
/// Real implementations land in tickets #61 (capture path) and #62 (retrieval).
///
/// The actor isolation ensures all mutable state and URLSession callbacks are
/// serialised without manual locking. Network work is dispatched via URLSession
/// onto its own delegate queue and does NOT run on the main actor.
///
/// TODO(auth): When the bearer token moves to Keychain + LAContext (V2 auth
/// migration), update `authorizedRequest(for:)` to read the token from
/// Keychain at call time rather than from `Config.shared.bearerToken`. See
/// `Config.swift` for the matching TODO(auth) marker.
actor OracleAPI {
  // MARK: - Shared instance

  static let shared = OracleAPI()

  // MARK: - Private state

  private let session: URLSession
  private let baseURL: URL
  private let bearerToken: String

  // MARK: - Init

  private init() {
    self.baseURL = Config.shared.baseURL
    self.bearerToken = Config.shared.bearerToken

    // Use a background URLSession configuration so uploads survive app
    // suspension and locked-screen transitions (PRD §6.8, §8.2).
    // The identifier must be stable across launches.
    let config = URLSessionConfiguration.background(
      withIdentifier: "com.markdlabrecque.oracle.background-session"
    )
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    self.session = URLSession(configuration: config)
  }

  /// Designated initialiser used by unit tests.
  ///
  /// Accepts explicit `baseURL`, `bearerToken`, and `session` so tests can
  /// inspect constructed `URLRequest` values without a live server or the
  /// `Background` session configuration (which requires a real bundle
  /// identifier). See `OracleAPITests.swift` for usage.
  init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
    self.session = session
  }

  // MARK: - Capture

  /// Upload a single capture to the server.
  ///
  /// V1 stub — always succeeds immediately. Real implementation in #61.
  func postCapture(_ payload: CapturePayload) async throws -> CaptureResponse {
    // TODO(#61): Implement POST /v1/captures with the background URLSession.
    //            Use `payload.clientID` as the idempotency key per the
    //            server's UNIQUE constraint on `memories.client_id`.
    return CaptureResponse(id: payload.clientID.uuidString)
  }

  /// Build (but do not send) a URLRequest for POST /v1/captures.
  ///
  /// Separated from `postCapture` so unit tests can assert on the fully-formed
  /// request without a live server. Real `postCapture` will call this when
  /// the stub is replaced in #61.
  func captureRequest(for payload: CapturePayload) throws -> URLRequest {
    let url = baseURL.appendingPathComponent("v1/captures")
    var request = authorizedRequest(for: url)
    request.httpMethod = "POST"

    let body = CaptureRequestBody(
      clientID: payload.clientID,
      content: payload.content,
      sourceModality: payload.sourceModality,
      sourceDevice: "iPhone",
      capturedAt: payload.capturedAt
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Key mapping is handled by CaptureRequestBody.CodingKeys; no strategy needed.
    request.httpBody = try encoder.encode(body)
    return request
  }

  // MARK: - Query

  /// Send a natural-language query and receive a synthesised answer.
  ///
  /// V1 stub — returns a placeholder. Real implementation in #62.
  func postQuery(_ queryText: String) async throws -> QueryResponse {
    // TODO(#62): Implement POST /v1/queries; parse the answer and source
    //            memory references for display in QueryView.
    return QueryResponse(
      answer: "Retrieval not yet implemented. Coming in ticket #62.",
      sources: []
    )
  }

  // MARK: - Helpers

  func authorizedRequest(for url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    // TODO(auth): Read token from Keychain rather than Config once V2 auth
    //             migration lands. Delete this comment and the Config bearer
    //             token path at that time.
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }
}

// MARK: - Data transfer objects

struct CapturePayload: Sendable {
  let clientID: UUID
  let content: String
  let sourceModality: String   // "typed" | "dictated"
  let capturedAt: Date
}

/// Wire format sent to POST /v1/captures.
///
/// `CodingKeys` maps Swift camelCase property names to the server's
/// snake_case JSON keys. Using explicit keys instead of `.convertToSnakeCase`
/// avoids the gotcha where `clientID` would encode as `client_i_d` rather
/// than `client_id`.
struct CaptureRequestBody: Codable, Sendable {
  let clientID: UUID
  let content: String
  let sourceModality: String
  let sourceDevice: String
  let capturedAt: Date

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case content
    case sourceModality = "source_modality"
    case sourceDevice = "source_device"
    case capturedAt = "captured_at"
  }
}

/// Wire format returned by POST /v1/captures.
///
/// Matches the server's `CaptureResponse` Pydantic model.
/// `id` and `clientID` are UUIDs; `capturedAt` is an ISO 8601 timestamp
/// (nullable: rows pre-dating migration 0010 may have `captured_at IS NULL`).
struct CaptureResponseBody: Codable, Sendable {
  let id: UUID
  let clientID: UUID
  let capturedAt: Date?
  let enriched: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case clientID = "client_id"
    case capturedAt = "captured_at"
    case enriched
  }
}

struct CaptureResponse: Sendable {
  let id: String
}

struct QueryResponse: Sendable {
  let answer: String
  let sources: [MemorySource]
}

struct MemorySource: Sendable {
  let memoryID: String
  let excerpt: String
  let score: Double
}
