import SwiftUI

/// Application root: a three-tab shell containing the Save (capture), Ask
/// (retrieval), and Settings tabs.
///
/// The Settings tab was added in #184.  It hosts `SettingsView`, which
/// provides server URL / bearer token configuration (Keychain-persisted),
/// capture defaults (UserDefaults), force-resync, and build info.
///
/// # Auth-required banner (#185)
///
/// When any queued capture is in the `auth_required` state (server returned
/// 401), a sticky banner is shown at the top of the active screen on the next
/// foreground transition.  Tapping the banner switches to the Settings tab so
/// the user can update their bearer token.  The banner is dismissed once the
/// `auth_required` count drops to zero.
///
/// The check fires on `scenePhase` becoming `.active` — once per foregrounding,
/// not on every screen change.  Subsequent `authRequiredDidChange` notifications
/// from `UploadQueue` also re-evaluate the count so a spontaneous drain (e.g.
/// from an on-device OS background-task replay) can clear the banner without
/// requiring a foreground transition.
struct RootView: View {

  // MARK: - Tab selection

  /// Drives programmatic tab switching.  The Settings tab is index 2.
  @State private var selectedTab: Int = 0

  // MARK: - Banner state

  /// Whether the auth-required banner is currently visible.
  @State private var showAuthBanner: Bool = false

  // MARK: - Environment

  @Environment(\.scenePhase) private var scenePhase

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      // Auth-required banner — pinned above the tab bar.
      if showAuthBanner {
        AuthRequiredBanner {
          selectedTab = 2  // Settings tab index.
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: showAuthBanner)
      }

      TabView(selection: $selectedTab) {
        CaptureView()
          .tabItem {
            Label("Save", systemImage: "square.and.pencil")
          }
          .tag(0)

        QueryView()
          .tabItem {
            Label("Ask", systemImage: "magnifyingglass")
          }
          .tag(1)

        SettingsView()
          .tabItem {
            Label("Settings", systemImage: "gear")
          }
          .tag(2)
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        refreshAuthBannerState()
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .authRequiredDidChange)
    ) { _ in
      refreshAuthBannerState()
    }
  }

  // MARK: - Helpers

  private func refreshAuthBannerState() {
    Task {
      let count = (try? await OracleApp.uploadQueue.authRequiredCount()) ?? 0
      await MainActor.run {
        withAnimation(.easeInOut(duration: 0.25)) {
          showAuthBanner = count > 0
        }
      }
    }
  }
}

#Preview {
  RootView()
}
