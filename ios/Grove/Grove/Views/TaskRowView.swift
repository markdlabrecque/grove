import SwiftUI
import GroveCore

/// Renders a single `TaskDTO` with its EventKit linking affordance.
///
/// ## Unlinked task
///
/// Shows the task description with a "Create Reminder" button. Tapping triggers
/// the permission → create EKReminder → PATCH flow via `TaskLinkingViewModel`.
/// While in-flight, the button is replaced with a `ProgressView`.
///
/// ## Linked task
///
/// Shows the task description with a checkmark/circle icon reflecting the
/// reminder's live `isCompleted` state (fetched from EventKit at render time).
/// If the reminder was deleted from the Reminders app, shows a degraded
/// "Reminder deleted" state with a warning icon.
///
/// ## Accessibility
///
/// - The "Create Reminder" button has a meaningful `accessibilityLabel` and hint.
/// - The completion status is surfaced as an accessibility value on the row.
/// - All text honours Dynamic Type (uses `.font()` modifiers, no fixed sizes).
struct TaskRowView: View {
  @State private var vm: TaskLinkingViewModel

  init(task: TaskDTO) {
    _vm = State(initialValue: TaskLinkingViewModel(task: task))
  }

  /// Testing initialiser — accepts a pre-configured ViewModel.
  init(viewModel: TaskLinkingViewModel) {
    _vm = State(initialValue: viewModel)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 10) {
        // Status icon.
        taskStatusIcon
          .frame(width: 20, alignment: .center)
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 4) {
          Text(vm.task.description)
            .font(.subheadline)
            .foregroundStyle(Color.ink900)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Task: \(vm.task.description)")

          if let dueDate = vm.task.dueDate {
            Text("Due \(dueDate)")
              .font(.caption)
              .foregroundStyle(Color.ink500)
              .accessibilityLabel("Due date: \(dueDate)")
          }

          // Error state (permission denied, save failed, reminder deleted).
          if let error = vm.linkError {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
              .accessibilityLabel("Error: \(error)")
          }
        }

        Spacer(minLength: 4)

        // Action affordance (right-aligned).
        taskAction
      }
    }
    .padding(.vertical, 6)
    .onAppear {
      vm.refreshCompletionStatus()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }

  // MARK: - Status icon

  @ViewBuilder
  private var taskStatusIcon: some View {
    if vm.isLinked {
      if let completed = vm.reminderCompleted {
        if completed {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.forest500)
            .accessibilityHidden(true)
        } else {
          Image(systemName: "circle")
            .foregroundStyle(Color.ink300)
            .accessibilityHidden(true)
        }
      } else {
        // nil → reminder was deleted from Reminders app.
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(Color.ink500)
          .accessibilityHidden(true)
      }
    } else {
      Image(systemName: "circle.dotted")
        .foregroundStyle(Color.ink300)
        .accessibilityHidden(true)
    }
  }

  // MARK: - Action button

  @ViewBuilder
  private var taskAction: some View {
    if vm.isCreatingReminder {
      ProgressView()
        .controlSize(.small)
        .tint(.forest500)
        .accessibilityLabel("Creating reminder")
    } else if !vm.isLinked {
      Button {
        Task { await vm.createReminder() }
      } label: {
        Label("Create Reminder", systemImage: "bell.badge.plus")
          .font(.caption.weight(.medium))
          .labelStyle(.titleAndIcon)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Color.sage200)
          .foregroundStyle(Color.forest800)
          .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Create Reminder for: \(vm.task.description)")
      .accessibilityHint("Double-tap to create an Apple Reminder for this task")
    }
    // Linked + not in-flight: no action button. Status is clear from the icon.
  }

  // MARK: - Accessibility

  private var accessibilityLabel: String {
    var parts: [String] = ["Task: \(vm.task.description)"]
    if let dueDate = vm.task.dueDate {
      parts.append("Due \(dueDate)")
    }
    return parts.joined(separator: ". ")
  }

  private var accessibilityValue: String {
    guard vm.isLinked else { return "Not linked to Reminders" }
    switch vm.reminderCompleted {
    case .some(true):
      return "Completed in Reminders"
    case .some(false):
      return "Linked to Reminders, not yet completed"
    case .none:
      return "Reminder deleted from Reminders app"
    }
  }
}

// MARK: - Task list view

/// A list of `TaskDTO` values from a memory, each with its EventKit affordance.
///
/// Shown in the expanded section of `SourceCardRow` when tasks are present, and
/// on the `MemoryDetailView` detail screen.
struct TaskListView: View {
  let tasks: [TaskDTO]

  var body: some View {
    if tasks.isEmpty { return AnyView(EmptyView()) }

    return AnyView(
      VStack(alignment: .leading, spacing: 0) {
        Text("Tasks")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
          .accessibilityHidden(true)
          .padding(.bottom, 4)

        ForEach(tasks) { task in
          TaskRowView(task: task)

          if task.id != tasks.last?.id {
            Divider()
              .background(Color.hairline)
          }
        }
      }
    )
  }
}

#Preview("Unlinked task") {
  TaskRowView(task: TaskDTO(
    id: UUID(),
    memoryID: UUID(),
    description: "Call Theo about the upcoming demo next Thursday",
    dueDate: "2026-05-22",
    status: "open",
    relatedPeople: ["Theo"],
    eventkitIdentifier: nil,
    eventkitLinkedAt: nil
  ))
  .padding()
}

#Preview("Linked — not completed") {
  TaskRowView(viewModel: {
    let vm = TaskLinkingViewModel(
      task: TaskDTO(
        id: UUID(),
        memoryID: UUID(),
        description: "Buy oat milk",
        dueDate: nil,
        status: "open",
        relatedPeople: [],
        eventkitIdentifier: "EK-stub-123",
        eventkitLinkedAt: "2026-05-18T09:00:00Z"
      ),
      eventKitProvider: nil,
      patchProvider: { _, _ in fatalError("preview") }
    )
    return vm
  }())
  .padding()
}
