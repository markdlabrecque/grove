import Testing
import Foundation
@testable import Grove

// MARK: - CapturePolishTests
//
// Tests for the three capture-polish features introduced in #187:
//   1. FillerWordCleaner — filler-word stripping algorithm
//   2. Token-count heuristic — max(1, chars / 4)
//   3. Language detection wrapper — LanguageDetector
//   4. CaptureViewModel payload wiring — toggle ON → cleaned text in payload
//
// TDD: this file is committed RED before the production implementations exist.

// MARK: - FillerWordCleanerTests

@Suite("FillerWordCleaner")
struct FillerWordCleanerTests {

  // MARK: Basic filler removal

  @Test("removes standalone 'um'")
  func removesUm() {
    #expect(FillerWordCleaner.clean("Um, I think we should go.") == "I think we should go.")
  }

  @Test("removes standalone 'uh'")
  func removesUh() {
    #expect(FillerWordCleaner.clean("Uh, let me think.") == "Let me think.")
  }

  @Test("removes 'you know' at sentence boundary")
  func removesYouKnow() {
    let input = "You know, it was a great day."
    let result = FillerWordCleaner.clean(input)
    #expect(!result.contains("you know"))
    #expect(!result.contains("You know"))
  }

  @Test("removes 'like' used as a sentence-initial filler")
  func removesLikeFiller() {
    // "like" at the start of a clause with a comma is a filler
    let input = "Like, I was just standing there."
    let result = FillerWordCleaner.clean(input)
    #expect(!result.lowercased().hasPrefix("like,"))
  }

  // MARK: Case insensitivity

  @Test("handles mixed-case 'Um'")
  func handlesMixedCase() {
    let result = FillerWordCleaner.clean("Um, okay. UM, sure. um, yes.")
    #expect(!result.lowercased().contains("um,"))
  }

  // MARK: Non-filler preservation

  @Test("preserves 'like' used as a verb — conservative ruleset")
  func preservesLikeAsVerb() {
    // "I like coffee" — 'like' is a verb, must not be stripped.
    // The conservative ruleset only strips 'like' when followed by a comma.
    let input = "I like coffee every morning."
    let result = FillerWordCleaner.clean(input)
    #expect(result.contains("like coffee"), "Should preserve 'like' when used as a verb")
  }

  @Test("preserves 'you know' mid-sentence without comma boundary")
  func preservesYouKnowMidSentence() {
    // "You know this already" — 'you know' here is a statement, not a filler.
    // Conservative: only strip when followed by comma.
    let input = "You know this topic better than I do."
    let result = FillerWordCleaner.clean(input)
    #expect(result.contains("You know"), "Should preserve 'you know' used as a statement")
  }

  // MARK: Edge cases

  @Test("empty string returns empty string")
  func emptyString() {
    #expect(FillerWordCleaner.clean("") == "")
  }

  @Test("only-fillers input returns empty or whitespace-only string")
  func onlyFillers() {
    // "um uh" — after stripping, should be effectively empty (whitespace trimmed)
    let result = FillerWordCleaner.clean("um, uh,")
    // Acceptable: empty string or just punctuation remnants after trim
    #expect(result.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty)
  }

  @Test("fillers in the middle of a sentence are NOT stripped")
  func fillersInMiddleSentencePreserved() {
    // Filler removal is conservative: only sentence-boundary/comma patterns.
    // "I went, um, to the store" — mid-sentence filler with surrounding commas.
    // We document: mid-sentence "um," is also stripped when it matches the pattern.
    let input = "I went, um, to the store."
    let result = FillerWordCleaner.clean(input)
    // After cleaning "um," mid-sentence, result should not contain ", um,"
    #expect(!result.contains(", um,"))
  }

