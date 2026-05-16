import Testing
import Foundation
@testable import Grove
import GroveCore

/// Tests for `SettingsViewModel` Keychain write-failure paths.
///
/// These tests assert the behaviour specified in #254:
///   - When the Keychain write fails, `serverURLError` remains `nil`
///     (no crash, no user-visible error — the `print` warning is the only signal).
///   - When the Keychain write fails, the live API credentials action is NOT
///     invoked — Keychain is the source of truth; we do not propagate a value
///     that did not persist.
///
/// The `KeychainStoreStub` type is defined in `KeychainStoreStub.swift` in this
/// test target.  Each test constructs its own stub instance to prevent
/// cross-test state contamination.
///
/// # Production bug fixed in this PR
///
/// Prior to #254 both `commitServerURL()` and `commitToken()` called
/// `GroveAPI.shared.updateCredentials(...)` even when the Keychain write
/// threw.  The `return` added to each catch block, plus the injectable
/// `updateCredentialsAction`, closes that gap and makes it testable.
///
/// # Task timing note
///
/// `commitServerURL()` and `commitToken()` fire an unstructured `Task {}`
/// internally.  The "success" tests use a `CheckedContinuation` to properly
/// await that task's side effect; the "failure" tests only need a single
/// `Task.yield()` to confirm the Task was never scheduled.
@Suite("SettingsViewModel — Keychain write failures", .serialized)
struct SettingsViewModelKeychainFailureTests {

  // MARK: - commitServerURL — write fails

  @Test("commitServerURL: Keychain write failure leaves serverURLError nil")
  @MainActor
  func commitServerURL_keychainWriteFails_setsNoError() {
    let stub = KeychainStoreStub(
      writeFailures: [KeychainStore.serverURLKey]
    )
    let vm = SettingsViewModel.makeForTest(keychain: stub)
    vm.serverURLText = "https://oracle.example.ts.net"
    vm.commitServerURL()
    #expect(vm.serverURLError == nil)
  }

  @Test("commitServerURL: Keychain write failure does not invoke updateCredentials")
  @MainActor
  func commitServerURL_keychainWriteFails_doesNotUpdateLiveAPI() async {
    let credentialsCalled = ActorBox(value: false)
    let stub = KeychainStoreStub(
      writeFailures: [KeychainStore.serverURLKey]
    )
    let vm = SettingsViewModel.makeForTest(
      keychain: stub,
      onUpdateCredentials: { _, _ in
        await credentialsCalled.set(true)
      }
    )
    vm.serverURLText = "https://oracle.example.ts.net"
    vm.commitServerURL()
    // Yield to allow any Tasks that might have been scheduled to execute.
    await Task.yield()
    let called = await credentialsCalled.get()
    #expect(!called, "updateCredentials should not be called when Keychain write failed")
  }

  @Test("commitServerURL: Keychain write failure records the write attempt")
  @MainActor
  func commitServerURL_keychainWriteFails_writeWasAttempted() {
    let stub = KeychainStoreStub(
      writeFailures: [KeychainStore.serverURLKey]
    )
    let vm = SettingsViewModel.makeForTest(keychain: stub)
    vm.serverURLText = "https://oracle.example.ts.net"
    vm.commitServerURL()
    let writeAttempted = stub.writeCalls.contains { $0.key == KeychainStore.serverURLKey }
    #expect(writeAttempted, "write should have been attempted even though it threw")
  }

  // MARK: - commitServerURL — write succeeds

  @Test("commitServerURL: successful Keychain write does invoke updateCredentials")
  @MainActor
  func commitServerURL_keychainWriteSucceeds_updatesLiveAPI() async throws {
    // Use withCheckedContinuation to properly await the unstructured Task
    // that commitServerURL fires internally.
    let called: Bool = try await withCheckedThrowingContinuation { continuation in
      let stub = KeychainStoreStub()  // no write failures
      let vm = SettingsViewModel.makeForTest(
        keychain: stub,
        onUpdateCredentials: { _, _ in
          continuation.resume(returning: true)
        }
      )
      vm.serverURLText = "https://oracle.example.ts.net"
      vm.commitServerURL()
    }
    #expect(called, "updateCredentials should be called on a successful write")
  }

