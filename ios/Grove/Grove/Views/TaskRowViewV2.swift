import SwiftUI
import GroveCore

/// Renders a single `TaskDTO` row in the Tasks tab (spec-02).
///
/// Replaces the legacy `TaskRowView` (which is tied to EventKit linking and
/// will be removed in Part 3, #453). This file is named `TaskRowViewV2.swift`
/// to avoid a filename collision with the legacy `TaskRowView.swift` that
/// remains on disk until Part 3.
///
/// ## Row anatomy
///
/// ```
/// Task content line, possibly two lines if long
/// Due tomorrow · @mark, @sarah
/// ```
///
/// - Task content: 1–2 lines, truncated at 2 lines.
/// - Due date: shown when present, formatted relatively when near (≤ 14 days)
///   or as an absolute date otherwise.
/// - Related people: `@name` tokens joined by ", " on the subtitle line.
///
/// ## Accessibility
///
/// All text uses Dynamic Type. The whole row is an accessibility element with
/// a combined label. No provenance badge, source-memory navigation, or
/// EventKit affordance (R2.9).
struct TaskRowViewV2: View {
  let task: TaskDTO

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(task.description)
        .font(.subheadline)
        .foregroundStyle(Color.ink900)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Task: \(task.description)")

      let subtitle = subtitleText
      if !subtitle.isEmpty {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(Color.ink500)
          .lineLimit(1)
          .accessibilityLabel(subtitleAccessibilityLabel)
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(combinedAccessibilityLabel)
  }

  // MARK: - Subtitle

  private var subtitleText: String {
    var parts: [String] = []

    if let dueDate = task.dueDate {
      parts.append(formattedDueDate(dueDate))
    }

    if let people = task.relatedPeople, !people.isEmpty {
      let peopleStr = people.map { "@\($0)" }.joined(separator: ", ")
      parts.append(peopleStr)
    }

    return parts.joined(separator: " · ")
  }

  private var subtitleAccessibilityLabel: String {
    var parts: [String] = []

    if let dueDate = task.dueDate {
      parts.append("Due \(formattedDueDate(dueDate))")
    }

    if let people = task.relatedPeople, !people.isEmpty {
      let peopleStr = people.map { "@\($0)" }.joined(separator: ", ")
      parts.append("Related people: \(peopleStr)")
    }

    return parts.joined(separator: ". ")
  }

  private var combinedAccessibilityLabel: String {
    let sub = subtitleAccessibilityLabel
    if sub.isEmpty {
      return "Task: \(task.description)"
    }
    return "Task: \(task.description). \(sub)"
  }

  // MARK: - Date formatting

  /// Format a `"YYYY-MM-DD"` server date string for display.
  ///
  /// - If the date is within 14 days of today, use a relative format
  ///   ("Due tomorrow", "Due in 3 days", "Due today").
  /// - Otherwise use a medium absolute format ("Jun 1, 2026").
  private func formattedDueDate(_ dateString: String) -> String {
    let parts = dateString.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return dateString }

    var comps = DateComponents()
    comps.year = parts[0]
    comps.month = parts[1]
    comps.day = parts[2]

    guard let dueDate = Calendar.current.date(from: comps) else { return dateString }

    let today = Calendar.current.startOfDay(for: Date())
    let due = Calendar.current.startOfDay(for: dueDate)
    let days = Calendar.current.dateComponents([.day], from: today, to: due).day ?? 0

    if days == 0 { return "Due today" }
    if days == 1 { return "Due tomorrow" }
    if days > 1 && days <= 14 { return "Due in \(days) days" }
    if days == -1 { return "Due yesterday" }
    if days < -1 && days >= -14 { return "\(abs(days)) days overdue" }

    // Absolute date for anything further out or further past.
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: dueDate)
  }
}

// MARK: - Preview

#Preview("Task with due date and people") {
  List {
    TaskRowViewV2(task: TaskDTO(
      id: UUID(),
      memoryID: UUID(),
      description: "Call Theo about the demo next Thursday",
      dueDate: {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        let comps = cal.dateComponents([.year, .month, .day], from: tomorrow)
        return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
      }(),
      status: "open",
      relatedPeople: ["Theo"]
    ))

    TaskRowViewV2(task: TaskDTO(
      id: UUID(),
      memoryID: UUID(),
      description: "Buy oat milk",
      dueDate: nil,
      status: "open",
      relatedPeople: nil
    ))

    TaskRowViewV2(task: TaskDTO(
      id: UUID(),
      memoryID: UUID(),
      description: "Review the sprint retro notes with the whole team before Friday's planning session",
      dueDate: "2026-08-15",
      status: "open",
      relatedPeople: ["mark", "sarah", "theo"]
    ))
  }
  .listStyle(.plain)
}
