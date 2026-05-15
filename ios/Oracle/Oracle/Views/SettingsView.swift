import SwiftUI
import OracleCore

// MARK: - SettingsView

/// The Settings screen for The Oracle.
///
/// Reachable from the Settings tab (gear icon).  Sections:
///   1. **Server** — URL and bearer token (persisted to Keychain).
///   2. **Capture defaults** — language hint, filler-word cleanup (UserDefaults).
///   3. **Sync** — Force-resync button.
///   4. **About** — App version, build number, current server URL.
///
/// # Accessibility
///
/// All interactive controls have explicit accessibility labels.  The form uses
/// Dynamic Type — tested at Accessibility Extra Extra Extra Large.  SecureField
/// is VoiceOver-safe: it announces "Bearer Token, secure text field".
///
/// # @AppStorage bindings
///
/// `fillerWordCleanupEnabled` and `languageHint` are stored in `UserDefaults`
/// via `@AppStorage` using the key constants on `SettingsViewModel`.  CaptureViewModel
/// (#187) binds to the same keys — changing the key strings here is a
/// coordinated change.
struct SettingsView: View {

  @StateObject private var viewModel = SettingsViewModel()

  // Capture defaults — UserDefaults via @AppStorage.
  // These keys are the shared contract with CaptureViewModel (#187).
  @AppStorage(SettingsViewModel.fillerWordCleanupKey)
  private var fillerWordCleanupEnabled: Bool = false

  @AppStorage(SettingsViewModel.languageHintKey)
  private var languageHint: String = ""

  var body: some View {
    NavigationStack {
      Form {
        serverSection
        captureDefaultsSection
        syncSection
        aboutSection
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.large)
    }
  }

  // MARK: - Server section

  private var serverSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        TextField("https://oracle.example.ts.net", text: $viewModel.serverURLText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .keyboardType(.URL)
          .onSubmit { viewModel.commitServerURL() }
          .accessibilityLabel("Server URL")
          .accessibilityHint("Enter the full URL of your Oracle server")

        if let error = viewModel.serverURLError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel("Server URL error: \(error)")
        }
      }

      SecureField("Bearer token", text: $viewModel.bearerTokenText)
        .onSubmit { viewModel.commitToken() }
        .accessibilityLabel("Bearer Token")
        .accessibilityHint("Enter the bearer token for authenticating with the server")
    } header: {
      Text("Server")
    } footer: {
      Text("Changes take effect immediately. The app does not need to be restarted.")
        .font(.caption)
    }
  }

  // MARK: - Capture defaults section

  private var captureDefaultsSection: some View {
    Section("Capture Defaults") {
      Toggle(isOn: $fillerWordCleanupEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Filler Word Cleanup")
          Text("Remove \"um\", \"uh\", and similar words from voice captures")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel("Filler Word Cleanup")
      .accessibilityHint("When enabled, removes filler words from voice transcriptions before saving")

      HStack {
        Text("Language Hint")
        Spacer()
        TextField("e.g. en-US", text: $languageHint)
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .frame(maxWidth: 120)
          .accessibilityLabel("Language hint for voice capture")
          .accessibilityHint("BCP-47 language code, for example en-US or fr-CA. Leave empty to use the device locale.")
      }
    }
  }

  // MARK: - Sync section

  private var syncSection: some View {
    Section {
      NavigationLink(destination: UploadQueueDebugView()) {
        Label("Upload queue", systemImage: "tray.and.arrow.up")
          .accessibilityLabel("Upload Queue")
          .accessibilityHint("View upload queue items with state and error details")
      }

      Button(action: {
        Task { await viewModel.forceResync() }
      }) {
        HStack {
          if viewModel.isSyncing {
            ProgressView()
              .controlSize(.small)
              .padding(.trailing, 6)
          }
          Text(viewModel.isSyncing ? "Syncing…" : "Force Resync")
            .foregroundStyle(viewModel.isSyncing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
      }
      .disabled(viewModel.isSyncing)
      .accessibilityLabel("Force Resync")
      .accessibilityHint("Re-uploads any captures that are pending or failed to send")

      if let message = viewModel.lastSyncMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel(message)
      }
    } header: {
      Text("Sync")
    } footer: {
      Text("Triggers an immediate upload of any captures waiting in the local queue.")
        .font(.caption)
    }
  }

  // MARK: - About section

  private var aboutSection: some View {
    Section("About") {
      LabeledContent("Version", value: viewModel.appVersion)
        .accessibilityLabel("App version \(viewModel.appVersion)")

      LabeledContent("Build", value: viewModel.buildNumber)
        .accessibilityLabel("Build number \(viewModel.buildNumber)")

      LabeledContent("Server", value: viewModel.currentServerURL)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityLabel("Current server URL: \(viewModel.currentServerURL)")
    }
  }
}

// MARK: - Preview

#Preview {
  SettingsView()
}
