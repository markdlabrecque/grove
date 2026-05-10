import SwiftUI

/// Ask tab — accepts a natural-language query and displays a synthesised
/// answer grounded in captured memories.
///
/// V1 placeholder: full implementation in ticket #62.
struct QueryView: View {
  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)

        Text("Coming in next ticket")
          .font(.title3)
          .foregroundStyle(.secondary)

        Text("Retrieval implementation lands in #62.")
          .font(.footnote)
          .foregroundStyle(.tertiary)
      }
      .padding()
      .navigationTitle("Ask")
    }
  }
}

#Preview {
  QueryView()
}
