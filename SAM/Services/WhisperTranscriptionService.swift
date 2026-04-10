//
//  WhisperTranscriptionService.swift
//  SAM
//
//  Wraps WhisperKit for on-device speech-to-text with word timestamps.
//  Loads the model lazily, transcribes PCM WAV files or Float sample arrays,
//  and returns segments with word-level timings.
//
//  Model: openai_whisper-large-v3_turbo (~1.6GB, runs on Apple Silicon ANE).
//

import Foundation
import os.log
import WhisperKit

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "WhisperTranscriptionService")

@MainActor
@Observable
final class WhisperTranscriptionService {

    static let shared = WhisperTranscriptionService()

    // MARK: - Types

    enum ModelState: Sendable, Equatable {
        case notLoaded
        case loading(progress: Double)
        case ready(modelID: String)
        case failed(String)
    }

    struct TranscriptResult: Sendable {
        let text: String
        let segments: [Segment]
        let detectedLanguage: String?
        let modelID: String

        struct Segment: Sendable {
            let text: String
            let start: TimeInterval
            let end: TimeInterval
            let words: [Word]
        }

        struct Word: Sendable {
            let word: String
            let start: TimeInterval
            let end: TimeInterval
            let confidence: Float
        }
    }

    // MARK: - State

    private(set) var modelState: ModelState = .notLoaded

    /// The WhisperKit model ID currently loaded / being loaded.
    private(set) var currentModelID: String?

    /// Default model — `base.en` is ~140MB, downloads in well under a minute,
    /// and is accurate enough for English meeting speech. Users can switch to
    /// `openai_whisper-large-v3-turbo` (1.6GB) for higher accuracy.
    static let defaultModelID = "openai_whisper-base.en"

    // MARK: - Private

    private var whisperKit: WhisperKit?
    private var loadTask: Task<Void, Error>?

    private init() {}

    // MARK: - Model Loading

    /// Load the Whisper model. Safe to call multiple times — subsequent calls wait for the first.
    func loadModel(modelID: String = defaultModelID) async throws {
        // If already loaded with this model, return immediately
        if case .ready(let loaded) = modelState, loaded == modelID {
            return
        }

        // If a load is already in flight, await it
        if let existing = loadTask {
            try await existing.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                self.modelState = .loading(progress: 0)
                self.currentModelID = modelID

                logger.info("Loading WhisperKit model: \(modelID) — first run will download, subsequent runs load from cache")

                let config = WhisperKitConfig(
                    model: modelID,
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: true,
                    download: true
                )

                let kit = try await WhisperKit(config)
                self.whisperKit = kit
                self.modelState = .ready(modelID: modelID)

                logger.info("✅ WhisperKit model loaded: \(modelID)")
            } catch {
                logger.error("❌ WhisperKit load failed: \(error.localizedDescription)")
                self.modelState = .failed(error.localizedDescription)
                self.whisperKit = nil
                self.loadTask = nil
                throw error
            }
            self.loadTask = nil
        }
        self.loadTask = task
        try await task.value
    }

    /// Unload the model to free memory.
    func unloadModel() {
        whisperKit = nil
        loadTask?.cancel()
        loadTask = nil
        modelState = .notLoaded
        currentModelID = nil
    }

    // MARK: - Transcription

    /// Transcribe an audio file (WAV/any format WhisperKit can read).
    /// Returns segments with word-level timestamps.
    func transcribe(fileURL: URL) async throws -> TranscriptResult {
        if whisperKit == nil {
            try await loadModel()
        }
        guard let kit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        logger.debug("Transcribing file: \(fileURL.lastPathComponent)")

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            withoutTimestamps: false,
            wordTimestamps: true
        )

        let results = try await kit.transcribe(
            audioPath: fileURL.path,
            decodeOptions: options
        )

        return buildResult(from: results)
    }

    /// Transcribe a float sample array (16kHz mono expected — WhisperKit will resample if needed).
    func transcribe(audioArray: [Float]) async throws -> TranscriptResult {
        if whisperKit == nil {
            try await loadModel()
        }
        guard let kit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            withoutTimestamps: false,
            wordTimestamps: true
        )

        let results = try await kit.transcribe(
            audioArray: audioArray,
            decodeOptions: options
        )

        return buildResult(from: results)
    }

    // MARK: - Result Assembly

    private func buildResult(from results: [TranscriptionResult]) -> TranscriptResult {
        var allSegments: [TranscriptResult.Segment] = []
        var fullText = ""
        var language: String?

        for result in results {
            if language == nil, !result.language.isEmpty {
                language = result.language
            }
            fullText += result.text

            for segment in result.segments {
                let words: [TranscriptResult.Word] = (segment.words ?? []).map { w in
                    TranscriptResult.Word(
                        word: w.word,
                        start: TimeInterval(w.start),
                        end: TimeInterval(w.end),
                        confidence: w.probability
                    )
                }

                allSegments.append(TranscriptResult.Segment(
                    text: segment.text,
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    words: words
                ))
            }
        }

        return TranscriptResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: allSegments,
            detectedLanguage: language,
            modelID: currentModelID ?? Self.defaultModelID
        )
    }

    // MARK: - Errors

    enum TranscriptionError: LocalizedError {
        case modelNotLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "Whisper model is not loaded."
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            }
        }
    }
}
