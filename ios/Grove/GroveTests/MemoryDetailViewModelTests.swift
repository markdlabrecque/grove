import Testing
import Foundation
import GroveCore
@testable import Grove

/// Unit tests for `MemoryDetailViewModel`'s delete state machine and content loading.
///
/// The delete flow: idle → confirming → deleting → (success/dismiss | failure).
/// Tests inject a stub `deleteProvider` closure so no live network is needed.
/// All tests are `@MainActor` because `MemoryDetailViewModel` is `@Observable @MainActor`.
/// Serialised to avoid races on shared state.
@Suite("MemoryDetailViewModel delete state machine", .serialized)
@MainActor
struct MemoryDetailViewModelTests {

  // MARK: - Fixtures

  private static let memoryID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!

  // MARK: - Init shape

  @Test("MemoryDetailViewModel init accepts a bare memoryID UUID, not a QueryResult")
  func initTakesMemoryIDNotQueryResult() {
    // This test pins the new init signature. It will fail until
    // MemoryDetailViewModel(memoryID:...) is added.
    let id = Self.memoryID
    let vm = MemoryDetailViewModel(memoryID: id, deleteProvider: { _ in })
    #expect(vm.memoryID == id)
  }

  // MARK: - State: initial state is idle

  @Test("initial state is idle — not confirming, not deleting, no error")
  func initialStateIsIdle() {
    let vm = MemoryDetailViewModel(
      memoryID: Self.memoryID,
      deleteProvider: { _ in }
    )
    #expect(vm.isShowingDeleteConfirmation == false)
    #expect(vm.isDeleting == false)
    #expect(vm.deleteError == nil)
    #expect(vm.isDismissed == false)
  }

  // MARK: - State: requestDelete → confirming

  @Test("requestDelete() sets isShowingDeleteConfirmation to true")
  func requestDeleteSetsConfirming() {
    let vm = MemoryDetailViewModel(
      memoryID: Self.memoryID,
      deleteProvider: { _ in }
    )
    vm.requestDelete()
    #expect(vm.isShowingDeleteConfirmation == true)
  }

  // MARK: - State: cancel from confirming stays idle

  @Test("cancelDelete() resets isShowingDeleteConfirmation to false")
  func cancelDeleteResetsConfirming() {
    let vm = MemoryDetailViewModel(
      memoryID: Self.memoryID,
      deleteProvider: { _ in }
    )
    vm.requestDelete()
    vm.cancelDelete()
    #expect(vm.isShowingDeleteConfirmation == false)
    #expect(vm.isDeleting == false)
    #expect(vm.deleteError == nil)
    #expect(vm.isDismissed == false)
  }

  // MARK: - Happy path: confirming → success → dismissed

  @Test("confirmDelete() on success sets isDismissed and calls onDeleteSuccess with the memoryID")
  func confirmDeleteSuccessDismisses() async throws {
    let deleted = AsyncStream<UUID>.makeStream()

    var capturedDeletedID: UUID?
    let vm = MemoryDetailViewModel(
      memoryID: Self.memoryID,
      deleteProvider: { _ in
        // Successful no-op delete.
      },
      onDeleteSuccess: { id in
        capturedDeletedID = id
        deleted.continuation.yield(id)
      }
    )

    vm.requestDelete()
    await vm.confirmDelete()

    // Wait for onDeleteSuccess callback.
    var iter = deleted.stream.makeAsyncIterator()
    let receivedID = await iter.next()

    #expect(receivedID == Self.memoryID)
    #expect(capturedDeletedID == Self.memoryID)
    #expect(vm.isDismissed == true)
    #expect(vm.isDeleting == false)
    #expect(vm.deleteError == nil)
  }

  // MARK: - 404 path: server says memory is gone — treat as success

  @Test("confirmDelete() on 404 treats as success and dismisses")
  func confirmDelete404TreatsAsSuccess() async throws {
    let done = AsyncStream<Void>.makeStream()

    let vm = MemoryDetailViewModel(
      memoryID: Self.memoryID,
      deleteProvider: { _ in
        throw APIError.httpError(statusCode: 404, detail: "memory not found")
      },
      onDeleteSuccess: { _ in
        done.continuation.yield(())
      }
    )

    vm.requestDelete()
    await vm.confirmDelete()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()

    #expect(vm.isDismissed == true)
    #expect(vm.deleteError == nil)
  }

  // MARK: - 5xx path: real server error surfaces to user

