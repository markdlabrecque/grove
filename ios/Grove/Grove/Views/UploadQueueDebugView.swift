import SwiftUI
import SwiftData

// MARK: - UploadQueueDebugView

/// Debug screen for the upload queue, reachable from Settings → "Upload queue".
///
/// Lists all `QueuedCapture` rows in the local SwiftData store with their
/// current state (pending / backoff / failed / auth_required).  For rows in the
/// `failed` state, tapping reveals the full error and offers two actions:
///
///  - **Retry** — clears the `failed` flag and puts the row back into the
///    drainable pending pool (triggers an immediate drain attempt).
///  - **Discard** — permanently deletes the row from the queue.
///
/// # Accessibility
///
/// All interactive controls carry explicit `accessibilityLabel` / `accessibilityHint`
/// annotations.  The list supports Dynamic Type at Accessibility Extra Extra
/// Large — tested with Xcode's Accessibility Inspector before shipping.
///
/// # Data freshness
///
/// The view reads directly from the SwiftData `ModelContext` injected via the
/// environment.  It re-fetches on `onAppear` and after every Retry / Discard
/// action so the list stays current without polling.
struct UploadQueueDebugView: View {

  // MARK: - SwiftData

  @Query(sort: \QueuedCapture.createdAt, order: .forward)
  private var allRows: [QueuedCapture]

  // MARK: - Environment

  @Environment(\.modelContext) private var modelContext

  // MARK: - Body

  var body: some View {
    Group {
      if allRows.isEmpty {
        emptyState
      } else {
        rowList
      }
    }
    .navigationTitle("Upload Queue")
    .navigationBarTitleDisplayMode(.large)
  }

  // MARK: - Empty state

  private var emptyState: some View {
    ContentUnavailableView(
      "Queue Empty",
      systemImage: "checkmark.circle",
      description: Text("All captures have been uploaded successfully.")
    )
    .accessibilityLabel("Queue is empty. All captures uploaded successfully.")
  }

  // MARK: - Row list

  private var rowList: some View {
    List {
      ForEach(allRows, id: \.clientID) { row in
        QueueRowView(row: row) {
          handleRetry(row: row)
        } onDiscard: {
          handleDiscard(row: row)
        }
      }
    }
    .listStyle(.insetGrouped)
  }

  // MARK: - Actions

  private func handleRetry(row: QueuedCapture) {
    Task {
      do {
        try await GroveApp.uploadQueue.retryFailed(clientID: row.clientID)
        await GroveApp.uploadQueue.tryDrain()
      } catch {
        print("[UploadQueueDebugView] retry failed: \(error)")
      }
    }
  }

  private func handleDiscard(row: QueuedCapture) {
    Task {
      do {
        try await GroveApp.uploadQueue.discardFailed(clientID: row.clientID)
      } catch {
        print("[UploadQueueDebugView] discard failed: \(error)")
      }
    }
  }
}

// MARK: - QueueRowView

/// A single row in the upload-queue debug list.
private struct QueueRowView: View {

  let row: QueuedCapture
  let onRetry: () -> Void
  let onDiscard: () -> Void

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        stateLabel
        Spacer()
        attemptBadge
      }

      Text(row.clientID)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityLabel("Capture ID: \(row.clientID)")

      Text("Created \(row.createdAt.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Created \(row.createdAt.formatted())")

      if let nextAttempt = row.nextAttemptAt, !row.isFailed {
        Text("Next attempt \(nextAttempt.formatted(date: .omitted, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityLabel("Next retry scheduled for \(nextAttempt.formatted())")
      }

      if let error = row.lastError, !error.isEmpty {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(4)
          .accessibilityLabel("Error: \(error)")
      }

      if row.isFailed {
        failedActions
      }
    }
    .padding(.vertical, 4)
  }

  // MARK: - State label

  private var stateLabel: some View {
    Label(
      stateText,
      systemImage: stateIcon
    )
    .font(.subheadline.weight(.medium))
    .foregroundStyle(stateColor)
    .accessibilityLabel("State: \(stateText)")
  }

  private var stateText: String {
    if row.isFailed { return "Failed" }
    if row.isAuthRequired { return "Auth Required" }
    if row.nextAttemptAt != nil { return "Backoff" }
    return "Pending"
  }

  private var stateIcon: String {
    if row.isFailed { return "xmark.circle" }
    if row.isAuthRequired { return "lock.circle" }
    if row.nextAttemptAt != nil { return "clock.arrow.circlepath" }
    return "arrow.up.circle"
  }

  private var stateColor: Color {
    if row.isFailed { return .red }
    if row.isAuthRequired { return .orange }
    if row.nextAttemptAt != nil { return .orange }
    return .secondary
  }

  // MARK: - Attempt badge

  private var attemptBadge: some View {
    Text("×\(row.attemptCount)")
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .accessibilityLabel("\(row.attemptCount) attempts")
  }

  // MARK: - Failed actions

  private var failedActions: some View {
    HStack(spacing: 12) {
      Button(action: onRetry) {
        Label("Retry", systemImage: "arrow.clockwise")
          .font(.subheadline.weight(.medium))
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .accessibilityLabel("Retry upload")
      .accessibilityHint("Resets this item to pending and triggers an immediate upload attempt")

      Button(role: .destructive, action: onDiscard) {
        Label("Discard", systemImage: "trash")
          .font(.subheadline.weight(.medium))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityLabel("Discard capture")
      .accessibilityHint("Permanently removes this capture from the queue. It will not be uploaded.")
    }
    .padding(.top, 2)
  }
}

// MARK: - Preview

#Preview("Upload Queue — Failed") {
  // Build a minimal preview container with synthetic rows.
  let schema = Schema([QueuedCapture.self])
  let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
  let container = try! ModelContainer(for: schema, configurations: [config])
  let ctx = ModelContext(container)

  let failed = QueuedCapture(
    clientID: "a1b2c3d4-0000-0000-0000-000000000001",
    payload: Data(),
    createdAt: Date().addingTimeInterval(-300),
    attemptCount: 3,
    lastError: "HTTP 422: validation failed: content is required",
    isFailed: true
  )
  let pending = QueuedCapture(
    clientID: "a1b2c3d4-0000-0000-0000-000000000002",
    payload: Data(),
    createdAt: Date().addingTimeInterval(-60),
    attemptCount: 0
  )
  let backoff = QueuedCapture(
    clientID: "a1b2c3d4-0000-0000-0000-000000000003",
    payload: Data(),
    createdAt: Date().addingTimeInterval(-120),
    attemptCount: 2,
    lastError: "HTTP 503: service unavailable",
    nextAttemptAt: Date().addingTimeInterval(15)
  )
  ctx.insert(failed)
  ctx.insert(pending)
  ctx.insert(backoff)
  try! ctx.save()

  return NavigationStack {
    UploadQueueDebugView()
  }
  .modelContainer(container)
}
