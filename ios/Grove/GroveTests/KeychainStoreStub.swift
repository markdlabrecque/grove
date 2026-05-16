import Foundation
import GroveCore

/// In-memory stub for `KeychainStoreProtocol` used by `SettingsViewModelTests`.
///
/// Each test should construct its own `KeychainStoreStub` instance to avoid
/// cross-test state contamination.  The suite is marked `.serialized`, but
/// per-instance stubs make the isolation explicit regardless.
///
/// # Capabilities
///
/// - **Pre-seeded reads** — pass `reads: [key: value]` to simulate existing
///   Keychain entries.
/// - **Per-key write failures** — add keys to `writeFailures` to make
///   `write(_:forKey:)` throw `KeychainError.writeFailed(status: -25308)`
///   (`errSecInteractionNotAllowed`) for those keys only.
/// - **Call recording** — `writeCalls` and `readCalls` accumulate every call
///   so tests can assert "write was attempted" without relying on side-effects.
final class KeychainStoreStub: KeychainStoreProtocol, @unchecked Sendable {

  // MARK: - Configuration

  /// Pre-seeded values returned by `read(forKey:)`.
  var reads: [String: String]

  /// Keys for which `write(_:forKey:)` should throw.
  var writeFailures: Set<String>

  // MARK: - Call recording

  /// Every `(value, key)` pair passed to `write(_:forKey:)`.
  private(set) var writeCalls: [(value: String, key: String)] = []

  /// Every key passed to `read(forKey:)`.
  private(set) var readCalls: [String] = []

  // MARK: - In-memory store

  /// Values written by `write(_:forKey:)` (only for non-failing keys).
  private var store: [String: String]

  // MARK: - Init

  /// - Parameters:
  ///   - reads: Pre-seeded values for `read(forKey:)`.  Written values
  ///     overlay these after a successful `write`.
  ///   - writeFailures: Keys for which writes should throw.
  init(reads: [String: String] = [:], writeFailures: Set<String> = []) {
    self.reads = reads
    self.writeFailures = writeFailures
    self.store = reads
  }

  // MARK: - KeychainStoreProtocol

  func read(forKey key: String) throws -> String? {
    readCalls.append(key)
    return store[key]
  }

  func write(_ value: String, forKey key: String) throws {
    writeCalls.append((value: value, key: key))
    if writeFailures.contains(key) {
      // errSecInteractionNotAllowed (-25308) — typical when device is locked.
      throw KeychainError.writeFailed(status: -25308)
    }
    store[key] = value
  }

  func resolveToken(xconfigFallback: String) -> String {
    store[KeychainStore.bearerTokenKey] ?? xconfigFallback
  }
}
