import SwiftUI
import OracleCore

// MARK: - SettingsView

/// The Settings screen for The Oracle.
///
/// Reachable from the Settings tab (gear icon).  Sections:
///   1. **Server** — URL and bearer token (persisted to Keychain).
///   2. **Appearance** — Light / Dark / System colour-scheme override (#336).
///   3. **Capture defaults** — language hint, filler-word cleanup (UserDefaults).
///   4. **Sync** — Force-resync button.
///   5. **About** — App version, build number, current server URL.
///
/// # Accessibility
///
/// All interactive controls have explicit accessibility labels.  The form uses
/// Dynamic Type — tested at Accessibility Extra Extra Extra Large.  SecureField
/// is VoiceOver-safe: it announces "Bearer Token, secure text field".
///
/// # @AppStorage bindings
///
/// `fillerWordCleanupEnabled`, `languageHint`, and `appearancePreference` are
/// stored in `UserDefaults` via `@AppStorage` using the key constants on
/// `SettingsViewModel`.  `CaptureViewModel` (#187) binds to the filler and
/// language keys — changing the key strings here is a coordinated change.
///
/// # V2 forest-green (#320)
///
/// Settings rows have 28pt rounded-square icon badges per spec §3.11.
/// Section labels are 11pt uppercase semibold forest700. Toggles tinted forest500.
struct SettingsView: View {

  @StateObject private var viewModel = SettingsViewModel()

  // Capture defaults — UserDefaults via @AppStorage.
  // These keys are the shared contract with CaptureViewModel (#187).
  @AppStorage(SettingsViewModel.fillerWordCleanupKey)
  private var fillerWordCleanupEnabled: Bool = false

  @AppStorage(SettingsViewModel.languageHintKey)
  private var languageHint: String = ""

  // Appearance override (#336).  Default "system" — follows the OS setting.
  // Applied app-wide via .preferredColorScheme() in OracleApp/RootView.
  @AppStorage(SettingsViewModel.appearancePreferenceKey)
  private var appearancePreference: String = "system"

