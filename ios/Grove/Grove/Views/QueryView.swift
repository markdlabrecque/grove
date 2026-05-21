import SwiftUI
import GroveCore

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
///
/// # V2 forest-green (#320)
///
/// Search bar uses card surface with hairline border (§3.7). Answer card has
/// a 3pt vertical gradient bar on the leading edge (§3.8). Source cards use
/// a leaf score pill (§3.9). Recent-queries strip lead chip is forest700/paper;
/// others are outline style (§3.10).
struct QueryView: View {
  @State private var viewModel = QueryViewModel()
  @FocusState private var isFocused: Bool

  /// The `ScrollViewProxy` passed in from the `ScrollViewReader` that wraps
  /// the source list — stored so citation tap actions can scroll to a source.
  @State private var scrollProxy: ScrollViewProxy?

  /// The source index that is briefly highlighted after a citation tap.
  @State private var highlightedSourceIndex: Int?

  /// Navigation path for the `NavigationStack` — allows `SourceCardRow`'s
  /// swipe action to push `MemoryDetailView` without the deprecated
  /// `NavigationLink(isActive:)` pattern. The binding is passed down to each
  /// `SourceCardRow` so swipe-triggered navigation appends a typed value here
  /// and the stack's `navigationDestination(for:)` resolves it.
  @State private var navigationPath = NavigationPath()

  var body: some View {
    NavigationStack(path: $navigationPath) {
      ZStack {
        Color.paper
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { isFocused = false }

        VStack(spacing: 0) {
          queryInputArea
            .padding()

          // Recent-queries chip strip — only shown when the list is non-empty.
          if !viewModel.recentQueries.isEmpty {
            recentQueriesStrip
          }

          Divider()
            .background(Color.hairline)

          resultArea
        }
      }
      .navigationTitle("Ask")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavWordmarkView()
        }
      }
      // Resolves QueryResult values pushed onto `navigationPath` by
      // Resolves QueryResult values pushed onto `navigationPath` by
      // SourceCardRow's swipe action. Passes the bare memoryID plus a
      // QueryContext so MemoryDetailView can display relevance metadata.
      // The footer NavigationLink still uses the closure form and is
      // handled separately below.
      .navigationDestination(for: QueryResult.self) { result in
        MemoryDetailView(
          memoryID: result.memoryID,
          queryContext: QueryContext(
            score: result.score,
            matchedVia: result.matchedVia,
            matchedChunkIndex: result.matchedChunkIndex
          ),
          onDeleteSuccess: { deletedID in viewModel.removeSource(memoryID: deletedID) }
        )
      }
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

  // MARK: - Recent-queries chip strip (§3.10)