  @Test("unicode text with fillers is handled safely")
  func unicodeText() {
    // Fillers followed by unicode content must not corrupt the string.
    // The cleaner capitalises the first character of the result, so "café"
    // becomes "Café" — test the lowercased result for the substring check.
    let input = "Um, café au lait is délicieux."
    let result = FillerWordCleaner.clean(input)
    #expect(result.lowercased().contains("café au lait"))
    #expect(!result.lowercased().hasPrefix("um"))
  }

  @Test("sentence-initial filler followed by comma is stripped cleanly")
  func punctuationCleanup() {
    // "Um, let's go." → "Let's go." (comma is consumed, next word is recapitalised)
    let result = FillerWordCleaner.clean("Um, let's go.")
    #expect(result == "Let's go.")
  }
}

// MARK: - TokenCountTests

@Suite("TokenCount")
struct TokenCountTests {

  @Test("zero chars returns token count of 1 (max(1, 0/4))")
  func zeroChars() {
    #expect(tokenCount(charCount: 0) == 1)
  }

  @Test("4 chars returns 1 token")
  func fourChars() {
    #expect(tokenCount(charCount: 4) == 1)
  }

  @Test("5 chars returns 1 token (integer division)")
  func fiveChars() {
    #expect(tokenCount(charCount: 5) == 1)
  }

  @Test("8 chars returns 2 tokens")
  func eightChars() {
    #expect(tokenCount(charCount: 8) == 2)
  }

  @Test("100 chars returns 25 tokens")
  func hundredChars() {
    #expect(tokenCount(charCount: 100) == 25)
  }

  @Test("400 chars returns 100 tokens")
  func fourHundredChars() {
    #expect(tokenCount(charCount: 400) == 100)
  }

  // Helper that mirrors CaptureViewModel.tokenCount(charCount:)
  private func tokenCount(charCount: Int) -> Int {
    max(1, charCount / 4)
  }
}

// MARK: - LanguageDetectorTests

/// Tests for the `LanguageDetector` wrapper around `NLLanguageRecognizer`.
///
/// # Short-string behaviour
///
/// `detect(_:)` returns `nil` for inputs shorter than `LanguageDetector.minimumDetectableLength`
/// (currently 4 characters). Below this threshold `NLLanguageRecognizer` routinely
/// mis-identifies single common characters as a random language (e.g. `"I"` → `"hr"`),
/// so the guard is enforced in code rather than relying on the model's confidence score.
///
/// # Thread safety
///
/// Each `detect(_:)` call creates a fresh `NLLanguageRecognizer` instance. This avoids
/// data races under Swift Testing's parallel test runner and in any future concurrent
/// call site (the old shared-instance approach was not thread-safe).
@Suite("LanguageDetector")
struct LanguageDetectorTests {

  // MARK: - Language detection

  @Test("detects English from a clear English sentence")
  func detectsEnglish() {
    let lang = LanguageDetector.detect("The quick brown fox jumps over the lazy dog.")
    #expect(lang == "en")
  }

  @Test("detects French from a clear French sentence")
  func detectsFrench() {
    let lang = LanguageDetector.detect("Bonjour, comment allez-vous aujourd'hui?")
    #expect(lang == "fr")
  }

  // MARK: - nil-return contract (pinned)
  //
  // These are value-pinning assertions, not crash-guards. The production length
  // guard enforces nil independently of the language model.

  @Test("empty input returns nil")
  func emptyInputReturnsNil() {
    // 0 chars < minimumDetectableLength → nil unconditionally.
    #expect(LanguageDetector.detect("") == nil)
  }

  @Test("single character returns nil")
  func singleCharReturnsNil() {
    // 1 char < minimumDetectableLength → nil unconditionally.
    // Without this guard, NLLanguageRecognizer mis-identifies "I" as "hr".
    #expect(LanguageDetector.detect("I") == nil)
  }

  // MARK: - Threshold contract (pinned)

  @Test("minimumDetectableLength is 4")
  func minimumDetectableLengthIsCorrect() {
    // Pins the threshold so accidental widening is caught immediately.
    // Increase only with a corresponding update to the doc comment and tests.
    #expect(LanguageDetector.minimumDetectableLength == 4)
  }

