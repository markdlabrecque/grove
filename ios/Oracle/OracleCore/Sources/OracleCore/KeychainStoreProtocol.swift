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
