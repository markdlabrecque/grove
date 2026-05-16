import Foundation

/// Typed interface to the build-configuration values injected via Info.plist.
///
/// Values flow from the active `.xcconfig` file → build settings → Info.plist
/// key/value pairs → here.
///
/// # V1 auth model (as of #184)
///
/// The **Keychain is the runtime source of truth** for both `bearerToken` and
/// `baseURL`.  xcconfig / Info.plist is a *first-launch bootstrap* only:
///
///   1. On first launch (Keychain is empty) `Config.init()` reads the xcconfig
///      value from Info.plist and seeds it into the Keychain via
///      `KeychainStore.shared`.
///   2. On every subsequent launch the Keychain value is used directly.
///   3. The user can update the token and URL in the Settings screen; those
///      writes go to the Keychain and take effect on the next API call.
///
/// The xcconfig / Info.plist path is kept intact so the app still builds
/// correctly from a fresh clone with a populated `Config.debug.xcconfig`.
/// `Config.xcconfig.example` and the build-time wiring are never removed.
///
/// TODO(auth-v2): Add Face/Touch ID gate (`LAContext`) around the Keychain
/// token read before any production or wider-distribution use.
public struct Config: Sendable {
  /// Shared singleton; constructed once at app launch.
  public static let shared = Config()

  /// The server's base URL, e.g. `https://oracle.example.ts.net`.
  ///
  /// At runtime this reflects the Keychain value (potentially updated by the
  /// user in Settings).  The xcconfig bootstrap value is used only when the
  /// Keychain has no entry.
  public let baseURL: URL

  /// Long-lived bearer token sent with every API request.
  ///
  /// Source of truth at runtime is the Keychain (see class-level doc).
  /// xcconfig / Info.plist is the first-launch bootstrap only.
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
    // Note: SPM `swift test` (GroveCore package tests) uses Swift Testing and
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

    // --- xcconfig bootstrap values from Info.plist ---
    guard
      let rawURL = Bundle.main.object(forInfoDictionaryKey: "BASE_URL") as? String,
      !rawURL.isEmpty
    else {
      fatalError(
        "Oracle: BASE_URL is missing in Info.plist. "
          + "Copy Config.xcconfig.example → Config.debug.xcconfig and fill in your values."
      )
    }

    guard
      let xconfigToken = Bundle.main.object(forInfoDictionaryKey: "BEARER_TOKEN") as? String,
      !xconfigToken.isEmpty,
      xconfigToken != "replace-me"
    else {
      fatalError(
        "Oracle: BEARER_TOKEN is missing or still set to the placeholder in Info.plist. "
          + "Copy Config.xcconfig.example → Config.debug.xcconfig and fill in your values."
      )
    }

    // --- Token: Keychain first, xcconfig as first-launch bootstrap ---
    //
    // One read determines both the resolved value and whether we need to seed.
    // If the Keychain has a value, use it directly.  If not (first launch, or
    // a read failure), fall back to xcconfig and seed the Keychain so the
    // Settings screen round-trips correctly from the very first session.
    let keychain = KeychainStore.shared
    let resolvedToken: String
    if let keychainToken = try? keychain.read(forKey: KeychainStore.bearerTokenKey),
       !keychainToken.isEmpty
    {
      resolvedToken = keychainToken
    } else {
      resolvedToken = xconfigToken
      try? keychain.write(xconfigToken, forKey: KeychainStore.bearerTokenKey)
    }

    // --- URL: Keychain first, xcconfig as first-launch bootstrap ---
    let resolvedRawURL: String
    if let keychainURL = try? keychain.read(forKey: KeychainStore.serverURLKey),
       let _ = URL(string: keychainURL),
       !keychainURL.isEmpty
    {
      resolvedRawURL = keychainURL
    } else {
      resolvedRawURL = rawURL
      // Seed the Keychain with the xcconfig URL on first launch.
      try? keychain.write(rawURL, forKey: KeychainStore.serverURLKey)
    }

    guard let url = URL(string: resolvedRawURL) else {
      fatalError(
        "Oracle: resolved BASE_URL '\(resolvedRawURL)' is not a valid URL."
      )
    }

    self.baseURL = url
    self.bearerToken = resolvedToken
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
