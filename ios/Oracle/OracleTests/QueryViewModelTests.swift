import Testing
import Foundation
import OracleCore
@testable import Oracle

/// Unit tests for `QueryViewModel`'s in-flight cancel behaviour.
///
/// These tests inject a stub `queryProvider` closure so no live network is
/// needed. Because `QueryViewModel` is `@MainActor`, every test is also
/// `@MainActor` to satisfy the actor isolation requirement.
///
/// Serialised to avoid shared-state races between tests that rely on
/// continuation-based synchronisation.
@Suite("QueryViewModel cancel-in-flight", .serialized)
@MainActor
struct QueryViewModelTests {

  // MARK: - Fixtures

  private func makeResults() -> [QueryResult] {
    [
      QueryResult(
        memoryID: UUID(),
        score: 0.9,
        matchedVia: "whole",
        matchedChunkIndex: nil,
        excerpt: "Existing result",
        capturedAt: nil,
        sourceModality: "text"
      )
    ]
  }

  private func makeResponse(sources: [QueryResult] = []) -> QueryResponseBody {
    QueryResponseBody(sources: sources, queryTokenCount: 3, latencyMs: 100)
  }

  // MARK: - Cancel-in-flight: spinner clears, prior results survive

  /// Tapping Ask while a slow query is running should:
  ///   1. Cancel the first request (no error alert).
  ///   2. Clear the spinner (queryStatus → .idle) once cancelled.
  ///   3. Leave any prior `.results(...)` state intact.
  @Test("cancel() clears spinner and preserves prior results")
  func cancelClearSpinnerPreservesResults() async throws {
    // First: put the VM in a known .results state by running a fast query.
    let priorResults = makeResults()

    // Continuation signals when the fast provider's closure has returned,
    // replacing the 10 ms sleep-as-sync that was here before.
    let firstDone = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel { _ in
      defer { firstDone.continuation.yield(()) }
      return self.makeResponse(sources: priorResults)
    }
    vm.query = "first query"
    vm.ask()

    // Wait until the fast provider has returned, then yield once so
    // performQuery's remaining main-actor statements (queryStatus update) land.
    var firstDoneIter = firstDone.stream.makeAsyncIterator()
    _ = await firstDoneIter.next()
    await Task.yield()

    guard case .results(_, let r) = vm.queryStatus, !r.isEmpty else {
      Issue.record("Expected .results after first fast query, got \(vm.queryStatus)")
      return
    }

    // Now inject a slow provider and fire a second query.
    let slowStarted = AsyncStream<Void>.makeStream()
    let slowUnblock = AsyncStream<Void>.makeStream()
    // slowExited fires when the slow provider's closure exits (cancelled or
    // normally), replacing the 50 ms sleep-as-sync used to let the catch block
    // settle.
    let slowExited = AsyncStream<Void>.makeStream()

    vm.queryProvider = { _ in
      defer { slowExited.continuation.yield(()) }
      slowStarted.continuation.yield(())
      // Block until unblocked or cancelled.
      for await _ in slowUnblock.stream {
        break
      }
      try Task.checkCancellation()
      return self.makeResponse()
    }

    vm.query = "slow query"
    vm.ask()

    // Wait until the slow provider has started.
    var slowIter = slowStarted.stream.makeAsyncIterator()
    _ = await slowIter.next()

    // At this point the spinner should be showing.
    #expect(vm.isLoading == true)

    // Cancel the in-flight request explicitly.
    vm.cancel()

    // Wait until the slow provider's closure has exited (i.e. the
    // checkCancellation throw propagated out), then yield once so
    // performQuery's catch-block main-actor statements land.
    var slowExitedIter = slowExited.stream.makeAsyncIterator()
    _ = await slowExitedIter.next()
    await Task.yield()

    // Spinner must be gone.
    #expect(vm.isLoading == false)

    // No error alert must have fired.
    #expect(vm.showErrorAlert == false)

    // Prior results must still be visible.
    guard case .results(_, let surviving) = vm.queryStatus else {
      Issue.record("Expected .results after cancel, got \(vm.queryStatus)")
      return
    }
    #expect(surviving.count == priorResults.count)
  }

  // MARK: - Empty query while in-flight keeps Ask disabled

  @Test("empty query keeps isAskEnabled false even while loading")
  func emptyQueryDisabledWhileLoading() async {
    // Slow provider that never completes on its own.
    let started = AsyncStream<Void>.makeStream()
    let vm = QueryViewModel { _ in
      started.continuation.yield(())
      // Suspend indefinitely — test will cancel before it matters.
      try await Task.sleep(nanoseconds: 999_000_000_000)
      return self.makeResponse()
    }

    vm.query = "something"
    vm.ask()

    var iter = started.stream.makeAsyncIterator()
    _ = await iter.next()

    // Now clear the query field.
    vm.query = ""

    // With an empty field, Ask must be disabled even though a request is running.
    #expect(vm.isAskEnabled == false)

    // Clean up.
    vm.cancel()
  }

  // MARK: - Ask during in-flight cancels and restarts

