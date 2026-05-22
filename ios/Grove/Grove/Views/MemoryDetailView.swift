import SwiftUI
import GroveCore

/// Detail view for a single memory source result.
///
/// Shown when the user taps a source card in the Ask results list or taps a
/// provenance badge in the Tasks tab. Fetches its own content from
/// `GET /v1/memories/{id}` on every appear — no caller-supplied excerpt is used.
///
/// ## Query context
///
/// When navigating from Ask search results, the caller passes a `QueryContext`
/// carrying relevance metadata (score, match type, chunk index). When navigating
/// from a non-search surface (e.g., the Tasks provenance badge) `queryContext`
/// is `nil` and the relevance section is hidden.
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

  /// Ask-flow relevance metadata. `nil` when navigating from a non-search surface.
  let queryContext: QueryContext?

  @Environment(\.dismiss) private var dismiss

  init(
    memoryID: UUID,
    queryContext: QueryContext? = nil,
    onDeleteSuccess: @escaping (UUID) -> Void = { _ in }
  ) {
    _viewModel = State(initialValue: MemoryDetailViewModel(
      memoryID: memoryID,
      onDeleteSuccess: onDeleteSuccess
    ))
    self.queryContext = queryContext
  }

  /// Testing initialiser — accepts a pre-configured ViewModel.
  init(viewModel: MemoryDetailViewModel, queryContext: QueryContext? = nil) {
    _viewModel = State(initialValue: viewModel)
    self.queryContext = queryContext
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
    .task {
      await viewModel.loadContent()
    }
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
      Text("This memory will be permanently deleted from Grove. This cannot be undone.")
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

      if viewModel.isFetchingContent {
        ProgressView()
          .frame(maxWidth: .infinity, alignment: .center)
          .accessibilityLabel("Loading memory content")
      } else if let fetched = viewModel.fetchedContent {
        Text(fetched)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Memory content: \(fetched)")
      } else if let fetchError = viewModel.fetchError {
        Text("Could not load content: \(fetchError)")
          .font(.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Error loading memory content: \(fetchError)")
      }
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
        // Capture date (from fetched DTO)
        if let capturedAt = viewModel.capturedAt {
          metadataRow(
            label: "Captured",
            value: Self.dateFormatter.string(from: capturedAt)
          )
        }

        // Source modality (from fetched DTO)
        if let modality = viewModel.sourceModality {
          metadataRow(
            label: "Source",
            value: modality.capitalized
          )
        }

        // Ask-flow relevance metadata — only shown when a QueryContext was supplied.
        if let ctx = queryContext {
          metadataRow(
            label: "Match",
            value: matchDescription(for: ctx)
          )

          metadataRow(
            label: "Relevance",
            value: String(format: "%.0f%%", ctx.score * 100)
          )
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }

  private func matchDescription(for ctx: QueryContext) -> String {
    if ctx.matchedVia == "chunk", let idx = ctx.matchedChunkIndex {
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
      memoryID: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!,
      queryContext: QueryContext(
        score: 0.92,
        matchedVia: "whole",
        matchedChunkIndex: nil
      )
    )
  }
}
