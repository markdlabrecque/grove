// WhisperKitRecognizer.swift
// Grove — spike branch only (issue #384)
//
// This file is SPIKE-ONLY code on branch spike/384-whisperkit.
// It is NOT production-ready and MUST NOT be merged to develop without
// a production follow-up ticket that resolves the protocol seam mismatch
// documented below.
//
// ─── Protocol seam note ─────────────────────────────────────────────────────
// The existing `SpeechRecognizing` protocol is tightly coupled to
// `SFSpeechRecognizer`'s Objective-C types:
//
//   recognitionTask(with: SFSpeechAudioBufferRecognitionRequest,
//                   resultHandler: (SFSpeechRecognitionResult?, Error?) -> Void)
//     -> SFSpeechRecognitionTask
//
// `SFSpeechRecognitionTask` is a final Objective-C class; we cannot synthesise
// a conforming return value from Swift. WhisperKit uses a completely different
// concurrency model (actor `AudioStreamTranscriber`, pull-based audio loop).
//
// Recommendation (see #384 spike findings): the production ticket should
// introduce a second, Swift-native protocol alongside `SpeechRecognizing`
// — tentatively `DictationEngine` — that exposes:
//
//   func startStream() -> AsyncStream<DictationEvent>
//   func stopStream()
//
// `DictationController` would then be refactored to accept `any DictationEngine`
// rather than `any SpeechRecognizing`, making WhisperKit a genuine drop-in.
// ────────────────────────────────────────────────────────────────────────────

import AVFoundation
import Foundation
import Speech
import WhisperKit

// MARK: - WhisperKitRecognizer

/// A standalone dictation controller backed by WhisperKit's on-device Whisper
/// models rather than Apple's `SFSpeechRecognizer`.
///
/// This class intentionally mirrors the public API of ``DictationController``
/// (`start()` → `AsyncStream<DictationEvent>`, `stop()`) so that the
/// call-site diff in a future production ticket is minimal. It does NOT
/// conform to `SpeechRecognizing` because that protocol requires returning an
/// `SFSpeechRecognitionTask`, which is a final Objective-C class that cannot
/// be subclassed or synthetically instantiated from Swift.
///
/// ## Model choice
///
/// The default model is `openai_whisper-small.en` (≈ 217 MB download,
/// ≈ 465 MB resident after ANE specialisation). `openai_whisper-base.en`
/// (≈ 145 MB) is offered as the lightweight option. Both are lazy-downloaded
/// from HuggingFace on first use; nothing is bundled in the app binary.
///
/// Swap the constant below to trial other variants during the spike.
///
/// ## Threading
///
/// All public methods are `@MainActor`-isolated to match `DictationController`.
/// WhisperKit's `AudioStreamTranscriber` is itself an `actor`; state-change
/// callbacks are delivered on WhisperKit's internal queue and hopped to the
/// main actor before touching any `WhisperKitRecognizer` state.
@MainActor
final class WhisperKitRecognizer {

  // MARK: - Model configuration (tune during spike)

  /// Primary spike model. Adjust to `"openai_whisper-base.en"` to compare.
  nonisolated static let defaultModel = "openai_whisper-small.en"

  // MARK: - State

  /// Load state so callers can show a progress indicator during model load.
  enum LoadState {
    case idle
    case loading
    case ready
    case failed(Error)
  }

  private(set) var loadState: LoadState = .idle

  // MARK: - Private

  private var whisperKit: WhisperKit?
  private var transcriber: AudioStreamTranscriber?
  private var continuation: AsyncStream<DictationEvent>.Continuation?

  /// Timestamp when mic was armed; used to measure first-partial latency.
  private var sessionStartDate: Date?
  private var firstPartialEmitted = false

  // MARK: - Authorisation

  /// Requests microphone access.
  ///
  /// WhisperKit manages its own mic permission through `AudioProcessor`;
  /// we mirror the behaviour of `DictationController.requestAuthorization()`
  /// and throw `DictationError` on denial so callers are consistent.
  func requestAuthorization() async throws {
    let granted = await AVAudioApplication.requestRecordPermission()
    guard granted else {
      throw DictationError.microphonePermissionDenied
    }
    // WhisperKit does not require speech-recognition entitlement — on-device
    // only, so no `SFSpeechRecognizer.requestAuthorization()` call needed.
  }

  // MARK: - Model load

  /// Loads (and, if needed, downloads) the Whisper model.
  ///
  /// This is a cold-start measurement point for the spike. Call it eagerly
  /// on app launch to prime the model; the `loadState` transitions allow
  /// the UI to show a loading indicator.
  ///
  /// - Parameter model: The HuggingFace variant name. Defaults to
  ///   ``defaultModel``.
  func loadModel(_ model: String = WhisperKitRecognizer.defaultModel) async {
    guard case .idle = loadState else { return }
    loadState = .loading

    let loadStart = Date()
    do {
      let config = WhisperKitConfig(
        model: model,
        verbose: true,
        logLevel: .debug,
        // Download to app's Caches directory; not bundled.
        download: true,
        useBackgroundDownloadSession: false
      )
      let kit = try await WhisperKit(config)
      whisperKit = kit
      let elapsed = Date().timeIntervalSince(loadStart)
      loadState = .ready
      // Log cold-start time so it appears in Xcode console during spike.
      print("[WhisperKitRecognizer] Model '\(model)' ready in \(String(format: "%.2f", elapsed))s")
    } catch {
      loadState = .failed(error)
      print("[WhisperKitRecognizer] Model load failed: \(error)")
    }
  }

