import Testing
import Foundation
import OracleTestSupport
@testable import OracleCore

/// Smoke tests that exercise `OracleAPI` through the same `URLSession(configuration:)`
/// code path as the production singleton (`OracleAPI.shared`).
///
/// # Why this suite exists
///
/// `OracleAPITests` only exercises request-building (`captureRequest(for:)`) and
/// never actually calls `session.data(for:)`. The bug fixed in #87 — constructing
/// `OracleAPI.shared` with a background `URLSessionConfiguration`, then calling
/// the async `data(for:)` API — was invisible to that suite because the broken
/// code path was never executed.
///
/// These smoke tests use `StubURLProtocol` injected via the internal
/// `OracleAPI.init(baseURL:bearerToken:configuration:)` so that `URLSession` is
/// constructed the same way the singleton does it (via
/// `URLSession(configuration:)`), but with a `.default`-shaped config rather
/// than a `.background(...)` one. This makes the async `data(for:)` call legal
/// and exercises the full round-trip up to (but not including) the real network.
///
/// # Serialization
///
/// `StubURLProtocol.responder` is a static property, so tests must not run in
/// parallel — the `@Suite(.serialized)` annotation opts out of Swift Testing's
/// default concurrent runner.
@Suite("OracleAPI Smoke Tests", .serialized)
struct OracleAPISmokeTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://oracle.example.ts.net")!
  private static let token = "smoke-test-token"

  /// Build an `OracleAPI` whose `URLSession` uses a `.default` configuration
  /// augmented with `StubURLProtocol`. This mirrors the singleton's session
  /// construction path (`.default` config → `URLSession(configuration:)`) and
  /// is the path that the #87 regression broke.
  private func makeAPI() -> OracleAPI {
    let config = URLSessionConfiguration.default
    config.protocolClasses = [StubURLProtocol.self]
    return OracleAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: config
    )
  }

  private func makePayload(content: String = "Buy oat milk.") -> CapturePayload {
    CapturePayload(
      clientID: UUID(),
      content: content,
      sourceModality: "text",
      sourceDevice: "iphone",
      language: "en",
      capturedAt: Date()
    )
  }

  // MARK: - Helpers

  private func loadFixture(_ name: String) throws -> Data {
    // .process("Fixtures") in Package.swift copies JSON files to the bundle
    // root — no subdirectory argument needed here.
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
      throw FixtureError.notFound(name)
    }
    return try Data(contentsOf: url)
  }

  private enum FixtureError: Error {
    case notFound(String)
  }

  // MARK: - postCapture happy path

  @Test("postCapture happy path: stub returns 201, response decodes correctly")
  func postCaptureHappyPath() async throws {
    let captureURL = Self.baseURL.appendingPathComponent("v1/captures")
    let responseData = try loadFixture("capture_response")

    StubURLProtocol.responder = { [captureURL, responseData] _ in
      let resp = HTTPURLResponse(
        url: captureURL,
        statusCode: 201,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, responseData)
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
    let result = try await api.postCapture(makePayload())

    // Spot-check the decoded fixture values.
    #expect(result.id == UUID(uuidString: "b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f"))
    #expect(result.clientID == UUID(uuidString: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"))
    #expect(result.enriched == false)
  }

  // MARK: - postQuery happy path

  @Test("postQuery happy path: stub returns 200, results decode correctly")
  func postQueryHappyPath() async throws {
    let queryURL = Self.baseURL.appendingPathComponent("v1/queries")
    let responseData = try loadFixture("query_response")

    StubURLProtocol.responder = { [queryURL, responseData] _ in
      let resp = HTTPURLResponse(
        url: queryURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, responseData)
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
    let result = try await api.postQuery("SwiftData local store")

    #expect(result.results.count == 2)
    #expect(result.queryTokenCount == 7)
    #expect(result.latencyMs == 612.4)

    let first = try #require(result.results.first)
    #expect(first.matchedVia == "whole")
    #expect(first.score > 0.9)
  }

  // MARK: - Network failure / HTTP error path

  @Test("postCapture HTTP 500 throws APIError.httpError(500, _)")
  func postCaptureHTTPError() async throws {
    let captureURL = Self.baseURL.appendingPathComponent("v1/captures")
    let errorBody = #"{"detail":"internal server error"}"#.data(using: .utf8)!

    StubURLProtocol.responder = { [captureURL, errorBody] _ in
      let resp = HTTPURLResponse(
        url: captureURL,
        statusCode: 500,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, errorBody)
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()

    do {
      _ = try await api.postCapture(makePayload())
      Issue.record("Expected APIError.httpError to be thrown, but postCapture succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, let detail) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 500)
      #expect(detail == "internal server error")
    }
  }

  // MARK: - Background session regression test (#87)

  /// Regression test for #87: constructing a URLSession with a background
  /// configuration and then calling async `data(for:)` triggers an NSException
  /// at runtime ("background session") that cannot be caught as a Swift `Error`.
  ///
  /// # What this test verifies
  ///
  /// The production singleton's `private init()` now uses `.default` (the fix
  /// from #87). This test confirms that path — constructing a session via
  /// `URLSession(configuration: .default)` and calling `data(for:)` — works
  /// correctly end-to-end, by using a `.default`-shaped config with
  /// `StubURLProtocol` injected. If someone regresses the singleton back to
  /// `.background(...)`, this test won't catch it directly (because
  /// `NSException` isn't a Swift `Error`), but it DOES prove that the
  /// `.default` path is green.
  ///
  /// # Why we don't test the background config directly
  ///
  /// `URLSession.data(for:)` raises an `NSException` (not a Swift `Error`)
  /// when called on a background-configured session. NSExceptions bypass
  /// Swift's `do/try/catch` and terminate the process. There is no portable
  /// way to catch an `NSException` in Swift without an Objective-C wrapper,
  /// and adding one would introduce test-only production complexity.
  ///
  /// Instead, we document the limitation here and rely on code review to keep
  /// the singleton's `private init()` using `.default`. The comment block in
  /// `OracleAPI.swift`'s `private init()` is the source of truth for that
  /// constraint.
  @Test("postCapture succeeds through URLSession(configuration: .default) path")
  func defaultConfigPathSucceeds() async throws {
    // This test is the affirmative half of the #87 regression guard: the
    // .default config + async data(for:) path must work end-to-end.
    let captureURL = Self.baseURL.appendingPathComponent("v1/captures")
    let responseData = try loadFixture("capture_response")

    StubURLProtocol.responder = { [captureURL, responseData] _ in
      let resp = HTTPURLResponse(
        url: captureURL,
        statusCode: 201,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, responseData)
    }
    defer { StubURLProtocol.responder = nil }

    // Explicit .default config — same shape as OracleAPI.shared's session.
    let config = URLSessionConfiguration.default
    config.protocolClasses = [StubURLProtocol.self]
    let api = OracleAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: config
    )

    // If this throws or crashes, the .default path is broken.
    let result = try await api.postCapture(makePayload())
    #expect(result.enriched == false)
  }
}
