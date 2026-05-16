import SwiftUI

// MARK: - DictationResumeBanner

/// A persistent banner shown when dictation was interrupted mid-session (e.g.
/// the app was backgrounded), leaving a partial transcript as a draft.
///
/// Pinned in the same banner slot as ``AuthRequiredBanner`` in ``RootView``.
/// When both banners are active, ``AuthRequiredBanner`` is shown above this one
/// because authentication failure is more urgent.
///
/// ## Interaction
///
/// - **Resume**: re-presents ``DictationCaptureView`` with the partial
///   transcript pre-filled.  The mic is NOT auto-armed — the user decides
///   whether to record more or just save what they have.
/// - **Dismiss (×)**: discards the partial transcript.
///
/// ## Duration display
///
/// The banner copies the Voice Memos pattern: _"Unfinished dictation — 12 s"_.
/// `DictationDraft.approximateDuration` provides the seconds figure; if zero,
/// only _"Unfinished dictation"_ is shown.
///
/// ## Non-destructive property
///
/// The banner and the resume sheet operate independently from any text already
/// in the Save tab editor.  The draft is in-memory only (V1).
///
/// ## Accessibility
///
/// - Banner is announced as a whole with a combined label for VoiceOver.
/// - The dismiss button has an explicit `accessibilityLabel`.
struct DictationResumeBanner: View {
  let draft: DictationDraft
  let onResume: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "mic.fill")
        .foregroundStyle(.white)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(bannerTitle)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)

        Text("Tap to resume editing before saving")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.9))
          .lineLimit(2)
      }

      Spacer()

      // Resume button
      Button(action: onResume) {
        Text("Resume")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.white.opacity(0.2))
          .clipShape(Capsule())
      }
      .accessibilityLabel("Resume dictation")
      .buttonStyle(.plain)

      // Dismiss button
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.8))
      }
      .accessibilityLabel("Dismiss unfinished dictation")
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color.forest700)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
    .accessibilityAddTraits(.isButton)
  }

  // MARK: - Helpers

  private var bannerTitle: String {
    if draft.approximateDuration > 0 {
      let seconds = Int(draft.approximateDuration.rounded())
      return "Unfinished dictation — \(seconds) s"
    }
    return "Unfinished dictation"
  }

  private var accessibilityDescription: String {
    "Unfinished dictation. \(draft.transcript.prefix(60)). Tap Resume to edit or save, or dismiss to discard."
  }
}

#Preview {
  VStack {
    DictationResumeBanner(
      draft: DictationDraft(transcript: "This is a partial transcript.", approximateDuration: 12),
      onResume: {},
      onDismiss: {}
    )
    Spacer()
  }
}
