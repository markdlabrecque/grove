import Foundation
import SwiftUI
import GroveCore

// MARK: - SettingsViewModel

/// ViewModel for `SettingsView`.
///
/// Owns:
///   - Server URL and bearer token editing + Keychain persistence.
///   - Capture defaults (UserDefaults via `@AppStorage` in the View).
///   - Force-resync: triggers an `UploadQueue.tryDrain()` sweep.
///   - Build info: reads `CFBundleShortVersionString` / `CFBundleVersion`.
///
/// # Keychain round-trip
///
/// Server URL and bearer token are persisted to Keychain via `KeychainStore`.
/// After a successful save the live `GroveAPI.shared` actor is updated via
/// `updateCredentials(baseURL:bearerToken:)` so subsequent API calls use the
/// new values without an app restart.
///
/// # AppStorage keys
///
/// The constants `fillerWordCleanupKey` and `languageHintKey` are the shared
/// `UserDefaults` keys that `CaptureViewModel` (ticket #187) and `SettingsView`
/// bind to via `@AppStorage`.  Changing them here requires a matching update in
/// every binding site.
///
/// # @Observable + @AppStorage incompatibility
///
/// `@Observable` and `@AppStorage` cannot be combined on the same class —
/// `@Observable` synthesises `_`-prefixed backing storage that conflicts with
/// the property wrapper.  `SettingsViewModel` therefore uses `ObservableObject`
/// + `@Published` for its own mutable state.  `@AppStorage` bindings live
/// directly in `SettingsView` and reference the well-known key constants.
@MainActor
final class SettingsViewModel: ObservableObject {

  // MARK: - AppStorage keys (shared with CaptureViewModel in #187)

  /// `UserDefaults` key for the filler-word cleanup toggle.
  ///
  /// `SettingsView` binds via `@AppStorage(SettingsViewModel.fillerWordCleanupKey)`.
  /// `CaptureViewModel` will bind to the same key in #187.
  static let fillerWordCleanupKey = "capture.fillerWordCleanup"

  /// `UserDefaults` key for the voice capture language hint (BCP-47, e.g. "en").
  static let languageHintKey = "capture.languageHint"

  /// `UserDefaults` key for the explicit appearance (colour-scheme) override (#336).
  ///
  /// Valid stored values: `"system"` (default — follows OS), `"light"`, `"dark"`.
  /// Missing key at first launch defaults to `"system"` via `@AppStorage`'s
  /// type-default, so existing users see no visible change on upgrade.
  static let appearancePreferenceKey = "appearance.preference"

  // MARK: - Editable fields

  /// Current text in the Server URL field.  Committed (and validated) on blur
  /// via `commitServerURL()`.
  @Published var serverURLText: String = ""

  /// Validation error message for `serverURLText`.  `nil` when the URL is
  /// valid or has not been committed yet.
  @Published var serverURLError: String? = nil

  /// Current text in the Bearer Token field (SecureField).  Committed on blur
  /// via `commitToken()`.
  @Published var bearerTokenText: String = ""

  // MARK: - Build info

