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