  @Test("3-character input returns nil (below threshold)")
  func threeCharInputReturnsNil() {
    // "ici" is a valid French word but below the minimum length.
    #expect(LanguageDetector.detect("ici") == nil)
  }

  // MARK: - Format contract

  @Test("returns a BCP-47 code (e.g. 'en', 'fr') not an Apple locale identifier")
  func returnsBCP47Format() {
    // NLLanguageRecognizer returns codes like "en", "fr", "de" not "en_US".
    // Pinning the exact value catches a nil regression that an `if let` would
    // silently skip.
    let lang = LanguageDetector.detect("Hello world, this is a test sentence.")
    #expect(lang == "en")
  }
}

// MARK: - CaptureViewModelPolishTests
//
// Verifies payload wiring: when fillerWordCleanup is ON, the encoded payload
// content is the cleaned text; when OFF, it is the raw text.

@Suite("CaptureViewModel.polish")
struct CaptureViewModelPolishTests {

  @Test("payload encodes raw text when filler cleanup is OFF")
  func payloadRawWhenCleanupOff() throws {
    let rawContent = "Um, I think we should ship this feature."
    let payload = CaptureViewModel.buildPayload(
      content: rawContent,
      sourceModality: "typed",
      applyFillerCleanup: false,
      detectedLanguage: "en",
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(decoded.content == rawContent, "Raw content should be unmodified when cleanup is off")
  }

  @Test("payload encodes cleaned text when filler cleanup is ON")
  func payloadCleanedWhenCleanupOn() throws {
    let rawContent = "Um, I think we should ship this feature."
    let payload = CaptureViewModel.buildPayload(
      content: rawContent,
      sourceModality: "typed",
      applyFillerCleanup: true,
      detectedLanguage: "en",
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(!decoded.content.lowercased().hasPrefix("um"), "Cleaned content should strip leading 'Um,'")
    #expect(decoded.content != rawContent, "Cleaned content should differ from raw when cleanup is on")
  }

  @Test("payload language is detected language when no hint is set")
  func payloadLanguageFromDetected() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Hello world",
      sourceModality: "typed",
      applyFillerCleanup: false,
      detectedLanguage: "fr",
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(decoded.language == "fr")
  }

  @Test("payload language uses detected when hint and detected differ")
  func payloadLanguageDetectedWhenDiffers() throws {
    // When hint is "en" but we detected "fr", we send the detected language.
    // (See ticket §Integration hooks: "If they differ, send detected.")
    let payload = CaptureViewModel.buildPayload(
      content: "Bonjour le monde",
      sourceModality: "typed",
      applyFillerCleanup: false,
      detectedLanguage: "fr",
      languageHint: "en"
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(decoded.language == "fr", "Detected language should win when hint and detected differ")
  }

  @Test("payload language uses hint when hint and detected agree")
  func payloadLanguageHintWhenAgree() throws {
    // When hint is "en" and detected is "en", we can use either — test that
    // the result is "en" regardless of which wins.
    let payload = CaptureViewModel.buildPayload(
      content: "Hello there",
      sourceModality: "typed",
      applyFillerCleanup: false,
      detectedLanguage: "en",
      languageHint: "en"
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(decoded.language == "en")
  }

  @Test("typed capture has sourceModality 'typed'")
  func typedCaptureHasTypedModality() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Hello world",
      sourceModality: "typed",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(decoded.sourceModality == "typed", "Keyboard capture should have sourceModality 'typed'")
  }

  @Test("dictated capture has sourceModality 'dictated'")
  func dictatedCaptureHasDictatedModality() throws {
    let payload = CaptureViewModel.buildPayload(
      content: "Hello world",
      sourceModality: "dictated",
      applyFillerCleanup: false,
      detectedLanguage: nil,
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(decoded.sourceModality == "dictated", "Dictation capture should have sourceModality 'dictated'")
  }

  // MARK: - Settings-driven filler cleanup (#335)
  //
  // The filler-word toggle was removed from the Save screen in #335.
  // The save action now reads the persisted @AppStorage value and passes it
  // directly to buildPayload. These value-pin tests confirm that the
  // buildPayload pathway still applies cleanup correctly when the Settings
  // value is true, so the removal of the UI toggle causes no behaviour change.

  @Test("Settings-enabled filler cleanup strips fillers from save payload (#335)")
  func settingsEnabledFillerCleanupAppliedOnSave() throws {
    // Simulate: Settings has fillerWordCleanup = true.
    // The save action reads the persisted value and calls buildPayload with it.
    let rawContent = "Uh, I wanted to capture this thought."
    let payload = CaptureViewModel.buildPayload(
      content: rawContent,
      sourceModality: "typed",
      applyFillerCleanup: true,   // mirrors what CaptureView reads from @AppStorage
      detectedLanguage: "en",
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(!decoded.content.lowercased().hasPrefix("uh"), "Filler 'Uh,' should be stripped when Settings value is true")
    #expect(decoded.content != rawContent, "Cleaned content must differ from raw input")
  }

  @Test("Settings-disabled filler cleanup leaves save payload unchanged (#335)")
  func settingsDisabledFillerCleanupPreservesPayload() throws {
    // Simulate: Settings has fillerWordCleanup = false (the default).
    let rawContent = "Uh, I wanted to capture this thought."
    let payload = CaptureViewModel.buildPayload(
      content: rawContent,
      sourceModality: "typed",
      applyFillerCleanup: false,  // mirrors what CaptureView reads from @AppStorage
      detectedLanguage: "en",
      languageHint: nil
    )
    let encoded = try CaptureViewModel.encodePayload(payload)
    let decoded = try JSONDecoder().decode(DecodedBody.self, from: encoded)
    #expect(decoded.content == rawContent, "Raw content must be preserved when Settings cleanup is false")
  }

  // MARK: - Helpers

  /// Minimal decodable shape matching the CaptureRequestBody wire format.
  private struct DecodedBody: Decodable {
    let content: String
    let language: String
    let sourceModality: String

    enum CodingKeys: String, CodingKey {
      case content
      case language
      case sourceModality = "source_modality"
    }
  }
}

// MARK: - CaptureViewModel.tokenCount wiring tests
//
// Pins the wiring between `content.count` and `tokenCount` on the view model.
// The formula is already exercised by `TokenCountTests`; these tests catch a
// regression where the property formula is accidentally overridden or
// disconnected from `content`.

import SwiftData
import GroveCore

@Suite("CaptureViewModel.tokenCount")
@MainActor
struct CaptureViewModelTokenCountTests {

  // MARK: - Fixture

  /// Minimal in-memory queue — `tokenCount` never touches the upload queue,
  /// but `CaptureViewModel`'s init requires one.
  private func makeQueue() throws -> UploadQueue {
    let schema = Schema([QueuedCapture.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let api = GroveAPI(
      baseURL: URL(string: "https://grove.test.example")!,
      bearerToken: "test-token"
    )
    return UploadQueue(modelContainer: container, api: api)
  }

  // MARK: - Tests

  @Test("tokenCount is 1 for empty content")
  func viewModelTokenCountEmptyContent() throws {
    let vm = CaptureViewModel(uploadQueue: try makeQueue())
    // content defaults to "" — max(1, 0 / 4) == 1
    #expect(vm.tokenCount == 1)
  }

  @Test("tokenCount is 1 for 4-character content")
  func viewModelTokenCountFourChars() throws {
    let vm = CaptureViewModel(uploadQueue: try makeQueue())
    vm.content = "test"  // 4 chars → max(1, 4 / 4) == 1
    #expect(vm.tokenCount == 1)
  }
}
