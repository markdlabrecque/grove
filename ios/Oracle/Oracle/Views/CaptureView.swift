import SwiftUI
import OracleCore

/// Capture tab — accepts text input and sends it to POST /v1/captures.
///
/// State and networking are owned by `CaptureViewModel`; this view is
/// intentionally thin. The Save button is disabled while content is empty
/// (after trimming) or a request is in flight. Field is not cleared on failure
/// so the user can retry without retyping.
struct CaptureView: View {
  @State private var viewModel = CaptureViewModel()

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        TextEditor(text: $viewModel.content)
          .frame(minHeight: 120, maxHeight: 240)
          .padding(8)
          .background(Color(.secondarySystemBackground))
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .accessibilityLabel("Capture text")
          .accessibilityHint("Type your thought here")

        Button(action: {
          Task { await viewModel.save() }
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
    }
    .alert("Could Not Save", isPresented: $viewModel.showErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(viewModel.errorMessage)
    }
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
