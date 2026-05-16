import SwiftUI
import OracleCore

/// Detail view for a single memory source result.
///
/// Shown when the user taps a source card in the Ask results list. Displays
/// the full memory content, capture metadata, and a Delete button.
///
/// ## Delete flow
///
/// Tapping Delete shows a confirmation alert. On confirm the view calls
/// `DELETE /v1/memories/{id}` via `MemoryDetailViewModel`. On success the
/// view dismisses and the parent's `onDeleteSuccess` callback removes the
/// source from the visible Ask results list.
///
/// ## Navigation
///
/// Presented from `SourceCardRow` inside `QueryView`'s `NavigationStack` —
/// via either the leading swipe action (which appends a typed `QueryResult`
/// value to the stack's `NavigationPath`) or the expanded-footer
/// `NavigationLink` closure. The back button returns to the Ask results list
/// without any side-effect.
struct MemoryDetailView: View {
  @State private var viewModel: MemoryDetailViewModel
  @Environment(\.dismiss) private var dismiss

  init(result: QueryResult, onDeleteSuccess: @escaping (UUID) -> Void) {
    _viewModel = State(initialValue: MemoryDetailViewModel(
      result: result,
      onDeleteSuccess: onDeleteSuccess
    ))
  }

  /// Testing initialiser — accepts a pre-configured ViewModel.
  init(viewModel: MemoryDetailViewModel) {
    _viewModel = State(initialValue: viewModel)
  }

  // MARK: - Formatters

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  // MARK: - Body

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        contentSection
        metadataSection
        Spacer(minLength: 32)
        deleteSection
      }
      .padding()
    }
    .navigationTitle("Memory")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .destructiveAction) {
        if viewModel.isDeleting {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Deleting memory")
        }
      }
    }
    .alert("Delete Memory", isPresented: $viewModel.isShowingDeleteConfirmation) {
      Button("Delete", role: .destructive) {
        Task { await viewModel.confirmDelete() }
      }
      Button("Cancel", role: .cancel) {
        viewModel.cancelDelete()
      }
    } message: {
      Text("This memory will be permanently deleted from your Oracle. This cannot be undone.")
    }
    .alert("Delete Failed", isPresented: Binding(
      get: { viewModel.deleteError != nil },
      set: { if !$0 { viewModel.deleteError = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(viewModel.deleteError ?? "")
    }
    .onChange(of: viewModel.isDismissed) { _, dismissed in
      if dismissed { dismiss() }
    }
  }

  // MARK: - Content section

  private var contentSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Content")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .accessibilityHidden(true)

      Text(viewModel.result.excerpt)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Memory content: \(viewModel.result.excerpt)")
    }
  }

  // MARK: - Metadata section

  private var metadataSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Details")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 8) {
        // Capture date
        if let capturedAt = viewModel.result.capturedAt {
          metadataRow(
            label: "Captured",
            value: Self.dateFormatter.string(from: capturedAt)
          )
        }

        // Source modality
        if let modality = viewModel.result.sourceModality {
          metadataRow(
            label: "Source",
            value: modality.capitalized
          )
        }

        // Match type
        metadataRow(
          label: "Match",
          value: matchDescription
        )

        // Similarity score
        metadataRow(
          label: "Relevance",
          value: String(format: "%.0f%%", viewModel.result.score * 100)
        )
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }

  private var matchDescription: String {
    if viewModel.result.matchedVia == "chunk", let idx = viewModel.result.matchedChunkIndex {
      return "Chunk \(idx)"
    }
    return "Full memory"
  }

  private func metadataRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(width: 80, alignment: .leading)

      Text(value)
        .font(.subheadline)
        .foregroundStyle(.primary)

      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label): \(value)")
  }

  // MARK: - Delete section

  private var deleteSection: some View {
    VStack(spacing: 8) {
      Button(role: .destructive) {
        viewModel.requestDelete()
      } label: {
        Label("Delete Memory", systemImage: "trash")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .tint(.red)
      .disabled(viewModel.isDeleting)
      .accessibilityLabel("Delete this memory")
      .accessibilityHint("Double-tap to permanently delete this memory")
    }
  }
}

#Preview {
  NavigationStack {
    MemoryDetailView(
      result: QueryResult(
        memoryID: UUID(),
        score: 0.92,
        matchedVia: "whole",
        matchedChunkIndex: nil,
        excerpt: "Remember to buy oat milk and call Theo about the upcoming demo next Thursday afternoon.",
        capturedAt: Date(timeIntervalSince1970: 1_778_423_400),
        sourceModality: "text"
      ),
      onDeleteSuccess: { _ in }
    )
  }
}
