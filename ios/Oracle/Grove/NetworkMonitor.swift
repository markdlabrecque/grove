import Network
import Observation

// MARK: - NetworkMonitor

/// Wraps `NWPathMonitor` and calls `UploadQueue.tryDrain()` whenever the device
/// transitions from no-network to network-available (a rising-edge trigger).
///
/// # Design: `@Observable` class, not an actor
///
/// `NetworkMonitor` is `@Observable` so that SwiftUI views can bind to
/// `isReachable` without a separate published-property wrapper. Mutable state
/// is split across two execution contexts:
///
///  - `wasReachable` is read and written exclusively on `monitorQueue` (the
///    same `DispatchQueue` supplied to `NWPathMonitor.start(queue:)`). Its
///    single-queue rule provides actor-like safety for edge detection.
///  - `isReachable` is always written on the main actor via
///    `Task { @MainActor in … }`, so SwiftUI bindings never race with a
///    background-queue mutation.
///
/// # Launch-drain strategy: eager launch drain, no first-edge suppression
///
/// `GroveApp.init` performs an explicit `Task { await uploadQueue.tryDrain() }`
/// immediately on startup to flush rows left from previous sessions. We do NOT
/// suppress the first path-update event from `NWPathMonitor`.
///
/// If the network is already up when `start()` is called, `NWPathMonitor` fires
/// its handler immediately with `.satisfied`. That triggers a second drain within
/// milliseconds of launch. This is safe because:
///
///  1. `UploadQueue.tryDrain()` is idempotent — the actor serialises concurrent
///     calls, so a second overlapping call finds no rows (the first drain deletes
///     eagerly on success).
///  2. The server enforces `UNIQUE(client_id)` with `ON CONFLICT DO NOTHING`, so
///     even if two drains race and both send the same row, the second upload is a
///     server-side no-op.
///  3. Suppression logic adds complexity and a possible off-by-one where a real
///     reconnect event is missed if the first event arrives after the launch drain
///     starts but before it finishes.
///
/// # Edge triggering
///
/// Only a `.unsatisfied → .satisfied` transition calls `tryDrain()`. Two
/// consecutive `.satisfied` updates (e.g. Wi-Fi handoff that stays connected)
/// do not retrigger. A `.satisfied → .unsatisfied` transition does nothing.
///
/// # Concurrency safety
///
/// `monitorQueue` is a private serial `DispatchQueue`. `NWPathMonitor`'s
/// `pathUpdateHandler` and all reads/writes to `wasReachable` run exclusively
/// on that queue. `isReachable` — the `@Observable` property observed by
/// SwiftUI — is written on the main actor via `Task { @MainActor in … }` so
/// that there is no data race between the background monitor queue and the
/// main-actor SwiftUI render loop. `@Observable`'s unfair-lock registrar
/// protects change-notification bookkeeping, but does not protect the stored
/// property itself from concurrent mutation; the explicit main-actor hop
/// eliminates that risk and is forward-compatible with Swift 6 strict
/// concurrency mode.
///
/// # Test seam
///
/// `pathDidUpdate(_:status:)` is exposed `internal` so that unit tests can
/// drive the edge-detection logic directly without real networking hardware.
/// Tests pass a synthesised `.satisfied` / `.unsatisfied` status and verify
/// that `drainAction` fires the expected number of times. `drainAction` is an
/// injected closure (default: `await uploadQueue.tryDrain()`) that tests can
/// replace with a drain counter.
@Observable
final class NetworkMonitor {

  // MARK: - Public state

  /// `true` when the most recently observed network path was `.satisfied`.
  ///
  /// Always written on the main actor (via `Task { @MainActor in … }` inside
  /// `pathDidUpdate`). SwiftUI bindings observe this property on the main
  /// actor, so keeping mutations there eliminates the data race that would
  /// otherwise exist between `monitorQueue` writes and main-actor reads.
  private(set) var isReachable: Bool = false

  // MARK: - Private state

  private let monitor: NWPathMonitor
  private let monitorQueue: DispatchQueue

  /// Closure invoked on a rising-edge (network reconnect). In production this
  /// calls `uploadQueue.tryDrain()`. Tests substitute a drain counter.
  ///
  /// The closure is `@Sendable` because it is called from a `Task { }` spawned
  /// inside `pathDidUpdate`, which may run on any executor.
  private let drainAction: @Sendable () async -> Void

  /// The reachability value from the *previous* path update. Used to detect a
  /// rising edge (unsatisfied → satisfied). Accessed exclusively on
  /// `monitorQueue` in production; accessed synchronously in tests (no queue
  /// needed when the test drives `pathDidUpdate` directly on one thread).
  private(set) var wasReachable: Bool = false

