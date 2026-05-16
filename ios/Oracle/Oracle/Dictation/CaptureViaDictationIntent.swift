import AppIntents
import Foundation

// MARK: - CaptureViaDictationIntent

/// An `AppIntent` that opens The Oracle and presents the dictation capture
/// sheet with the microphone pre-armed.
///
/// ## Action Button binding
///
/// The user binds this intent in:
/// **Settings → Action Button → Shortcut → The Oracle → "Capture with Oracle"**
///
/// Once bound, a single press on the Action Button foregrounds the app and
/// opens ``DictationCaptureView`` immediately.
///
/// ## Donation
///
/// The intent is donated via `AppIntentRecommendation` in ``OracleApp`` so it
/// appears in the Shortcuts picker under the "The Oracle" app section, in the
/// Action Button settings panel, and in Spotlight.
///
/// ## Return value
///
/// Returns `IntentResult` with no output value.  The capture UUID is not
/// surfaced to Shortcuts because it requires a server round-trip; a follow-up
/// ticket can make this chainable once the sync path is synchronous.
@available(iOS 16.0, *)
struct CaptureViaDictationIntent: AppIntent {

  static var title: LocalizedStringResource = "Capture with Oracle"

  static var description: IntentDescription = IntentDescription(
    "Opens The Oracle and starts microphone dictation immediately. Speak your thought and save it in seconds.",
    categoryName: "Capture"
  )

  /// Foreground the app when this intent runs.
  static var openAppWhenRun: Bool = true

  // MARK: - Perform

  @MainActor
  func perform() async throws -> some IntentResult {
    // Signal RootView to open the dictation sheet.
    NotificationCenter.default.post(
      name: .openDictationCapture,
      object: nil
    )
    return .result()
  }
}

// MARK: - AppShortcutsProvider

/// Donates the dictation intent to the system so it appears in:
/// - Shortcuts app under "The Oracle"
/// - Action Button settings picker
/// - Siri suggestions
@available(iOS 16.0, *)
struct OracleShortcutsProvider: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CaptureViaDictationIntent(),
      phrases: [
        "Capture with \(.applicationName)",
        "Dictate to \(.applicationName)",
        "Save a thought in \(.applicationName)",
      ],
      shortTitle: "Capture with Oracle",
      systemImageName: "mic.fill"
    )
  }
}

// MARK: - Notification name

extension Notification.Name {
  /// Posted by ``CaptureViaDictationIntent`` when the Action Button is pressed.
  /// ``RootView`` observes this to open the dictation sheet.
  static let openDictationCapture = Notification.Name("com.oracle.openDictationCapture")
}
