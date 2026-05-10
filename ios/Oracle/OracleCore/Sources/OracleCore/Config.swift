import Foundation

/// Typed interface to the build-configuration values injected via Info.plist.
///
/// Values flow from the active `.xcconfig` file → build settings → Info.plist
/// key/value pairs → here.
///
/// V1 note: `bearerToken` is read from Info.plist, which is populated by the
/// active `.xcconfig` (Config.debug.xcconfig or Config.release.xcconfig).
/// This approach is intentional for V1 transparency and per-environment
/// flexibility.
///
/// TODO(auth): Migrate `bearerToken` storage to iOS Keychain protected by
/// `LAContext` (Face ID / Touch ID) before any production or wider-distribution
/// use. See `kai.md` §"What to avoid" — "Keychain only" is the standing rule;
/// this `.xcconfig` path is an explicit V1 override. The Keychain migration
/// ticket follows this one.
public struct Config: Sendable {
  /// Shared singleton; constructed once at app launch.
  public static let shared = Config()

  /// The server's base URL, e.g. `https://oracle.example.ts.net`.
  public let baseURL: URL

  /// Long-lived bearer token sent with every API request.
  ///
  /// TODO(auth): V2 — move this value to Keychain + LAContext; delete the
  /// `BEARER_TOKEN` key from Info.plist and the `.xcconfig` files.
  public let bearerToken: String

  private init() {
    // Under XCTest (Xcode unit-test host and XCUITest target-app launches),
    // the xcconfig files are intentionally unpopulated on CI and fresh clones.
    // Rather than fatalError before tests can attach, return well-known stub
    // values that let the app reach its first screen.
    //
    // Detection strategy:
    //   1. `XCTestConfigurationFilePath` — set by Xcode in the unit-test host
    //      process when running the OracleTests target.
    //   2. `XCTestSessionIdentifier`     — set by Xcode in the app-under-test
    //      process when running XCUITests (OracleUITests target).
    //
    // Note: SPM `swift test` (OracleCore package tests) uses Swift Testing and
    // does NOT set either env var. Those tests avoid `Config.shared` entirely
    // and construct Config directly via `Config(baseURL:bearerToken:)`.
    //
    // Production builds (Release scheme, real devices) never have these env
    // vars set, so the loud fatalError path below is unchanged.
    let env = ProcessInfo.processInfo.environment
    let isUnderTest = env["XCTestConfigurationFilePath"] != nil
      || env["XCTestSessionIdentifier"] != nil

    if isUnderTest {
      // Stub values — never used for real network calls; tests that need a
      // live Config construct one explicitly via Config(baseURL:bearerToken:).
      self.baseURL = URL(string: "https://oracle-test.example.ts.net")!
      self.bearerToken = "test-bearer-token"
      return
    }

    guard
      let rawURL = Bundle.main.object(forInfoDictionaryKey: "BASE_URL") as? String,
      let url = URL(string: rawURL)
    else {
      fatalError(
        "Oracle: BASE_URL is missing or malformed in Info.plist. "
          + "Copy Config.xcconfig.example → Config.debug.xcconfig and fill in your values."
      )
    }

    guard
      let token = Bundle.main.object(forInfoDictionaryKey: "BEARER_TOKEN") as? String,
      !token.isEmpty,
      token != "replace-me"
    else {
      fatalError(
        "Oracle: BEARER_TOKEN is missing or still set to the placeholder in Info.plist. "
          + "Copy Config.xcconfig.example → Config.debug.xcconfig and fill in your values."
      )
    }

    self.baseURL = url
    self.bearerToken = token
  }

  /// Designated initialiser used by unit tests.
  ///
  /// The test bundle cannot easily inject its own `Info.plist` into
  /// `Bundle.main`, so tests that need a `Config` instance construct one
  /// directly via this path rather than going through `Config.shared`.
  /// See `ConfigTests.swift` for usage.
  public init(baseURL: URL, bearerToken: String) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
  }
}