  var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "—"
  }

  var buildNumber: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? "—"
  }

  /// The server URL currently in use, read from Keychain (or xcconfig if
  /// Keychain has no entry yet).  Read-only display field.
  ///
  /// Falls back to empty string on a Keychain read failure — intentionally
  /// NOT `serverURLText`, which is the live edit buffer and would show
  /// whatever the user is currently half-typing.
  var currentServerURL: String {
    (try? keychain.read(forKey: KeychainStore.serverURLKey)) ?? ""
  }

  // MARK: - Force-resync state

  @Published var isSyncing: Bool = false
  @Published var lastSyncMessage: String? = nil

  // MARK: - Private dependencies

  private let keychain: any KeychainStoreProtocol
  private let drainAction: () async -> Void
  /// Called with the new token value after a successful `commitToken()`.
  /// In production, delegates to `GroveApp.uploadQueue.reenqueueAuthRequired`.
  /// Tests inject a stub to assert the call without a live queue.
  private let reenqueueAction: (String) async -> Void
  /// Called with `(baseURL, bearerToken)` after a successful credential
  /// persist.  In production this updates `GroveAPI.shared`; tests inject a
  /// recording closure to assert the call (or absence of it) without touching
  /// the shared actor.
  private let updateCredentialsAction: (URL, String) async -> Void

  // MARK: - Init

  /// Production initialiser — uses the shared Keychain and upload queue.
  init() {
    self.keychain = KeychainStore.shared
    self.drainAction = {
      await GroveApp.uploadQueue.tryDrain()
    }
    self.reenqueueAction = { newToken in
      await GroveApp.uploadQueue.updateToken(newToken)
      await GroveApp.uploadQueue.reenqueueAuthRequired(newToken: newToken)
    }
    self.updateCredentialsAction = { baseURL, token in
      await GroveAPI.shared.updateCredentials(baseURL: baseURL, bearerToken: token)
    }
    loadFromKeychain()
  }

  /// Testing initialiser — injectable Keychain service, drain action, and
  /// reenqueue action.
  ///
  /// - Parameters:
  ///   - keychainService: A unique Keychain service string for this test run.
  ///   - onDrain: Closure called instead of the real `uploadQueue.tryDrain()`.
  ///   - onReenqueue: Closure called with the new token instead of
  ///     `uploadQueue.reenqueueAuthRequired(newToken:)`.
  ///   - onUpdateCredentials: Closure called with `(baseURL, token)` instead of
  ///     `GroveAPI.shared.updateCredentials`.
  init(
    keychainService: String,
    onDrain: @escaping () async -> Void,
    onReenqueue: @escaping (String) async -> Void = { _ in },
    onUpdateCredentials: @escaping (URL, String) async -> Void = { _, _ in }
  ) {
    self.keychain = KeychainStore(service: keychainService)
    self.drainAction = onDrain
    self.reenqueueAction = onReenqueue
    self.updateCredentialsAction = onUpdateCredentials
    loadFromKeychain()
  }

  /// Testing initialiser — injectable `KeychainStoreProtocol` conformer, drain
  /// action, and reenqueue action.
  ///
  /// Use this overload when you need a stub that controls Keychain behaviour
  /// (e.g. simulating write failures).
  ///
  /// - Parameters:
  ///   - keychain: A stub conforming to `KeychainStoreProtocol`.
  ///   - onDrain: Closure called instead of the real `uploadQueue.tryDrain()`.
  ///   - onReenqueue: Closure called with the new token instead of
  ///     `uploadQueue.reenqueueAuthRequired(newToken:)`.
  ///   - onUpdateCredentials: Closure called with `(baseURL, token)` instead of
  ///     `GroveAPI.shared.updateCredentials`.
  init(
    keychain: any KeychainStoreProtocol,
    onDrain: @escaping () async -> Void = {},
    onReenqueue: @escaping (String) async -> Void = { _ in },
    onUpdateCredentials: @escaping (URL, String) async -> Void = { _, _ in }
  ) {
    self.keychain = keychain
    self.drainAction = onDrain
    self.reenqueueAction = onReenqueue
    self.updateCredentialsAction = onUpdateCredentials
    loadFromKeychain()
  }

  // MARK: - Test factory

  /// Convenience factory for tests — generates a unique Keychain namespace.
  static func makeForTest(
    onDrain: @escaping () async -> Void = {},
    onReenqueue: @escaping (String) async -> Void = { _ in },
    onUpdateCredentials: @escaping (URL, String) async -> Void = { _, _ in }
  ) -> SettingsViewModel {
    SettingsViewModel(
      keychainService: "com.oracle.test.\(UUID().uuidString)",
      onDrain: onDrain,
      onReenqueue: onReenqueue,
      onUpdateCredentials: onUpdateCredentials
    )
  }

  /// Convenience factory for tests — injects a `KeychainStoreProtocol` stub.
  static func makeForTest(
    keychain: any KeychainStoreProtocol,
    onDrain: @escaping () async -> Void = {},
    onReenqueue: @escaping (String) async -> Void = { _ in },
    onUpdateCredentials: @escaping (URL, String) async -> Void = { _, _ in }
  ) -> SettingsViewModel {
    SettingsViewModel(
      keychain: keychain,
      onDrain: onDrain,
      onReenqueue: onReenqueue,
      onUpdateCredentials: onUpdateCredentials
    )
  }

  // MARK: - Load from Keychain

  private func loadFromKeychain() {
    serverURLText = (try? keychain.read(forKey: KeychainStore.serverURLKey)) ?? ""
    bearerTokenText = (try? keychain.read(forKey: KeychainStore.bearerTokenKey)) ?? ""
  }

  // MARK: - Commit server URL

  /// Validate and persist the current `serverURLText` to Keychain.
  ///
  /// Sets `serverURLError` when the URL is invalid.  On a successful Keychain
  /// write, updates the live `GroveAPI.shared` actor with the new base URL.
  /// If the Keychain write fails the live API is NOT updated — Keychain is the
  /// source of truth; we do not propagate a value that did not persist.
  func commitServerURL() {
    let raw = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)

    guard KeychainStore.isValidServerURL(raw), let url = URL(string: raw) else {
      serverURLError = "Enter a valid URL (e.g. https://oracle.example.ts.net)"
      return
    }

    serverURLError = nil

    do {
      try keychain.write(raw, forKey: KeychainStore.serverURLKey)
    } catch {
      print("[SettingsViewModel] WARN Keychain write failed for server_url: \(error)")
      // Don't surface Keychain errors to the user in V1 — fall back silently.
      // Do NOT update the live API: if the value didn't persist to Keychain it
      // would be lost on next launch, creating a split-brain state.
      return
    }

    // Push the new URL to the live API actor so subsequent calls use it.
    let currentToken = bearerTokenText.isEmpty
      ? ((try? keychain.read(forKey: KeychainStore.bearerTokenKey)) ?? "")
      : bearerTokenText
    Task {
      await updateCredentialsAction(url, currentToken)
    }
  }

  // MARK: - Commit bearer token

  /// Persist the current `bearerTokenText` to Keychain, update the live API
  /// actor, and auto-resume any `auth_required` items in the upload queue.
  ///
  /// An empty token is silently ignored — the existing Keychain value is kept.
  ///
  /// If the Keychain write fails the live API is NOT updated — Keychain is the
  /// source of truth; we do not propagate a value that did not persist.
  ///
  /// After updating credentials, `UploadQueue.reenqueueAuthRequired(newToken:)`
  /// is called so that captures stuck in `auth_required` state are re-enqueued
  /// automatically — the user does not need to tap "Force Resync".
  func commitToken() {
    let raw = bearerTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return }

    do {
      try keychain.write(raw, forKey: KeychainStore.bearerTokenKey)
    } catch {
      print("[SettingsViewModel] WARN Keychain write failed for bearer_token: \(error)")
      // Do NOT update the live API: if the value didn't persist to Keychain it
      // would be lost on next launch, creating a split-brain state.
      return
    }

    // Resolve the current base URL from Keychain for the live API update.
    let currentRawURL = (try? keychain.read(forKey: KeychainStore.serverURLKey)) ?? ""
    guard let currentURL = URL(string: currentRawURL) else { return }

    let newToken = raw
    Task {
      await updateCredentialsAction(currentURL, newToken)
      // Keep the queue's token tracking in sync so idempotency works correctly.
      await reenqueueAction(newToken)
    }
  }

  // MARK: - Force-resync

  /// Re-enqueue all pending + failed items and trigger an upload sweep.
  ///
  /// `UploadQueue.tryDrain()` iterates all queued rows and posts them.  Rows
  /// that were permanently failed (4xx) were already deleted by the queue; this
  /// sweep picks up any `pending` or transient-failed rows that haven't been
  /// uploaded yet.
  func forceResync() async {
    guard !isSyncing else { return }
    isSyncing = true
    defer { isSyncing = false }

    print("[SettingsViewModel] force-resync: triggering upload-queue sweep")
    await drainAction()
    lastSyncMessage = "Sync sweep complete — check console for details."
    print("[SettingsViewModel] force-resync: sweep complete")
  }
}
