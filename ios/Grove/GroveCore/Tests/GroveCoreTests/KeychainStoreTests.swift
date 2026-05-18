import Testing
import Foundation
@testable import GroveCore

/// Tests for `KeychainStore` — the Keychain wrapper used to persist the bearer
/// token and server URL for runtime auth.
///
/// These tests run in the SPM package via `make ios-test-core`.  They do NOT
/// test the Xcode-target path; `GroveTests/SettingsViewModelTests.swift`
/// covers the SettingsViewModel (URL validation, force-resync sweep, AppStorage
/// key round-trip) using `@testable import Grove`.
///
/// Note: Keychain access in simulator + swift-test runs in a sandboxed process
/// that *does* have a Keychain.  Items are isolated per service/account pair so
/// tests can write and read back without colliding with app data.
@Suite("KeychainStore", .serialized)
struct KeychainStoreTests {

  // MARK: - Helpers

  /// A unique service string per test run so stale items from a previous run
  /// don't interfere.  The UUID guarantees isolation even when tests are
  /// re-ordered or repeated.
  private func freshService() -> String {
    "com.markdlabrecque.grove.test.\(UUID().uuidString)"
  }

  // MARK: - write / read round-trip

  @Test("write then read returns the same string")
  func writeReadRoundTrip() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    try store.write("test-token-abc", forKey: "bearer_token")
    let read = try store.read(forKey: "bearer_token")
    #expect(read == "test-token-abc")
  }

  @Test("reading a key that was never written returns nil")
  func readMissingKeyReturnsNil() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    let result = try store.read(forKey: "nonexistent_key")
    #expect(result == nil)
  }

  @Test("write overwrites an existing value")
  func writeOverwritesExistingValue() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    try store.write("first", forKey: "bearer_token")
    try store.write("second", forKey: "bearer_token")
    let read = try store.read(forKey: "bearer_token")
    #expect(read == "second")
  }

  @Test("delete removes an existing key")
  func deleteRemovesKey() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    try store.write("value-to-delete", forKey: "bearer_token")
    try store.delete(forKey: "bearer_token")
    let result = try store.read(forKey: "bearer_token")
    #expect(result == nil)
  }

  @Test("delete is a no-op for a key that does not exist")
  func deleteNonexistentKeyIsNoOp() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    // Should not throw
    try store.delete(forKey: "nonexistent")
  }

  @Test("write then delete then write returns the new value")
  func writeThenDeleteThenWriteReturnsNewValue() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    try store.write("first", forKey: "token")
    try store.delete(forKey: "token")
    try store.write("second", forKey: "token")
    let result = try store.read(forKey: "token")
    #expect(result == "second")
  }

  @Test("multiple keys are stored independently")
  func multipleKeysAreIndependent() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    try store.write("url-value", forKey: "server_url")
    try store.write("token-value", forKey: "bearer_token")
    let url = try store.read(forKey: "server_url")
    let token = try store.read(forKey: "bearer_token")
    #expect(url == "url-value")
    #expect(token == "token-value")
  }

  @Test("write preserves unicode content correctly")
  func writePreservesUnicode() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    let value = "token-with-\u{1F512}-unicode"
    try store.write(value, forKey: "bearer_token")
    let result = try store.read(forKey: "bearer_token")
    #expect(result == value)
  }

  // MARK: - Token-getter precedence (Keychain > xcconfig fallback)

  @Test("token getter returns Keychain value when present")
  func tokenGetterPrefersKeychain() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    let xconfigFallback = "xcconfig-token"
    let keychainToken = "keychain-token"

    try store.write(keychainToken, forKey: KeychainStore.bearerTokenKey)
    let resolved = store.resolveToken(xconfigFallback: xconfigFallback)
    #expect(resolved == keychainToken)
  }

  @Test("token getter falls back to xcconfig when Keychain is empty")
  func tokenGetterFallsBackToXcconfig() throws {
    let service = freshService()
    let store = KeychainStore(service: service)
    let xconfigFallback = "xcconfig-token"

    let resolved = store.resolveToken(xconfigFallback: xconfigFallback)
    #expect(resolved == xconfigFallback)
  }

  // MARK: - URL validation

  @Test("isValidServerURL accepts a well-formed https URL")
  func isValidServerURLAcceptsHTTPS() {
    #expect(KeychainStore.isValidServerURL("https://grove.example.ts.net"))
  }

  @Test("isValidServerURL accepts a URL with a port number")
  func isValidServerURLAcceptsPort() {
    #expect(KeychainStore.isValidServerURL("https://grove.example.ts.net:8443"))
  }

  @Test("isValidServerURL rejects an empty string")
  func isValidServerURLRejectsEmpty() {
    #expect(!KeychainStore.isValidServerURL(""))
  }

  @Test("isValidServerURL rejects a non-URL string")
  func isValidServerURLRejectsGarbage() {
    #expect(!KeychainStore.isValidServerURL("not a url"))
  }

  @Test("isValidServerURL rejects a plain host without scheme")
  func isValidServerURLRejectsHostWithoutScheme() {
    #expect(!KeychainStore.isValidServerURL("grove.example.ts.net"))
  }

  @Test("isValidServerURL accepts http for non-production development URLs")
  func isValidServerURLAcceptsHTTP() {
    #expect(KeychainStore.isValidServerURL("http://localhost:8000"))
  }
}
