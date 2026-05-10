import Foundation

/// Async HTTP client for the Oracle backend.
///
/// `postCapture` sends to POST /v1/captures via `URLSession.shared` async APIs.
/// `postQuery` is a V1 stub; real implementation lands in ticket #62.
///
/// The actor isolation ensures all mutable state and URLSession callbacks are
/// serialised without manual locking. Network work is dispatched via URLSession
/// onto its own delegate queue and does NOT run on the main actor.
///
/// TODO(auth): When the bearer token moves to Keychain + LAContext (V2 auth
/// migration), update `authorizedRequest(for:)` to read the token from
/// Keychain at call time rather than from `Config.shared.bearerToken`. See
/// `Config.swift` for the matching TODO(auth) marker.
public actor OracleAPI {
  // MARK: - Shared instance

  public static let shared = OracleAPI()

  // MARK: - Private state

  private let session: URLSession
  private let baseURL: URL
  private let bearerToken: String

  // MARK: - Init

  private init() {
    self.baseURL = Config.shared.baseURL
    self.bearerToken = Config.shared.bearerToken

    // V1 uses a default session. A background `URLSessionConfiguration` is
    // incompatible with async `data(for:)` — background sessions require
    // delegate-based `uploadTask`/`downloadTask` calls. V2 will migrate to a
    // proper background + delegate pipeline alongside the offline-queue work
    // (see TODO(offline) on `postCapture`).
    self.session = URLSession(configuration: .default)
  }

  /// Designated initialiser used by unit tests.
  ///
  /// Accepts explicit `baseURL`, `bearerToken`, and `session` so tests can
  /// inspect constructed `URLRequest` values without a live server or the
  /// `Background` session configuration (which requires a real bundle
  /// identifier). See `OracleAPITests.swift` for usage.
  public init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
    self.session = session
  }

  // MARK: - Capture

  /// Upload a single capture to the server (POST /v1/captures).
  ///
  /// Uses the injected `session` (defaulting to `URLSession.shared`) so callers
  /// and tests can swap in a custom session. Network work runs on URLSession's
  /// internal dispatch queue and can be awaited from the caller's async context
  /// without blocking the main actor.
  ///
  /// Throws `APIError` on HTTP-level failures. Does NOT retry — callers are
  /// responsible for re-enqueueing failed captures.
  ///
  /// TODO(offline): V2 should persist failed captures locally in SwiftData,
  /// retry when connectivity returns (NWPathMonitor "satisfied" event), and
  /// reuse the same `client_id` on retry — the server's UNIQUE constraint on
  /// `memories.client_id` guarantees idempotency so duplicate uploads are
  /// harmless no-ops. V2 should also migrate to a background `URLSession`
  /// with a `URLSessionDataDelegate` so uploads survive app suspension; V1
  /// uses the default config because async `data(for:)` is incompatible with
  /// background sessions.
  public func postCapture(_ payload: CapturePayload) async throws -> CaptureResponseBody {
    let request = try captureRequest(for: payload)

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.unexpectedResponse
    }

    let status = httpResponse.statusCode
    print("[capture] sent client_id=\(payload.clientID.uuidString.lowercased()) status=\(status)")

    // 200 (idempotent re-upload) and 201 (new record) are both success.
    guard status == 200 || status == 201 else {
      // Try to extract the server's `detail` field from the JSON error body.
      let detail = extractDetail(from: data)
      throw APIError.httpError(statusCode: status, detail: detail)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CaptureResponseBody.self, from: data)
  }

  /// Build (but do not send) a URLRequest for POST /v1/captures.
  ///
  /// Separated from `postCapture` so unit tests can assert on the fully-formed
  /// request without a live server.
  public func captureRequest(for payload: CapturePayload) throws -> URLRequest {
    let url = baseURL.appendingPathComponent("v1/captures")
    var request = authorizedRequest(for: url)
    request.httpMethod = "POST"

    let body = CaptureRequestBody(
      clientID: payload.clientID,
      content: payload.content,
      sourceModality: payload.sourceModality,
      sourceDevice: payload.sourceDevice,
      language: payload.language,
      capturedAt: payload.capturedAt
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Key mapping is handled by CaptureRequestBody.CodingKeys; no strategy needed.
    request.httpBody = try encoder.encode(body)
    return request
  }

  // MARK: - Query

  /// Send a natural-language query and receive ranked memory snippets.
  ///
  /// Hits POST /v1/queries with `{"query": <text>, "limit": 10}`. Decodes
  /// the server's `QueryResponse` shape into `QueryResponseBody`. Same auth
  /// and Content-Type pattern as `postCapture`.
  ///
  /// Throws `APIError` on HTTP-level failures. The caller owns retry logic.
  ///
  /// TODO(offline): V2 should queue failed queries locally and retry on
  /// NWPathMonitor "satisfied", consistent with the capture offline strategy.
  public func postQuery(_ queryText: String, limit: Int = 10) async throws -> QueryResponseBody {
    let url = baseURL.appendingPathComponent("v1/queries")
    var request = authorizedRequest(for: url)
    request.httpMethod = "POST"

    let body = QueryRequestBody(query: queryText, limit: limit)
    let encoder = JSONEncoder()
    request.httpBody = try encoder.encode(body)

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.unexpectedResponse
    }

    let status = httpResponse.statusCode
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    print("[query] sent query_chars=\(queryText.count) status=\(status)")

    guard status == 200 else {
      let detail = extractDetail(from: data)
      throw APIError.httpError(statusCode: status, detail: detail)
    }

    let result = try decoder.decode(QueryResponseBody.self, from: data)
    print("[query] sent query_chars=\(queryText.count) status=\(status) results=\(result.results.count)")
    return result
  }

  // MARK: - Helpers

  public func authorizedRequest(for url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    // TODO(auth): Read token from Keychain rather than Config once V2 auth
    //             migration lands. Delete this comment and the Config bearer
    //             token path at that time.
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  /// Extract the `detail` string from a FastAPI-style JSON error body.
  ///
  /// FastAPI returns `{"detail": "…"}` for 4xx/5xx errors. Returns `nil`
  /// if the body is not JSON or does not contain a `detail` key.
  private func extractDetail(from data: Data) -> String? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let detail = json["detail"] as? String
    else { return nil }
    return detail
  }
}

