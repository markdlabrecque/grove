import SwiftUI

// MARK: - AuthRequiredBanner

/// A persistent banner shown at the top of the active screen when one or more
/// captures are in the `auth_required` state (server returned 401).
///
/// Tapping the banner navigates the user to the Settings tab so they can
/// update their bearer token.  Once a valid token is committed, the upload
/// queue's `reenqueueAuthRequired(newToken:)` method re-enqueues the stuck
/// captures automatically — no additional user action is required.
///
/// # Accessibility
///
/// - `accessibilityLabel` provides a complete description for VoiceOver users
///   who may not see the icon.
/// - The banner uses `.dynamicTypeSize` without a ceiling so the text scales
///   correctly at all Dynamic Type sizes.  The layout uses `.lineLimit(2)` so
///   very large sizes wrap rather than clipping.
struct AuthRequiredBanner: View {
  /// Called when the user taps the banner.  In production, switches the tab
  /// selection to the Settings tab.  Tests inject a closure to verify the tap.
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 12) {
        Image(systemName: "lock.fill")
          .foregroundStyle(.white)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text("Authentication required")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)

          Text("Tap to update your token in Settings")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(2)
        }

        Spacer()

        Image(systemName: "chevron.right")
          .foregroundStyle(.white.opacity(0.8))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(Color.red.gradient)
      .accessibilityLabel(
        "Authentication required. One or more captures could not be uploaded because your token is invalid. Tap to update your token in Settings."
      )
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  VStack {
    AuthRequiredBanner(onTap: {})
    Spacer()
  }
}
