import SwiftUI

/// Capture tab — accepts text input and saves a memory locally, then syncs
/// in the background.
///
/// V1 placeholder: full implementation in ticket #61.
struct CaptureView: View {
  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)

        Text("Coming in next ticket")
          .font(.title3)
          .foregroundStyle(.secondary)

        Text("Capture implementation lands in #61.")
          .font(.footnote)
          .foregroundStyle(.tertiary)
      }
      .padding()
      .navigationTitle("Save")
    }
  }
}

#Preview {
  CaptureView()
}
