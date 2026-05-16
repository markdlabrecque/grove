import UIKit
import GroveCore

/// UIApplicationDelegate that handles background URLSession events for capture
/// uploads.
///
/// The OS calls `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// when a background upload completes while the app is suspended or not running.
/// This delegate stores the system-supplied completion handler so that
/// `UploadSessionDelegate.urlSessionDidFinishEvents(forBackgroundURLSession:)`
/// can drain it after all pending events have been delivered.
///
/// # Lifecycle
///
/// 1. OS reactivates the app (launch or resume) and calls this delegate method.
/// 2. We hand the `completionHandler` to `OracleAPI.shared` keyed by `identifier`.
/// 3. `OracleAPI` reconnects to the background session (it was recreated with the
///    same identifier on launch), and the OS replays any outstanding task events
///    via `UploadSessionDelegate`.
/// 4. Once all events are delivered the OS calls
///    `urlSessionDidFinishEvents(forBackgroundURLSession:)` on the delegate, which
///    calls `OracleAPI.drainBackgroundCompletionHandlers()`.
/// 5. That method calls the stored completion handler on the main thread, as
///    Apple's documentation requires.
final class AppDelegate: NSObject, UIApplicationDelegate {

  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    // Wrap the system-supplied handler in a @Sendable closure so it can cross
    // the actor boundary into OracleAPI. The system's completionHandler is a
    // plain C-function-pointer bridge with no shared mutable state; the wrapper
    // is safe to send across isolation domains.
    let sendableHandler: @Sendable () -> Void = { completionHandler() }
    Task {
      await OracleAPI.shared.storeBackgroundCompletionHandler(
        sendableHandler,
        forIdentifier: identifier
      )
    }
  }
}
