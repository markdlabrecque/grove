import SwiftUI
import OracleCore

/// Capture tab — accepts text input and sends it to POST /v1/captures.
///
/// State and networking are owned by `CaptureViewModel`; this view is
/// intentionally thin. The Save button is disabled while content is empty
/// (after trimming) or a request is in flight. Field is not cleared on failure
/// so the user can retry without retyping.
///
/// # Capture polish (#187)
///
/// Three quality-of-life affordances are shown below the text editor:
///
///   - **Char/token count chip**: updates on every keystroke using the
///     `max(1, chars / 4)` heuristic.
///   - **Detected-language chip**: shows the BCP-47 language code detected by
///     `NLLanguageRecognizer`, debounced at 200 ms. Hidden when detection
///     returns undetermined.
///   - **Filler-word cleanup toggle**: when on, common fillers ("um", "uh",
///     "you know", "like,") are stripped from the outgoing payload before Save.
///     The text field always shows the original typed/dictated text.
///     Persisted via `@AppStorage(SettingsViewModel.fillerWordCleanupKey)` so it
///     round-trips with the Settings screen.
struct CaptureView: View {
  @State private var viewModel = CaptureViewModel()
  @FocusState private var isFocused: Bool

  // Filler-word toggle — shared key with SettingsView (#184).
  @AppStorage(SettingsViewModel.fillerWordCleanupKey) private var fillerCleanupEnabled: Bool = false

  // Language hint from Settings (optional BCP-47 code, e.g. "en").
  @AppStorage(SettingsViewModel.languageHintKey) private var languageHint: String = ""

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        TextEditor(text: $viewModel.content)
          .frame(minHeight: 120, maxHeight: 240)
          .padding(8)
          .background(Color(.secondarySystemBackground))
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .focused($isFocused)
          .accessibilityLabel("Capture text")
          .accessibilityHint("Type your thought here")

        // MARK: Metadata row — char/token count + language chip
        metadataRow

        // MARK: Filler cleanup toggle
        fillerToggleRow

        Button(action: {
          isFocused = false
          let cleanup = fillerCleanupEnabled
          let hint = languageHint.isEmpty ? nil : languageHint
          Task { await viewModel.save(applyFillerCleanup: cleanup, languageHint: hint) }
        }) {
          Label("Save", systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!viewModel.isSaveEnabled)
        .accessibilityLabel("Save capture")
        .accessibilityHint("Saves your capture to The Oracle")

        statusArea
      }
      .padding()
      .navigationTitle("Save")
      .background(
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { isFocused = false }
      )
    }
    .alert("Could Not Save", isPresented: $viewModel.showErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(viewModel.errorMessage)
    }
  }

  // MARK: - Metadata row

  /// Inline chips showing character/token count and detected language.
  ///
  /// Both chips are small and secondary so they don't compete with the
  /// primary Save action. They use `.caption` + `.secondaryLabel` tint so
  /// they scale correctly with Dynamic Type.
  @ViewBuilder
  private var metadataRow: some View {
    HStack(spacing: 8) {
      // Char / token count chip
      Label(
        "\(viewModel.charCount) chars · ~\(viewModel.tokenCount) tokens",
        systemImage: "textformat.size"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityLabel("\(viewModel.charCount) characters, approximately \(viewModel.tokenCount) tokens")

      Spacer()

      // Language chip — only shown when detection has a result
      if let lang = viewModel.detectedLanguage {
        Label(lang, systemImage: "globe")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color(.tertiarySystemBackground))
          .clipShape(Capsule())
          .accessibilityLabel("Detected language: \(lang)")
      }
    }
  }

  // MARK: - Filler cleanup toggle row

  @ViewBuilder
  private var fillerToggleRow: some View {
    Toggle(isOn: $fillerCleanupEnabled) {
      Label("Clean up filler words", systemImage: "wand.and.stars")
        .font(.subheadline)
    }
    .toggleStyle(.switch)
    .tint(.accentColor)
    .accessibilityLabel("Filler word cleanup")
    .accessibilityHint(
      fillerCleanupEnabled
        ? "On. Words like um and uh will be removed before saving."
        : "Off. Your text will be saved as spoken."
    )
  }

  // MARK: - Status area

  @ViewBuilder
  private var statusArea: some View {
    switch viewModel.saveStatus {
    case .idle:
      EmptyView()

    case .loading:
      ProgressView()
        .accessibilityLabel("Saving")

    case .success:
      Label("Saved", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("Saved successfully")

    case .failure:
      EmptyView()
    }
  }
}

#Preview {
  CaptureView()
}