  /// Horizontally scrolling strip of the user's most-recent distinct queries.
  ///
  /// Each chip, when tapped, populates the query field and immediately fires a
  /// fresh submit via `QueryViewModel.tapRecentQuery(_:)` — it does not just
  /// show cached results.
  ///
  /// The strip is hidden when `viewModel.recentQueries` is empty (on first
  /// install, or when the strip fetch fails). It refreshes after every
  /// successful ask so the most-recent query floats to the front.
  ///
  /// Lead chip (first/most-recent): forest700 bg, paper text.
  /// Other chips: outline style.
  private var recentQueriesStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Array(viewModel.recentQueries.enumerated()), id: \.element.id) { idx, item in
          RecentQueryChip(queryText: item.queryText, isLead: idx == 0) {
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

  // MARK: - Query input (§3.7)

  /// Search bar: card surface, 50pt height, 14pt radius.
  /// Leading magnifyingglass in forest500; trailing mic in forest500.
  private var queryInputArea: some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(Color.forest500)
        .accessibilityHidden(true)

      TextField("Ask your memory…", text: $viewModel.query)
        .submitLabel(.search)
        .onSubmit {
          isFocused = false
          viewModel.ask()
        }
        .focused($isFocused)
        .textInputAutocapitalization(.sentences)
        .autocorrectionDisabled(false)
        .foregroundStyle(Color.ink900)
        .accessibilityLabel("Query field")
        .accessibilityHint("Type a question to search your memories")

      // Inline clear button — visible only while the field has content (#380).
      if !viewModel.query.isEmpty {
        Button {
          viewModel.query = ""
          isFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(Color.ink500)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear query")
        .accessibilityHint("Erase the current question")
      }

      Button(action: {
        isFocused = false
        viewModel.ask()
      }) {
        if viewModel.isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(.forest500)
        } else {
          Text("Ask")
            .fontWeight(.semibold)
            .foregroundStyle(Color.forest500)
        }
      }
      .disabled(!viewModel.isAskEnabled)
      .accessibilityLabel(viewModel.isLoading ? "Ask — cancels current search and starts a new one" : "Ask")
      .accessibilityHint("Submit query to search your memories")
    }
    .padding(.horizontal, 14)
    .frame(height: 50)
    .background(Color.card)
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(Color.hairline, lineWidth: 1)
    )
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
          .tint(.forest500)
          .accessibilityLabel("Searching memories")
        Spacer()
      }

    case .results(let answer, let sources, let queryID):
      if answer == nil && sources.isEmpty {
        VStack {
          Spacer()
          Text("No matches")
            .foregroundStyle(Color.ink500)
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
                .listRowBackground(Color.paper)

              // Divider between answer card and source list.
              Divider()
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.paper)
            }

            // Source cards — tap the chevron to expand/collapse inline;
            // the expanded card footer contains a link to MemoryDetailView
            // for the full delete flow (#172).
            ForEach(Array(sources.enumerated()), id: \.element.memoryID) { idx, result in
              SourceCardRow(
                result: result,
                isHighlighted: highlightedSourceIndex == idx,
                navigationPath: $navigationPath,
                onDeleteSuccess: { deletedID in
                  viewModel.removeSource(memoryID: deletedID)
                }
              )
              .id("source-\(idx)")
              .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
              .listRowSeparator(.hidden)
              .listRowBackground(Color.paper)
            }
          }
          .listStyle(.plain)
          .background(Color.paper)
          .scrollContentBackground(.hidden)
          .onAppear { scrollProxy = proxy }
        }
      }

    case .failure:
      // Alert handles failure display; this case is momentary.
      Spacer()
    }
  }

  // MARK: - Answer card (§3.8)

  private func answerCard(answer: String, sources: [QueryResult], queryID: UUID?) -> some View {
    let segments = CitationParser.parse(answer: answer, sources: sources)

    return HStack(spacing: 0) {
      // 3pt leading gradient bar per spec §3.8.
      LinearGradient(
        colors: [Color.forest500, Color.moss400],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(width: 3)
      .clipShape(
        // Outer (leading) corners follow the card curve; inner (trailing)
        // corners are sharp so the bar butts flush against the card content.
        UnevenRoundedRectangle(
          topLeadingRadius: 3,
          bottomLeadingRadius: 3,
          bottomTrailingRadius: 0,
          topTrailingRadius: 0
        )
      )

      VStack(alignment: .leading, spacing: 8) {
        // Header strip: leaf.fill + "ANSWER" in forest500 uppercase.
        HStack(spacing: 4) {
          Image(systemName: "leaf.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.forest500)
          Text("Answer")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.forest500)
            .textCase(.uppercase)
            .tracking(1.5)
        }
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
    }
    .background(Color.card)
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .shadow(color: Color(red: 0.08, green: 0.15, blue: 0.11).opacity(0.07), radius: 24, x: 0, y: 8)
    .shadow(color: Color(red: 0.08, green: 0.15, blue: 0.11).opacity(0.05), radius: 2, x: 0, y: 1)
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
        // Citation badge styling: sage200 bg, forest800 text per spec §3.8.
        marker.foregroundColor = UIColor(named: "forest800").map { Color($0) } ?? .accentColor
        marker.font = .caption.weight(.bold)
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
        .font(.system(size: 15))
        .foregroundStyle(Color.ink900)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)

      if !citationButtons.isEmpty {
        HStack(spacing: 8) {
          ForEach(Array(citationButtons.enumerated()), id: \.offset) { _, entry in
            Button(entry.label) {
              onCitationTap(entry.sourceIndex)
            }
            // Citation badge: sage200 bg, forest800 text, 10pt bold per spec §3.8.
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(Color.forest800)
            .background(Color.sage200)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to source \(entry.label)")
          }
          Spacer()
        }
      }
    }
  }
}

// MARK: - Source card row (expandable) (§3.9)

/// A source card that can be expanded inline to show the full memory content.
///
/// Tapping the chevron button toggles expanded/collapsed state with a smooth
/// height animation. Citation tap-throughs from the answer card (#171) scroll
/// to this card via its list `.id`; the expand toggle is on the chevron button
/// only so that scroll-and-highlight does not unintentionally expand the card.
///
/// Two paths to `MemoryDetailView` (which hosts the delete flow from #172):
/// - Leading swipe action on the row (#263) — one gesture, no expand required.
/// - "View detail / Delete" link in the expanded footer — explicit, always visible
///   after expanding.
private struct SourceCardRow: View {
  let result: QueryResult
  let isHighlighted: Bool
  /// Binding to the ancestor `NavigationStack`'s path — appending `result`
  /// pushes `MemoryDetailView` via the stack's `navigationDestination(for:)`.
  @Binding var navigationPath: NavigationPath
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
            .font(.system(size: 14))
            .foregroundStyle(Color.ink900)
            .lineLimit(isExpanded ? nil : 3)
            .accessibilityLabel(isExpanded ? "Memory content: \(result.excerpt)" : "Snippet: \(result.excerpt)")

