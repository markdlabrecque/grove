import SwiftUI
import SwiftData
import OracleCore

@main
struct OracleApp: App {

  // Wire AppDelegate so the OS can deliver background URLSession completion
  // handlers when a capture upload finishes while the app is suspended.
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  // MARK: - SwiftData container

  /// The shared model container for the app. Contains `QueuedCapture` rows —
  /// the durable offline queue for captures that have not yet been uploaded.
  ///
  /// `isStoredInMemoryOnly: false` is the default (disk-backed). Tests supply
  /// their own in-memory container via `UploadQueue(modelContext:api:)` directly.
  static let modelContainer: ModelContainer = {
    let schema = Schema([QueuedCapture.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    do {
      return try ModelContainer(for: schema, configurations: [config])
    } catch {
      // A fatal crash here is appropriate — if SwiftData cannot open its store
      // on launch there is no safe recovery path (the queue would silently drop
      // every capture). The crash message appears in Xcode's console with the
      // root cause.
      fatalError("[OracleApp] failed to create ModelContainer: \(error)")
    }
  }()

  // MARK: - Upload queue

  /// The shared upload queue used by `CaptureViewModel` (wired in PR 5).
  ///
  /// The actor is initialised with a `ModelContext` from the shared container
  /// and the production `OracleAPI.shared`. Stored as a `nonisolated(unsafe)` var
  /// so it is accessible from the main actor without crossing an isolation boundary
  /// at declaration time. The actor's own serial executor protects all mutations.
  nonisolated(unsafe) static let uploadQueue: UploadQueue = {
    let context = ModelContext(OracleApp.modelContainer)
    return UploadQueue(modelContext: context, api: OracleAPI.shared)
  }()

  var body: some Scene {
    WindowGroup {
      RootView()
    }
    .modelContainer(OracleApp.modelContainer)
  }
}
