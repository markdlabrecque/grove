import SwiftUI

/// Renders a single `ReminderListItem` row in the Tasks tab (#438, #439).
///
/// Shows the reminder's title, optional due date (relative when near,
/// absolute when far), and the source list name separated by a middle dot.
///
/// A leading circle glyph provides visual confirmation the reminder is
/// incomplete. The row body is tappable via the `onTap` closure — the caller
/// opens the Reminders.app deep-link.
///
/// ## Provenance badge (R3.3, R3.4)
///
/// When `memoryID` is non-nil, a leaf-icon badge appears on the trailing edge.
/// The badge is a separate tap target (distinct from the row body) that calls
/// `onBadgeTap` with the memory UUID. The caller navigates to `MemoryDetailView`.
/// When `memoryID` is nil, the badge area is empty and the row renders identically
/// to a non-Grove row.
///
/// ## Accessibility
///
/// The row body is a combined accessibility element presenting title + due date +
/// list name. The badge is a separate accessibility element with label
/// "View source memory in Grove".
struct ReminderRowView: View {
  let item: ReminderListItem
  /// Non-nil when this reminder originated from a Grove capture.
  /// Drives the provenance badge (R3.3).
  var memoryID: UUID? = nil
  var onTap: (() -> Void)? = nil
  /// Called with the memory UUID when the Grove badge is tapped (R3.4).
  var onBadgeTap: ((UUID) -> Void)? = nil

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Row body button — opens Reminders.app.
      Button {
        onTap?()
      } label: {
        HStack(alignment: .top, spacing: 10) {
          // Incomplete indicator — visual only (non-interactive per spec).
          Image(systemName: "circle")
            .foregroundStyle(Color.ink300)
            .font(.body)
            .frame(width: 20, alignment: .center)
            .padding(.top, 2)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
              .font(.subheadline)
              .foregroundStyle(Color.ink900)
              .lineLimit(2)
              .multilineTextAlignment(.leading)

            HStack(spacing: 4) {
              if let dueDate = item.dueDate {
                Text(formattedDueDate(dueDate))
                  .font(.caption)
                  .foregroundStyle(dueDateColor(dueDate))
                Text("·")
                  .font(.caption)
                  .foregroundStyle(Color.ink300)
              }

              Text(item.listName)
                .font(.caption)
                .foregroundStyle(Color.ink500)
            }
          }

          Spacer(minLength: 4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint("Double-tap to open in Reminders")

      // Trailing provenance badge — separate tap target (R3.4).
      if let id = memoryID {
        Button {
          onBadgeTap?(id)
        } label: {
          HStack(spacing: 2) {
            Image(systemName: "leaf.fill")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.forest500)
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Color.ink300)
          }
          .padding(.vertical, 6)
          .padding(.leading, 4)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View source memory in Grove")
        .accessibilityHint("Double-tap to open the Grove memory that created this reminder")
      }
    }
  }

  // MARK: - Due date formatting

  /// Formats a due date. Dates within the next 6 days use the relative
  /// `.dateTime` style (e.g. "Tomorrow", "In 3 days"); further dates use
  /// an abbreviated absolute format (e.g. "Jun 5").
  private func formattedDueDate(_ date: Date) -> String {
    let daysAway = Calendar.current.dateComponents([.day], from: .now, to: date).day ?? 0
    if daysAway >= 0 && daysAway <= 6 {
      return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    } else {
      return date.formatted(.dateTime.month(.abbreviated).day())
    }
  }

  /// Overdue dates render in red; due today in orange; future dates use ink500.
  private func dueDateColor(_ date: Date) -> Color {
    let daysAway = Calendar.current.dateComponents([.day], from: .now, to: date).day ?? 0
    if daysAway < 0 { return .red }
    if daysAway == 0 { return Color.orange }
    return Color.ink500
  }

  // MARK: - Accessibility label

  private var accessibilityLabel: String {
    var parts = [item.title]
    if let dueDate = item.dueDate {
      parts.append("Due \(formattedDueDate(dueDate))")
    }
    parts.append(item.listName)
    if memoryID != nil {
      parts.append("Grove task")
    }
    return parts.joined(separator: ". ")
  }
}

#Preview {
  List {
    ReminderRowView(
      item: ReminderListItem(
        id: "1",
        title: "Call Theo about the upcoming demo",
        dueDate: Date().addingTimeInterval(86_400),
        listName: "Work"
      ),
      memoryID: UUID(),
      onBadgeTap: { _ in }
    )
    ReminderRowView(
      item: ReminderListItem(
        id: "2",
        title: "Buy oat milk",
        dueDate: nil,
        listName: "Personal"
      )
    )
    ReminderRowView(
      item: ReminderListItem(
        id: "3",
        title: "Overdue task",
        dueDate: Date().addingTimeInterval(-86_400),
        listName: "Personal"
      )
    )
  }
  .listStyle(.plain)
}
