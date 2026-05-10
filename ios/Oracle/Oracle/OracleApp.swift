import SwiftUI

@main
struct OracleApp: App {
  init() {
    // Debug helper: confirm which config is in use at launch.
    // Remove or gate behind a build flag before any wider distribution.
    #if DEBUG
    print("[Oracle] baseURL:", Config.shared.baseURL)
    #endif
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
