import SwiftUI
import OracleCore

/// Ask tab — accepts a natural-language query and displays a RAG-synthesised
/// answer (when available) followed by ranked source snippets from
/// POST /v1/queries.
///
/// ## Answer rendering
///
/// When the server returns an `answer` field, `QueryView` renders it in an
/// answer card above the source list. `[#<UUID>]` citation tokens in the
/// answer text are parsed by `CitationParser` and rendered as tappable
/// superscript-style badges that scroll to and briefly highlight the matching
/// source card in the list below.
///
/// When `answer` is nil (server skipped synthesis), the view falls back to the
/// original snippet-list-only behaviour.
struct QueryView: View {
  @State private var viewModel = QueryViewModel()
  @FocusState private var isFocused: Bool

  /// The `ScrollViewProxy` passed in from the `ScrollViewReader` that wraps
  /// the source list — stored so citation tap actions can scroll to a source.
  @State private var scrollProxy: ScrollViewProxy?

  /// The source index that is briefly highlighted after a citation tap.
  @State private var highlightedSourceIndex: Int?

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        queryInputArea
          .padding()

        Divider()

        resultArea
      }
      .navigationTitle("Ask")
      .background(
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { isFocused = false }
      )
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
          isFocused = false
          viewModel.ask()
        }
        .focused($isFocused)
        .textInputAutocapitalization(.sentences)
        .autocorrectionDisabled(false)
        .accessibilityLabel("Query field")
        .accessibilityHint("Type a question to search your memories")

      Button(action: {
        isFocused = false
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

    case .results(let answer, let sources):
      if answer == nil && sources.isEmpty {
        VStack {
          Spacer()
          Text("No matches")
            .foregroundStyle(.secondary)
            .accessibilityLabel("No results found")
          Spacer()
        }
      } else {
        ScrollViewReader { proxy in
          List {
            // Answer card — only when the server returned a synthesised answer.
            if let answer {
              answerCard(answer: answer, sources: sources)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)

              // Divider between answer card and source list.
              Divider()
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }

            // Source cards.
            ForEach(Array(sources.enumerated()), id: \.element.memoryID) { idx, result in
              QueryResultRow(
                result: result,
                isHighlighted: highlightedSourceIndex == idx
              )
              .id("source-\(idx)")
              .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
              // TODO(detail): navigate to full memory view (#207)
            }
          }
          .listStyle(.plain)
          .onAppear { scrollProxy = proxy }
        }
      }

    case .failure:
      // Alert handles failure display; this case is momentary.
      Spacer()
    }
  }

  // MARK: - Answer card

  private func answerCard(answer: String, sources: [QueryResult]) -> some View {
    let segments = CitationParser.parse(answer: answer, sources: sources)

    return VStack(alignment: .leading, spacing: 8) {
      Text("Answer")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .accessibilityHidden(true)

      // Build the answer text with inline tappable citation badges.
      answerText(segments: segments, sources: sources)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityAnswerLabel(answer: answer, sources: sources))
  }

  // MARK: - Answer text with inline citations

  /// Renders the answer segments as a `Text`-flow with tappable citation badges.
  ///
  /// SwiftUI does not support heterogeneous inline buttons inside `Text`.
  /// The approach: render all segments in a single `Text` where citations are
  /// represented as numbered footnote markers `[1]`, `[2]`, etc. A `Button`
  /// strip below the text maps the same numbers to scroll actions. This keeps
  /// prose readable and interactions discoverable.
  ///
  /// Design note: tappable inline ranges inside flowing `Text` are not
  /// supported in SwiftUI (no `AttributedString` gesture support as of iOS 26).
  /// The numbered-footnote approach is the standard workaround.
  private func answerText(segments: [AnswerSegment], sources: [QueryResult]) -> some View {
    let (displayText, citationButtons) = buildAnswerDisplay(segments: segments)
    return AnswerTextView(
      displayText: displayText,
      citationButtons: citationButtons,
      onCitationTap: scrollToSource
    )
  }

  /// Build the attributed display string and citation button descriptors from
  /// parsed segments. Extracted from the view builder so plain Swift control
  /// flow can be used freely.
  private func buildAnswerDisplay(
    segments: [AnswerSegment]
  ) -> (AttributedString, [(label: String, sourceIndex: Int)]) {
    var displayText = AttributedString()
    var citationButtons: [(label: String, sourceIndex: Int)] = []

    for segment in segments {
      switch segment {
      case .text(let prose):
        displayText += AttributedString(prose)
      case .citation(let idx):
        let n = citationButtons.count + 1
        citationButtons.append((label: "[\(n)]", sourceIndex: idx))
        var marker = AttributedString("[\(n)]")
        marker.foregroundColor = .accentColor
        marker.font = .caption.weight(.semibold)
        displayText += marker
      }
    }

    return (displayText, citationButtons)
  }

  // MARK: - Citation scroll action

  private func scrollToSource(index: Int) {
    withAnimation(.easeInOut(duration: 0.3)) {
      scrollProxy?.scrollTo("source-\(index)", anchor: .top)
    }
    // Flash highlight briefly.
    highlightedSourceIndex = index
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      if highlightedSourceIndex == index {
        highlightedSourceIndex = nil
      }
    }
  }

  // MARK: - Accessibility

  /// Produces a VoiceOver-readable label for the answer card, replacing
  /// `[N]` footnote markers with "citation N" so they are audible.
  private func accessibilityAnswerLabel(answer: String, sources: [QueryResult]) -> String {
    let segments = CitationParser.parse(answer: answer, sources: sources)
    var out = "Answer: "
    var citationCounter = 0
    for segment in segments {
      switch segment {
      case .text(let t):
        out += t
      case .citation:
        citationCounter += 1
        out += ", citation \(citationCounter),"
      }
    }
    return out
  }
}

// MARK: - Answer text view

/// Renders the attributed answer string and a row of tappable citation buttons.
///
/// Extracted from `QueryView` so `buildAnswerDisplay`'s plain-Swift loops can
/// produce the data before the `ViewBuilder` context begins.
private struct AnswerTextView: View {
  let displayText: AttributedString
  let citationButtons: [(label: String, sourceIndex: Int)]
  let onCitationTap: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(displayText)
        .font(.title3)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)

      if !citationButtons.isEmpty {
        HStack(spacing: 8) {
          ForEach(Array(citationButtons.enumerated()), id: \.offset) { _, entry in
            Button(entry.label) {
              onCitationTap(entry.sourceIndex)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            .foregroundStyle(.accent)
            .accessibilityLabel("Jump to source \(entry.label)")
          }
          Spacer()
        }
      }
    }
  }
}

// MARK: - Result row

private struct QueryResultRow: View {
  let result: QueryResult
  let isHighlighted: Bool

  init(result: QueryResult, isHighlighted: Bool = false) {
    self.result = result
    self.isHighlighted = isHighlighted
  }

  private static let relativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(result.excerpt)
        .font(.body)
        .lineLimit(3)
        .accessibilityLabel("Snippet: \(result.excerpt)")

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
    // Brief highlight flash when scrolled-to from a citation tap.
    .padding(8)
    .background(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .animation(.easeOut(duration: 0.3), value: isHighlighted)
  }
}

#Preview {
  QueryView()
}
