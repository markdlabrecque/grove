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

        // Recent-queries chip strip — only shown when the list is non-empty.
        if !viewModel.recentQueries.isEmpty {
          recentQueriesStrip
        }

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
    .task {
      // Fetch on view appear. `.task` cancels and re-runs when the view is
      // re-presented, so the strip is always fresh without manual lifecycle
      // management. The fetch itself is fire-and-forget inside the ViewModel.
      viewModel.refreshRecentQueries()
    }
  }

  // MARK: - Recent-queries chip strip

  /// Horizontally scrolling strip of the user's most-recent distinct queries.
  ///
  /// Each chip, when tapped, populates the query field and immediately fires a
  /// fresh submit via `QueryViewModel.tapRecentQuery(_:)` — it does not just
  /// show cached results.
  ///
  /// The strip is hidden when `viewModel.recentQueries` is empty (on first
  /// install, or when the strip fetch fails). It refreshes after every
  /// successful ask so the most-recent query floats to the front.
  private var recentQueriesStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(viewModel.recentQueries) { item in
          RecentQueryChip(queryText: item.queryText) {
            isFocused = false
            viewModel.tapRecentQuery(item)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .accessibilityLabel("Recent queries")
    .accessibilityHint("Double-tap a chip to re-run that query")
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

    case .results(let answer, let sources, let queryID):
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
              answerCard(answer: answer, sources: sources, queryID: queryID)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)

              // Divider between answer card and source list.
              Divider()
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }

            // Source cards — tap the chevron to expand/collapse inline;
            // the expanded card footer contains a link to MemoryDetailView
            // for the full delete flow (#172).
            ForEach(Array(sources.enumerated()), id: \.element.memoryID) { idx, result in
              SourceCardRow(
                result: result,
                isHighlighted: highlightedSourceIndex == idx,
                onDeleteSuccess: { deletedID in
                  viewModel.removeSource(memoryID: deletedID)
                }
              )
              .id("source-\(idx)")
              .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
              .listRowSeparator(.hidden)
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

  private func answerCard(answer: String, sources: [QueryResult], queryID: UUID?) -> some View {
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

      // Feedback chips — only shown when the server returned a query_id.
      if let queryID {
        FeedbackChipsView(
          queryID: queryID,
          currentFeedback: viewModel.feedback(for: queryID),
          onFeedback: { feedback in
            viewModel.submitFeedback(feedback, for: queryID)
          }
        )
        .padding(.top, 4)
      }
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

// MARK: - Source card row (expandable)

/// A source card that can be expanded inline to show the full memory content.
///
/// Tapping the chevron button toggles expanded/collapsed state with a smooth
/// height animation. Citation tap-throughs from the answer card (#171) scroll
/// to this card via its list `.id`; the expand toggle is on the chevron button
/// only so that scroll-and-highlight does not unintentionally expand the card.
///
/// The expanded footer contains a `NavigationLink` to `MemoryDetailView`,
/// keeping the delete flow from #172 reachable without a separate navigation
/// path.
private struct SourceCardRow: View {
  let result: QueryResult
  let isHighlighted: Bool
  let onDeleteSuccess: (UUID) -> Void

  @State private var isExpanded = false

  private static let relativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
  }()

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // --- Collapsed chrome (always visible) ---
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 6) {
          Text(result.excerpt)
            .font(.body)
            .lineLimit(isExpanded ? nil : 3)
            .accessibilityLabel(isExpanded ? "Memory content: \(result.excerpt)" : "Snippet: \(result.excerpt)")

          metadataRow
        }

        Spacer(minLength: 4)

        // Chevron button — the ONLY expand/collapse trigger. Isolated so that
        // the text content above (which may receive highlight flashes from
        // citation taps) never accidentally toggles expansion.
        Button {
          isExpanded.toggle()
        } label: {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color(.tertiarySystemBackground))
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse memory" : "Expand memory")
        .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") the full content of this memory")
      }
      .padding(8)

      // --- Expanded content footer ---
      if isExpanded {
        VStack(alignment: .leading, spacing: 12) {
          Divider()
            .padding(.horizontal, 8)

          expandedMetadata
            .padding(.horizontal, 8)

          // NavigationLink to the detail view — keeps delete reachable (#172).
          NavigationLink {
            MemoryDetailView(
              result: result,
              onDeleteSuccess: onDeleteSuccess
            )
          } label: {
            Label("View detail / Delete", systemImage: "arrow.right.circle")
              .font(.subheadline)
              .foregroundStyle(.accent)
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 8)
          .padding(.bottom, 8)
          .accessibilityLabel("View memory detail and delete options")
          .accessibilityHint("Double-tap to open full detail view where you can delete this memory")
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    // Animate the isExpanded flag on both the lineLimit change and the footer.
    .animation(.easeInOut(duration: 0.25), value: isExpanded)
    .background(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .animation(.easeOut(duration: 0.3), value: isHighlighted)
    .accessibilityElement(children: .contain)
  }

  // MARK: - Metadata row (collapsed)

  private var metadataRow: some View {
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

  // MARK: - Expanded metadata

  private var expandedMetadata: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let capturedAt = result.capturedAt {
        expandedMetaItem(
          label: "Captured",
          value: Self.dateFormatter.string(from: capturedAt)
        )
      }
      if let modality = result.sourceModality {
        expandedMetaItem(label: "Source", value: modality.capitalized)
      }
      expandedMetaItem(
        label: "Match",
        value: result.matchedVia == "chunk"
          ? (result.matchedChunkIndex.map { "Chunk \($0)" } ?? "Chunk")
          : "Full memory"
      )
      expandedMetaItem(
        label: "Relevance",
        value: String(format: "%.0f%%", result.score * 100)
      )
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func expandedMetaItem(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)
      Text(value)
        .font(.caption)
        .foregroundStyle(.primary)
      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label): \(value)")
  }
}

