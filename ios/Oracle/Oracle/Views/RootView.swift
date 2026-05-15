import SwiftUI

/// Application root: a three-tab shell containing the Save (capture), Ask
/// (retrieval), and Settings tabs.
///
/// The Settings tab was added in #184.  It hosts `SettingsView`, which
/// provides server URL / bearer token configuration (Keychain-persisted),
/// capture defaults (UserDefaults), force-resync, and build info.
struct RootView: View {
  var body: some View {
    TabView {
      CaptureView()
        .tabItem {
          Label("Save", systemImage: "square.and.pencil")
        }

      QueryView()
        .tabItem {
          Label("Ask", systemImage: "magnifyingglass")
        }

      SettingsView()
        .tabItem {
          Label("Settings", systemImage: "gear")
        }
    }
  }
}

#Preview {
  RootView()
}
