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

  private func authorizedRequest(for url: URL) -> URLRequest {
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