// MARK: - Feedback chips

/// Thumbs-up / thumbs-down feedback chips displayed beneath each answer card.
///
/// Tapping a chip immediately reflects the selection visually (no spinner).
/// Tapping the alternate chip overwrites the prior selection both locally and
/// on the server. A 5xx from the server is swallowed silently — the
/// `QueryViewModel.submitFeedback` method handles the fire-and-forget contract.
///
/// The chip is hidden when the server did not return a `query_id` (older server
/// versions) — the caller is responsible for only rendering this view when a
/// query ID is available.
private struct FeedbackChipsView: View {
  let queryID: UUID
  let currentFeedback: Feedback?
  let onFeedback: (Feedback) -> Void

  var body: some View {
    HStack(spacing: 12) {
      FeedbackChip(
        symbol: "hand.thumbsup",
        label: "Helpful",
        isSelected: currentFeedback == .positive,
        action: { onFeedback(.positive) }
      )
      FeedbackChip(
        symbol: "hand.thumbsdown",
        label: "Not helpful",
        isSelected: currentFeedback == .negative,
        action: { onFeedback(.negative) }
      )
      Spacer()
    }
  }
}

/// A single thumbs-up or thumbs-down chip button.
private struct FeedbackChip: View {
  let symbol: String
  let label: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(label, systemImage: isSelected ? "\(symbol).fill" : symbol)
        .font(.caption.weight(.medium))
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          isSelected
            ? Color.accentColor.opacity(0.15)
            : Color(.tertiarySystemBackground)
        )
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .clipShape(Capsule())
        .overlay(
          Capsule()
            .strokeBorder(
              isSelected ? Color.accentColor.opacity(0.4) : Color.clear,
              lineWidth: 1
            )
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

// MARK: - Recent query chip

/// A single recent-query chip in the horizontal strip above the input field.
///
/// Displays the `queryText` truncated to a single line. Tapping fires the
/// provided `action` closure (which in production calls
/// `QueryViewModel.tapRecentQuery(_:)` to populate the field and submit).
private struct RecentQueryChip: View {
  let queryText: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(queryText)
        .font(.subheadline)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .foregroundStyle(.primary)
        .clipShape(Capsule())
        .overlay(
          Capsule()
            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Recent query: \(queryText)")
    .accessibilityHint("Double-tap to re-run this query")
    .accessibilityAddTraits(.isButton)
  }
}

#Preview {
  QueryView()
}
