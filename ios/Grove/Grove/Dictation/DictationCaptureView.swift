import SwiftUI

// MARK: - DictationCaptureView

/// A minimal sheet for Action Button dictation capture.
///
/// ## Flow
///
/// 1. View appears with mic pre-armed (``DictationCaptureViewModel/startDictation()``
///    called in `onAppear`).
/// 2. Partial transcripts stream into the live text area.
/// 3. User taps **Stop** (or 3-second trailing-silence auto-stop fires) →
///    transcript becomes editable.
/// 4. User taps **Save** → capture persisted via the existing
///    ``CaptureViewModel/save(applyFillerCleanup:languageHint:)`` pipeline.
///
/// ## Permission denial
///
/// If mic or speech recognition permission is denied, a clear error state is
/// shown with an "Open Settings" button deep-linking to `UIApplication.openSettingsURLString`.
///
/// ## Resume mode
///
/// When initialised with `initialTranscript`, the mic is NOT auto-armed.
/// A prominent **Record again** button lets the user re-arm if needed.
/// This matches the banner-resume flow from ``DictationResumeBanner``.
///
/// ## Accessibility
///
/// The pulsing dot is hidden from VoiceOver; the recording state is announced
/// via `accessibilityLabel` on the transcript area.  All text scales with
/// Dynamic Type.
struct DictationCaptureView: View {

  // MARK: - State

  @State private var viewModel = DictationCaptureViewModel()
  @FocusState private var transcriptFocused: Bool
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase

  // Optional initial transcript for resume mode.
  private let initialTranscript: String?

  // Filler-word preference shared with CaptureView.
  @AppStorage(SettingsViewModel.fillerWordCleanupKey) private var fillerCleanupEnabled: Bool = false
  @AppStorage(SettingsViewModel.languageHintKey) private var languageHint: String = ""

  // MARK: - Init