  var body: some View {
    NavigationStack {
      ZStack {
        Color.paperWarm
          .ignoresSafeArea()

        List {
          serverSection
          appearanceSection
          captureDefaultsSection
          syncSection
          aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.paperWarm)
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.large)
      // Settings tab replaces the "GROVE" wordmark with the version
      // string per spec §3.2.
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavWordmarkView(text: "v\(viewModel.appVersion)")
        }
      }
    }
  }

  // MARK: - Server section

  private var serverSection: some View {
    Section {
      // Server URL row
      settingsRow(
        icon: "network",
        iconColor: .forest500,
        content: {
          VStack(alignment: .leading, spacing: 4) {
            TextField("https://oracle.example.ts.net", text: $viewModel.serverURLText)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .keyboardType(.URL)
              .font(.system(size: 15))
              .foregroundStyle(Color.ink900)
              .onSubmit { viewModel.commitServerURL() }
              .accessibilityLabel("Server URL")
              .accessibilityHint("Enter the full URL of your Oracle server")

            if let error = viewModel.serverURLError {
              Text(error)
                .font(.caption)
                .foregroundStyle(Color.destructive)
                .accessibilityLabel("Server URL error: \(error)")
            }
          }
        }
      )

      // Bearer token row
      settingsRow(
        icon: "lock.fill",
        iconColor: .forest800,
        content: {
          SecureField("Bearer token", text: $viewModel.bearerTokenText)
            .font(.system(size: 15))
            .foregroundStyle(Color.ink900)
            .onSubmit { viewModel.commitToken() }
            .accessibilityLabel("Bearer Token")
            .accessibilityHint("Enter the bearer token for authenticating with the server")
        }
      )
    } header: {
      sectionHeader("Server")
    } footer: {
      Text("Changes take effect immediately. The app does not need to be restarted.")
        .font(.caption)
        .foregroundStyle(Color.ink500)
    }
    .listRowBackground(Color.card)
  }

  // MARK: - Appearance section (#336)

  private var appearanceSection: some View {
    Section {
      settingsRow(
        icon: "circle.lefthalf.filled",
        iconColor: .forest700,
        content: {
          Picker(selection: $appearancePreference) {
            Text("System").tag("system")
            Text("Light").tag("light")
            Text("Dark").tag("dark")
          } label: {
            Text("Appearance")
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(Color.ink900)
          }
          .pickerStyle(.menu)
          .tint(.forest500)
          .accessibilityLabel("Appearance")
          .accessibilityHint("Choose whether the app follows the system setting or stays in Light or Dark mode")
        }
      )
    } header: {
      sectionHeader("Appearance")
    } footer: {
      Text("Override the system Light/Dark setting. \"System\" follows your device's appearance.")
        .font(.caption)
        .foregroundStyle(Color.ink500)
    }
    .listRowBackground(Color.card)
  }

  // MARK: - Capture defaults section

  private var captureDefaultsSection: some View {
    Section {
      // Filler word cleanup toggle row (§3.5)
      settingsRow(
        icon: "text.alignleft",
        iconColor: .moss400,
        content: {
          Toggle(isOn: $fillerWordCleanupEnabled) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Filler Word Cleanup")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.ink900)
              Text("Remove \"um\", \"uh\", and similar words from voice captures")
                .font(.system(size: 12))
                .foregroundStyle(Color.ink500)
            }
          }
          .tint(.forest500)
          .accessibilityLabel("Filler Word Cleanup")
          .accessibilityHint("When enabled, removes filler words from voice transcriptions before saving")
        }
      )

      // Language hint row
      settingsRow(
        icon: "globe",
        iconColor: .forest500,
        content: {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("Language Hint")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.ink900)
            }
            Spacer()
            TextField("e.g. en-US", text: $languageHint)
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .font(.system(size: 15))
              .foregroundStyle(Color.ink500)
              .frame(maxWidth: 120)
              .accessibilityLabel("Language hint for voice capture")
              .accessibilityHint("BCP-47 language code, for example en-US or fr-CA. Leave empty to use the device locale.")
          }
        }
      )
    } header: {
      sectionHeader("Capture Defaults")
    }
    .listRowBackground(Color.card)
  }

  // MARK: - Sync section

  private var syncSection: some View {
    Section {
      // Upload queue row
      settingsRow(
        icon: "tray.and.arrow.up",
        iconColor: .forest500,
        content: {
          NavigationLink(destination: UploadQueueDebugView()) {
            Text("Upload queue")
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(Color.ink900)
          }
          .accessibilityLabel("Upload Queue")
          .accessibilityHint("View upload queue items with state and error details")
        }
      )

      // Force resync row
      settingsRow(
        icon: "arrow.triangle.2.circlepath",
        iconColor: .forest700,
        content: {
          Button(action: {
            Task { await viewModel.forceResync() }
          }) {
            HStack {
              if viewModel.isSyncing {
                ProgressView()
                  .controlSize(.small)
                  .tint(.forest500)
                  .padding(.trailing, 6)
              }
              Text(viewModel.isSyncing ? "Syncing…" : "Force Resync")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(viewModel.isSyncing ? Color.ink500 : Color.forest500)
            }
          }
          .disabled(viewModel.isSyncing)
          .accessibilityLabel("Force Resync")
          .accessibilityHint("Re-uploads any captures that are pending or failed to send")
        }
      )

      if let message = viewModel.lastSyncMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(Color.ink500)
          .listRowBackground(Color.card)
          .accessibilityLabel(message)
      }
    } header: {
      sectionHeader("Sync")
    } footer: {
      Text("Triggers an immediate upload of any captures waiting in the local queue.")
        .font(.caption)
        .foregroundStyle(Color.ink500)
    }
    .listRowBackground(Color.card)
  }

  // MARK: - About section

  private var aboutSection: some View {
    Section {
      settingsRow(
        icon: "info.circle.fill",
        iconColor: .forest800,
        content: {
          LabeledContent("Version", value: viewModel.appVersion)
            .font(.system(size: 15))
            .foregroundStyle(Color.ink900)
            .accessibilityLabel("App version \(viewModel.appVersion)")
        }
      )

      settingsRow(
        icon: "hammer.fill",
        iconColor: .forest800,
        content: {
          LabeledContent("Build", value: viewModel.buildNumber)
            .font(.system(size: 15))
            .foregroundStyle(Color.ink900)
            .accessibilityLabel("Build number \(viewModel.buildNumber)")
        }
      )

      settingsRow(
        icon: "network",
        iconColor: .ink500,
        content: {
          LabeledContent("Server", value: viewModel.currentServerURL)
            .font(.system(size: 15))
            .foregroundStyle(Color.ink900)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel("Current server URL: \(viewModel.currentServerURL)")
        }
      )
    } header: {
      sectionHeader("About")
    }
    .listRowBackground(Color.card)
  }

  // MARK: - Helpers

  /// Section header: 11pt uppercase semibold forest700, 0.14em tracking (spec §3.11).
  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(Color.forest700)
      .textCase(.uppercase)
      .tracking(1.5)
  }

  /// A settings row with a 28pt rounded-square icon badge on the left (spec §3.11).
  ///
  /// `iconColor` drives the badge background; the glyph is always `paper` (warm cream).
  @ViewBuilder
  private func settingsRow<Content: View>(
    icon: String,
    iconColor: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 12) {
      // Icon badge: 28pt, 8pt radius, soft shadow.
      Image(systemName: icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.paper)
        .frame(width: 28, height: 28)
        .background(iconColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: iconColor.opacity(0.3), radius: 4, x: 0, y: 2)
        .accessibilityHidden(true)

      content()
    }
  }
}

// MARK: - Preview

#Preview {
  SettingsView()
}
