import SwiftUI

@main
struct OracleApp: App {
  init() {
    // Debug helper: confirm which config is in use at launch.
    // Remove or gate behind a build flag before any wider distribution.
    //
    // Guard: skip the config access when the app is being launched as a unit
    // test host. `Config.shared` calls fatalError if BASE_URL is missing, and
    // the test host process doesn't have a populated Info.plist.
    #if DEBUG
    let isRunningTests = ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    if !isRunningTests {
      print("[Oracle] baseURL:", Config.shared.baseURL)
    }
    #endif
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
