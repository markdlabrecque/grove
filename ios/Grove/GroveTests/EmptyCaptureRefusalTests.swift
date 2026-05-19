import Testing
import Foundation
import SwiftData
import GroveCore
@testable import Grove

// MARK: - EmptyCaptureRefusalTests
//
// Verifies the global "empty captures are never enqueued" rule across all
// save entry points. Ticket #396.
//
// Three paths are exercised:
//   1. Typed save — CaptureViewModel.save() with empty/whitespace content.
//   2. Dictation save — DictationCaptureViewModel.save() with empty/whitespace transcript.
//   3. AppIntent path — CaptureViaDictationIntent only opens the sheet; the
//      actual persist goes through DictationCaptureViewModel.save(), so the
//      dictation path tests fully cover this surface. A structural test below
//      documents the call chain so regressions are caught at code-review time.
//
// CI coverage: CaptureGuard pure-logic tests (validate / trimmedContent) live in
// GroveCoreTests and run under `make ios-test-core` (SPM / CI). The tests here
// remain the VM integration regression net — they exercise isSaveEnabled and the
// full save() path including SwiftData enqueue, which requires @testable import Grove.

// MARK: - Shared fixture

@MainActor
private func makeDictationQueue() throws -> UploadQueue {
  let schema = Schema([QueuedCapture.self])
  let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
  let container = try ModelContainer(for: schema, configurations: [config])
  let api = GroveAPI(
    baseURL: URL(string: "https://grove.test.example")!,
    bearerToken: "test-token"
  )
  return UploadQueue(modelContainer: container, api: api)
}

// MARK: - Path 1: Typed save (CaptureViewModel)
//
// This path is also covered by the `emptyContentIsNoop` test in
// StubNetworkTests.swift. These tests add whitespace-only variants and
// document the isSaveEnabled computed property contract.

@Suite("EmptyCapture — Typed save path (CaptureViewModel)")
@MainActor
struct EmptyCaptureTypedSaveTests {

  @Test("isSaveEnabled is false when content is empty")
  func isSaveEnabledFalseWhenEmpty() {
    let vm = CaptureViewModel(uploadQueue: try! makeDictationQueue())
    vm.content = ""
    #expect(vm.isSaveEnabled == false, "Save must be disabled when content is empty")
  }

  @Test("isSaveEnabled is false when content is whitespace-only")
  func isSaveEnabledFalseWhenWhitespace() {
    let vm = CaptureViewModel(uploadQueue: try! makeDictationQueue())
    vm.content = "   \n\t  "
    #expect(vm.isSaveEnabled == false, "Save must be disabled when content is whitespace-only")
  }

  @Test("isSaveEnabled is true when content has at least one non-whitespace character")
  func isSaveEnabledTrueWithContent() {
    let vm = CaptureViewModel(uploadQueue: try! makeDictationQueue())
    vm.content = " x "
    #expect(vm.isSaveEnabled == true, "Save must be enabled when content has a non-whitespace character")
  }

  @Test("save() with empty content does not call enqueue")
  func saveEmptyDoesNotEnqueue() async throws {
    let queue = try makeDictationQueue()
    let vm = CaptureViewModel(uploadQueue: queue)
    vm.content = ""
    await vm.save()
    let count = try await queue.pendingCount()
    #expect(count == 0, "Empty content must not enqueue a QueuedCapture row")
  }

  @Test("save() with whitespace-only content does not call enqueue")
  func saveWhitespaceDoesNotEnqueue() async throws {
    let queue = try makeDictationQueue()
    let vm = CaptureViewModel(uploadQueue: queue)
    vm.content = "   \n\t  "
    await vm.save()
    let count = try await queue.pendingCount()
    #expect(count == 0, "Whitespace-only content must not enqueue a QueuedCapture row")
  }
}

// MARK: - Path 2: Dictation save (DictationCaptureViewModel)

@Suite("EmptyCapture — Dictation save path (DictationCaptureViewModel)")
@MainActor
struct EmptyCaptureDictationSaveTests {

  private func makeViewModel() throws -> (DictationCaptureViewModel, UploadQueue) {
    let queue = try makeDictationQueue()
    let mock = MockSpeechRecognizer()
    mock.isAvailable = false
    let controller = DictationController(recognizer: mock)
    let vm = DictationCaptureViewModel(controller: controller, uploadQueue: queue)
    return (vm, queue)
  }

  // MARK: isSaveEnabled

  @Test("isSaveEnabled is false when transcript is empty")
  func isSaveEnabledFalseWhenTranscriptEmpty() throws {
    let (vm, _) = try makeViewModel()
    vm.transcript = ""
    vm.recordingState = .stopped
    #expect(vm.isSaveEnabled == false, "Save must be disabled when transcript is empty")
  }

