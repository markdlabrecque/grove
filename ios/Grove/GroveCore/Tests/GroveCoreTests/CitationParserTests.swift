import Testing
import Foundation
@testable import GroveCore

/// Unit tests for `CitationParser`.
///
/// `CitationParser.parse(answer:sources:)` splits a RAG-synthesised answer into
/// a sequence of `AnswerSegment` values — either plain text runs or resolved /
/// unresolvable citation references of the form `[#<UUID>]`.
///
/// TDD: this file was committed red before `CitationParser` existed. Green commit
/// adds the implementation.
@Suite("CitationParser")
struct CitationParserTests {

  // MARK: - Fixtures

  private let memoryA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
  private let memoryB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

  private func source(id: UUID, excerpt: String = "excerpt") -> QueryResult {
    QueryResult(
      memoryID: id,
      score: 0.9,
      matchedVia: "whole",
      matchedChunkIndex: nil,
      excerpt: excerpt,
      capturedAt: nil,
      sourceModality: "text"
    )
  }

  // MARK: - Happy path: no citations

  @Test("answer with no citations returns a single text segment")
  func noCitations() {
    let segments = CitationParser.parse(
      answer: "The sky is blue.",
      sources: []
    )

    #expect(segments.count == 1)
    guard case .text(let t) = segments[0] else {
      Issue.record("Expected .text, got \(segments[0])")
      return
    }
    #expect(t == "The sky is blue.")
  }

  // MARK: - Happy path: one citation

  @Test("single citation at the end is replaced with a resolved citation segment")
  func oneCitationAtEnd() {
    let src = source(id: memoryA, excerpt: "SwiftData is the local store.")
    let answer = "SwiftData is the local store of truth. [#\(memoryA.uuidString)]"

    let segments = CitationParser.parse(answer: answer, sources: [src])

    // Expect: text segment + citation segment
    #expect(segments.count == 2)

    guard case .text(let t) = segments[0] else {
      Issue.record("Expected .text at index 0, got \(segments[0])")
      return
    }
    #expect(t == "SwiftData is the local store of truth. ")

    guard case .citation(let sourceIndex) = segments[1] else {
      Issue.record("Expected .citation at index 1, got \(segments[1])")
      return
    }
    #expect(sourceIndex == 0)
  }

  // MARK: - Happy path: multiple citations

  @Test("multiple citations interleaved with prose produce alternating segments")
  func multipleCitationsInterleaved() {
    let srcA = source(id: memoryA, excerpt: "Fact A.")
    let srcB = source(id: memoryB, excerpt: "Fact B.")
    let answer = "First fact [#\(memoryA.uuidString)] and second fact [#\(memoryB.uuidString)]."

    let segments = CitationParser.parse(answer: answer, sources: [srcA, srcB])

    // Expected: text, citationA, text, citationB, text
    #expect(segments.count == 5)

    guard case .text(let t0) = segments[0] else {
      Issue.record("Expected .text at 0, got \(segments[0])")
      return
    }
    #expect(t0 == "First fact ")

    guard case .citation(let idxA) = segments[1] else {
      Issue.record("Expected .citation at 1, got \(segments[1])")
      return
    }
    #expect(idxA == 0)

    guard case .text(let t2) = segments[2] else {
      Issue.record("Expected .text at 2, got \(segments[2])")
      return
    }
    #expect(t2 == " and second fact ")

    guard case .citation(let idxB) = segments[3] else {
      Issue.record("Expected .citation at 3, got \(segments[3])")
      return
    }
    #expect(idxB == 1)

    guard case .text(let t4) = segments[4] else {
      Issue.record("Expected .text at 4, got \(segments[4])")
      return
    }
    #expect(t4 == ".")
  }

  // MARK: - Happy path: citation at the start

  @Test("citation at the start of the answer is handled correctly")
  func citationAtStart() {
    let src = source(id: memoryA)
    let answer = "[#\(memoryA.uuidString)] was the first memory."

    let segments = CitationParser.parse(answer: answer, sources: [src])

    #expect(segments.count == 2)
    guard case .citation(let idx) = segments[0] else {
      Issue.record("Expected .citation at 0, got \(segments[0])")
      return
    }
    #expect(idx == 0)

    guard case .text(let t) = segments[1] else {
      Issue.record("Expected .text at 1, got \(segments[1])")
      return
    }
    #expect(t == " was the first memory.")
  }

  // MARK: - Malformed: not a UUID

