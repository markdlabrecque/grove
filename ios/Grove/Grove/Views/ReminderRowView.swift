import SwiftUI

/// Renders a single `ReminderListItem` row in the Tasks tab.
///
/// TODO(#438): implement title, due date, list name display and row tap.
struct ReminderRowView: View {
  let item: ReminderListItem

  var body: some View {
    Text(item.title)
  }
}
