import EventKit
import SwiftUI
import GroveCore
import os

/// The Tasks tab — lists all incomplete EKReminders from the device (#438, #439).
///
/// ## States
///
/// - `.notDetermined`: permission not yet requested; shows a "Grant access"
///   prompt explaining why Grove needs Reminders access.
/// - `.denied` / `.restricted`: shows a "Open Settings" affordance.
/// - `.loading`: shows a `ProgressView` while the EventKit fetch is in flight.
/// - `.empty`: shows a "No incomplete reminders" empty state.
/// - `.loaded([ReminderListItem])`: shows the sorted reminder list.
///
/// ## Provenance (R3.3, R3.4)
///
/// After the EKReminder fetch, `TasksViewModel` performs a batch lookup of
/// `calendarItemIdentifier`s against the server to build a provenance map.
/// Grove-originated rows display a leaf badge; tapping it navigates to
/// `MemoryDetailView` via the `NavigationStack`'s path.
///
/// ## Lifecycle
///
/// - `load()` is called on `.onAppear`.
/// - `EKEventStoreChanged` triggers a re-fetch while the tab is visible;
///   the observer is set up on `.onAppear` and torn down on `.onDisappear`
///   to avoid background work when other tabs are active.
/// - Pull-to-refresh also calls `load()`.
///
/// ## Accessibility
///
/// All text uses SwiftUI dynamic type. Each interactive element has an
/// `accessibilityLabel` and `accessibilityHint` per the app's conventions.
struct TasksView: View {

