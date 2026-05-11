import SwiftUI
import OracleCore

@main
struct OracleApp: App {

  // Wire AppDelegate so the OS can deliver background URLSession completion
  // handlers when a capture upload finishes while the app is suspended.
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
