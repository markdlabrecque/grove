import Testing
import Foundation
import SwiftData
import GroveCore
@testable import GroveCore
@testable import Grove

// MARK: - TrackAsTaskTests
//
// Tests for the "Track as task" feature (#397):
//   1. Toggle state persists across view re-renders.
//   2. Save with toggle on sends client_intent: "task" in the payload.
//   3. Save with toggle off omits the field entirely.
//   4. Permission-denied path saves capture but skips reminder creation
//      and surfaces the reminder-skipped banner.
//   5. Reconciliation: pending entry + memory body with matching task
//      → PATCH called with stored identifier → entry removed.
//   6. Reconciliation idempotency: 409 response also removes the entry.
//   7. Reconciliation: 404 retains the entry.
//
// CI placement: GroveTests app target (make ios-test-app), not GroveCore SPM.

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

  @Test("save with permission granted creates reminder and stores entry")
  func saveWithPermissionCreatesReminder() async throws {
    let queue = try makeTaskAsQueue()
    let stub = StubEventKitProviderCounting(authStatus: .authorized, createdIdentifier: Self.reminderID)
    let store = InMemoryPendingReminderStore()

    let vm = CaptureViewModel(
      uploadQueue: queue,
      eventKitProvider: stub,
      pendingReminderStore: store
    )
    vm.content = "Buy groceries"
    vm.trackAsTask = true

    // Intercept enqueue so we can get the clientID without a live server.
    var enqueuedClientID: String?
    vm._enqueueObserver = { id in enqueuedClientID = id }

    await vm.save(applyFillerCleanup: false, languageHint: nil)

    #expect(stub.createReminderCallCount == 1, "createReminder should be called once")
    let entries = store.all()
    #expect(entries.count == 1, "One pending reminder entry should be stored")
    if let entry = entries.first {
      #expect(entry.calendarItemIdentifier == Self.reminderID)
    }
  }

  @Test("save with permission denied: capture saves but no reminder is created, banner shown")
  func saveWithPermissionDenied() async throws {
    let queue = try makeTaskAsQueue()
    let stub = StubEventKitProviderCounting(authStatus: .denied, createdIdentifier: nil)
    let store = InMemoryPendingReminderStore()

    let vm = CaptureViewModel(
      uploadQueue: queue,
      eventKitProvider: stub,
      pendingReminderStore: store
    )
    vm.content = "Schedule vet appointment"
    vm.trackAsTask = true

    await vm.save(applyFillerCleanup: false, languageHint: nil)

    #expect(stub.createReminderCallCount == 0, "createReminder must NOT be called when permission denied")
    #expect(store.all().isEmpty, "No pending reminder entry on permission denial")
    #expect(vm.showReminderPermissionDeniedBanner == true, "Banner should be shown")
  }

  @Test("save with toggle off: createReminder is never called")
  func saveWithToggleOff() async throws {
    let queue = try makeTaskAsQueue()
    let stub = StubEventKitProviderCounting(authStatus: .authorized, createdIdentifier: Self.reminderID)
    let store = InMemoryPendingReminderStore()

    let vm = CaptureViewModel(
      uploadQueue: queue,
      eventKitProvider: stub,
      pendingReminderStore: store
    )
    vm.content = "Read that article"
    vm.trackAsTask = false

    await vm.save(applyFillerCleanup: false, languageHint: nil)

    #expect(stub.requestAccessCallCount == 0, "requestAccess must NOT be called when toggle is off")
    #expect(stub.createReminderCallCount == 0, "createReminder must NOT be called when toggle is off")
  }
}

// MARK: - Suite 4: Reconciliation

@Suite("TrackAsTask — Reconciliation")
@MainActor
struct TrackAsTaskReconciliationTests {

  private static let memoryID = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!
  private static let taskID   = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000002")!
  private static let reminderID = "EK-reconcile-999"

  private func makeTask(
    id: UUID = TrackAsTaskReconciliationTests.taskID,
    memoryID: UUID = TrackAsTaskReconciliationTests.memoryID,
    eventkitIdentifier: String? = nil
  ) -> TaskDTO {
    TaskDTO(
      id: id,
      memoryID: memoryID,
      description: "Call the vet",
      dueDate: nil,
      status: "open",
      relatedPeople: [],
      eventkitIdentifier: eventkitIdentifier,
      eventkitLinkedAt: nil
    )
  }

  @Test("reconcile: pending entry + matching task → PATCH called, entry removed")
  func reconcileHappyPath() async throws {
    let store = InMemoryPendingReminderStore()
    store.store(memoryID: Self.memoryID, calendarItemIdentifier: Self.reminderID)

    var patchedTaskID: UUID?
    var patchedIdentifier: String?

    let reconciler = TaskReconciler(
      pendingStore: store,
      patchProvider: { taskID, identifier in
        patchedTaskID = taskID
        patchedIdentifier = identifier
        return self.makeTask(eventkitIdentifier: identifier)
      }
    )

    await reconciler.reconcile(tasks: [makeTask()])

    #expect(patchedTaskID == Self.taskID)
    #expect(patchedIdentifier == Self.reminderID)
    #expect(store.all().isEmpty, "Entry should be removed after successful PATCH")
  }

