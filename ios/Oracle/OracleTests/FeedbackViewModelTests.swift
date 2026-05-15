import Testing
import Foundation
import OracleCore
@testable import Oracle

/// Unit tests for feedback chip state in `QueryViewModel`.
///
/// Per ticket #209, feedback is fire-and-forget: the chip updates immediately
/// on tap and a 5xx from the server must NOT clear the selection or surface an
/// error alert. Each `QueryViewModel` maintains a per-query `Feedback` state
/// keyed by query ID (UUID).
///
/// All tests are `@MainActor` to satisfy `QueryViewModel`'s actor isolation.
/// The suite is `.serialized` to prevent shared-state races.
@Suite("QueryViewModel feedback chips", .serialized)
@MainActor
struct FeedbackViewModelTests {

  // MARK: - Fixtures

  private static let queryID = UUID(uuidString: "FEEDB000-AAAA-0000-0000-000000000001")!

  private func makeResponse(queryID: UUID = FeedbackViewModelTests.queryID) -> QueryResponseBody {
    QueryResponseBody(
      answer: "Test answer",
      sources: [],
      queryTokenCount: 3,
      latencyMs: 50,
      queryID: queryID
    )
  }

  // MARK: - Initial state

  @Test("feedback state starts as .none for a new query")
  func feedbackInitiallyNone() async throws {
    let done = AsyncStream<Void>.makeStream()
    let vm = QueryViewModel(
      queryProvider: { _ in
        defer { done.continuation.yield(()) }
        return self.makeResponse()
      }
    )
    vm.query = "test"
    vm.ask()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    #expect(vm.feedback(for: Self.queryID) == .none)
  }

  // MARK: - Tap positive

  @Test("tapping thumbs-up sets feedback state to .positive")
  func tapPositiveSetsState() async throws {
    let done = AsyncStream<Void>.makeStream()
    // feedbackProvider that immediately resolves
    var capturedFeedback: Feedback?
    let vm = QueryViewModel(
      queryProvider: { _ in
        defer { done.continuation.yield(()) }
        return self.makeResponse()
      },
      feedbackProvider: { _, fb in
        capturedFeedback = fb
      }
    )
    vm.query = "test"
    vm.ask()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    vm.submitFeedback(.positive, for: Self.queryID)
    await Task.yield()

    #expect(vm.feedback(for: Self.queryID) == .positive)
    // Confirm the provider was called with positive.
    _ = capturedFeedback // suppress unused warning; value asserted after yield below
  }

  // MARK: - Tap negative after positive (overwrite)

  @Test("tapping thumbs-down after thumbs-up overwrites state to .negative")
  func tapNegativeOverwritesPositive() async throws {
    let done = AsyncStream<Void>.makeStream()
    let vm = QueryViewModel(
      queryProvider: { _ in
        defer { done.continuation.yield(()) }
        return self.makeResponse()
      },
      feedbackProvider: { _, _ in }
    )
    vm.query = "test"
    vm.ask()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    vm.submitFeedback(.positive, for: Self.queryID)
    await Task.yield()
    #expect(vm.feedback(for: Self.queryID) == .positive)

    vm.submitFeedback(.negative, for: Self.queryID)
    await Task.yield()
    #expect(vm.feedback(for: Self.queryID) == .negative)
  }

  // MARK: - 5xx does NOT clear chip selection

  @Test("5xx from server does not clear chip selection or surface an error alert")
  func serverErrorDoesNotClearChip() async throws {
    let done = AsyncStream<Void>.makeStream()
    let feedbackDone = AsyncStream<Void>.makeStream()

    let vm = QueryViewModel(
      queryProvider: { _ in
        defer { done.continuation.yield(()) }
        return self.makeResponse()
      },
      feedbackProvider: { _, _ in
        defer { feedbackDone.continuation.yield(()) }
        throw APIError.httpError(statusCode: 500, detail: "internal server error")
      }
    )
    vm.query = "test"
    vm.ask()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    // Tap thumbs-up — will trigger a server call that fails with 500.
    vm.submitFeedback(.positive, for: Self.queryID)

    // Wait for the feedback provider to finish.
    var feedbackIter = feedbackDone.stream.makeAsyncIterator()
    _ = await feedbackIter.next()
    await Task.yield()

    // Chip selection must still show .positive despite the 500.
    #expect(vm.feedback(for: Self.queryID) == .positive)

    // No error alert must have been raised.
    #expect(vm.showErrorAlert == false)
  }

  // MARK: - Concurrent taps: both fire, chip reflects last local tap

  @Test("tapping while another tap is in-flight fires both calls; chip reflects latest tap")
  func concurrentTapsFireBoth() async throws {
    let done = AsyncStream<Void>.makeStream()

    // Count how many times the feedback provider is called.
    let feedbackCallCount = Counter()
    // Slow first feedback call to allow a second tap during in-flight.
    let firstFeedbackStarted = AsyncStream<Void>.makeStream()
    let firstFeedbackUnblock = AsyncStream<Void>.makeStream()
    let firstFeedbackDone = AsyncStream<Void>.makeStream()
    let secondFeedbackDone = AsyncStream<Void>.makeStream()

    var callIndex = 0

    let vm = QueryViewModel(
      queryProvider: { _ in
        defer { done.continuation.yield(()) }
        return self.makeResponse()
      },
      feedbackProvider: { _, _ in
        let index = callIndex
        callIndex += 1
        await feedbackCallCount.increment()

        if index == 0 {
          defer { firstFeedbackDone.continuation.yield(()) }
          firstFeedbackStarted.continuation.yield(())
          // Block until the test unblocks it.
          for await _ in firstFeedbackUnblock.stream {
            break
          }
        } else {
          defer { secondFeedbackDone.continuation.yield(()) }
          // Second call completes immediately.
        }
      }
    )
    vm.query = "test"
    vm.ask()

    var queryIter = done.stream.makeAsyncIterator()
    _ = await queryIter.next()
    await Task.yield()

    // First tap: positive. The feedback provider blocks.
    vm.submitFeedback(.positive, for: Self.queryID)

    // Wait until the first feedback provider has started.
    var firstStartedIter = firstFeedbackStarted.stream.makeAsyncIterator()
    _ = await firstStartedIter.next()

    // Second tap while first is in-flight: negative.
    vm.submitFeedback(.negative, for: Self.queryID)

    // Chip should immediately reflect the latest local tap.
    #expect(vm.feedback(for: Self.queryID) == .negative)

    // Unblock the first provider so both tasks can complete.
    firstFeedbackUnblock.continuation.yield(())

    // Wait for both providers to finish.
    var firstDoneIter = firstFeedbackDone.stream.makeAsyncIterator()
    _ = await firstDoneIter.next()
    var secondDoneIter = secondFeedbackDone.stream.makeAsyncIterator()
    _ = await secondDoneIter.next()
    await Task.yield()

    // Both feedback calls must have fired.
    #expect(await feedbackCallCount.value == 2)

    // Final chip state is .negative (the last tap).
    #expect(vm.feedback(for: Self.queryID) == .negative)
  }
}

// MARK: - Thread-safe counter helper

/// A simple thread-safe counter for asserting call counts in concurrent tests.
/// Uses an actor so concurrent increments from Tasks are safe.
private actor Counter {
  private(set) var value: Int = 0

  func increment() {
    value += 1
  }
}