  @Test("bracket reference that is not a valid UUID is kept as literal text")
  func malformedNotUUID() {
    let answer = "This is [#not-a-uuid] in the text."
    let segments = CitationParser.parse(answer: answer, sources: [])

    // The entire string should be a single text segment (no citation parsed).
    #expect(segments.count == 1)
    guard case .text(let t) = segments[0] else {
      Issue.record("Expected .text, got \(segments[0])")
      return
    }
    #expect(t == "This is [#not-a-uuid] in the text.")
  }

  // MARK: - Unresolved citation (UUID present but no matching source)

  @Test("UUID citation with no matching source becomes plain text")
  func unresolvedCitation() {
    let unknownID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    // Sources list has memoryA but answer references unknownID.
    let src = source(id: memoryA)
    let answer = "Some text [#\(unknownID.uuidString)] here."

    let segments = CitationParser.parse(answer: answer, sources: [src])

    // Unresolved → plain text. The entire string collapses to one text run.
    #expect(segments.count == 1)
    guard case .text(let t) = segments[0] else {
      Issue.record("Expected .text for unresolved citation, got \(segments[0])")
      return
    }
    #expect(t == "Some text [#\(unknownID.uuidString)] here.")
  }

  // MARK: - Mixed resolved + unresolved

  @Test("mix of resolved and unresolved citations: resolved → citation, unresolved → literal")
  func mixedResolvedAndUnresolved() {
    let knownID = memoryA
    let unknownID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    let src = source(id: knownID)
    let answer = "Known [#\(knownID.uuidString)] and unknown [#\(unknownID.uuidString)]."

    let segments = CitationParser.parse(answer: answer, sources: [src])

    // text "Known " + citation(0) + text " and unknown [#<unknownID>]."
    #expect(segments.count == 3)

    guard case .text(let t0) = segments[0] else {
      Issue.record("Expected .text at 0, got \(segments[0])")
      return
    }
    #expect(t0 == "Known ")

    guard case .citation(let idx) = segments[1] else {
      Issue.record("Expected .citation at 1, got \(segments[1])")
      return
    }
    #expect(idx == 0)

    guard case .text(let t2) = segments[2] else {
      Issue.record("Expected .text at 2, got \(segments[2])")
      return
    }
    // The unresolved citation bracket stays verbatim in the trailing text run.
    #expect(t2.contains("[#\(unknownID.uuidString)]"))
  }

  // MARK: - Answer with only a citation token (no prose)

  @Test("answer that is exactly one resolved citation produces a single citation segment")
  func answerIsExactlyCitation() {
    let src = source(id: memoryA)
    let answer = "[#\(memoryA.uuidString)]"

    let segments = CitationParser.parse(answer: answer, sources: [src])

    #expect(segments.count == 1)
    guard case .citation(let idx) = segments[0] else {
      Issue.record("Expected .citation, got \(segments[0])")
      return
    }
    #expect(idx == 0)
  }

  // MARK: - Duplicate citation

  @Test("two citations to the same source both produce citation segments")
  func multipleCitationsSameSource() {
    let src = source(id: memoryA)
    let answer = "First [#\(memoryA.uuidString)] and again [#\(memoryA.uuidString)]."

    let segments = CitationParser.parse(answer: answer, sources: [src])

    // text + citation(0) + text + citation(0) + text
    #expect(segments.count == 5)

    guard case .citation(let first) = segments[1] else {
      Issue.record("Expected .citation at 1, got \(segments[1])")
      return
    }
    guard case .citation(let second) = segments[3] else {
      Issue.record("Expected .citation at 3, got \(segments[3])")
      return
    }
    #expect(first == 0)
    #expect(second == 0)
  }

  // MARK: - QueryResponseBody answer field decoding

  @Test("QueryResponseBody decodes answer field when present")
  func decodesAnswerField() throws {
    let json = """
    {
      "answer": "SwiftData is used as the local store. [#aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa]",
      "sources": [],
      "query_token_count": 5,
      "latency_ms": 200.0
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let body = try decoder.decode(QueryResponseBody.self, from: data)

    #expect(body.answer != nil)
    #expect(body.answer!.contains("SwiftData"))
  }

  @Test("QueryResponseBody answer field is nil when absent from JSON")
  func answerIsNilWhenAbsent() throws {
    let json = """
    {
      "sources": [],
      "query_token_count": 3,
      "latency_ms": 100.0
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let body = try decoder.decode(QueryResponseBody.self, from: data)

    #expect(body.answer == nil)
  }
}