  @Test("reconcile: 409 response also removes the entry (idempotency)")
  func reconcile409RemovesEntry() async throws {
    let store = InMemoryPendingReminderStore()
    store.store(memoryID: Self.memoryID, calendarItemIdentifier: Self.reminderID)

    let reconciler = TaskReconciler(
      pendingStore: store,
      patchProvider: { _, _ in
        throw TaskLinkingError.alreadyLinked(existingIdentifier: Self.reminderID)
      }
    )

    await reconciler.reconcile(tasks: [makeTask()])

    #expect(store.all().isEmpty, "409 should still remove the entry — server is right")
  }

  @Test("reconcile: 404 response retains the entry")
  func reconcile404RetainsEntry() async throws {
    let store = InMemoryPendingReminderStore()
    store.store(memoryID: Self.memoryID, calendarItemIdentifier: Self.reminderID)

    let reconciler = TaskReconciler(
      pendingStore: store,
      patchProvider: { _, _ in
        throw APIError.httpError(statusCode: 404, detail: "Not found")
      }
    )

    await reconciler.reconcile(tasks: [makeTask()])

    #expect(store.all().count == 1, "404 should retain the entry — do not lose it on transient errors")
  }

  @Test("reconcile: no pending entry for memory — PATCH not called")
  func reconcileNoPendingEntry() async throws {
    let store = InMemoryPendingReminderStore()
    // Nothing stored for Self.memoryID

    var patchCalled = false
    let reconciler = TaskReconciler(
      pendingStore: store,
      patchProvider: { _, _ in
        patchCalled = true
        return self.makeTask()
      }
    )

    await reconciler.reconcile(tasks: [makeTask()])

    #expect(patchCalled == false)
  }
}

// MARK: - Suite 5: PendingReminderStore notification-driven remap

@Suite("TrackAsTask — PendingReminderStore remap via notification")
@MainActor
struct PendingReminderStoreRemapTests {

  private static let calendarID = "EK-remap-test-abc"

  /// Verify that posting `captureUploadedNotification` causes the store to
  /// remap the entry from `clientID` to `serverMemoryID`.
  ///
  /// Uses a hermetic `UserDefaults` suite so the test never touches the app's
  /// real defaults and teardown is a single `removeSuite` call.
  @Test("captureUploadedNotification remaps clientID → serverMemoryID")
  func notificationRemapsClientIDToServerMemoryID() async throws {
    let suiteName = UUID().uuidString
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removeSuite(named: suiteName) }

    let store = UserDefaultsPendingReminderStore(defaults: suite)

    let clientID = UUID()
    let serverMemoryID = UUID()

    store.store(memoryID: clientID, calendarItemIdentifier: Self.calendarID)
    #expect(store.entry(for: clientID) != nil, "Precondition: entry exists under clientID before remap")

    // The observer lives in a `Task { @MainActor ... }` started during init.
    // That Task has not iterated yet because the current test function holds
    // the main-actor executor.  Yield once to let it reach its first `next()`
    // suspension point and register with the notification stream.
    await Task.yield()

    NotificationCenter.default.post(
      name: .captureUploadedNotification,
      object: nil,
      userInfo: [
        "clientID": clientID.uuidString,
        "serverMemoryID": serverMemoryID.uuidString,
      ]
    )

    // Now yield again so the observer task wakes up and calls remap().
    await Task.yield()

    #expect(store.entry(for: serverMemoryID) != nil, "Entry must exist under serverMemoryID after remap")
    #expect(store.entry(for: clientID) == nil, "Old clientID key must be gone after remap")

    let remapped = store.entry(for: serverMemoryID)
    #expect(remapped?.calendarItemIdentifier == Self.calendarID,
            "Remapped entry must retain the original calendarItemIdentifier")
  }

  /// Posting `captureUploadedNotification` for an unknown `clientID` is a
  /// no-op — the store must remain unchanged.
  @Test("captureUploadedNotification with unknown clientID is a no-op")
  func notificationUnknownClientIDNoOp() async throws {
    let suiteName = UUID().uuidString
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removeSuite(named: suiteName) }

    let store = UserDefaultsPendingReminderStore(defaults: suite)

    let knownClientID = UUID()
    let unknownClientID = UUID()
    let serverMemoryID = UUID()

    store.store(memoryID: knownClientID, calendarItemIdentifier: Self.calendarID)

    // Yield before posting so the observer task has started iterating.
    await Task.yield()

    NotificationCenter.default.post(
      name: .captureUploadedNotification,
      object: nil,
      userInfo: [
        "clientID": unknownClientID.uuidString,
        "serverMemoryID": serverMemoryID.uuidString,
      ]
    )

    // Yield after posting so the observer gets a chance to process (and
    // confirm it correctly ignores the unknown clientID).
    await Task.yield()

    #expect(store.all().count == 1, "Unrelated notification must not remove existing entries")
    #expect(store.entry(for: knownClientID) != nil, "Original entry must still be present")
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

  func fetchCompletion(for identifier: String) -> Bool? { false }
}

/// An in-memory `PendingReminderStoring` implementation for tests.
@MainActor
final class InMemoryPendingReminderStore: PendingReminderStoring {
  private var entries: [PendingReminderEntry] = []

  func store(memoryID: UUID, calendarItemIdentifier: String) {
    entries.append(
      PendingReminderEntry(memoryID: memoryID, calendarItemIdentifier: calendarItemIdentifier)
    )
  }

  func entry(for memoryID: UUID) -> PendingReminderEntry? {
    entries.first { $0.memoryID == memoryID }
  }

  func remove(memoryID: UUID) {
    entries.removeAll { $0.memoryID == memoryID }
  }

  func all() -> [PendingReminderEntry] { entries }
}
