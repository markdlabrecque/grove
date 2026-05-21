import SwiftUI

/// Renders a single `ReminderListItem` row in the Tasks tab (#438).
///
/// Shows the reminder's title, optional due date (relative when near,
/// absolute when far), and the source list name separated by a middle dot.
///
/// A leading circle glyph provides visual confirmation the reminder is
/// incomplete. The row body is tappable via the `onTap` closure — the caller
/// opens the Reminders.app deep-link.
///
/// ## Accessibility
///
/// The combined accessibility element presents title + due date + list name
/// as a single statement. The leading circle glyph is decorative (`accessibilityHidden`).
///
/// ## Provenance badge
///
/// The trailing badge area is reserved for the provenance affordance added
/// in Part 3 (#439). In V1 (this ticket) the trailing space is empty.
struct ReminderRowView: View {
  let item: ReminderListItem
  var onTap: (() -> Void)? = nil

  var body: some View {
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

        // Trailing area reserved for provenance badge (#439).
        // Empty in V1.
      }
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Double-tap to open in Reminders")
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
      )
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
