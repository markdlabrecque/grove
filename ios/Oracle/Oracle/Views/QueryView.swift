import SwiftUI
import OracleCore

/// Ask tab — accepts a natural-language query and displays ranked memory
/// snippets from POST /v1/queries.
///
/// No LLM synthesis in V1. The user sees ranked results with snippet,
/// similarity score, capture date, and matched_via badge.
struct QueryView: View {
  @State private var viewModel = QueryViewModel()

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        queryInputArea
          .padding()

        Divider()

        resultArea
      }
      .navigationTitle("Ask")
    }
    .alert("Query Failed", isPresented: $viewModel.showErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(viewModel.errorMessage)
    }
  }

  // MARK: - Query input

  private var queryInputArea: some View {
    HStack(spacing: 12) {
      TextField("Ask your memory…", text: $viewModel.query)
        .submitLabel(.search)
        .onSubmit {
          viewModel.ask()
        }
        .textInputAutocapitalization(.sentences)
        .autocorrectionDisabled(false)
        .accessibilityLabel("Query field")
        .accessibilityHint("Type a question to search your memories")

      Button(action: {
        viewModel.ask()
      }) {
        if viewModel.isLoading {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Ask")
            .fontWeight(.semibold)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!viewModel.isAskEnabled)
      .accessibilityLabel(viewModel.isLoading ? "Ask — cancels current search and starts a new one" : "Ask")
      .accessibilityHint("Submit query to search your memories")
    }
  }

  // MARK: - Result area

  @ViewBuilder
  private var resultArea: some View {
    switch viewModel.queryStatus {
    case .idle:
      Spacer()

    case .loading:
      VStack {
        Spacer()
        ProgressView("Searching…")
          .accessibilityLabel("Searching memories")
        Spacer()
      }

    case .results(let results):
      if results.isEmpty {
        VStack {
          Spacer()
          Text("No matches")
            .foregroundStyle(.secondary)
            .accessibilityLabel("No results found")
          Spacer()
        }
      } else {
        List(results, id: \.memoryID) { result in
          QueryResultRow(result: result)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            // TODO(detail): navigate to full memory view
        }
        .listStyle(.plain)
      }

    case .failure:
      // Alert handles failure display; this case is momentary.
      Spacer()
    }
  }
}

// MARK: - Result row

private struct QueryResultRow: View {
  let result: QueryResult

  private static let relativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(result.snippet)
        .font(.body)
        .lineLimit(3)
        .accessibilityLabel("Snippet: \(result.snippet)")

      HStack(spacing: 8) {
        // Similarity score as a percentage — visually subordinate.
        Text(String(format: "%.0f%%", result.score * 100))
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Similarity \(String(format: "%.0f", result.score * 100)) percent")

        // Relative capture date.
        if let capturedAt = result.capturedAt {
          Text(Self.relativeDateFormatter.localizedString(for: capturedAt, relativeTo: Date()))
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Captured \(Self.relativeDateFormatter.localizedString(for: capturedAt, relativeTo: Date()))")
        }

        // matched_via badge: nothing for "whole", [chunk N] for "chunk".
        if result.matchedVia == "chunk", let idx = result.matchedChunkIndex {
          Text("[chunk \(idx)]")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Chunk \(idx)")
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

#Preview {
  QueryView()
}
