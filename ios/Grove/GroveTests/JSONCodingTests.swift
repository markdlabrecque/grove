import Testing
import Foundation
import GroveCore
@testable import Grove

/// Anchor class used solely to locate the GroveTests bundle at runtime.
///
/// Swift Testing `@Suite` structs have no `self` that is an `NSObject`, so
/// `Bundle(for:)` must be called with a named class. This private class lives
/// in the GroveTests target and therefore resolves to the correct bundle
/// regardless of which process loads the tests.
private final class BundleLocator: NSObject {}

/// Tests for JSON coding/decoding of Grove wire-format types.
///
/// Fixtures live in GroveTests/Fixtures/ and are loaded by looking up the
/// GroveTests bundle via `BundleLocator` — a lightweight class defined in
/// this file whose sole purpose is to anchor `Bundle(for:)`. This approach
/// works for both Xcode test targets and SPM test targets without any extra
/// build-settings plumbing.
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
    // Use BundleLocator (a class in this target) to locate the test bundle.
    // Fixture files must be listed in GroveTests' Copy Bundle Resources
    // build phase in project.pbxproj.
    let bundle = Bundle(for: BundleLocator.self)
    guard let url = bundle.url(forResource: name, withExtension: "json") else {
      Issue.record("Fixture '\(name).json' not found. Verify it is in GroveTests Copy Bundle Resources.")
      throw FixtureError.notFound(name)
    }
    return try Data(contentsOf: url)
  }

  private enum FixtureError: Error {
    case notFound(String)
  }
}
