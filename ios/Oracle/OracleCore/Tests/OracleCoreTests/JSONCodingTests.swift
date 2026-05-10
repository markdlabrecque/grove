import Testing
import Foundation
@testable import OracleCore

/// Tests for JSON coding/decoding of Oracle wire-format types.
///
/// Fixtures live in Tests/OracleCoreTests/Fixtures/ and are accessed via
/// `Bundle.module` — the SPM-generated bundle accessor for test-target resources
/// declared in Package.swift with `.process("Fixtures")`.
@Suite("JSONCoding")
struct JSONCodingTests {

  // MARK: - CaptureResponseBody

  @Test("CaptureResponseBody decodes from canned JSON fixture")
  func decodesCaptureResponseBody() throws {
    let data = try loadFixture(named: "capture_response")
    let decoder = makeDecoder()
    let response = try decoder.decode(CaptureResponseBody.self, from: data)

    #expect(response.id.uuidString.lowercased() == "b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f")
    #expect(response.clientID.uuidString.lowercased() == "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    #expect(response.enriched == false)
  }

  @Test("CaptureResponseBody captured_at parses as timezone-aware Date")
  func capturedAtIsTimezoneAware() throws {
    let data = try loadFixture(named: "capture_response")
    let decoder = makeDecoder()
    let response = try decoder.decode(CaptureResponseBody.self, from: data)

    let capturedAt = try #require(response.capturedAt)

    // 2026-05-10T14:30:00+00:00 = Unix timestamp 1778423400
    // Verify against a known reference to confirm TZ was parsed, not dropped.
    #expect(abs(capturedAt.timeIntervalSince1970 - 1_778_423_400) < 1.0)
  }

  // MARK: - QueryResponseBody

  @Test("QueryResponseBody decodes from canned JSON fixture")
  func decodesQueryResponseBody() throws {
    let data = try loadFixture(named: "query_response")
    let decoder = makeDecoder()
    let response = try decoder.decode(QueryResponseBody.self, from: data)

    #expect(response.results.count == 2)
    #expect(response.queryTokenCount == 7)
    #expect(abs(response.latencyMs - 612.4) < 0.01)
  }

  @Test("QueryResponseBody first result is a whole-memory match")
  func queryResponseBodyFirstResultIsWholeMatch() throws {
    let data = try loadFixture(named: "query_response")
    let decoder = makeDecoder()
    let response = try decoder.decode(QueryResponseBody.self, from: data)

    let first = try #require(response.results.first)
    #expect(first.memoryID.uuidString.lowercased() == "c1d2e3f4-a5b6-7890-cdef-012345678901")
    #expect(first.matchedVia == "whole")
    #expect(first.matchedChunkIndex == nil)
    #expect(abs(first.score - 0.912345) < 0.000001)
    #expect(first.snippet.hasPrefix("The project uses SwiftData"))
  }

  @Test("QueryResponseBody second result is a chunk match with index")
  func queryResponseBodySecondResultIsChunkMatch() throws {
    let data = try loadFixture(named: "query_response")
    let decoder = makeDecoder()
    let response = try decoder.decode(QueryResponseBody.self, from: data)

    let second = try #require(response.results.dropFirst().first)
    #expect(second.matchedVia == "chunk")
    #expect(second.matchedChunkIndex == 2)
    #expect(second.sourceModality == "voice")
  }

  @Test("QueryResponseBody captured_at parses as timezone-aware Date")
  func queryResponseBodyCapturedAtIsTimezoneAware() throws {
    let data = try loadFixture(named: "query_response")
    let decoder = makeDecoder()
    let response = try decoder.decode(QueryResponseBody.self, from: data)

    let capturedAt = try #require(response.results.first?.capturedAt)
    // 2026-05-09T10:15:00+00:00 = 1778321700 seconds since epoch
    #expect(abs(capturedAt.timeIntervalSince1970 - 1_778_321_700) < 1.0)
  }

  @Test("QueryRequestBody encodes to server-expected JSON keys")
  func queryRequestBodyEncodesCorrectly() throws {
    let body = QueryRequestBody(query: "what did I capture about SwiftData?", limit: 10)
    let encoder = JSONEncoder()
    let data = try encoder.encode(body)

    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["query"] as? String == "what did I capture about SwiftData?")
    #expect(json["limit"] as? Int == 10)
    // Ensure no unexpected extra fields.
    #expect(json.count == 2)
  }

  // MARK: - Helpers

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // CaptureResponseBody uses explicit CodingKeys; no key strategy needed.
    return decoder
  }

  private func loadFixture(named name: String) throws -> Data {
    // In an SPM test target, fixture files declared with .process("Fixtures")
    // in Package.swift are accessible via Bundle.module — the generated bundle
    // accessor that Swift Package Manager synthesises for the test target.
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
      Issue.record("Fixture '\(name).json' not found in Bundle.module. Verify it is under Tests/OracleCoreTests/Fixtures/ and listed in Package.swift resources.")
      throw FixtureError.notFound(name)
    }
    return try Data(contentsOf: url)
  }

  private enum FixtureError: Error {
    case notFound(String)
  }
}
