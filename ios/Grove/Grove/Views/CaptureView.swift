import SwiftUI
import GroveCore

/// Capture tab — accepts text input and sends it to POST /v1/captures.
///
/// State and networking are owned by `CaptureViewModel`; this view is
/// intentionally thin. The Save button is disabled while content is empty
/// (after trimming) or a request is in flight. Field is not cleared on failure
/// so the user can retry without retyping.
///
/// # Capture polish (#187)
///
/// Two quality-of-life affordances are shown below the text editor:
///
///   - **Char/token count chip**: updates on every keystroke using the
///     `max(1, chars / 4)` heuristic.
///   - **Detected-language chip**: shows the BCP-47 language code detected by
///     `NLLanguageRecognizer`, debounced at 200 ms. Hidden when detection
///     returns undetermined.
///
/// Filler-word cleanup is now a Settings-only control (#335). The Save action
/// silently reads the persisted `@AppStorage(SettingsViewModel.fillerWordCleanupKey)`
/// value at save time — no per-capture toggle is shown here.
///
/// # V2 forest-green (#320)
///
/// Editor card uses `card` surface with `hairline` border, 18pt radius, subtle
/// drop shadow, and a `leaf.fill` accent in the corner. Save button uses the
/// `forest500 → forest700` gradient with `paper` foreground. Chips use tonal
/// (sage200) and outline styles per spec §3.4.
struct CaptureView: View {
  @State private var viewModel = CaptureViewModel()
  @FocusState private var isFocused: Bool
  @Environment(\.colorScheme) private var colorScheme

  // Filler-word cleanup preference — read from the shared Settings key at
  // save time (#335). No toggle shown here; controlled via Settings only.
  @AppStorage(SettingsViewModel.fillerWordCleanupKey) private var fillerCleanupEnabled: Bool = false

  // Language hint from Settings (optional BCP-47 code, e.g. "en").
  @AppStorage(SettingsViewModel.languageHintKey) private var languageHint: String = ""

  var body: some View {
    NavigationStack {
      ZStack {
        // App background — warm paper.
        Color.paper
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { isFocused = false }

        VStack(spacing: 16) {
          // MARK: Editor card (§3.3)
          editorCard

          // MARK: Metadata row — char/token count + language chip
          metadataRow

          // MARK: Save button (§3.6)
          saveButton

          statusArea

          Spacer()
        }
        .padding()
      }
      .navigationTitle("Save")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavWordmarkView()
        }
      }
    }
    .alert("Could Not Save", isPresented: $viewModel.showErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(viewModel.errorMessage)
    }
  }

  // MARK: - Editor card (§3.3)

  private var editorCard: some View {
    ZStack(alignment: .topTrailing) {
      // Card surface
      VStack {
        TextEditor(text: $viewModel.content)
          .frame(minHeight: 140, maxHeight: 260)
          .scrollContentBackground(.hidden)
          .background(Color.clear)
          .focused($isFocused)
          .accessibilityLabel("Capture text")
          .accessibilityHint("Type your thought here")
      }
      .padding(18)
      .background(Color.card)
      .clipShape(RoundedRectangle(cornerRadius: 18))
      .overlay(
        RoundedRectangle(cornerRadius: 18)
          .strokeBorder(Color.hairline, lineWidth: 1)
      )
      // Subtle drop shadow per spec §3.3.
      .shadow(color: Color(red: 0.08, green: 0.15, blue: 0.11).opacity(0.07), radius: 24, x: 0, y: 8)
      .shadow(color: Color(red: 0.08, green: 0.15, blue: 0.11).opacity(0.05), radius: 2, x: 0, y: 1)

      // Leaf accent — top-right corner.
      Image(systemName: "leaf.fill")
        .font(.system(size: 22))
        .foregroundStyle(Color.sage300.opacity(0.65))
        .padding(.top, 14)
        .padding(.trailing, 14)
        .accessibilityHidden(true)
    }
  }

  // MARK: - Metadata row (§3.4 chips)

  @ViewBuilder
  private var metadataRow: some View {
    HStack(spacing: 8) {
      // Char / token count — outline chip style.
      outlineChip(
        label: "\(viewModel.charCount) chars · ~\(viewModel.tokenCount) tokens",
        icon: "textformat.size"
      )
      .accessibilityLabel("\(viewModel.charCount) characters, approximately \(viewModel.tokenCount) tokens")

      Spacer()

      // Language chip — tonal sage style, only shown when detection has a result.
      if let lang = viewModel.detectedLanguage {
        tonalSageChip(label: lang, icon: "globe")
          .accessibilityLabel("Detected language: \(lang)")
      }
    }
  }

  // MARK: - Save button (§3.6)

  private var saveButton: some View {
    Button(action: {
      isFocused = false
      let cleanup = fillerCleanupEnabled
      let hint = languageHint.isEmpty ? nil : languageHint
      Task { await viewModel.save(applyFillerCleanup: cleanup, languageHint: hint) }
    }) {
      Label("Save", systemImage: "arrow.up.circle.fill")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color.paper)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }
    .background(
      LinearGradient(
        colors: [Color.forest500, Color.forest700],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: 16))
    // Shadow only in light mode per spec §3.6 — against a dark surface the
    // same colour renders as a green glow, which the spec explicitly avoids.
    .shadow(
      color: colorScheme == .light
        ? Color(red: 0.16, green: 0.29, blue: 0.22).opacity(0.55)
        : .clear,
      radius: 24, x: 0, y: 8
    )
    .disabled(!viewModel.isSaveEnabled)
    .accessibilityLabel("Save capture")
    .accessibilityHint("Saves your capture to Grove")
  }

  // MARK: - Status area

  @ViewBuilder
  private var statusArea: some View {
    switch viewModel.saveStatus {
    case .idle:
      EmptyView()

    case .loading:
      ProgressView()
        .tint(.forest500)
        .accessibilityLabel("Saving")

    case .success:
      Label("Saved", systemImage: "checkmark.circle.fill")
        .foregroundStyle(Color.moss400)
        .accessibilityLabel("Saved successfully")

    case .failure:
      EmptyView()
    }
  }

  // MARK: - Chip helpers (§3.4)

  /// Outline chip: `card` bg, `hairline` border, `ink700` text.
  private func outlineChip(label: String, icon: String) -> some View {
    Label(label, systemImage: icon)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(Color.ink700)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(Color.card)
      .clipShape(Capsule())
      .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
  }

  /// Tonal sage chip: `sage200` bg, no border, `forest800` text.
  private func tonalSageChip(label: String, icon: String) -> some View {
    Label(label, systemImage: icon)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(Color.forest800)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(Color.sage200)
      .clipShape(Capsule())
  }
}

#Preview {
  CaptureView()
}
