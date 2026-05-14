import Testing
import Foundation
import OracleCore
@testable import Oracle

/// Unit tests for recent-queries chip strip state in `QueryViewModel`.
///
/// Per ticket #211, the ViewModel:
/// - Fetches recent queries on view appear via `refreshRecentQueries()`.
/// - Re-fetches after every successful new query submission.
/// - On chip tap, populates the input field AND triggers a fresh submit.
/// - A 5xx from `recentQueries` must NOT break the Ask flow — the strip shows
///   empty, the user can still submit new queries.
///
/// All tests are `@MainActor` to satisfy `QueryViewModel`'s actor isolation.
/// The suite is `.serialized` to prevent shared-state races.
@Suite("QueryViewModel recent queries", .serialized)
@MainActor
struct RecentQueriesViewModelTests {

  // MARK: - Fixtures

  private func makeRecentItems(count: Int = 3) -> [RecentQueryItem] {
    (1...count).map { i in
      RecentQueryItem(
        id: UUID(),
        queryText: "query \(i)",
        createdAt: Date().addingTimeInterval(Double(-i) * 60)
      )
    }
  }

  private func makeQueryResponse() -> QueryResponseBody {
    QueryResponseBody(sources: [], queryTokenCount: 1, latencyMs: 10)
  }

  // MARK: - On view appear: fetches recent queries

  @Test("refreshRecentQueries populates recentQueries on success")
  func refreshPopulatesRecentQueries() async throws {
    let items = makeRecentItems(count: 3)
    let done = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel(
      recentQueriesProvider: { _ in
        defer { done.continuation.yield(()) }
        return items
      }
    )

    vm.refreshRecentQueries()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    #expect(vm.recentQueries.count == 3)
    #expect(vm.recentQueries[0].queryText == "query 1")
  }

  // MARK: - Empty list

  @Test("refreshRecentQueries sets empty recentQueries when server returns empty")
  func refreshEmptyList() async throws {
    let done = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel(
      recentQueriesProvider: { _ in
        defer { done.continuation.yield(()) }
        return []
      }
    )

    vm.refreshRecentQueries()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    #expect(vm.recentQueries.isEmpty)
  }

  // MARK: - 5xx does NOT break the Ask flow

  @Test("5xx from recentQueries fetch does not break Ask flow and leaves strip empty")
  func recentQueries5xxDoesNotBreakAskFlow() async throws {
    let recentDone = AsyncStream<Void>.makeStream()
    let queryDone = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel(
      queryProvider: { _ in
        defer { queryDone.continuation.yield(()) }
        return self.makeQueryResponse()
      },
      recentQueriesProvider: { _ in
        defer { recentDone.continuation.yield(()) }
        throw APIError.httpError(statusCode: 500, detail: "server error")
      }
    )

    // Trigger the failing recent-queries fetch.
    vm.refreshRecentQueries()

    var recentIter = recentDone.stream.makeAsyncIterator()
    _ = await recentIter.next()
    await Task.yield()

    // Strip must be empty (not populated with stale or partial data).
    #expect(vm.recentQueries.isEmpty)

    // Ask flow must still work despite the failed recent-queries fetch.
    vm.query = "does this still work?"
    vm.ask()

    var queryIter = queryDone.stream.makeAsyncIterator()
    _ = await queryIter.next()
    await Task.yield()

    // No error alert from the failed recent-queries (only real Ask failures alert).
    // The Ask succeeded; status should be .results.
    guard case .results = vm.queryStatus else {
      Issue.record("Expected .results after Ask, got \(vm.queryStatus)")
      return
    }

    // No error alert must have been raised.
    #expect(vm.showErrorAlert == false)
  }

  // MARK: - Re-fetches after successful new query