  // MARK: - Start

  /// Begins a dictation session and returns an `AsyncStream<DictationEvent>`.
  ///
  /// The stream emits `.partial` updates as WhisperKit produces unconfirmed
  /// segments, followed by one `.final_` when `stop()` is called.  If the
  /// model is not yet loaded, it is loaded now (cold-start path).
  func start() -> AsyncStream<DictationEvent> {
    AsyncStream<DictationEvent> { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      self.continuation = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor [weak self] in self?.teardown() }
      }
      Task { @MainActor [weak self] in
        await self?.beginSession()
      }
    }
  }

  // MARK: - Stop

  /// Stops the current session and yields the final transcript.
  ///
  /// Safe to call multiple times; subsequent calls are no-ops.
  func stop() {
    guard let t = transcriber else { return }
    Task {
      await t.stopStreamTranscription()
    }
    // `teardown()` is also triggered by the state-change callback when
    // `isRecording` flips to false; calling it here as well is a safety net.
    teardown()
  }

  // MARK: - Private helpers

  private func beginSession() async {
    // Ensure model is loaded.
    if case .idle = loadState {
      await loadModel()
    }
    guard case .ready = loadState, let kit = whisperKit else {
      emit(.error(.recognizerUnavailable))
      teardown()
      return
    }

    sessionStartDate = Date()
    firstPartialEmitted = false

    // Build the AudioStreamTranscriber with sensible spike defaults.
    let decodingOptions = DecodingOptions(
      verbose: false,
      task: .transcribe,
      language: "en",
      // Temperature scheduling: start low, allow fallback.
      temperature: 0,
      temperatureIncrementOnFallback: 0.2,
      temperatureFallbackCount: 3,
      // Two required segments before confirming a segment; reduces word-loss
      // at the cost of slightly more lag on short utterances.
      sampleLength: 224,
      usePrefillPrompt: true,
      skipSpecialTokens: true,
      withoutTimestamps: true,
      // Chunking strategy: VAD-based so silent gaps don't trigger a decode
      // cycle unnecessarily.
      chunkingStrategy: .vad
    )

    let transcriberInstance = AudioStreamTranscriber(
      audioEncoder: kit.audioEncoder,
      featureExtractor: kit.featureExtractor,
      segmentSeeker: kit.segmentSeeker,
      textDecoder: kit.textDecoder,
      tokenizer: kit.tokenizer!,
      audioProcessor: kit.audioProcessor,
      decodingOptions: decodingOptions,
      requiredSegmentsForConfirmation: 2,
      silenceThreshold: 0.3,
      useVAD: true
    ) { [weak self] oldState, newState in
      Task { @MainActor [weak self] in
        self?.handleStateChange(oldState, newState)
      }
    }
    transcriber = transcriberInstance

    do {
      try await transcriberInstance.startStreamTranscription()
    } catch {
      emit(.error(.audioEngineError(error.localizedDescription)))
      teardown()
    }
  }

  // MARK: - State-change handler (always on @MainActor)

  private func handleStateChange(
    _ old: AudioStreamTranscriber.State,
    _ new: AudioStreamTranscriber.State
  ) {
    // Assemble the running transcript from confirmed + unconfirmed segments.
    let confirmedText = new.confirmedSegments
      .map { $0.text }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)

    let unconfirmedText = new.unconfirmedSegments
      .map { $0.text }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)

    let combinedText = [confirmedText, unconfirmedText]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)

    // Only emit if text changed to avoid redundant UI updates.
    guard combinedText != assembleText(from: old) else { return }

    if !firstPartialEmitted, !combinedText.isEmpty, let start = sessionStartDate {
      let latency = Date().timeIntervalSince(start)
      print("[WhisperKitRecognizer] First-partial latency: \(String(format: "%.2f", latency))s")
      firstPartialEmitted = true
    }

    if !new.isRecording && old.isRecording {
      // Session ended — emit final.
      emit(.final_(combinedText))
      teardown()
    } else if !combinedText.isEmpty {
      emit(.partial(combinedText))
    }
  }

  private func assembleText(from state: AudioStreamTranscriber.State) -> String {
    let confirmed = state.confirmedSegments.map { $0.text }.joined(separator: " ")
    let unconfirmed = state.unconfirmedSegments.map { $0.text }.joined(separator: " ")
    return [confirmed, unconfirmed]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  // MARK: - Emit

  private func emit(_ event: DictationEvent) {
    continuation?.yield(event)
    if case .final_ = event { continuation?.finish() }
    if case .error = event { continuation?.finish() }
  }

  // MARK: - Teardown

  private func teardown() {
    transcriber = nil
    continuation?.finish()
    continuation = nil
    sessionStartDate = nil
    firstPartialEmitted = false
  }
}
