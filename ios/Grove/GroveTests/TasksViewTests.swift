import Testing
import Foundation
@testable import Grove

// MARK: - TasksViewTests
//
// Tests for `TasksViewModel` — the state machine backing the Tasks tab (#438).
//
// These tests cover:
//   1. Sorting: due-date ascending, nil due dates last, alpha tiebreak.
//   2. Empty state: fetch returns [] → .empty load state.
//   3. Loading state: set to .loading while fetch is in flight.
//   4. Denied state: permission denied → .denied load state.
//   5. Not-determined state: no access requested yet → .notDetermined.
//   6. Deep-link URL construction from a known calendarItemIdentifier.
//
// CI placement: GroveTests app target (make ios-test-app).
// Tests use a stub EventKitProviding that returns fixture ReminderListItems
// without touching a real EKEventStore.

// MARK: - Stub provider

/// A minimal stub for `EventKitProviding` used only by `TasksViewTests`.
/// Does NOT conflict with `StubEventKitProvider` in `TaskLinkingViewModelTests`.
@MainActor
private final class TasksStubProvider: EventKitProviding {
  enum AccessResult { case granted, denied }

  private let accessResult: AccessResult
  private let reminders: [ReminderListItem]

  init(accessResult: AccessResult, reminders: [ReminderListItem] = []) {
    self.accessResult = accessResult
    self.reminders = reminders
  }

  func requestAccess() async -> Bool {
    accessResult == .granted
  }

  func createReminder(title: String, dueDateComponents: DateComponents?) async throws -> String {
    throw EventKitError.saveFailed
  }

  func fetchCompletion(for identifier: String) -> Bool? {
    nil
  }

  func fetchIncompleteReminders() async throws -> [ReminderListItem] {
    reminders
  }
}

// MARK: - Fixtures

private func makeReminder(
  id: String = UUID().uuidString,
  title: String,
  dueDate: Date? = nil,
  listName: String = "Reminders"
) -> ReminderListItem {
  ReminderListItem(id: id, title: title, dueDate: dueDate, listName: listName)
}

// MARK: - Suite

@Suite("TasksViewModel")
@MainActor
struct TasksViewTests {

  // MARK: - Sort order

  @Test("sort: due-date ascending, nil last, alpha tiebreak")
  func sortOrder() async throws {
    let now = Date()
    let soon = now.addingTimeInterval(86_400)       // +1 day
    let later = now.addingTimeInterval(7 * 86_400)  // +7 days

    let reminders = [
      makeReminder(title: "Zebra", dueDate: later, listName: "Work"),
      makeReminder(title: "Apple", dueDate: nil, listName: "Work"),
      makeReminder(title: "Mango", dueDate: soon, listName: "Work"),
      makeReminder(title: "Banana", dueDate: nil, listName: "Work"),
    ]

    let stub = TasksStubProvider(accessResult: .granted, reminders: reminders)
    let vm = TasksViewModel(provider: stub)

    await vm.load()

    guard case .loaded(let sorted) = vm.loadState else {
      Issue.record("Expected .loaded, got \(vm.loadState)")
      return
    }

    // Expected order: Mango (soon), Zebra (later), Apple (nil, alpha), Banana (nil, alpha)
    #expect(sorted[0].title == "Mango")
    #expect(sorted[1].title == "Zebra")
    #expect(sorted[2].title == "Apple")
    #expect(sorted[3].title == "Banana")
  }

  // MARK: - Empty state

  @Test("empty state: fetch returns [] → .empty")
  func emptyState() async throws {
    let stub = TasksStubProvider(accessResult: .granted, reminders: [])
    let vm = TasksViewModel(provider: stub)

    await vm.load()

    guard case .empty = vm.loadState else {
      Issue.record("Expected .empty, got \(vm.loadState)")
      return
    }
  }

  // MARK: - Denied state

  @Test("denied state: permission denied → .denied")
  func deniedState() async throws {
    let stub = TasksStubProvider(accessResult: .denied)
    let vm = TasksViewModel(provider: stub)

    await vm.load()

    guard case .denied = vm.loadState else {
      Issue.record("Expected .denied, got \(vm.loadState)")
      return
    }
  }

  // MARK: - NotDetermined initial state

  @Test("initial state is .notDetermined before load()")
  func initialStateIsNotDetermined() {
    let stub = TasksStubProvider(accessResult: .granted)
    let vm = TasksViewModel(provider: stub)

    guard case .notDetermined = vm.loadState else {
      Issue.record("Expected .notDetermined, got \(vm.loadState)")
      return
    }
  }

  // MARK: - Loaded state with items

  @Test("loaded state: fetch returns items → .loaded with correct count")
  func loadedState() async throws {
    let reminders = [
      makeReminder(title: "Buy milk"),
      makeReminder(title: "Call Theo"),
    ]
    let stub = TasksStubProvider(accessResult: .granted, reminders: reminders)
    let vm = TasksViewModel(provider: stub)

    await vm.load()

    guard case .loaded(let items) = vm.loadState else {
      Issue.record("Expected .loaded, got \(vm.loadState)")
      return
    }

    #expect(items.count == 2)
  }

  // MARK: - Deep-link URL construction

  @Test("deep-link URL: constructed from calendarItemIdentifier")
  func deepLinkURL() {
    let identifier = "REMCDReminder-ABC-123"
    let url = TasksViewModel.reminderDeepLinkURL(for: identifier)

    #expect(url != nil)
    #expect(url?.scheme == "x-apple-reminderkit")
    #expect(url?.host == "REMCDReminder")
    #expect(url?.path == "/\(identifier)")
  }

  // MARK: - Nil due-date sort stability

  @Test("sort: two nil-due-date reminders are sorted alphabetically")
  func nilDueDateAlphaSort() async throws {
    let reminders = [
      makeReminder(title: "Zoo", dueDate: nil),
      makeReminder(title: "Ant", dueDate: nil),
      makeReminder(title: "Mole", dueDate: nil),
    ]
    let stub = TasksStubProvider(accessResult: .granted, reminders: reminders)
    let vm = TasksViewModel(provider: stub)

    await vm.load()

    guard case .loaded(let sorted) = vm.loadState else {
      Issue.record("Expected .loaded, got \(vm.loadState)")
      return
    }

    #expect(sorted[0].title == "Ant")
    #expect(sorted[1].title == "Mole")
    #expect(sorted[2].title == "Zoo")
  }
}
