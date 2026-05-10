import OracleCore
import SwiftUI

@main
struct OracleApp: App {
  init() {
    // Debug helper: confirm which config is in use at launch.
    // Remove or gate behind a build flag before any wider distribution.
    //
    // Guard: suppress the print during test runs — `Config.shared` returns
    // stub values under XCTest (see Config.swift), so logging them would be
    // misleading noise in the test output.  The fatalError crash that
    // originally motivated this guard is now handled inside Config.init().
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