  @Test("isSaveEnabled is false when transcript is whitespace-only")
  func isSaveEnabledFalseWhenTranscriptWhitespace() throws {
    let (vm, _) = try makeViewModel()
    vm.transcript = "   \n\t  "
    vm.recordingState = .stopped
    #expect(vm.isSaveEnabled == false, "Save must be disabled when transcript is whitespace-only")
  }

  @Test("isSaveEnabled is false when recording (even with non-empty transcript)")
  func isSaveEnabledFalseWhileRecording() throws {
    let (vm, _) = try makeViewModel()
    vm.transcript = "Partial live text"
    vm.recordingState = .recording
    #expect(vm.isSaveEnabled == false, "Save must be disabled while recording is still active")
  }

  @Test("isSaveEnabled is true when transcript has content and state is stopped")
  func isSaveEnabledTrueWithContent() throws {
    let (vm, _) = try makeViewModel()
    vm.transcript = " x "
    vm.recordingState = .stopped
    #expect(vm.isSaveEnabled == true, "Save must be enabled when transcript has a non-whitespace character and recording is stopped")
  }

  // MARK: save() guard

  @Test("save() with empty transcript does not call enqueue")
  func saveEmptyTranscriptDoesNotEnqueue() async throws {
    let (vm, queue) = try makeViewModel()
    vm.transcript = ""
    vm.recordingState = .stopped
    await vm.save()
    let count = try await queue.pendingCount()
    #expect(count == 0, "Empty transcript must not enqueue a QueuedCapture row")
  }

  @Test("save() with whitespace-only transcript does not call enqueue")
  func saveWhitespaceTranscriptDoesNotEnqueue() async throws {
    let (vm, queue) = try makeViewModel()
    vm.transcript = "   \n\t  "
    vm.recordingState = .stopped
    await vm.save()
    let count = try await queue.pendingCount()
    #expect(count == 0, "Whitespace-only transcript must not enqueue a QueuedCapture row")
  }

  @Test("save() with no-speech silence-timeout result (empty transcript) does not enqueue")
  func saveAfterSilenceTimeoutNoSpeechDoesNotEnqueue() async throws {
    // Simulates the post-#387 silence-timeout case where the user pressed the
    // Action Button but did not speak. The transcript is empty and the recording
    // state has advanced to .stopped (timeout teardown). Any attempt to save at
    // this point must be a no-op.
    let (vm, queue) = try makeViewModel()
    vm.transcript = ""  // No speech was detected.
    vm.recordingState = .stopped
    await vm.save()
    let count = try await queue.pendingCount()
    #expect(count == 0, "Silence-timeout with no speech must not enqueue a QueuedCapture row")
  }
}

// MARK: - Path 3: AppIntent / Action Button
//
// `CaptureViaDictationIntent.perform()` does not save anything itself — it only
// posts a notification that causes `RootView` to open `DictationCaptureView`,
// which drives `DictationCaptureViewModel`. The actual persist call therefore
// goes through `DictationCaptureViewModel.save()`, which is fully covered by the
// dictation-path tests above.
//
// The structural test below pins the absence of a direct `enqueue` call in the
// intent, so a future refactor that pulls the save into the intent will require
// updating this file and the PR will surface the change.

@Suite("EmptyCapture — AppIntent path (CaptureViaDictationIntent)")
struct EmptyCaptureAppIntentTests {

  @Test("CaptureViaDictationIntent.perform() posts a notification; it does not call enqueue directly")
  func intentPostsNotificationOnly() async throws {
    // Arrange: observe the openDictationCapture notification.
    let notificationReceived = LockIsolated(false)
    let token = NotificationCenter.default.addObserver(
      forName: .openDictationCapture,
      object: nil,
      queue: .main
    ) { _ in
      notificationReceived.withLock { $0 = true }
    }
    defer { NotificationCenter.default.removeObserver(token) }

    // Act: run the intent.
    let intent = CaptureViaDictationIntent()
    _ = try await intent.perform()

    // Assert: the notification was posted (intent's only side-effect).
    #expect(notificationReceived.withLock { $0 }, "Intent must post .openDictationCapture notification")
    // No UploadQueue is reachable from the intent — the absence of an enqueue
    // call is enforced structurally: there is no UploadQueue parameter on the intent.
  }
}

// MARK: - LockIsolated helper
//
// Minimal Sendable wrapper for mutating a value from a non-Sendable closure
// (NotificationCenter callback).

private final class LockIsolated<T: Sendable>: @unchecked Sendable {
  private var _value: T
  private let lock = NSLock()

  init(_ value: T) { _value = value }

  func withLock<R>(_ body: (inout T) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&_value)
  }
}
