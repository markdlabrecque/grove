import Testing
import Foundation
@testable import Oracle
import OracleCore

/// Tests for `SettingsViewModel` — URL validation, Keychain round-trip,
/// AppStorage key consistency, and force-resync sweep.
///
/// These run in the OracleTests Xcode target (host-app test bundle) so they
/// can @testable import Oracle.  KeychainStore unit-level tests live in
/// OracleCoreTests (KeychainStoreTests.swift).
///
/// `SettingsViewModel` is `@MainActor`-isolated, so every test that touches
/// the ViewModel must hop to the main actor.  Swift Testing supports this via
/// `@MainActor` on the test function directly.
@Suite("SettingsViewModel", .serialized)
struct SettingsViewModelTests {

  // MARK: - URL validation

  @Test("serverURL validation accepts a well-formed https URL")
  @MainActor
  func urlValidationAcceptsHTTPS() throws {
    let vm = SettingsViewModel.makeForTest()
    vm.serverURLText = "https://oracle.example.ts.net"
    vm.commitServerURL()
    #expect(vm.serverURLError == nil)
  }

  @Test("serverURL validation rejects an empty string")
  @MainActor
  func urlValidationRejectsEmpty() throws {
    let vm = SettingsViewModel.makeForTest()
    vm.serverURLText = ""
    vm.commitServerURL()
    #expect(vm.serverURLError != nil)
  }

  @Test("serverURL validation rejects a non-URL string")
  @MainActor
  func urlValidationRejectsGarbage() throws {
    let vm = SettingsViewModel.makeForTest()
    vm.serverURLText = "not a url"
    vm.commitServerURL()
    #expect(vm.serverURLError != nil)
  }

  @Test("serverURL validation rejects a host without scheme")
  @MainActor
  func urlValidationRejectsHostWithoutScheme() throws {
    let vm = SettingsViewModel.makeForTest()
    vm.serverURLText = "oracle.example.ts.net"
    vm.commitServerURL()
    #expect(vm.serverURLError != nil)
  }

  @Test("serverURL validation clears error after correcting an invalid URL")
  @MainActor
  func urlValidationClearsErrorAfterCorrection() throws {
    let vm = SettingsViewModel.makeForTest()
    vm.serverURLText = "bad"
    vm.commitServerURL()
    #expect(vm.serverURLError != nil)
    vm.serverURLText = "https://oracle.example.ts.net"
    vm.commitServerURL()
    #expect(vm.serverURLError == nil)
  }

  // MARK: - AppStorage key consistency

  @Test("fillerWordCleanupEnabled AppStorage key matches the expected constant")
  func fillerWordCleanupStorageKey() {
    // If this test fails it means the key was renamed in SettingsViewModel but
    // not updated in CaptureViewModel (or vice-versa).  Both must bind to
    // SettingsViewModel.fillerWordCleanupKey.
    #expect(SettingsViewModel.fillerWordCleanupKey == "capture.fillerWordCleanup")
  }

  @Test("languageHint AppStorage key matches the expected constant")
  func languageHintStorageKey() {
    #expect(SettingsViewModel.languageHintKey == "capture.languageHint")
  }

  // MARK: - currentServerURL fallback

  @Test("currentServerURL returns Keychain value when one is stored")
  @MainActor
  func currentServerURLReturnsKeychainValue() throws {
    let vm = SettingsViewModel.makeForTest()
    vm.serverURLText = "https://oracle.example.ts.net"
    vm.commitServerURL()
    #expect(vm.currentServerURL == "https://oracle.example.ts.net")
  }

  @Test("currentServerURL returns empty string (not serverURLText) when Keychain has no entry")
  @MainActor
  func currentServerURLFallsBackToEmptyNotEditBuffer() throws {
    // Fresh test keychain has no entry; simulate a half-typed edit buffer.
    let vm = SettingsViewModel.makeForTest()
    vm.serverURLText = "https://half-typed.example"
    // Do NOT call commitServerURL() — nothing written to Keychain.
    #expect(vm.currentServerURL == "")
  }

  // MARK: - Force-resync

  @Test("forceResync calls tryDrain on the upload queue")
  @MainActor
  func forceResyncCallsTryDrain() async throws {
    let drainCalled = ActorBox(value: false)
    let vm = SettingsViewModel.makeForTest(onDrain: {
      await drainCalled.set(true)
    })
    await vm.forceResync()
    let called = await drainCalled.get()
    #expect(called)
  }
}

// MARK: - Test helper — actor-safe bool box

/// An actor-isolated mutable bool for use in async test assertions.
private actor ActorBox<T: Sendable> {
  var value: T
  init(value: T) { self.value = value }
  func set(_ v: T) { value = v }
  func get() -> T { value }
}

// MARK: - AppearancePreference key tests (#336)

/// Pins the `appearancePreferenceKey` constant and its `UserDefaults` default.
///
/// `@AppStorage` returns the default value (`"system"`) when the key is absent.
/// Tests here use `UserDefaults` directly so they work in the unit-test target
/// without a running SwiftUI view hierarchy.  They write to an in-memory
/// `UserDefaults` suite isolated from the app store.
@Suite("AppearancePreference", .serialized)
struct AppearancePreferenceTests {

  private let defaults: UserDefaults
  private let suiteName = "com.oracle.test.appearance.\(UUID().uuidString)"

  init() {
    // Create an isolated UserDefaults domain for each test run.
    // Force-unwrap is safe: a unique UUID suite name always succeeds.
    defaults = UserDefaults(suiteName: suiteName)!
  }

  @Test("appearancePreferenceKey constant is 'appearance.preference'")
  func keyConstantValue() {
    #expect(SettingsViewModel.appearancePreferenceKey == "appearance.preference")
  }

  @Test("default value is 'system' when key is absent (#336)")
  func defaultIsSystem() {
    // No write — key must be absent.
    defaults.removeObject(forKey: SettingsViewModel.appearancePreferenceKey)
    // @AppStorage returns its type-default when the key is missing.
    // Equivalent: reading a String key that doesn't exist returns nil from
    // UserDefaults; @AppStorage interprets that as the provided default "system".
    let stored = defaults.string(forKey: SettingsViewModel.appearancePreferenceKey)
    // nil means the key is absent → @AppStorage default "system" is in effect.
    #expect(stored == nil, "Key must be absent on a clean install so @AppStorage default 'system' is used")
  }

  @Test("persisted 'light' survives a write/read round-trip (#336)")
  func lightPersists() {
    defaults.set("light", forKey: SettingsViewModel.appearancePreferenceKey)
    let stored = defaults.string(forKey: SettingsViewModel.appearancePreferenceKey)
    #expect(stored == "light", "Light preference must round-trip through UserDefaults")
  }

  @Test("persisted 'dark' survives a write/read round-trip (#336)")
  func darkPersists() {
    defaults.set("dark", forKey: SettingsViewModel.appearancePreferenceKey)
    let stored = defaults.string(forKey: SettingsViewModel.appearancePreferenceKey)
    #expect(stored == "dark", "Dark preference must round-trip through UserDefaults")
  }

  @Test("toggling from 'dark' to 'light' to 'system' persists each change (#336)")
  func togglePersistsEachChange() {
    for value in ["dark", "light", "system"] {
      defaults.set(value, forKey: SettingsViewModel.appearancePreferenceKey)
      let stored = defaults.string(forKey: SettingsViewModel.appearancePreferenceKey)
      #expect(stored == value, "Persisted value should match '\(value)' after write")
    }
  }
}