  @State private var vm: TasksViewModel
  @State private var navigationPath = NavigationPath()
  @State private var notificationObserver: NSObjectProtocol? = nil

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.markdlabrecque.grove",
    category: "tasks-view"
  )

  init(provider: (any EventKitProviding)? = nil) {
    let resolved = provider ?? LiveEventKitProvider()
    _vm = State(initialValue: TasksViewModel(provider: resolved))
  }

  var body: some View {
    NavigationStack(path: $navigationPath) {
      content
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.large)
        // R3.4: Navigate to MemoryDetailView when a UUID is pushed onto the path.
        .navigationDestination(for: UUID.self) { memoryID in
          MemoryDetailView(
            result: QueryResult(
              memoryID: memoryID,
              score: 1.0,
              matchedVia: "provenance",
              matchedChunkIndex: nil,
              excerpt: "",
              capturedAt: nil,
              sourceModality: nil
            ),
            onDeleteSuccess: { _ in
              // Pop back to the Tasks tab after deletion.
              navigationPath.removeLast()
            }
          )
        }
    }
    .onAppear {
      Task { await vm.load() }
      subscribeToStoreChanges()
    }
    .onDisappear {
      unsubscribeFromStoreChanges()
    }
  }

  // MARK: - Content dispatcher

  @ViewBuilder
  private var content: some View {
    switch vm.loadState {
    case .notDetermined:
      permissionPromptView
    case .denied:
      permissionDeniedView
    case .loading:
      loadingView
    case .empty:
      emptyView
    case .loaded(let items):
      listView(items: items)
    }
  }

  // MARK: - Permission prompt (.notDetermined)

  private var permissionPromptView: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: "checklist")
        .font(.system(size: 56))
        .foregroundStyle(Color.forest500)
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("Grove needs access to Reminders")
          .font(.headline)
          .multilineTextAlignment(.center)
          .foregroundStyle(Color.ink900)

        Text("Grant access to see all your incomplete reminders here.")
          .font(.subheadline)
          .multilineTextAlignment(.center)
          .foregroundStyle(Color.ink500)
          .padding(.horizontal, 32)
      }

      Button {
        Task { await vm.load() }
      } label: {
        Text("Grant access")
          .font(.body.weight(.medium))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Color.forest500)
          .foregroundStyle(.white)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .padding(.horizontal, 32)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Grant Reminders access")
      .accessibilityHint("Double-tap to request permission to read Apple Reminders")

      Spacer()
    }
    .padding(.top, 24)
  }

  // MARK: - Permission denied

  private var permissionDeniedView: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: "bell.slash.fill")
        .font(.system(size: 48))
        .foregroundStyle(Color.ink300)
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("Reminders access is off")
          .font(.headline)
          .multilineTextAlignment(.center)
          .foregroundStyle(Color.ink900)

        Text("Turn it on in Settings to see your tasks here.")
          .font(.subheadline)
          .multilineTextAlignment(.center)
          .foregroundStyle(Color.ink500)
          .padding(.horizontal, 32)
      }

      Button {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      } label: {
        Text("Open Settings")
          .font(.body.weight(.medium))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Color.forest500)
          .foregroundStyle(.white)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .padding(.horizontal, 32)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open Settings")
      .accessibilityHint("Double-tap to open the Settings app to grant Reminders access")

      Spacer()
    }
    .padding(.top, 24)
  }

  // MARK: - Loading

  private var loadingView: some View {
    VStack {
      Spacer()
      ProgressView("Loading reminders…")
        .tint(Color.forest500)
        .foregroundStyle(Color.ink500)
      Spacer()
    }
  }

  // MARK: - Empty

  private var emptyView: some View {
    VStack {
      Spacer()
      Text("No incomplete reminders")
        .font(.subheadline)
        .foregroundStyle(Color.ink300)
      Spacer()
    }
    .refreshable {
      await vm.load()
    }
  }

  // MARK: - List

  private func listView(items: [ReminderListItem]) -> some View {
    List(items) { item in
      ReminderRowView(
        item: item,
        memoryID: vm.provenanceMap[item.id],
        onTap: { openReminder(identifier: item.id) },
        onBadgeTap: { memoryID in
          navigationPath.append(memoryID)
        }
      )
      .listRowSeparatorTint(Color.hairline)
    }
    .listStyle(.plain)
    .refreshable {
      await vm.load()
    }
  }

  // MARK: - Deep-link

  private func openReminder(identifier: String) {
    guard let url = TasksViewModel.reminderDeepLinkURL(for: identifier) else {
      logger.error("Could not construct deep-link URL for identifier: \(identifier, privacy: .public)")
      return
    }
    guard UIApplication.shared.canOpenURL(url) else {
      logger.error("Cannot open Reminders deep-link URL: \(url, privacy: .public)")
      return
    }
    UIApplication.shared.open(url) { success in
      if !success {
        self.logger.error("UIApplication.open failed for URL: \(url, privacy: .public)")
      }
    }
  }

  // MARK: - EKEventStoreChanged (R2.10)

  private func subscribeToStoreChanges() {
    guard notificationObserver == nil else { return }
    notificationObserver = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged,
      object: nil,
      queue: .main
    ) { [weak vm = vm] _ in
      guard let vm else { return }
      Task { @MainActor in
        await vm.load()
      }
    }
  }

  private func unsubscribeFromStoreChanges() {
    if let observer = notificationObserver {
      NotificationCenter.default.removeObserver(observer)
      notificationObserver = nil
    }
  }
}

// MARK: - Preview

#Preview("Permission prompt") {
  TasksView(provider: PreviewNotDeterminedProvider())
}

#Preview("List with Grove badge") {
  TasksView(provider: PreviewLoadedProvider())
}

// MARK: - Preview providers

@MainActor
private final class PreviewNotDeterminedProvider: EventKitProviding {
  func requestAccess() async -> Bool { false }
  func createReminder(title: String, dueDateComponents: DateComponents?) async throws -> String { "" }
  func fetchCompletion(for identifier: String) -> Bool? { nil }
  func fetchIncompleteReminders() async throws -> [ReminderListItem] { [] }
}

@MainActor
private final class PreviewLoadedProvider: EventKitProviding {
  func requestAccess() async -> Bool { true }
  func createReminder(title: String, dueDateComponents: DateComponents?) async throws -> String { "" }
  func fetchCompletion(for identifier: String) -> Bool? { nil }
  func fetchIncompleteReminders() async throws -> [ReminderListItem] {
    let now = Date()
    return [
      ReminderListItem(id: "1", title: "Call Theo about the demo", dueDate: now.addingTimeInterval(86_400), listName: "Work"),
      ReminderListItem(id: "2", title: "Buy oat milk", dueDate: nil, listName: "Personal"),
      ReminderListItem(id: "3", title: "Review PR #438", dueDate: now.addingTimeInterval(3_600), listName: "Work"),
    ]
  }
}