  /// Guards against calling `NWPathMonitor.start(queue:)` more than once.
  ///
  /// `NWPathMonitor.start(queue:)` does NOT ignore subsequent calls — a second
  /// call changes the delivery queue, which can produce callbacks on two queues
  /// simultaneously and race on `wasReachable`/`isReachable`. This flag makes
  /// `start()` idempotent.
  ///
  /// Concurrency contract: `start()` is called only from `GroveApp.init()`,
  /// which runs on the main actor during single-threaded app boot. A plain
  /// `Bool` is therefore sufficient; no lock or actor isolation is needed.
  private var isStarted = false

  // MARK: - Init (production)

  /// Create a `NetworkMonitor` that drains `uploadQueue` on reconnect.
  ///
  /// - Parameters:
  ///   - uploadQueue: The queue to drain when connectivity is re-established.
  ///   - monitor: Override for testing. Production code uses the default
  ///     `NWPathMonitor()` which monitors all interface types.
  ///   - monitorQueue: The serial dispatch queue on which `NWPathMonitor`
  ///     delivers callbacks. Override for testing.
  convenience init(
    uploadQueue: UploadQueue,
    monitor: NWPathMonitor = NWPathMonitor(),
    monitorQueue: DispatchQueue = DispatchQueue(
      label: "com.oracle.NetworkMonitor", qos: .utility
    )
  ) {
    self.init(
      monitor: monitor,
      monitorQueue: monitorQueue,
      drainAction: { await uploadQueue.tryDrain() }
    )
  }

  // MARK: - Init (internal / test)

  /// Designated initialiser. Accepts an arbitrary drain action so tests can
  /// inject a counter without a real `UploadQueue`.
  ///
  /// - Parameters:
  ///   - monitor: `NWPathMonitor` instance (or a subclass for testing).
  ///   - monitorQueue: Queue on which path updates are delivered.
  ///   - drainAction: Async closure called when a reconnect edge is detected.
  init(
    monitor: NWPathMonitor = NWPathMonitor(),
    monitorQueue: DispatchQueue = DispatchQueue(
      label: "com.oracle.NetworkMonitor", qos: .utility
    ),
    drainAction: @escaping @Sendable () async -> Void
  ) {
    self.monitor = monitor
    self.monitorQueue = monitorQueue
    self.drainAction = drainAction
  }

  // MARK: - Lifecycle

  /// Start observing network-path changes.
  ///
  /// Idempotent: subsequent calls are a no-op. `NWPathMonitor.start(queue:)`
  /// does not ignore repeat calls — it changes the delivery queue, which would
  /// race on `wasReachable`/`isReachable`. The `isStarted` guard prevents that.
  func start() {
    guard !isStarted else { return }
    isStarted = true
    monitor.pathUpdateHandler = { [weak self] path in
      self?.pathDidUpdate(status: path.status)
    }
    monitor.start(queue: monitorQueue)
  }

  /// Stop observing. Primarily useful for unit tests that need to tear down
  /// the monitor between test cases.
  func stop() {
    monitor.cancel()
  }

  // MARK: - Internal test seam

  /// Process a path-status update.
  ///
  /// Exposed `internal` (not `private`) so unit tests can drive it directly
  /// with a synthesised `NWPath.Status` value, bypassing real network hardware.
  ///
  /// In production this is called only by `NWPathMonitor`'s `pathUpdateHandler`
  /// on `monitorQueue`. In tests it is called synchronously from the test body
  /// on whatever thread the test runs on; no concurrent access occurs there.
  ///
  /// - Parameter status: The path status reported by `NWPathMonitor`.
  func pathDidUpdate(status: NWPath.Status) {
    let nowReachable = (status == .satisfied)
    let wasAlreadyReachable = wasReachable

    // `wasReachable` stays on monitorQueue — it is only ever touched inside
    // this method, which NWPathMonitor calls serially on that queue.
    wasReachable = nowReachable

    // Hop to the main actor for the @Observable property that SwiftUI reads.
    // @Observable's unfair-lock registrar protects change-notification
    // bookkeeping, but does NOT protect the stored property from concurrent
    // mutation; an explicit main-actor write eliminates that race.
    Task { @MainActor [weak self] in
      self?.isReachable = nowReachable
    }

    // Rising-edge gate: only drain on unsatisfied → satisfied.
    guard nowReachable && !wasAlreadyReachable else { return }

    // Spawn a Task so we don't block NWPathMonitor's callback queue.
    Task { [drainAction] in
      await drainAction()
    }
  }
}
