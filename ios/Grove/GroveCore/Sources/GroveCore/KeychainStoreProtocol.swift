import Foundation

/// Minimal abstraction over Keychain read/write operations used by
/// `SettingsViewModel`.
///
/// Exposing only the methods that `SettingsViewModel` actually calls keeps the
/// surface area small and test stubs straightforward.  `KeychainStore` is the
/// sole production conformer; `KeychainStoreStub` in the test bundle is the
/// injectable double.
///
/// Static constants (`bearerTokenKey`, `serverURLKey`) remain on `KeychainStore`
/// directly — the protocol covers instance methods only, so callers continue to
/// use `KeychainStore.bearerTokenKey` / `KeychainStore.serverURLKey` at call
/// sites.  This minimises blast radius: `Config.swift` and `KeychainStoreTests`
/// are unaffected.
///
/// Visibility note: this protocol is `public` rather than `package` because
/// the sole consumer (`SettingsViewModel` in the `Oracle` app target) lives
/// outside the GroveCore Swift package and depends on it as an external SPM
/// product. `package` access would not be visible across that boundary.
/// `internal` is likewise insufficient. Treat this protocol as an
/// implementation-detail seam — do not extend it for external API use.
public protocol KeychainStoreProtocol: Sendable {

  /// Read the `String` value for the given `key`.
  ///
  /// Returns `nil` when no item exists.
  ///
  /// - Throws: A `KeychainError` on unexpected Keychain failures (excluding
  ///   "item not found", which surfaces as `nil`).
  func read(forKey key: String) throws -> String?

  /// Write (add or update) a `String` value for the given `key`.
  ///
  /// - Throws: `KeychainError.writeFailed(status:)` on any non-success result.
  func write(_ value: String, forKey key: String) throws

  /// Return the bearer token from the Keychain, falling back to the xcconfig
  /// bootstrap value when the Keychain has no entry yet.
  func resolveToken(xconfigFallback: String) -> String
}
