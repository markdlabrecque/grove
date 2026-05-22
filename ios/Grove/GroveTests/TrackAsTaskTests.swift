import Testing
import Foundation
import SwiftData
import GroveCore
@testable import GroveCore
@testable import Grove

// MARK: - TrackAsTaskTests
//
// Tests for the "Track as task" feature (#397).
//
// Suites kept after spec-02 cleanup (#453):
//   1. Toggle state persists across view re-renders.
//   2. Save with toggle on sends client_intent: "task" in the payload.
//   3. Save with toggle off omits the field entirely.
//   4. Permission-denied path saves capture but skips reminder creation
//      and surfaces the reminder-skipped banner.
//
// Removed in #453 (dead code after spec-02 cleanup):
//   - Suite 4 (Reconciliation): used TaskReconciler + PendingReminderStore,
//     both deleted as part of the EventKit-coupling removal.
//
// CI placement: GroveTests app target (make ios-test-app).

// MARK: - Shared fixtures

@MainActor
private func makeTaskAsQueue() throws -> UploadQueue {
  let schema = Schema([QueuedCapture.self])
  let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
  let container = try ModelContainer(for: schema, configurations: [config])
  let api = GroveAPI(
    baseURL: URL(string: "https://grove.test.example")!,
    bearerToken: "test-token"
  )
  return UploadQueue(modelContainer: container, api: api)
}

// MARK: - Suite 1: CaptureViewModel toggle state

@Suite("TrackAsTask — CaptureViewModel toggle state")
@MainActor
struct TrackAsTaskToggleTests {

  @Test("trackAsTask defaults to false")
  func trackAsTaskDefaultFalse() throws {
    let vm = CaptureViewModel(uploadQueue: try makeTaskAsQueue())
    #expect(vm.trackAsTask == false)
  }

  @Test("trackAsTask toggles to true and stays true")
  func trackAsTaskTogglesPersists() throws {
    let vm = CaptureViewModel(uploadQueue: try makeTaskAsQueue())
    vm.trackAsTask = true
    #expect(vm.trackAsTask == true)
  }

  @Test("dueDate defaults to nil")
  func dueDateDefaultNil() throws {
    let vm = CaptureViewModel(uploadQueue: try makeTaskAsQueue())
    #expect(vm.taskDueDate == nil)
  }

  @Test("dueDate can be set when trackAsTask is true")
  func dueDateCanBeSet() throws {
    let vm = CaptureViewModel(uploadQueue: try makeTaskAsQueue())
    vm.trackAsTask = true
    let date = Date()
    vm.taskDueDate = date
    #expect(vm.taskDueDate == date)
  }
}

// MARK: - Suite 2: Payload encoding

@Suite("TrackAsTask — Payload encoding")
struct TrackAsTaskPayloadTests {

  @Test("buildPayload with clientIntent task includes client_intent")
  func payloadWithClientIntentTask() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Buy oat milk",
      sourceModality: "text",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: "en",
      clientIntent: "task"
    )
    #expect(payload.clientIntent == "task")
  }

  @Test("buildPayload without clientIntent has nil client_intent")
  func payloadWithoutClientIntent() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Buy oat milk",
      sourceModality: "text",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: "en",
      clientIntent: nil
    )
    #expect(payload.clientIntent == nil)
  }

  @Test("encodePayload with task intent includes client_intent key in JSON")
  func encodedPayloadIncludesClientIntent() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Book dentist",
      sourceModality: "text",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: "en",
      clientIntent: "task"
    )
    let data = try CaptureViewModel.encodePayload(payload)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["client_intent"] as? String == "task")
  }

  @Test("encodePayload without client intent omits client_intent key from JSON")
  func encodedPayloadOmitsClientIntent() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Book dentist",
      sourceModality: "text",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: "en",
      clientIntent: nil
    )
    let data = try CaptureViewModel.encodePayload(payload)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["client_intent"] == nil, "client_intent must be absent when not set")
  }
}

// MARK: - Suite 3: EventKit permission + save flow

@Suite("TrackAsTask — EventKit save flow")
@MainActor
struct TrackAsTaskSaveFlowTests {

  private static let reminderID = "EK-task-reminder-001"

  @Test("save with permission granted creates reminder (fire-and-forget)")
  func saveWithPermissionCreatesReminder() async throws {
    let queue = try makeTaskAsQueue()
    let stub = StubEventKitProviderCounting(authStatus: .authorized, createdIdentifier: Self.reminderID)

    let vm = CaptureViewModel(
      uploadQueue: queue,
      eventKitProvider: stub
    )
    vm.content = "Buy groceries"
    vm.trackAsTask = true

    await vm.save(applyFillerCleanup: false, languageHint: nil)

    #expect(stub.createReminderCallCount == 1, "createReminder should be called once")
  }

  @Test("save with permission denied: capture saves but no reminder is created, banner shown")
  func saveWithPermissionDenied() async throws {
    let queue = try makeTaskAsQueue()
    let stub = StubEventKitProviderCounting(authStatus: .denied, createdIdentifier: nil)

    let vm = CaptureViewModel(
      uploadQueue: queue,
      eventKitProvider: stub
    )
    vm.content = "Schedule vet appointment"
    vm.trackAsTask = true

    await vm.save(applyFillerCleanup: false, languageHint: nil)

    #expect(stub.createReminderCallCount == 0, "createReminder must NOT be called when permission denied")
    #expect(vm.showReminderPermissionDeniedBanner == true, "Banner should be shown")
  }

  @Test("save with toggle off: createReminder is never called")
  func saveWithToggleOff() async throws {
    let queue = try makeTaskAsQueue()
    let stub = StubEventKitProviderCounting(authStatus: .authorized, createdIdentifier: Self.reminderID)

    let vm = CaptureViewModel(
      uploadQueue: queue,
      eventKitProvider: stub
    )
    vm.content = "Read that article"
    vm.trackAsTask = false

    await vm.save(applyFillerCleanup: false, languageHint: nil)

    #expect(stub.requestAccessCallCount == 0, "requestAccess must NOT be called when toggle is off")
    #expect(stub.createReminderCallCount == 0, "createReminder must NOT be called when toggle is off")
  }
}

// MARK: - Test doubles

/// A counting stub for `EventKitProviding` that records call counts.
@MainActor
final class StubEventKitProviderCounting: EventKitProviding {
  enum AuthStatus { case authorized, denied }

  private let authStatus: AuthStatus
  private let createdIdentifier: String?

  private(set) var requestAccessCallCount = 0
  private(set) var createReminderCallCount = 0

  init(authStatus: AuthStatus, createdIdentifier: String?) {
    self.authStatus = authStatus
    self.createdIdentifier = createdIdentifier
  }

  func requestAccess() async -> Bool {
    requestAccessCallCount += 1
    return authStatus == .authorized
  }

  func createReminder(title: String, dueDateComponents: DateComponents?) async throws -> String {
    createReminderCallCount += 1
    guard let id = createdIdentifier else { throw EventKitError.saveFailed }
    return id
  }
}