          metadataRow
        }

        Spacer(minLength: 4)

        // Chevron button — the ONLY expand/collapse trigger.
        Button {
          isExpanded.toggle()
        } label: {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.ink300)
            .frame(width: 28, height: 28)
            .background(Color.paperWarm)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse memory" : "Expand memory")
        .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") the full content of this memory")
      }
      .padding(12)

      // --- Expanded content footer ---
      if isExpanded {
        VStack(alignment: .leading, spacing: 12) {
          Divider()
            .background(Color.hairline)
            .padding(.horizontal, 12)

          expandedMetadata
            .padding(.horizontal, 12)

          // Footer: "View detail / Delete" link in forest500 per spec §3.9.
          NavigationLink {
            MemoryDetailView(
              memoryID: result.memoryID,
              queryContext: QueryContext(
                score: result.score,
                matchedVia: result.matchedVia,
                matchedChunkIndex: result.matchedChunkIndex
              ),
              onDeleteSuccess: onDeleteSuccess
            )
          } label: {
            HStack(spacing: 4) {
              Text("View detail / Delete")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.forest500)
              Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.ink300)
            }
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
          .accessibilityLabel("View memory detail and delete options")
          .accessibilityHint("Double-tap to open full detail view where you can delete this memory")
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    // Animate the isExpanded flag on both the lineLimit change and the footer.
    .animation(.easeInOut(duration: 0.25), value: isExpanded)
    .background(isHighlighted ? Color.forest500.opacity(0.12) : Color.card)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.hairline, lineWidth: 1)
    )
    .animation(.easeOut(duration: 0.3), value: isHighlighted)
    .accessibilityElement(children: .contain)
    // Leading swipe action — restores one-gesture detail access removed in #188.
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      Button {
        navigationPath.append(result)
      } label: {
        Label("View Detail", systemImage: "arrow.right.circle")
      }
      .tint(.forest500)
      .accessibilityLabel("View memory detail")
      .accessibilityHint("Opens the full detail view where you can delete this memory")
    }
  }

  // MARK: - Metadata row (§3.9 score pill + meta)

  private var metadataRow: some View {
    HStack(spacing: 8) {
      // Score pill: leaf-shaped tonal badge — sage200 bg, forest800 text, leaf SF Symbol.
      HStack(spacing: 4) {
        Image(systemName: "leaf.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.forest800)
        Text(String(format: "%.0f%%", result.score * 100))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.forest800)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.sage200)
      .clipShape(Capsule())
      .accessibilityLabel("Similarity \(String(format: "%.0f", result.score * 100)) percent")

      // Relative capture date.
      if let capturedAt = result.capturedAt {
        Text(Self.relativeDateFormatter.localizedString(for: capturedAt, relativeTo: Date()))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.ink500)
          .accessibilityLabel("Captured \(Self.relativeDateFormatter.localizedString(for: capturedAt, relativeTo: Date()))")
      }

      // matched_via badge: nothing for "whole", [chunk N] for "chunk".
      if result.matchedVia == "chunk", let idx = result.matchedChunkIndex {
        Text("[chunk \(idx)]")
          .font(.caption2)
          .foregroundStyle(Color.ink500)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(Color.paperWarm)
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
    .background(Color.paperWarm)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func expandedMetaItem(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.caption)
        .foregroundStyle(Color.ink500)
        .frame(width: 72, alignment: .leading)
      Text(value)
        .font(.caption)
        .foregroundStyle(Color.ink900)
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
            ? Color.sage200
            : Color.paperWarm
        )
        .foregroundStyle(isSelected ? Color.forest800 : Color.ink500)
        .clipShape(Capsule())
        .overlay(
          Capsule()
            .strokeBorder(
              isSelected ? Color.sage300 : Color.clear,
              lineWidth: 1
            )
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

// MARK: - Recent query chip (§3.10)

/// A single recent-query chip in the horizontal strip above the input field.
///
/// Lead chip (idx == 0): `forest700` bg, `paper` text.
/// Other chips: outline style (`card` bg, `hairline` border, `ink700` text).
private struct RecentQueryChip: View {
  let queryText: String
  let isLead: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(queryText)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isLead ? Color.forest700 : Color.card)
        .foregroundStyle(isLead ? Color.paper : Color.ink700)
        .clipShape(Capsule())
        .overlay(
          Capsule()
            .strokeBorder(isLead ? Color.clear : Color.hairline, lineWidth: 1)
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
