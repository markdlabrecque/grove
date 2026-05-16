import Testing
import Foundation
@testable import GroveCore

/// Tests for Config — the typed wrapper over Info.plist build-settings values.
///
/// Workaround: `Config.shared` reads from `Bundle.main`, which in a test
/// bundle does not have `BASE_URL` or `BEARER_TOKEN` in its Info.plist.
/// Rather than stub the bundle (complex; requires test-target Info.plist
/// fixtures and build-settings plumbing), these tests construct `Config`
/// directly via `Config.init(baseURL:bearerToken:)` — an internal init added
/// for exactly this purpose.
///
/// Note on `Config.shared`: The singleton's test-mode stub (ticket #71) is
/// verified in `OracleTests/ConfigTests.swift` rather than here because SPM
/// `swift test` does not set `XCTestConfigurationFilePath` or
/// `XCTestSessionIdentifier` — the env vars that trigger the stub path.
/// Accessing `Config.shared` from this suite would crash unless real xcconfig
/// values are present. Xcode's test runner (which does set those vars) is the
/// right home for that coverage.
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
}
