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
///
/// # V2 forest-green (#320)
///
/// Tab bar uses `.forest500` tint on the `TabView` so active icons and labels
/// render in the primary forest green. Inactive items fall back to `ink300`
/// via the system's default unselected color, which is overridden by
/// `UITabBar.appearance()` in `init` to match the palette.
struct RootView: View {

  // MARK: - Tab selection

  /// Drives programmatic tab switching.  The Settings tab is index 2.
  @State private var selectedTab: Int = 0

  // MARK: - Banner state

  /// Whether the auth-required banner is currently visible.
  @State private var showAuthBanner: Bool = false

  // MARK: - Environment

  @Environment(\.scenePhase) private var scenePhase

  // MARK: - Init

  init() {
    // Apply forest-green palette to the tab bar chrome.
    // Active tint is handled by SwiftUI `.tint(.forest500)` below;
    // inactive items get ink300 via UITabBarAppearance.
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    // Inactive tab icon + label color.
    let ink300 = UIColor(named: "ink300") ?? .systemGray
    appearance.stackedLayoutAppearance.normal.iconColor = ink300
    appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: ink300]
    UITabBar.appearance().standardAppearance = appearance
    UITabBar.appearance().scrollEdgeAppearance = appearance
  }

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
            Label("Settings", systemImage: "gearshape.fill")
          }
          .tag(2)
      }
      .tint(.forest500)
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
