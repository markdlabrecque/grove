import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

/// Verifies that `StubURLProtocol.makeSession(responder:)` provides per-test
/// isolation so concurrent suites cannot corrupt each other's responders.
///
/// These tests call the new factory API introduced in #422. Before that change
/// the only way to configure a stub was to mutate the static `responder`
/// property directly — a pattern that is not safe when Swift Testing runs
/// multiple `.serialized` suites in parallel.
///
/// # Red-commit note
///
/// This file is committed first (red). It references `StubURLProtocol.makeSession`
/// which does not exist yet, so the package will not compile until the green
/// commit lands.
@Suite("StubURLProtocol isolation")
struct StubURLProtocolIsolationTests {

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "isolation-test-token"

  // MARK: - makeSession factory returns a configured URLSessionConfiguration

  @Test("makeSession: returned configuration intercepts requests via StubURLProtocol")
  func makeSessionConfigurationUsesStub() async throws {
    let responseBody = Data("{\"ok\":true}".utf8)
    let (config, teardown) = StubURLProtocol.makeSession { request in
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, responseBody)
    }
    defer { teardown() }

    let session = URLSession(configuration: config)
    let targetURL = Self.baseURL.appendingPathComponent("v1/captures")
    var req = URLRequest(url: targetURL)
    // URLSession normally merges httpAdditionalHeaders automatically, but that
    // merge only happens when the task is created via URLSessionTask helpers.
    // Because we build URLRequest directly here, we copy the headers manually
    // so the stub-ID header reaches StubURLProtocol's canInit check.
    req.allHTTPHeaderFields = config.httpAdditionalHeaders as? [String: String]
    let (data, response) = try await session.data(for: req)

    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(data == responseBody)
  }

  // MARK: - Two concurrent sessions don't bleed responders

  @Test("makeSession: two concurrent sessions receive their own responders")
  func concurrentSessionsAreIsolated() async throws {
    let bodyA = Data("session-A".utf8)
    let bodyB = Data("session-B".utf8)

    let (configA, teardownA) = StubURLProtocol.makeSession { request in
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (resp, bodyA)
    }
    let (configB, teardownB) = StubURLProtocol.makeSession { request in
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 201,
        httpVersion: nil,
        headerFields: nil
      )!
      return (resp, bodyB)
    }
    defer { teardownA(); teardownB() }

    let sessionA = URLSession(configuration: configA)
    let sessionB = URLSession(configuration: configB)

    let targetURL = Self.baseURL.appendingPathComponent("v1/test")

    // Build requests that carry the stub-ID headers from each config.
    // URLSession only merges httpAdditionalHeaders automatically during task
    // creation; direct URLRequest construction bypasses that merge, so we copy
    // the headers here to ensure the stub-ID header is present for routing.
    var reqA = URLRequest(url: targetURL)
    reqA.allHTTPHeaderFields = configA.httpAdditionalHeaders as? [String: String]
    var reqB = URLRequest(url: targetURL)
    reqB.allHTTPHeaderFields = configB.httpAdditionalHeaders as? [String: String]

    async let (dataA, responseA) = sessionA.data(for: reqA)
    async let (dataB, responseB) = sessionB.data(for: reqB)

    let (da, ra) = try await (dataA, responseA)
    let (db, rb) = try await (dataB, responseB)

    let httpA = try #require(ra as? HTTPURLResponse)
    let httpB = try #require(rb as? HTTPURLResponse)

    // Session A must receive its own body and status code.
    #expect(httpA.statusCode == 200)
    #expect(da == bodyA)

    // Session B must receive its own body and status code.
    #expect(httpB.statusCode == 201)
    #expect(db == bodyB)
  }

  // MARK: - teardown removes the responder

  @Test("makeSession: teardown removes the responder entry from the registry")
  func teardownClearsRegistry() async throws {
    let (config, teardown) = StubURLProtocol.makeSession { request in
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (resp, Data())
    }

    // Extract the stub ID from the config's additional headers.
    let headers = config.httpAdditionalHeaders as? [String: String] ?? [:]
    let stubID = try #require(headers["X-Stub-ID"])
    let uuid = try #require(UUID(uuidString: stubID))

    // Before teardown: the registry must contain the responder.
    #expect(StubURLProtocol.hasResponder(for: uuid))

    teardown()

    // After teardown: the registry entry must be gone.
    #expect(!StubURLProtocol.hasResponder(for: uuid))
  }
}
