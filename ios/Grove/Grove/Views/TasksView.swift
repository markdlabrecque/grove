import SwiftUI
import GroveCore
import os

/// The Tasks tab — lists all Grove tasks for the authenticated user (#452).
///
/// ## States
///
/// - `.loading`: shows a `ProgressView` while the server fetch is in flight.
/// - `.empty`: shows a "No tasks" centred message after a successful fetch
///   that returned zero rows.
/// - `.loaded([TaskDTO])`: shows the task list with swipe-to-delete.
/// - `.error(Error)`: shows a centred error message and a "Try again" button.
///
/// ## Swipe-to-delete (R2.5)
///
/// Each row has a trailing swipe action that calls `TasksViewModel.deleteTask(_:)`.
/// The row is removed optimistically; the view model restores it and sets
/// `deleteError` if the server call fails.
///
/// ## Lifecycle
///
/// - `load()` is called on `.onAppear`.
/// - Pull-to-refresh also calls `load()`.
/// - No `EKEventStoreChanged` subscription (R2.10).
/// - No `NavigationStack` + `navigationDestination` wiring (R2.11).
///
/// ## Accessibility
///
/// All text uses SwiftUI dynamic type. Each interactive element has an
/// `accessibilityLabel` and `accessibilityHint` per the app's conventions.
struct TasksView: View {

  @State private var vm: TasksViewModel

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.markdlabrecque.grove",
    category: "tasks-view"
  )

  init(
    fetch: (() async throws -> [TaskDTO])? = nil,
    delete: ((UUID) async throws -> Void)? = nil
  ) {
    if let fetch, let delete {
      _vm = State(initialValue: TasksViewModel(fetch: fetch, delete: delete))
    } else {
      _vm = State(initialValue: TasksViewModel())
    }
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.large)
    }
    .onAppear {
      Task { await vm.load() }
    }
  }

  // MARK: - Content dispatcher

  @ViewBuilder
  private var content: some View {
    switch vm.loadState {
    case .loading:
      loadingView
    case .empty:
      emptyView
    case .loaded(let tasks):
      listView(tasks: tasks)
    case .error(let error):
      errorView(error: error)
    }
  }

  // MARK: - Loading

  private var loadingView: some View {
    VStack {
      Spacer()
      ProgressView("Loading tasks…")
        .tint(Color.forest500)
        .foregroundStyle(Color.ink500)
        .accessibilityLabel("Loading tasks")
      Spacer()
    }
  }

  // MARK: - Empty (R2.7)

  private var emptyView: some View {
    VStack {
      Spacer()
      Text("No tasks")
        .font(.subheadline)
        .foregroundStyle(Color.ink300)
        .accessibilityLabel("No tasks")
      Spacer()
    }
    .refreshable {
      await vm.load()
    }
  }

  // MARK: - Error (R2.8)

  private func errorView(error: Error) -> some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundStyle(Color.ink300)
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("Couldn't load tasks")
          .font(.headline)
          .foregroundStyle(Color.ink900)
          .multilineTextAlignment(.center)

        Text(error.localizedDescription)
          .font(.subheadline)
          .foregroundStyle(Color.ink500)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }

      Button {
        Task { await vm.load() }
      } label: {
        Text("Try again")
          .font(.body.weight(.medium))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Color.forest500)
          .foregroundStyle(.white)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .padding(.horizontal, 32)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Try again")
      .accessibilityHint("Double-tap to retry loading tasks")

      Spacer()
    }
    .padding(.top, 24)
  }

  // MARK: - List

  private func listView(tasks: [TaskDTO]) -> some View {
    List {
      ForEach(tasks) { task in
        TaskRowViewV2(task: task)
          .listRowSeparatorTint(Color.hairline)
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
              Task { await vm.deleteTask(task) }
            } label: {
              Label("Delete", systemImage: "trash")
            }
            .accessibilityLabel("Delete task: \(task.description)")
          }
      }
    }
    .listStyle(.plain)
    .refreshable {
      await vm.load()
    }
    .overlay {
      // Delete error banner (R2.5).
      if let deleteError = vm.deleteError {
        deleteErrorBanner(message: deleteError.localizedDescription)
      }
    }
  }

  // MARK: - Delete error banner

  private func deleteErrorBanner(message: String) -> some View {
    VStack {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(.red)
          .accessibilityHidden(true)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(Color.ink900)
          .lineLimit(2)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(.regularMaterial)
          .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
      )
      .padding(.horizontal, 16)
      .accessibilityLabel("Error: \(message)")

      Spacer()
    }
    .padding(.top, 8)
  }
}

// MARK: - Preview

#Preview("Loading") {
  TasksView(
    fetch: {
      try await Task.sleep(for: .seconds(999))
      return []
    },
    delete: { _ in }
  )
}

#Preview("With tasks") {
  let now = Date()
  let cal = Calendar.current
  let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
  let tomorrowComps = cal.dateComponents([.year, .month, .day], from: tomorrow)
  let tomorrowStr = String(format: "%04d-%02d-%02d",
    tomorrowComps.year!, tomorrowComps.month!, tomorrowComps.day!)

  return TasksView(
    fetch: {
      [
        TaskDTO(
          id: UUID(), memoryID: UUID(),
          description: "Call Theo about the demo",
          dueDate: tomorrowStr, status: "open",
          relatedPeople: ["Theo"],
          eventkitIdentifier: nil, eventkitLinkedAt: nil
        ),
        TaskDTO(
          id: UUID(), memoryID: UUID(),
          description: "Buy oat milk",
          dueDate: nil, status: "open",
          relatedPeople: nil,
          eventkitIdentifier: nil, eventkitLinkedAt: nil
        ),
        TaskDTO(
          id: UUID(), memoryID: UUID(),
          description: "Review PR #452 — the rebuild spec is detailed",
          dueDate: "2026-08-15", status: "open",
          relatedPeople: ["mark", "sarah"],
          eventkitIdentifier: nil, eventkitLinkedAt: nil
        ),
      ]
    },
    delete: { _ in }
  )
}

#Preview("Empty") {
  TasksView(fetch: { [] }, delete: { _ in })
}

#Preview("Error") {
  struct PreviewError: LocalizedError {
    var errorDescription: String? { "Could not reach the server." }
  }
  return TasksView(fetch: { throw PreviewError() }, delete: { _ in })
}