  @Test("successful ask() triggers a re-fetch of recent queries")
  func askTriggersRecentQueriesRefresh() async throws {
    var recentCallCount = 0
    let recentDone = AsyncStream<Void>.makeStream()
    let queryDone = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel(
      queryProvider: { _ in
        defer { queryDone.continuation.yield(()) }
        return self.makeQueryResponse()
      },
      recentQueriesProvider: { _ in
        recentCallCount += 1
        // Signal on the second call (post-ask refresh).
        if recentCallCount == 2 {
          recentDone.continuation.yield(())
        }
        return self.makeRecentItems(count: 1)
      }
    )

    // Initial load.
    vm.refreshRecentQueries()

    // Fire a query.
    vm.query = "something new"
    vm.ask()

    // Wait for the query to complete.
    var queryIter = queryDone.stream.makeAsyncIterator()
    _ = await queryIter.next()
    await Task.yield()

    // Wait for the second recent-queries fetch (triggered by successful ask).
    var recentIter = recentDone.stream.makeAsyncIterator()
    _ = await recentIter.next()
    await Task.yield()

    // recentQueries provider must have been called at least twice.
    #expect(recentCallCount >= 2)
  }

  // MARK: - Chip tap populates input field

  @Test("tapping a chip populates the query input field with the chip text")
  func chipTapPopulatesInputField() async throws {
    let item = RecentQueryItem(
      id: UUID(),
      queryText: "what is the capital of France?",
      createdAt: Date()
    )

    let vm = QueryViewModel()
    vm.tapRecentQuery(item)

    #expect(vm.query == "what is the capital of France?")
  }

  // MARK: - Chip tap triggers a fresh submit

  @Test("tapping a chip triggers a fresh ask() with the chip text")
  func chipTapTriggersSubmit() async throws {
    var capturedQuery: String?
    let done = AsyncStream<Void>.makeStream()

    let item = RecentQueryItem(
      id: UUID(),
      queryText: "what did I say about Paris?",
      createdAt: Date()
    )

    let vm = QueryViewModel(
      queryProvider: { text in
        defer { done.continuation.yield(()) }
        capturedQuery = text
        return self.makeQueryResponse()
      }
    )

    vm.tapRecentQuery(item)

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    // The query field must reflect the chip text.
    #expect(vm.query == "what did I say about Paris?")

    // The provider must have been called with the chip text.
    #expect(capturedQuery == "what did I say about Paris?")

    // Results state must be .results (ask fired successfully).
    guard case .results = vm.queryStatus else {
      Issue.record("Expected .results after chip tap, got \(vm.queryStatus)")
      return
    }
  }

  // MARK: - Regression: removeSource cancel-restore still works after chip strip changes

  /// Pins the dual-filter invariant that was introduced in #207.
  /// This test ensures that adding recent-queries state did not accidentally
  /// alter `removeSource` behaviour or the cancel-and-restore path.
  @Test("removeSource: deleted source does not reappear after cancel-and-restore (regression)")
  func removeSourceRegressionAfterChipStrip() async throws {
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
    let vm = QueryViewModel(
      queryProvider: { _ in
        defer { firstDone.continuation.yield(()) }
        return QueryResponseBody(sources: [memoryA, memoryB], queryTokenCount: 2, latencyMs: 10)
      },
      recentQueriesProvider: { _ in [] }
    )

    vm.query = "initial query"
    vm.ask()

    var firstDoneIter = firstDone.stream.makeAsyncIterator()
    _ = await firstDoneIter.next()
    await Task.yield()

    guard case .results(_, let initial, _) = vm.queryStatus, initial.count == 2 else {
      Issue.record("Expected .results with 2 sources, got \(vm.queryStatus)")
      return
    }

    vm.removeSource(memoryID: memoryA.memoryID)

    guard case .results(_, let afterDelete, _) = vm.queryStatus else {
      Issue.record("Expected .results after removeSource, got \(vm.queryStatus)")
      return
    }
    #expect(afterDelete.count == 1)
    #expect(!afterDelete.contains(where: { $0.memoryID == memoryA.memoryID }))

    // Fire a slow query, then cancel it — triggers the restore path.
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
    #expect(vm.isLoading == true)

    vm.cancel()

    var slowExitedIter = slowExited.stream.makeAsyncIterator()
    _ = await slowExitedIter.next()
    await Task.yield()

    guard case .results(_, let restored, _) = vm.queryStatus else {
      Issue.record("Expected .results after cancel-restore, got \(vm.queryStatus)")
      return
    }
    #expect(!restored.contains(where: { $0.memoryID == memoryA.memoryID }),
            "Deleted memoryA must not reappear after cancel-and-restore")
    #expect(restored.contains(where: { $0.memoryID == memoryB.memoryID }),
            "Non-deleted memoryB must survive cancel-and-restore")
  }
}
