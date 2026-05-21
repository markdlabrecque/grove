import Testing
import Foundation
@testable import GroveCore
@testable import Grove

/// Unit tests for `TaskLinkingViewModel`.
///
/// These tests exercise the create-reminder → PATCH server flow without a real
/// `EKEventStore` or live network. The EventKit boundary is mocked via
/// `EventKitProviding`, and network calls are stubbed via `GroveAPI`'s
/// injectable `patchTaskEventKit` closure.
///
/// ## CI placement (per [[ci-xcode-target-gap]])
///
/// These tests live in the `GroveTests` Xcode target because:
/// - `TaskLinkingViewModel` imports EventKit and is `@MainActor @Observable`,
///   neither of which is buildable in GroveCore's macOS/SPM target.
/// - Tests use `@testable import Grove` which is app-target-only.
///
/// They are NOT covered by `make ios-test-core` (SPM). They run under
/// `make ios-test-app` (Xcode) and in CI's Xcode-hosted test run.
@Suite("TaskLinkingViewModel", .serialized)
@MainActor
struct TaskLinkingViewModelTests {

  // MARK: - Fixtures

  private static let taskID = UUID(uuidString: "AABBCCDD-0000-0000-0000-000000000001")!
  private static let existingIdentifier = "EK-existing-123"
  private static let newIdentifier = "EK-new-456"

  private func makeTask(
    id: UUID = TaskLinkingViewModelTests.taskID,
    description: String = "Call Theo about the demo",
    dueDate: String? = nil,
    eventkitIdentifier: String? = nil
  ) -> TaskDTO {
    TaskDTO(
      id: id,
      memoryID: UUID(),
      description: description,
      dueDate: dueDate,
      status: "open",
      relatedPeople: [],
      eventkitIdentifier: eventkitIdentifier,
      eventkitLinkedAt: nil
    )
  }

  // MARK: - Initial state

  @Test("unlinked task: initial state shows Create Reminder button")
  func unlinkedTaskInitialState() {
    let vm = TaskLinkingViewModel(task: makeTask())
    #expect(vm.isLinked == false)
    #expect(vm.isCreatingReminder == false)
    #expect(vm.linkError == nil)
    #expect(vm.reminderCompleted == nil)
  }

  @Test("linked task: isLinked is true when eventkitIdentifier is present")
  func linkedTaskIsLinked() {
    let vm = TaskLinkingViewModel(
      task: makeTask(eventkitIdentifier: Self.existingIdentifier)
    )
    #expect(vm.isLinked == true)
  }

  // MARK: - Happy path: create reminder → PATCH

  @Test("createReminder: happy path stores identifier and calls PATCH")
  func createReminderHappyPath() async throws {
    var patchedTaskID: UUID?
    var patchedIdentifier: String?

    let stub = StubEventKitProvider(
      authStatus: .authorized,
      createdIdentifier: Self.newIdentifier
    )

    let vm = TaskLinkingViewModel(
      task: makeTask(),
      eventKitProvider: stub,
      patchProvider: { taskID, identifier in
        patchedTaskID = taskID
        patchedIdentifier = identifier
        return TaskDTO(
          id: taskID,
          memoryID: UUID(),
          description: "Call Theo about the demo",
          dueDate: nil,
          status: "open",
          relatedPeople: [],
          eventkitIdentifier: identifier,
          eventkitLinkedAt: "2026-05-18T12:00:00Z"
        )
      }
    )

    await vm.createReminder()

    #expect(patchedTaskID == Self.taskID)
    #expect(patchedIdentifier == Self.newIdentifier)
    #expect(vm.isLinked == true)
    #expect(vm.isCreatingReminder == false)
    #expect(vm.linkError == nil)
  }

  // MARK: - 409 conflict: self-heal from existing identifier

  @Test("createReminder: 409 conflict uses existing_identifier to self-heal")
  func createReminder409Conflict() async throws {
    let stub = StubEventKitProvider(
      authStatus: .authorized,
      createdIdentifier: Self.newIdentifier
    )

    let vm = TaskLinkingViewModel(
      task: makeTask(),
      eventKitProvider: stub,
      patchProvider: { _, _ in
        throw TaskLinkingError.alreadyLinked(existingIdentifier: Self.existingIdentifier)
      }
    )

    await vm.createReminder()

    // Should self-heal: pick up the existing identifier from the 409 body.
    #expect(vm.isLinked == true)
    #expect(vm.task.eventkitIdentifier == Self.existingIdentifier)
    #expect(vm.linkError == nil)
  }

  // MARK: - 404 not found

  @Test("createReminder: 404 surfaces a link error")
  func createReminder404() async throws {
    let stub = StubEventKitProvider(
      authStatus: .authorized,
      createdIdentifier: Self.newIdentifier
    )

    let vm = TaskLinkingViewModel(
      task: makeTask(),
      eventKitProvider: stub,
      patchProvider: { _, _ in
        throw APIError.httpError(statusCode: 404, detail: "Task not found")
      }
    )

    await vm.createReminder()

    #expect(vm.isLinked == false)
    // Value-equality: APIError.httpError with a non-nil detail forwards the
    // detail string directly (see APIError.errorDescription). Pin the exact
    // message so future regressions surface if the error stops being
    // human-readable or starts leaking the raw status code.
    #expect(vm.linkError == "Task not found")
    #expect(vm.linkError != "404", "linkError must not expose the bare status code")
  }

  // MARK: - Denied EventKit permission

  @Test("createReminder: denied permission surfaces a link error")
  func createReminderDeniedPermission() async throws {
    let stub = StubEventKitProvider(authStatus: .denied, createdIdentifier: nil)

    var patchCalled = false
    let vm = TaskLinkingViewModel(
      task: makeTask(),
      eventKitProvider: stub,
      patchProvider: { _, _ in
        patchCalled = true
        return makeTask()
      }
    )

    await vm.createReminder()

    #expect(patchCalled == false, "PATCH must not be called when permission is denied")
    #expect(vm.isLinked == false)
    #expect(vm.linkError != nil)
  }
}

// MARK: - Stub EventKit provider for tests

/// A test double for `EventKitProviding` that returns canned values without
/// touching the real `EKEventStore`.
@MainActor
final class StubEventKitProvider: EventKitProviding {
  enum AuthStatus { case authorized, denied }

  private let authStatus: AuthStatus
  private let createdIdentifier: String?

  init(authStatus: AuthStatus, createdIdentifier: String?) {
    self.authStatus = authStatus
    self.createdIdentifier = createdIdentifier
  }

  func requestAccess() async -> Bool {
    authStatus == .authorized
  }

  func createReminder(title: String, dueDateComponents: DateComponents?) async throws -> String {
    guard let id = createdIdentifier else {
      throw EventKitError.saveFailed
    }
    return id
  }

  func fetchCompletion(for identifier: String) -> Bool? {
    // Stub: always return not completed.
    false
  }

  func fetchIncompleteReminders() async throws -> [ReminderListItem] {
    []
  }
}