// MARK: - API errors

/// Errors surfaced by `OracleAPI` network calls.
public enum APIError: Error, LocalizedError {
  case unexpectedResponse
  case httpError(statusCode: Int, detail: String?)

  public var errorDescription: String? {
    switch self {
    case .unexpectedResponse:
      return "Received an unexpected response from the server."
    case .httpError(let code, let detail):
      if let detail {
        return detail
      }
      return "Server returned HTTP \(code)."
    }
  }
}

// MARK: - Data transfer objects

public struct CapturePayload: Sendable {
  public let clientID: UUID
  public let content: String
  public let sourceModality: String   // "text" | "voice"
  public let sourceDevice: String     // "iphone"
  public let language: String         // BCP-47 language code, e.g. "en"
  public let capturedAt: Date

  public init(
    clientID: UUID,
    content: String,
    sourceModality: String,
    sourceDevice: String,
    language: String,
    capturedAt: Date
  ) {
    self.clientID = clientID
    self.content = content
    self.sourceModality = sourceModality
    self.sourceDevice = sourceDevice
    self.language = language
    self.capturedAt = capturedAt
  }
}

/// Wire format sent to POST /v1/captures.
///
/// `CodingKeys` maps Swift camelCase property names to the server's
/// snake_case JSON keys. Using explicit keys instead of `.convertToSnakeCase`
/// avoids the gotcha where `clientID` would encode as `client_i_d` rather
/// than `client_id`.
public struct CaptureRequestBody: Codable, Sendable {
  public let clientID: UUID
  public let content: String
  public let sourceModality: String
  public let sourceDevice: String
  public let language: String
  public let capturedAt: Date

  public enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case content
    case sourceModality = "source_modality"
    case sourceDevice = "source_device"
    case language
    case capturedAt = "captured_at"
  }
}

/// Wire format returned by POST /v1/captures.
///
/// Matches the server's `CaptureResponse` Pydantic model.
/// `id` and `clientID` are UUIDs; `capturedAt` is an ISO 8601 timestamp
/// (nullable: rows pre-dating migration 0010 may have `captured_at IS NULL`).
public struct CaptureResponseBody: Codable, Sendable {
  public let id: UUID
  public let clientID: UUID
  public let capturedAt: Date?
  public let enriched: Bool

  public enum CodingKeys: String, CodingKey {
    case id
    case clientID = "client_id"
    case capturedAt = "captured_at"
    case enriched
  }
}

/// Wire format sent to POST /v1/queries.
public struct QueryRequestBody: Codable, Sendable {
  public let query: String
  public let limit: Int

  public init(query: String, limit: Int = 10) {
    self.query = query
    self.limit = limit
  }
}

/// A single ranked result returned by POST /v1/queries.
///
/// `matchedVia` is either `"whole"` (whole-memory cosine match) or `"chunk"`
/// (chunk-level match). When `"chunk"`, `matchedChunkIndex` carries the
/// 0-based chunk index from the server.
public struct QueryResult: Codable, Sendable {
  public let memoryID: UUID
  public let score: Float
  public let matchedVia: String         // "whole" | "chunk"
  public let matchedChunkIndex: Int?    // 0-based; nil when matchedVia == "whole"
  public let snippet: String
  public let capturedAt: Date?
  public let sourceModality: String?

  public enum CodingKeys: String, CodingKey {
    case memoryID = "memory_id"
    case score
    case matchedVia = "matched_via"
    case matchedChunkIndex = "matched_chunk_index"
    case snippet
    case capturedAt = "captured_at"
    case sourceModality = "source_modality"
  }
}

/// Wire format returned by POST /v1/queries.
///
/// Matches the server's `QueryResponse` Pydantic model.
public struct QueryResponseBody: Codable, Sendable {
  public let results: [QueryResult]
  public let queryTokenCount: Int
  public let latencyMs: Double

  public enum CodingKeys: String, CodingKey {
    case results
    case queryTokenCount = "query_token_count"
    case latencyMs = "latency_ms"
  }
}
