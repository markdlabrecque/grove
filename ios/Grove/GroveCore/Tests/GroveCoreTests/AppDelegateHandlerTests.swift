import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

/// Unit tests for the AppDelegate background-completion-handler contract.
///
/// `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// (wired in PR 2) stores the system-supplied handler into `GroveAPI` keyed by
/// the session identifier, then `GroveAPI.drainBackgroundCompletionHandlers()`
/// calls it on the main thread.
///
/// These tests exercise that round-trip from the actor side — no `UIApplication`
/// required. They verify:
///   - A handler stored with `GroveAPI.backgroundSessionIdentifier` is called
///     after `drainBackgroundCompletionHandlers`.
///   - A handler stored for an unknown identifier is also drained (the drain is
///     not restricted to the canonical identifier; AppDelegate may receive
///     multiple background session identifiers if a second background session is
///     added in a future PR).
///   - Storing a second handler for the same identifier replaces the first
///     (idempotent store — the OS never delivers two concurrent handler calls
///     for the same identifier, but the contract should be well-defined).
///
/// Serialised to prevent concurrent mutations on the shared `api` instance.
@Suite("AppDelegate background handler contract", .serialized)
struct AppDelegateHandlerTests {

  private func makeAPI() -> GroveAPI {
    GroveAPI(
      baseURL: URL(string: "https://grove.example.ts.net")!,
      bearerToken: "test-token"
    )
  }

  // MARK: - Store + drain with canonical identifier

  @Test("Handler stored with backgroundSessionIdentifier is called on drain")
  func handlerCalledForCanonicalIdentifier() async throws {
    let api = makeAPI()

    final class Box: @unchecked Sendable { var called = false }
    let box = Box()

    await api.storeBackgroundCompletionHandler(
      { box.called = true },
      forIdentifier: GroveAPI.backgroundSessionIdentifier
    )

    #expect(await api.backgroundHandlerCount == 1)

    // Await drain completion via a sentinel continuation rather than a fixed
    // sleep. The sentinel handler is stored alongside the real handler and
    // resumes the continuation when the @MainActor Task inside drain dispatches
    // all handlers — deterministic and instant.
    // Wrapped in withBridgeTimeout so a broken drain fails fast rather than
    // hanging the CI runner for the full budget.
    try await withBridgeTimeout(seconds: 2) {
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        Task { @MainActor in
          await api.storeBackgroundCompletionHandler(
            { cont.resume() },
            forIdentifier: "com.markdlabrecque.grove.capture-upload-sentinel"
          )
          await api.drainBackgroundCompletionHandlers()
        }
      }
    }

    #expect(box.called)
    #expect(await api.backgroundHandlerCount == 0)
  }

  // MARK: - Store + drain with arbitrary identifier

  @Test("Handler stored for any identifier is drained")
  func handlerCalledForArbitraryIdentifier() async throws {
    let api = makeAPI()

    final class Box: @unchecked Sendable { var called = false }
    let box = Box()

    await api.storeBackgroundCompletionHandler(
      { box.called = true },
      forIdentifier: "com.example.some-other-session"
    )

    // Trigger the drain on the main actor, then poll until box.called flips.
    //
    // The previous sentinel-continuation pattern was racy: drain spawns a
    // single `Task { @MainActor in handlers.forEach { $0() } }` and the order
    // of items in Array(dict.values) is non-deterministic. When the sentinel
    // was called first inside forEach it resumed the continuation — but the
    // box.called = true handler had not yet executed in that same forEach
    // iteration, so the outer #expect(box.called) could observe false.
    //
    // Polling with Task.checkCancellation() inside withBridgeTimeout is the
    // same pattern used to fix a structurally identical race in #411.
    await api.drainBackgroundCompletionHandlers()

    try await withBridgeTimeout(seconds: 2) {
      while !box.called {
        try Task.checkCancellation()
        await Task.yield()
      }
    }

    #expect(box.called)
  }

  // MARK: - Second store for same identifier replaces first

  @Test("Storing a second handler for the same identifier replaces the first")
  func secondStoreReplacesFirst() async throws {
    let api = makeAPI()

    final class Counter: @unchecked Sendable { var count = 0 }
    let counter = Counter()

    await api.storeBackgroundCompletionHandler(
      { counter.count += 10 },
      forIdentifier: GroveAPI.backgroundSessionIdentifier
    )
    // Replace with a different handler before drain.
    await api.storeBackgroundCompletionHandler(
      { counter.count += 1 },
      forIdentifier: GroveAPI.backgroundSessionIdentifier
    )

    // Only one entry in the map (replaced, not appended).
    #expect(await api.backgroundHandlerCount == 1)

    try await withBridgeTimeout(seconds: 2) {
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        Task { @MainActor in
          await api.storeBackgroundCompletionHandler(
            { cont.resume() },
            forIdentifier: "com.markdlabrecque.grove.capture-upload-sentinel"
          )
          await api.drainBackgroundCompletionHandlers()
        }
      }
    }

    // Only the second handler should have run (count == 1, not 11).
    #expect(counter.count == 1)
  }

  // MARK: - Drain with no handlers is a no-op

  @Test("Draining with no stored handlers is a no-op")
  func drainWithNoHandlers() async {
    let api = makeAPI()
    // Should not crash or hang.
    await api.drainBackgroundCompletionHandlers()
    let count = await api.backgroundHandlerCount
    #expect(count == 0)
  }
}
