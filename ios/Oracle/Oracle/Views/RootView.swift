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
/// # Action Button dictation (#326)
///
/// When `CaptureViaDictationIntent` fires (Action Button press or Shortcut),
/// it posts `.openDictationCapture`.  RootView observes this and sets
/// `showDictationSheet = true`, presenting `DictationCaptureView` as a sheet.
///
/// If the app is backgrounded mid-dictation, `DictationCaptureView` observes
/// `scenePhase` and calls `viewModel.makeDraftIfNeeded()`.  If a non-empty
/// partial transcript exists it posts `.dictationDraftAvailable` carrying the
/// `DictationDraft` in `userInfo`.  RootView receives that notification and
/// sets `pendingDictation`, surfacing the `DictationResumeBanner`.
/// Tap Resume to reopen the sheet pre-filled; tap × to discard.
///
/// Banner stacking order (top to bottom — most urgent first):
///   1. AuthRequiredBanner
///   2. DictationResumeBanner
///
/// # V2 forest-green (#320)
///
/// Tab bar uses `.forest500` tint on the `TabView` so active icons and labels
/// render in the primary forest green. Inactive items fall back to `ink300`
/// via the system's default unselected color, which is overridden by
/// `UITabBar.appearance()` in `init` to match the palette.
struct RootView: View {

  // MARK: - Appearance override (#336)

  /// Reads the persisted appearance preference and maps it to a
  /// `ColorScheme?` value for `.preferredColorScheme(_:)`.
  ///
  /// `"system"` (or any unrecognised value) → `nil` (follows OS).
  /// `"light"` → `.light`, `"dark"` → `.dark`.
  @AppStorage(SettingsViewModel.appearancePreferenceKey)
  private var appearancePreference: String = "system"

  private var preferredColorScheme: ColorScheme? {
    switch appearancePreference {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
  }

  // MARK: - Tab selection

  /// Drives programmatic tab switching.  The Settings tab is index 2.
  @State private var selectedTab: Int = 0

  // MARK: - Banner state

  /// Whether the auth-required banner is currently visible.
  @State private var showAuthBanner: Bool = false

  // MARK: - Dictation state (#326)

  /// Whether the dictation capture sheet is currently presented.
  @State private var showDictationSheet: Bool = false

  /// A partial dictation draft left when the app was backgrounded mid-session.
  /// In-memory only (V1).  `nil` when there is no pending draft.
  @State var pendingDictation: DictationDraft? = nil

  /// Transcript carried into the sheet when the user taps Resume on the banner.
  ///
  /// This is intentionally separate from `pendingDictation`.  SwiftUI
  /// coalesces state mutations that happen in the same synchronous closure, so
  /// if we nil out `pendingDictation` and set `showDictationSheet = true` in
  /// the same handler, the sheet's content closure evaluates *after* the
  /// coalesced render pass — by which point `pendingDictation` is already nil
  /// and the resume path is never taken.  Storing the transcript here before
  /// clearing `pendingDictation` breaks that dependency.
  @State private var dictationResumeTranscript: String? = nil

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
      // Auth-required banner — pinned above the dictation-resume banner.
      // Auth failure is more urgent than an unfinished dictation.
      if showAuthBanner {
        AuthRequiredBanner {
          selectedTab = 2  // Settings tab index.
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: showAuthBanner)
      }

      // Dictation-resume banner — shown when a partial transcript is waiting.
      if let draft = pendingDictation {
        DictationResumeBanner(
          draft: draft,
          onResume: {
            // Pin the transcript into `dictationResumeTranscript` BEFORE
            // clearing `pendingDictation`.  SwiftUI coalesces mutations from
            // the same synchronous closure into a single render pass, so the
            // sheet content closure would otherwise see a nil draft and open a
            // fresh, mic-armed sheet instead of the pre-filled resume sheet.
            dictationResumeTranscript = draft.transcript
            pendingDictation = nil
            showDictationSheet = true
          },
          onDismiss: {
            withAnimation(.easeInOut(duration: 0.25)) {
              pendingDictation = nil
            }
          }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: pendingDictation == nil)
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
    .sheet(isPresented: $showDictationSheet, onDismiss: {
      // Clear the pinned resume transcript once the sheet is gone so a
      // subsequent fresh Action-Button press gets a clean empty sheet.
      dictationResumeTranscript = nil
    }) {
      if let transcript = dictationResumeTranscript {
        // Resume mode: pre-filled transcript, mic not auto-armed.
        DictationCaptureView(initialTranscript: transcript)
      } else {
        // Fresh mode: mic arms immediately.
        DictationCaptureView()
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
    .onReceive(
      NotificationCenter.default.publisher(for: .openDictationCapture)
    ) { _ in
      showDictationSheet = true
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .dictationDraftAvailable)
    ) { notification in
      // A dictation session was backgrounded mid-recording.  Stash the draft
      // so DictationResumeBanner can offer to resume.
      if let draft = notification.userInfo?[dictationDraftUserInfoKey] as? DictationDraft {
        pendingDictation = draft
      }
    }
    // Apply the user's appearance preference app-wide (#336).
    // nil → follows OS; .light / .dark → explicit override.
    // @AppStorage binding means the update is live — no restart needed.
    .preferredColorScheme(preferredColorScheme)
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
