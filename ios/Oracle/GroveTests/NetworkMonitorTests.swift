import Testing
import Network
import Foundation
import Observation
@testable import Grove

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
/// `pathDidUpdate(status:)` spawns a `Task { @MainActor in … }` to write
/// `isReachable` and a `Task { await drainAction() }` on a rising edge.
///
/// Drain-count tests use `DrainCounter.waitForCount(_:)`, which suspends on a
/// `CheckedContinuation` until the counter reaches the expected value. This
/// avoids fixed sleeps — the test resumes as soon as the drain task fires.
///
/// `isReachable`-value tests use `waitForIsReachable(_:on:)`, which registers
/// a `withObservationTracking` onChange handler and resumes a continuation once
/// the property reaches the target value. Both helpers are sleep-free.
///
/// # Serialisation
///
/// `.serialized` prevents Swift Testing from running tests concurrently. Each
/// test constructs its own `NetworkMonitor` and `DrainCounter`, so this is
/// belt-and-suspenders — but it keeps test output deterministic.
@Suite("NetworkMonitor", .serialized)
struct NetworkMonitorTests {

  // MARK: - Helpers

  /// Build a `NetworkMonitor` whose drain action increments `counter`.
  ///
  /// We pass the default `NWPathMonitor()` but never call `monitor.start()`,
  /// so no OS networking is involved. Tests drive the monitor exclusively via
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

    // Wait (without sleeping) until the spawned drain Task has incremented.
    await counter.waitForCount(1)

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

    // Wait for the single drain that should have fired.
    await counter.waitForCount(1)

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

    // Wait for the one expected drain from the connect event.
    await counter.waitForCount(1)

    // The falling edge (connected → disconnected) must not trigger a drain.
    #expect(await counter.count == 1)
  }

  // MARK: - isReachableReflectsLastPath

  @Test("isReachable reflects the most recent path status")
  func isReachableReflectsLastPath() async {
    let counter = DrainCounter()
    let monitor = makeMonitor(counter: counter)

    // isReachable is now written on the main actor via Task { @MainActor in … },
    // so each assertion must await the main-actor hop before reading the value.

    monitor.pathDidUpdate(status: .unsatisfied)
    await waitForIsReachable(false, on: monitor)
    #expect(await MainActor.run { monitor.isReachable } == false)

    monitor.pathDidUpdate(status: .satisfied)
    await waitForIsReachable(true, on: monitor)
    #expect(await MainActor.run { monitor.isReachable } == true)

    monitor.pathDidUpdate(status: .unsatisfied)
    await waitForIsReachable(false, on: monitor)
    #expect(await MainActor.run { monitor.isReachable } == false)
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

    await counter.waitForCount(2)

    #expect(await counter.count == 2)
  }
}

// MARK: - Helpers

/// Wait (without sleeping) until `monitor.isReachable` equals `expected`.
///
/// Uses `withObservationTracking` to register for change notifications on the
/// `@Observable` property. Because `isReachable` is always written on the main
/// actor, the `onChange` callback fires on the main actor too.
///
/// If the property already equals `expected` at the time of the call, the
/// continuation resumes immediately without registering any observation.
@MainActor
private func waitForIsReachable(_ expected: Bool, on monitor: NetworkMonitor) async {
  // Fast path: already at the desired value.
  if monitor.isReachable == expected { return }

  await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    // Use a class box so we can mutate `resumed` from the escaping closure.
    let box = ResumeOnce(continuation)
    func observe() {
      withObservationTracking {
        _ = monitor.isReachable
      } onChange: {
        // onChange fires after the mutation is committed.
        // Re-dispatch to MainActor because onChange may be called on any thread.
        Task { @MainActor in
          if monitor.isReachable == expected {
            box.resume()
          } else {
            observe() // re-register for the next change
          }
        }
      }
    }
    observe()
  }
}

/// One-shot wrapper that ensures a `CheckedContinuation` is resumed at most once,
/// guarding against the edge case where two rapid mutations both fire `onChange`.
private final class ResumeOnce: @unchecked Sendable {
  private var continuation: CheckedContinuation<Void, Never>?
  private let lock = NSLock()

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func resume() {
    lock.lock()
    defer { lock.unlock() }
    continuation?.resume()
    continuation = nil
  }
}

// MARK: - DrainCounter

/// Thread-safe drain call counter. An actor so it can be captured by the
/// `@Sendable` drain-action closures spawned inside `NetworkMonitor`.
actor DrainCounter {
  private(set) var count: Int = 0

  /// Pending continuations waiting for `count` to reach a specific target.
  private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func increment() {
    count += 1
    // Resume any waiters whose target has been reached.
    waiters.removeAll { waiter in
      if count >= waiter.target {
        waiter.continuation.resume()
        return true
      }
      return false
    }
  }

  /// Suspend until `count` reaches `target`.
  ///
  /// Returns immediately if the count is already at or above `target`.
  /// No sleep — resumes via `CheckedContinuation` as soon as `increment()`
  /// hits the threshold.
  func waitForCount(_ target: Int) async {
    if count >= target { return }
    await withCheckedContinuation { continuation in
      waiters.append((target: target, continuation: continuation))
    }
  }
}