  /// Creates the view.
  ///
  /// - Parameter initialTranscript: Pre-filled text for resumed dictation.
  ///   Pass `nil` (default) when opening fresh from the Action Button intent;
  ///   the mic is armed immediately.  Pass a non-nil value when resuming from
  ///   the ``DictationResumeBanner`` — the mic is NOT auto-armed.
  init(initialTranscript: String? = nil) {
    self.initialTranscript = initialTranscript
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      ZStack {
        Color.paper.ignoresSafeArea()

        VStack(spacing: 20) {
          recordingIndicator

          transcriptArea

          controlRow

          if viewModel.isSaveEnabled {
            saveButton
          }

          statusArea

          Spacer()
        }
        .padding()
      }
      .navigationTitle("Dictate")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .foregroundStyle(Color.forest500)
        }
      }
    }
    .alert("Could Not Save", isPresented: $viewModel.showErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(viewModel.errorMessage)
    }
    .task {
      if let text = initialTranscript, !text.isEmpty {
        // Resume mode — pre-fill transcript without arming the mic.
        viewModel.resume(from: DictationDraft(transcript: text))
      } else if viewModel.recordingState == .idle {
        // Fresh mode — arm mic immediately.  The idle check prevents a
        // second .task invocation (e.g. scene re-appearance) from firing
        // startDictation() again and wiping an in-progress transcript.
        // startDictation() also has its own re-entry guard as defence-in-depth.
        await viewModel.startDictation()
      }
    }
    .onChange(of: viewModel.saveStatus) { _, newValue in
      if case .success = newValue {
        Task {
          try? await Task.sleep(for: .milliseconds(800))
          dismiss()
        }
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      // When the app moves to the background during an active recording (or
      // while a non-empty partial transcript exists), capture a draft and
      // notify RootView so it can surface the DictationResumeBanner.
      if newPhase == .background {
        if let draft = viewModel.makeDraftIfNeeded() {
          NotificationCenter.default.post(
            name: .dictationDraftAvailable,
            object: nil,
            userInfo: [dictationDraftUserInfoKey: draft]
          )
        }
      }
    }
  }

  // MARK: - Recording indicator

  @ViewBuilder
  private var recordingIndicator: some View {
    switch viewModel.recordingState {
    case .recording:
      PulsingDotView()
        .accessibilityHidden(true)
    case .requesting:
      ProgressView()
        .tint(.forest500)
        .accessibilityLabel("Requesting permissions")
    default:
      EmptyView()
    }
  }

  // MARK: - Transcript area

  @ViewBuilder
  private var transcriptArea: some View {
    switch viewModel.recordingState {
    case .permissionDenied(let err):
      permissionDeniedView(error: err)

    case .error(let err):
      errorView(error: err)

    default:
      ZStack(alignment: .topLeading) {
        if viewModel.transcript.isEmpty && viewModel.recordingState == .recording {
          Text("Listening…")
            .font(.body)
            .foregroundStyle(Color.ink300)
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 0, trailing: 0))
            .accessibilityHidden(true)
        }

        TextEditor(text: $viewModel.transcript)
          .frame(minHeight: 140, maxHeight: 260)
          .scrollContentBackground(.hidden)
          .background(Color.clear)
          .focused($transcriptFocused)
          .disabled(viewModel.recordingState == .recording || viewModel.recordingState == .requesting)
          .accessibilityLabel(
            viewModel.recordingState == .recording
              ? "Live transcript. \(viewModel.transcript.isEmpty ? "Listening." : viewModel.transcript)"
              : "Transcript. Edit before saving."
          )
      }
      .padding(18)
      .background(Color.card)
      .clipShape(RoundedRectangle(cornerRadius: 18))
      .overlay(
        RoundedRectangle(cornerRadius: 18)
          .strokeBorder(
            viewModel.recordingState == .recording ? Color.forest500 : Color.hairline,
            lineWidth: viewModel.recordingState == .recording ? 2 : 1
          )
      )
      .shadow(color: Color(red: 0.08, green: 0.15, blue: 0.11).opacity(0.07), radius: 24, x: 0, y: 8)
    }
  }

  // MARK: - Control row

  @ViewBuilder
  private var controlRow: some View {
    switch viewModel.recordingState {
    case .recording:
      stopButton

    case .stopped:
      HStack(spacing: 12) {
        // Re-record: discards current transcript and arms mic again.
        Button {
          Task { await viewModel.startDictation() }
        } label: {
          Label("Record again", systemImage: "mic.fill")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.forest500)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.card)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.forest500, lineWidth: 1))
        }
        .accessibilityLabel("Record again")
        .accessibilityHint("Discards the current transcript and starts a new recording")
      }

    case .idle, .requesting, .permissionDenied, .error:
      EmptyView()
    }
  }

  // MARK: - Stop button

  private var stopButton: some View {
    Button {
      viewModel.stopDictation()
    } label: {
      Label("Stop", systemImage: "stop.fill")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color.paper)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }
    .background(Color.destructive)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .accessibilityLabel("Stop dictation")
    .accessibilityHint("Stops recording and makes the transcript editable")
  }

  // MARK: - Save button

  private var saveButton: some View {
    Button {
      transcriptFocused = false
      let cleanup = fillerCleanupEnabled
      let hint = languageHint.isEmpty ? nil : languageHint
      Task { await viewModel.save(applyFillerCleanup: cleanup, languageHint: hint) }
    } label: {
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
    .shadow(
      color: colorScheme == .light
        ? Color(red: 0.16, green: 0.29, blue: 0.22).opacity(0.55)
        : .clear,
      radius: 24, x: 0, y: 8
    )
    .disabled(!viewModel.isSaveEnabled)
    .accessibilityLabel("Save capture")
    .accessibilityHint("Saves the dictated text to Grove")
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

  // MARK: - Permission denied

  private func permissionDeniedView(error: DictationError) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "mic.slash.fill")
        .font(.system(size: 44))
        .foregroundStyle(Color.destructive)
        .accessibilityHidden(true)

      Text(error.errorDescription ?? "Permission denied.")
        .font(.body)
        .foregroundStyle(Color.ink700)
        .multilineTextAlignment(.center)

      Button {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      } label: {
        Label("Open Settings", systemImage: "gear")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color.paper)
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
          .background(Color.forest500)
          .clipShape(Capsule())
      }
      .accessibilityLabel("Open Settings")
      .accessibilityHint("Opens iOS Settings so you can grant microphone or speech recognition access")
    }
    .padding()
    .background(Color.card)
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .overlay(
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(Color.hairline, lineWidth: 1)
    )
  }

  // MARK: - Error

  private func errorView(error: DictationError) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 36))
        .foregroundStyle(Color.amber)
        .accessibilityHidden(true)

      Text(error.errorDescription ?? "An error occurred.")
        .font(.body)
        .foregroundStyle(Color.ink700)
        .multilineTextAlignment(.center)

      Button {
        Task { await viewModel.startDictation() }
      } label: {
        Text("Try again")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color.forest500)
      }
      .accessibilityLabel("Try again")
      .accessibilityHint("Attempts to start dictation again")
    }
    .padding()
    .background(Color.card)
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .overlay(
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(Color.hairline, lineWidth: 1)
    )
  }
}

// MARK: - PulsingDotView

/// A simple pulsing circle that indicates active recording.
///
/// Intentionally minimal — no waveform analysis required.
private struct PulsingDotView: View {
  @State private var pulsing = false

  var body: some View {
    Circle()
      .fill(Color.destructive)
      .frame(width: 14, height: 14)
      .scaleEffect(pulsing ? 1.35 : 1.0)
      .opacity(pulsing ? 0.7 : 1.0)
      .animation(
        .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
        value: pulsing
      )
      .onAppear { pulsing = true }
  }
}

#Preview {
  DictationCaptureView()
}

#Preview("Resume mode") {
  DictationCaptureView(initialTranscript: "This is a partial transcript from a previous session.")
}
