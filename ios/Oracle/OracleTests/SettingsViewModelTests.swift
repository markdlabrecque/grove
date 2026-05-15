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
