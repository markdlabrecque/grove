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
  /// their own in-memory container via `UploadQueue(modelContainer:api:)` directly.
  ///
  /// # VersionedSchema + migration plan
  ///
  /// This init uses `QueuedCaptureSchemaV1` and `QueuedCaptureMigrationPlan` so that
  /// future schema changes can be performed safely. SwiftData's default lightweight
  /// migration handles *additive* changes (new optional properties) automatically,
  /// but any *destructive* change — removing a property, adding a non-optional field
  /// with no default, or renaming a property — will crash here without a proper
  /// migration mapping.
  ///
  /// **Rule for future changes:** any destructive schema mutation requires:
  /// 1. A new `QueuedCaptureSchemaV2` type.
  /// 2. A new `MigrationStage` entry in `QueuedCaptureMigrationPlan.stages`.
  /// 3. A manual test against an existing on-device store (see
  ///    `docs/manual-tests/123-versionedschema-migration.md` for the template).
  static let modelContainer: ModelContainer = {
    let schema = Schema(QueuedCaptureSchemaV1.models)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    do {
      return try ModelContainer(
        for: schema,
        migrationPlan: QueuedCaptureMigrationPlan.self,
        configurations: [config]
      )
    } catch {
      // A fatal crash here is appropriate — if SwiftData cannot open its store
      // on launch there is no safe recovery path (the queue would silently drop
      // every capture). The crash message appears in Xcode's console with the
      // root cause.
      fatalError("[OracleApp] failed to create ModelContainer: \(error)")
    }
  }()

  // MARK: - Upload queue

  /// The shared upload queue used by `CaptureViewModel`.
  ///
  /// `UploadQueue` is a `@ModelActor`; its executor is backed by the shared
  /// `modelContainer`'s concurrency domain. No explicit `ModelContext` is needed
  /// at the call site — the macro provides it. Stored as `nonisolated(unsafe)` so
  /// it is accessible from the main actor without crossing an isolation boundary
  /// at declaration time. The actor's own serial executor protects all mutations.
  nonisolated(unsafe) static let uploadQueue: UploadQueue = {
    UploadQueue(
      modelContainer: OracleApp.modelContainer,
      api: OracleAPI.shared,
      initialToken: Config.shared.bearerToken
    )
  }()

  // MARK: - Network monitor

  /// Observes `NWPathMonitor` and calls `uploadQueue.tryDrain()` on reconnect.
  ///
  /// `nonisolated(unsafe)` for the same reason as `uploadQueue` — declaration
  /// happens at struct-init time (before `body` runs on the main actor) and
  /// `NetworkMonitor` is thread-safe via its internal serial queue.
  nonisolated(unsafe) static let networkMonitor: NetworkMonitor = {
    NetworkMonitor(uploadQueue: OracleApp.uploadQueue)
  }()

  // MARK: - App init

  init() {
    // Start network monitoring for the lifetime of the app.
    OracleApp.networkMonitor.start()

    // Sweep orphaned temp files from previous sessions before enqueuing new
    // tasks. A *.upload-body file is orphaned if the app was killed between
    // writeBodyToTempFile and the URLSession delegate firing. Files older than
    // one hour are removed; legitimate in-flight uploads complete or are
    // replayed by the OS well within that window.
    Task {
      await OracleAPI.shared.sweepOrphanedTempFiles()
    }

    // Eager launch drain: flush any rows that were enqueued in a previous
    // session (force-kill, offline-at-save, etc.). We do this unconditionally
    // on launch — if the network is down `tryDrain()` will iterate rows, fail
    // each one gracefully, and update their `lastError` fields. When the network
    // comes back `NetworkMonitor` will trigger a second drain via the rising-edge
    // handler; the two drains are safe to overlap because `UploadQueue` is an
    // actor (mutations serialised) and the server is idempotent on `client_id`.
    Task {
      await OracleApp.uploadQueue.tryDrain()
    }
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
    .modelContainer(OracleApp.modelContainer)
  }
}