  @Test("calling ask() while in-flight cancels the first request and starts a second")
  func askWhileInFlightCancelsFirst() async throws {
    var firstRequestCancelled = false

    let firstStarted = AsyncStream<Void>.makeStream()
    // firstExited fires when the first provider's closure exits (after the
    // catch block sets firstRequestCancelled = true), replacing the 50 ms
    // sleep-as-sync used to wait for cancellation to propagate.
    let firstExited = AsyncStream<Void>.makeStream()

    // First provider: records cancellation, blocks until cancelled.
    let firstProvider: (String) async throws -> QueryResponseBody = { _ in
      defer { firstExited.continuation.yield(()) }
      firstStarted.continuation.yield(())
      do {
        try await Task.sleep(nanoseconds: 999_000_000_000)
        return QueryResponseBody(sources: [], queryTokenCount: 0, latencyMs: 0)
      } catch {
        firstRequestCancelled = true
        throw error
      }
    }

    // Second provider: fast, returns a real result.
    let secondResults = [QueryResult(
      memoryID: UUID(),
      score: 0.8,
      matchedVia: "whole",
      matchedChunkIndex: nil,
      excerpt: "Second result",
      capturedAt: nil,
      sourceModality: "text"
    )]
    // secondDone fires when the second provider's closure has returned,
    // replacing the 100 ms sleep-as-sync used to wait for it to complete.
    let secondDone = AsyncStream<Void>.makeStream()
    let secondProvider: (String) async throws -> QueryResponseBody = { _ in
      defer { secondDone.continuation.yield(()) }
      return QueryResponseBody(sources: secondResults, queryTokenCount: 4, latencyMs: 50)
    }

    var callCount = 0
    let vm = QueryViewModel { text in
      callCount += 1
      if callCount == 1 {
        return try await firstProvider(text)
      } else {
        return try await secondProvider(text)
      }
    }

    // Fire first request.
    vm.query = "first"
    vm.ask()

    var iter = firstStarted.stream.makeAsyncIterator()
    _ = await iter.next()

    // Fire second request while first is in-flight — should cancel first.
    vm.query = "second"
    vm.ask()

    // Wait until the second provider has returned, then yield once so
    // performQuery's remaining main-actor statements (queryStatus update) land.
    var secondDoneIter = secondDone.stream.makeAsyncIterator()
    _ = await secondDoneIter.next()
    await Task.yield()

    // Second query should have produced results.
    guard case .results(_, let r) = vm.queryStatus else {
      Issue.record("Expected .results from second query, got \(vm.queryStatus)")
      return
    }
    #expect(r.count == secondResults.count)

    // No error alert should have fired.
    #expect(vm.showErrorAlert == false)

    // First request was cancelled. Wait until firstProvider's closure has
    // exited (defer fires after the catch sets firstRequestCancelled = true),
    // then yield once for any remaining main-actor work in the first task.
    var firstExitedIter = firstExited.stream.makeAsyncIterator()
    _ = await firstExitedIter.next()
    await Task.yield()
    #expect(firstRequestCancelled == true)
  }

  // MARK: - Real errors still fire alert

  @Test("real network failure surfaces error alert, not silent swallow")
  func realErrorFiresAlert() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel { _ in
      defer { continuation.yield(()) }
      throw APIError.httpError(statusCode: 500, detail: "internal server error")
    }

    vm.query = "anything"
    vm.ask()

