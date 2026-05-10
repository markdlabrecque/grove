import SwiftUI

/// Application root: a two-tab shell containing the Save (capture) and Ask
/// (retrieval) tabs. Placeholder content in both tabs lands in #61 and #62.
struct RootView: View {
  var body: some View {
    TabView {
      CaptureView()
        .tabItem {
          Label("Save", systemImage: "square.and.pencil")
        }

      QueryView()
        .tabItem {
          Label("Ask", systemImage: "magnifyingglass")
        }
    }
  }
}

#Preview {
  RootView()
}
