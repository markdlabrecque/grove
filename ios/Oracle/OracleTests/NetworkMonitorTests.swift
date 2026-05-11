import Testing
import Network
import Foundation
@testable import Oracle

// MARK: - NetworkMonitorTests

/// Unit tests for `NetworkMonitor`.
///
/// # Test seam design
///
/// `NWPathMonitor` wraps OS networking hardware and cannot be reliably faked
/// in a unit test. The seam is `NetworkMonitor.pathDidUpdate(status:)`, which
/// is `internal` and accepts an `NWPath.Status` directly.
///
/// Tests call `monitor.pathDidUpdate(status: .satisfied)` (or `.unsatisfied`)
/// to simulate transitions without touching the real `NWPathMonitor`.
///
/// `NetworkMonitor` has a designated `init(monitor:monitorQueue:drainAction:)`
/// that accepts an arbitrary async drain closure. Tests inject a `DrainCounter`
/// actor as the drain action, giving precise call-count assertions without
/// a real `UploadQueue` or `SwiftData` container.
///
/// # Concurrency notes
///
/// `pathDidUpdate(status:)` spawns a `Task { await drainAction() }` on a
/// rising edge. Tests await a short sleep after the transition to let that Task
/// run. 100 ms is sufficient because the drain action in tests is a single
/// actor-increment with no I/O.
///
/// # Serialisation
///
/// `.serialized` matches the pattern used in `UploadQueueTests` and prevents
/// the Swift Testing framework from running tests concurrently. Each test
/// constructs its own `NetworkMonitor` and `DrainCounter`, so serialisation is
/// belt-and-suspenders here — but it keeps the test output deterministic.
@Suite("NetworkMonitor", .serialized)
struct NetworkMonitorTests {

  // MARK: - Helpers

  /// Build a `NetworkMonitor` whose drain action increments `counter`.
  ///
  /// We pass `NWPathMonitor()` but never call `monitor.start()`, so no OS
  /// networking is involved. Tests drive the monitor exclusively via
  /// `pathDidUpdate(status:)`.
  private func makeMonitor(counter: DrainCounter) -> NetworkMonitor {
    NetworkMonitor(drainAction: { await counter.increment() })
  }

  // MARK: - monitorIsConstructable

  @Test("NetworkMonitor can be constructed without crashing")
  func monitorIsConstructable() {
    let counter = DrainCounter()
    let monitor = makeMonitor(counter: counter)
    // stop() on an unstarted monitor must not crash.
    monitor.stop()
  }

  // MARK: - reconnectTriggersDrain

  @Test("pathDidUpdate: unsatisfied → satisfied triggers exactly one drain")
  func reconnectTriggersDrain() async throws {
    let counter = DrainCounter()
    let monitor = makeMonitor(counter: counter)

    // Simulate: starts offline, then reconnects.
    monitor.pathDidUpdate(status: .unsatisfied)
    monitor.pathDidUpdate(status: .satisfied)

    // Allow the spawned Task to execute.
    try await Task.sleep(for: .milliseconds(100))

    #expect(await counter.count == 1)
  }

  // MARK: - stayingConnectedDoesNotRedrain

  @Test("pathDidUpdate: two .satisfied updates trigger drain only once")
  func stayingConnectedDoesNotRedrain() async throws {
    let counter = DrainCounter()
    let monitor = makeMonitor(counter: counter)

    // First transition: wasReachable=false → nowReachable=true. Rising edge.
    monitor.pathDidUpdate(status: .satisfied)
    // Second transition: wasReachable=true → nowReachable=true. No edge.
    monitor.pathDidUpdate(status: .satisfied)

    try await Task.sleep(for: .milliseconds(100))

    // Only one drain should have fired.
    #expect(await counter.count == 1)
  }

  // MARK: - losingConnectionDoesNotDrain

  @Test("pathDidUpdate: .satisfied → .unsatisfied does not trigger drain")
  func losingConnectionDoesNotDrain() async throws {
    let counter = DrainCounter()
    let monitor = makeMonitor(counter: counter)

    // Connect (drain fires: 1) then disconnect (should not fire again).
    monitor.pathDidUpdate(status: .satisfied)
    monitor.pathDidUpdate(status: .unsatisfied)

    try await Task.sleep(for: .milliseconds(100))

    // The falling edge (connected → disconnected) must not trigger a drain.
    #expect(await counter.count == 1)
  }

  // MARK: - isReachableReflectsLastPath

  @Test("isReachable reflects the most recent path status")
  func isReachableReflectsLastPath() {
    let counter = DrainCounter()
    let monitor = makeMonitor(counter: counter)

    monitor.pathDidUpdate(status: .unsatisfied)
    #expect(monitor.isReachable == false)

    monitor.pathDidUpdate(status: .satisfied)
    #expect(monitor.isReachable == true)

    monitor.pathDidUpdate(status: .unsatisfied)
    #expect(monitor.isReachable == false)
  }

  // MARK: - multipleReconnectsCycleDrain

  @Test("pathDidUpdate: alternating satisfied/unsatisfied drains on each reconnect")
  func multipleReconnectsCycleDrain() async throws {
    let counter = DrainCounter()
    let monitor = makeMonitor(counter: counter)

    // Cycle 1: reconnect
    monitor.pathDidUpdate(status: .satisfied)   // edge: drain #1
    // Go offline
    monitor.pathDidUpdate(status: .unsatisfied) // no drain
    // Cycle 2: reconnect again
    monitor.pathDidUpdate(status: .satisfied)   // edge: drain #2
    // Go offline again
    monitor.pathDidUpdate(status: .unsatisfied) // no drain

    try await Task.sleep(for: .milliseconds(100))

    #expect(await counter.count == 2)
  }
}

// MARK: - DrainCounter

/// Thread-safe drain call counter. An actor so it can be captured by the
/// `@Sendable` drain-action closures spawned inside `NetworkMonitor`.
actor DrainCounter {
  private(set) var count: Int = 0

  func increment() {
    count += 1
  }
}