  // MARK: - commitToken — write fails

  @Test("commitToken: Keychain write failure does not invoke updateCredentials")
  @MainActor
  func commitToken_keychainWriteFails_doesNotUpdateLiveAPI() async {
    let credentialsCalled = ActorBox(value: false)
    // Pre-seed a server URL so commitToken can resolve it for the API call.
    let stub = KeychainStoreStub(
      reads: [KeychainStore.serverURLKey: "https://oracle.example.ts.net"],
      writeFailures: [KeychainStore.bearerTokenKey]
    )
    let vm = SettingsViewModel.makeForTest(
      keychain: stub,
      onUpdateCredentials: { _, _ in
        await credentialsCalled.set(true)
      }
    )
    vm.bearerTokenText = "tok_secret"
    vm.commitToken()
    await Task.yield()
    let called = await credentialsCalled.get()
    #expect(!called, "updateCredentials should not be called when Keychain write failed")
  }

  @Test("commitToken: Keychain write failure records the write attempt")
  @MainActor
  func commitToken_keychainWriteFails_writeWasAttempted() {
    let stub = KeychainStoreStub(
      reads: [KeychainStore.serverURLKey: "https://oracle.example.ts.net"],
      writeFailures: [KeychainStore.bearerTokenKey]
    )
    let vm = SettingsViewModel.makeForTest(keychain: stub)
    vm.bearerTokenText = "tok_secret"
    vm.commitToken()
    let writeAttempted = stub.writeCalls.contains { $0.key == KeychainStore.bearerTokenKey }
    #expect(writeAttempted, "write should have been attempted even though it threw")
  }

  // MARK: - commitToken — write succeeds

  @Test("commitToken: successful Keychain write does invoke updateCredentials")
  @MainActor
  func commitToken_keychainWriteSucceeds_updatesLiveAPI() async throws {
    let called: Bool = try await withCheckedThrowingContinuation { continuation in
      let stub = KeychainStoreStub(
        reads: [KeychainStore.serverURLKey: "https://oracle.example.ts.net"]
      )
      let vm = SettingsViewModel.makeForTest(
        keychain: stub,
        onUpdateCredentials: { _, _ in
          continuation.resume(returning: true)
        }
      )
      vm.bearerTokenText = "tok_secret"
      vm.commitToken()
    }
    #expect(called, "updateCredentials should be called on a successful write")
  }

  // MARK: - Per-key independence

  @Test("commitServerURL: URL write failure does not affect token write path")
  @MainActor
  func commitServerURL_urlWriteFails_tokenKeyUntouched() {
    // Only URL writes fail; token writes succeed.  This verifies the stub's
    // per-key granularity is working correctly.
    let stub = KeychainStoreStub(
      writeFailures: [KeychainStore.serverURLKey]
    )
    let vm = SettingsViewModel.makeForTest(keychain: stub)
    vm.serverURLText = "https://oracle.example.ts.net"
    vm.commitServerURL()
    // No token write should have been attempted by commitServerURL.
    let tokenWriteAttempted = stub.writeCalls.contains { $0.key == KeychainStore.bearerTokenKey }
    #expect(!tokenWriteAttempted)
  }
}

// MARK: - Shared helper

// `ActorBox` is declared `private` in SettingsViewModelTests.swift (file-scoped),
// so we redeclare it here for this file only.  Both live in the same test target
// and the names do not conflict because `private` is file-scoped in Swift.
private actor ActorBox<T: Sendable> {
  var value: T
  init(value: T) { self.value = value }
  func set(_ v: T) { value = v }
  func get() -> T { value }
}