  @Test("confirmDelete() on 5xx sets deleteError and does not dismiss")
  func confirmDelete5xxSetsError() async throws {
    let done = AsyncStream<Void>.makeStream()

    let vm = MemoryDetailViewModel(
      memoryID: Self.memoryID,
      deleteProvider: { _ in
        defer { done.continuation.yield(()) }
        throw APIError.httpError(statusCode: 500, detail: "internal server error")
      }
    )

    vm.requestDelete()
    await vm.confirmDelete()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()
    // Yield once so any remaining main-actor assignments land.
    await Task.yield()

    #expect(vm.isDismissed == false)
    #expect(vm.deleteError != nil)
    let errMsg = try #require(vm.deleteError)
    #expect(errMsg.contains("internal server error") || errMsg.contains("500"))
  }

  // MARK: - Generic non-API error path

  @Test("confirmDelete() on generic error surfaces deleteError and does not dismiss")
  func confirmDeleteGenericErrorSetsError() async throws {
    struct TestError: Error, LocalizedError {
      var errorDescription: String? { "network unavailable" }
    }

    let done = AsyncStream<Void>.makeStream()

    let vm = MemoryDetailViewModel(
      memoryID: Self.memoryID,
      deleteProvider: { _ in
        defer { done.continuation.yield(()) }
        throw TestError()
      }
    )

    vm.requestDelete()
    await vm.confirmDelete()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()
    await Task.yield()

    #expect(vm.isDismissed == false)
    #expect(vm.deleteError != nil)
  }

  // MARK: - loadContent: always fetches on appear

  @Test("loadContent() always calls fetchProvider on appear, regardless of any prior state")
  func loadContentAlwaysFetchesOnAppear() async throws {
    var fetchCallCount = 0
    let expectedContent = "Remember to call Theo about the upcoming demo."
    let vm = MemoryDetailViewModel(
      memoryID: Self.memoryID,
      fetchProvider: { _ in
        fetchCallCount += 1
        return MemoryDetailDTO(
          id: Self.memoryID,
          content: expectedContent,
          capturedAt: Date(timeIntervalSince1970: 1_778_423_400),
          sourceModality: "text"
        )
      }
    )

    // First call — must always fetch.
    await vm.loadContent()
    #expect(fetchCallCount == 1, "fetchProvider must be called on first loadContent()")
    #expect(vm.fetchedContent == expectedContent)
    #expect(vm.capturedAt == Date(timeIntervalSince1970: 1_778_423_400))
    #expect(vm.sourceModality == "text")
    #expect(vm.isFetchingContent == false)
    #expect(vm.fetchError == nil)

    // Second call — must still fetch (no excerpt-guard no-op).
    await vm.loadContent()
    #expect(fetchCallCount == 2, "fetchProvider must be called again on second loadContent()")
  }

  // MARK: - loadContent: surfaces error when fetch fails

  @Test("loadContent() sets fetchError and does not populate fetchedContent when fetch throws")
  func loadContentSurfacesFetchError() async throws {
    struct FetchFailure: Error, LocalizedError {
      var errorDescription: String? { "server unavailable" }
    }

    let vm = MemoryDetailViewModel(
      memoryID: Self.memoryID,
      fetchProvider: { _ in throw FetchFailure() }
    )

    await vm.loadContent()

    #expect(vm.fetchedContent == nil)
    #expect(vm.isFetchingContent == false)
    #expect(vm.fetchError != nil)
  }

  // MARK: - Ask results regression: deleted source no longer appears

  /// Regression test: after a successful delete, the caller's `onDeleteSuccess`
  /// callback receives the correct `memoryID`. This verifies the contract that
  /// `QueryViewModel` (or the parent view) uses to remove the source from its list.
  @Test("onDeleteSuccess callback receives correct memoryID for caller to filter")
  func onDeleteSuccessDeliversMemoryIDForFiltering() async throws {
    let targetID = UUID()
    let otherID = UUID()
    var sources = [
      QueryResult(
        memoryID: targetID,
        score: 0.9,
        matchedVia: "whole",
        matchedChunkIndex: nil,
        excerpt: "To be deleted",
        capturedAt: nil,
        sourceModality: "text"
      ),
      QueryResult(
        memoryID: otherID,
        score: 0.8,
        matchedVia: "whole",
        matchedChunkIndex: nil,
        excerpt: "Should survive",
        capturedAt: nil,
        sourceModality: "text"
      ),
    ]

    let done = AsyncStream<Void>.makeStream()
    var deletedID: UUID?

    let vm = MemoryDetailViewModel(
      memoryID: targetID,
      deleteProvider: { _ in },
      onDeleteSuccess: { id in
        deletedID = id
        // Simulate what QueryViewModel does on receiving this callback:
        sources.removeAll { $0.memoryID == id }
        done.continuation.yield(())
      }
    )

    vm.requestDelete()
    await vm.confirmDelete()

    var iter = done.stream.makeAsyncIterator()
    _ = await iter.next()

    // The deleted source must no longer appear in the list.
    #expect(sources.count == 1)
    #expect(sources.first?.memoryID == otherID)
    #expect(deletedID == targetID)
  }
}
