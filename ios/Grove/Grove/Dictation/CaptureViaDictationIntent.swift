import AppIntents
import Foundation

// MARK: - CaptureViaDictationIntent

/// An `AppIntent` that opens Grove and presents the dictation capture
/// sheet with the microphone pre-armed.
///
/// ## Action Button binding
///
/// The user binds this intent in:
/// **Settings → Action Button → Shortcut → Grove → "Capture with Grove"**
///
/// Once bound, a single press on the Action Button foregrounds the app and
/// opens ``DictationCaptureView`` immediately.
///
/// ## Donation
///
/// The intent is donated via `AppIntentRecommendation` in ``GroveApp`` so it
/// appears in the Shortcuts picker under the "Grove" app section, in the
/// Action Button settings panel, and in Spotlight.
///
/// ## Return value
///
/// Returns `IntentResult` with no output value.  The capture UUID is not
/// surfaced to Shortcuts because it requires a server round-trip; a follow-up
/// ticket can make this chainable once the sync path is synchronous.
struct CaptureViaDictationIntent: AppIntent {

  static var title: LocalizedStringResource = "Capture with Grove"

  static var description: IntentDescription = IntentDescription(
    "Opens Grove and starts microphone dictation immediately. Speak your thought and save it in seconds.",
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
/// - Shortcuts app under "Grove"
/// - Action Button settings picker
/// - Siri suggestions
struct GroveShortcutsProvider: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CaptureViaDictationIntent(),
      phrases: [
        "Capture with \(.applicationName)",
        "Dictate to \(.applicationName)",
        "Save a thought in \(.applicationName)",
      ],
      shortTitle: "Capture with Grove",
      systemImageName: "mic.fill"
    )
  }
}

// MARK: - Notification names

extension Notification.Name {
  /// Posted by ``CaptureViaDictationIntent`` when the Action Button is pressed.
  /// ``RootView`` observes this to open the dictation sheet.
  static let openDictationCapture = Notification.Name("com.oracle.openDictationCapture")

  /// Posted by ``DictationCaptureView`` when the app is backgrounded mid-recording
  /// and a partial transcript exists.  The notification's `userInfo` carries the
  /// ``DictationDraft`` under the key ``dictationDraftUserInfoKey``.
  /// ``RootView`` observes this to surface the ``DictationResumeBanner``.
  static let dictationDraftAvailable = Notification.Name("com.oracle.dictationDraftAvailable")
}

/// Key used to store a ``DictationDraft`` in a `dictationDraftAvailable` notification's
/// `userInfo` dictionary.
let dictationDraftUserInfoKey = "draft"