    // Wait until the provider closure has returned, then yield once to let
    // performQuery finish its remaining main-actor statements.
    var iter = stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    #expect(vm.showErrorAlert == true)
    #expect(vm.errorMessage.contains("internal server error"))
    #expect(vm.isLoading == false)
  }

  // MARK: - activeTask regression (#100 / #112)

  /// After a successful query completes, `activeTask` must be `nil`.
  ///
  /// Regression lock for #100: `performQuery` was not clearing the handle on
  /// the success path, leaving a stale `Task` reference until the next call to
  /// `ask()` or `cancel()`.
  @Test("activeTask is nil after ask() completes successfully")
  func activeTaskIsNilAfterSuccess() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel { _ in
      defer { continuation.yield(()) }
      return self.makeResponse(sources: self.makeResults())
    }

    vm.query = "test query"
    vm.ask()

    // Wait until the provider closure has returned, then yield once to let
    // performQuery finish its remaining main-actor statements (activeTask = nil).
    var iter = stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    #expect(vm.activeTask == nil)
  }

  /// After a real (non-cancellation) error, `activeTask` must be `nil`.
  ///
  /// Regression lock for #100: the error path must also clear the handle so
  /// the next `ask()` call does not operate on a stale task reference.
  @Test("activeTask is nil after ask() completes with a real error")
  func activeTaskIsNilAfterError() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel { _ in
      defer { continuation.yield(()) }
      throw APIError.httpError(statusCode: 503, detail: "service unavailable")
    }

    vm.query = "test query"
    vm.ask()

    // Wait until the provider closure has returned, then yield once to let
    // performQuery finish its remaining main-actor statements (activeTask = nil).
    var iter = stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    #expect(vm.activeTask == nil)
  }

  // MARK: - removeSource dual-filter: cancel-and-restore must not resurface deleted sources

  /// Pins the dual-filter invariant in `removeSource(memoryID:)`.
  ///
  /// `removeSource` filters the deleted memory from **both** `queryStatus` and
  /// `lastResponse`. The `lastResponse` filter is the load-bearing half: when a
  /// subsequent query is cancelled, `performQuery` restores from `lastResponse`
  /// (snapshotted as `preFlight`). Without the `lastResponse` filter, a
  /// cancel-and-restore would silently undelete the memory.
  ///
  /// Verification: revert the `lastResponse` filter in `removeSource` and this
  /// test fails; restore it and the test passes.
  @Test("removeSource: deleted source does not reappear after cancel-and-restore")
  func removeSourceDoesNotReappearAfterCancelRestore() async throws {
    // --- Step 1: put the VM in .results with two sources. ---
    let memoryA = QueryResult(
      memoryID: UUID(),
      score: 0.95,
      matchedVia: "whole",
      matchedChunkIndex: nil,
      excerpt: "Memory A",
      capturedAt: nil,
      sourceModality: "text"
    )
    let memoryB = QueryResult(
      memoryID: UUID(),
      score: 0.80,
      matchedVia: "whole",
      matchedChunkIndex: nil,
      excerpt: "Memory B",
      capturedAt: nil,
      sourceModality: "text"
    )

    let firstDone = AsyncStream<Void>.makeStream()
    let vm = QueryViewModel { _ in
      defer { firstDone.continuation.yield(()) }
      return QueryResponseBody(
        sources: [memoryA, memoryB],
        queryTokenCount: 2,
        latencyMs: 10
      )
    }
    vm.query = "initial query"
    vm.ask()

    var firstDoneIter = firstDone.stream.makeAsyncIterator()
    _ = await firstDoneIter.next()
    await Task.yield()

    guard case .results(_, let initialSources) = vm.queryStatus,
          initialSources.count == 2 else {
      Issue.record("Expected .results with 2 sources, got \(vm.queryStatus)")
      return
    }

    // --- Step 2: delete memoryA — assert it is gone from queryStatus and lastResponse. ---
    vm.removeSource(memoryID: memoryA.memoryID)

    guard case .results(_, let afterDelete) = vm.queryStatus else {
      Issue.record("Expected .results after removeSource, got \(vm.queryStatus)")
      return
    }
    #expect(afterDelete.count == 1)
    #expect(!afterDelete.contains(where: { $0.memoryID == memoryA.memoryID }))
    #expect(afterDelete.contains(where: { $0.memoryID == memoryB.memoryID }))

    // --- Step 3 + 4: fire a slow query, then cancel it (triggers restore path). ---
    let slowStarted = AsyncStream<Void>.makeStream()
    let slowExited = AsyncStream<Void>.makeStream()

    vm.queryProvider = { _ in
      defer { slowExited.continuation.yield(()) }
      slowStarted.continuation.yield(())
      do {
        try await Task.sleep(nanoseconds: 999_000_000_000)
        return QueryResponseBody(sources: [], queryTokenCount: 0, latencyMs: 0)
      } catch {
        throw error
      }
    }

    vm.query = "slow query"
    vm.ask()

    var slowStartedIter = slowStarted.stream.makeAsyncIterator()
    _ = await slowStartedIter.next()

    // Spinner is showing; cancel triggers the restore path.
    #expect(vm.isLoading == true)
    vm.cancel()

    var slowExitedIter = slowExited.stream.makeAsyncIterator()
    _ = await slowExitedIter.next()
    await Task.yield()

    // --- Step 5: assert memoryA does NOT reappear in the restored queryStatus. ---
    guard case .results(_, let restored) = vm.queryStatus else {
      Issue.record("Expected .results after cancel-restore, got \(vm.queryStatus)")
      return
    }
    #expect(!restored.contains(where: { $0.memoryID == memoryA.memoryID }),
            "Deleted memoryA must not reappear after cancel-and-restore")
    #expect(restored.contains(where: { $0.memoryID == memoryB.memoryID }),
            "Non-deleted memoryB must survive cancel-and-restore")
  }

  /// After `cancel()` is called, `activeTask` must be `nil`.
  ///
  /// The existing cancel-in-flight suite verifies spinner/results state but
  /// does not directly assert the handle is cleared. This test locks that
  /// contract explicitly (regression companion to `activeTaskIsNilAfterSuccess`
  /// and `activeTaskIsNilAfterError`).
  @Test("activeTask is nil after cancel()")
  func activeTaskIsNilAfterCancel() async throws {
    let started = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel { _ in
      started.continuation.yield(())
      // Block until cancelled.
      try await Task.sleep(nanoseconds: 999_000_000_000)
      return self.makeResponse()
    }

    vm.query = "slow query"
    vm.ask()

    // Wait until the provider has started so we know activeTask is set.
    var iter = started.stream.makeAsyncIterator()
    _ = await iter.next()

    // activeTask must be non-nil while in flight.
    #expect(vm.activeTask != nil)

    // Cancel clears the handle synchronously.
    vm.cancel()
    #expect(vm.activeTask == nil)
  }
}
