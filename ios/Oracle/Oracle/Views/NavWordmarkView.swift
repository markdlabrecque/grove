import SwiftUI

/// Shared navigation-bar wordmark used across the three main tabs (§3.2).
///
/// ## Usage
///
/// Add to any `NavigationStack` body via `.toolbar`:
///
/// ```swift
/// .toolbar {
///   ToolbarItem(placement: .topBarTrailing) {
///     NavWordmarkView()
///   }
/// }
/// ```
///
/// On the Settings tab, pass `text:` to replace "GROVE" with the build
/// version string (same typographic style, per spec §3.2):
///
/// ```swift
/// NavWordmarkView(text: "v\(viewModel.appVersion)")
/// ```
///
/// ## Design rationale (#323)
///
/// Spec §3.2 places an 11pt uppercase semibold `forest500` wordmark to the
/// right of the nav title.  Three implementation paths were considered:
///
/// 1. `.toolbar { ToolbarItem(placement: .principal) }` — custom HStack of
///    title + wordmark.  Loses the native large-title animation on scroll.
///
/// 2. `UINavigationBarAppearance` with a custom title view — UIKit bridge,
///    fragile across iOS releases.
///
/// 3. `.toolbar { ToolbarItem(placement: .topBarTrailing) }` — wordmark in the
///    top-right trailing slot.  Large-title animation is fully preserved because
///    SwiftUI only manages the title portion; the trailing item scrolls with the
///    bar chrome as expected.  This matches the mockup and is the safest option.
///
/// Option 3 is used here.
struct NavWordmarkView: View {
  /// The label to display. Defaults to "GROVE" per spec §3.2.
  var text: String = "GROVE"

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .tracking(1.3)
      .foregroundStyle(Color.forest500)
      .accessibilityHidden(true)
  }
}

#Preview {
  NavigationStack {
    Color.paper
      .ignoresSafeArea()
      .navigationTitle("Ask")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavWordmarkView()
        }
      }
  }
}
