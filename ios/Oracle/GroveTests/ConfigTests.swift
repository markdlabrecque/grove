import Testing
import Foundation
import OracleCore
@testable import Grove

/// Tests for Config — the typed wrapper over Info.plist build-settings values.
///
/// Workaround: `Config.shared` reads from `Bundle.main`, which in a test
/// bundle does not have `BASE_URL` or `BEARER_TOKEN` in its Info.plist.
/// Rather than stub the bundle (complex; requires test-target Info.plist
/// fixtures and build-settings plumbing), these tests construct `Config`
/// directly via `Config.init(baseURL:bearerToken:)` — an internal init added
/// for exactly this purpose.
///
/// `Config.shared` itself is exercised below: because `XCTestConfigurationFilePath`
/// is set in the test process environment, the singleton returns stub values
/// rather than calling `fatalError`. That code path is what unblocks the
/// canary CI job (ticket #71).
@Suite("Config", .serialized)
struct ConfigTests {

  @Test("baseURL is set from the provided URL")
  func baseURLIsSet() throws {
    let url = try #require(URL(string: "https://oracle.example.ts.net"))
    let config = Config(baseURL: url, bearerToken: "test-token")
    #expect(config.baseURL == url)
  }

  @Test("bearerToken is set from the provided string")
  func bearerTokenIsSet() throws {
    let url = try #require(URL(string: "https://oracle.example.ts.net"))
    let token = "super-secret-bearer-token"
    let config = Config(baseURL: url, bearerToken: token)
    #expect(config.bearerToken == token)
  }

  @Test("baseURL is non-empty after construction")
  func baseURLIsNonEmpty() throws {
    let url = try #require(URL(string: "https://oracle.example.ts.net"))
    let config = Config(baseURL: url, bearerToken: "test-token")
    #expect(!config.baseURL.absoluteString.isEmpty)
  }

  @Test("bearerToken is non-empty after construction")
  func bearerTokenIsNonEmpty() throws {
    let url = try #require(URL(string: "https://oracle.example.ts.net"))
    let config = Config(baseURL: url, bearerToken: "test-token")
    #expect(!config.bearerToken.isEmpty)
  }

  // MARK: - Shared singleton under test

  /// Verify that `Config.shared` does not crash when accessed from a test
  /// process — the test env has no populated Info.plist, but `Config.init()`
  /// detects `XCTestConfigurationFilePath` and returns stub values instead of
  /// calling `fatalError`. If this test runs at all, the guard worked.
  @Test("Config.shared returns stub values under XCTest without crashing")
  func sharedReturnsStubbedValuesUnderTest() throws {
    let shared = Config.shared
    #expect(!shared.baseURL.absoluteString.isEmpty)
    #expect(!shared.bearerToken.isEmpty)
  }
}
