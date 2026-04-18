//
//  WhisperTranscriptionService.swift
//  SAM
//
//  Wraps WhisperKit for on-device speech-to-text with word timestamps.
//  Loads the model lazily, transcribes PCM WAV files or Float sample arrays,
//  and returns segments with word-level timings.
//
//  Architecture:
//    WhisperTranscriptionEngine (actor) — owns WhisperKit, does all heavy
//      compute on its own executor (NOT the main thread).
//    WhisperTranscriptionService (@MainActor @Observable) — thin state
//      holder for SwiftUI observation. Delegates all work to the engine.
//

import Foundation
import os.log
import WhisperKit

// MARK: - Shared Types

/// Observable state for the Whisper model lifecycle.
enum WhisperModelState: Sendable, Equatable {
    case notLoaded
    case loading(progress: Double)
    case ready(modelID: String)
    case failed(String)
}

/// Transcription result — fully Sendable, safe to cross actor boundaries.
struct WhisperTranscriptResult: Sendable, Codable {
    let text: String
    let segments: [Segment]
    let detectedLanguage: String?
    let modelID: String

    struct Segment: Sendable, Codable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let words: [Word]
    }

    struct Word: Sendable, Codable {
        let word: String
        let start: TimeInterval
        let end: TimeInterval
        let confidence: Float
    }
}

enum WhisperTranscriptionError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Whisper model is not loaded."
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        }
    }
}

// MARK: - WhisperTranscriptionEngine (background actor)

/// Owns WhisperKit and runs all transcription on its own executor.
/// This is NOT @MainActor — all compute happens off the main thread.
actor WhisperTranscriptionEngine {

    static let shared = WhisperTranscriptionEngine()

    /// Default model — `base.en` is ~140MB, accurate for English meeting speech.
    nonisolated static let defaultModelID = "openai_whisper-base.en"

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "WhisperTranscriptionService")

    private var whisperKit: WhisperKit?
    private var loadedModelID: String?
    private var isLoading = false
    private var loadContinuations: [CheckedContinuation<Void, Error>] = []

    // MARK: - Model Loading

    /// Load the Whisper model. Safe to call multiple times.
    func loadModel(modelID: String = defaultModelID) async throws {
        if loadedModelID == modelID && whisperKit != nil { return }
        if isLoading {
            try await withCheckedThrowingContinuation { loadContinuations.append($0) }
            return
        }

        isLoading = true

        logger.info("Loading WhisperKit model: \(modelID) — first run will download, subsequent runs load from cache")

        // Notify main actor of loading state
        await MainActor.run {
            WhisperTranscriptionService.shared.modelState = .loading(progress: 0)
            WhisperTranscriptionService.shared.currentModelID = modelID
        }

        do {
            let config = WhisperKitConfig(
                model: modelID,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )

            let kit = try await WhisperKit(config)
            whisperKit = kit
            loadedModelID = modelID
            isLoading = false
            let waiting = loadContinuations
            loadContinuations.removeAll()
            for c in waiting { c.resume() }

            logger.info("✅ WhisperKit model loaded: \(modelID)")

            await MainActor.run {
                WhisperTranscriptionService.shared.modelState = .ready(modelID: modelID)
            }
        } catch {
            isLoading = false
            whisperKit = nil
            loadedModelID = nil
            let waiting = loadContinuations
            loadContinuations.removeAll()
            for c in waiting { c.resume(throwing: error) }

            logger.error("❌ WhisperKit load failed: \(error.localizedDescription)")

            await MainActor.run {
                WhisperTranscriptionService.shared.modelState = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Unload the model to free memory.
    func unloadModel() async {
        whisperKit = nil
        loadedModelID = nil

        await MainActor.run {
            WhisperTranscriptionService.shared.modelState = .notLoaded
            WhisperTranscriptionService.shared.currentModelID = nil
        }
    }

    // MARK: - Transcription

    /// Transcribe an audio file. Runs entirely off the main thread.
    func transcribe(fileURL: URL) async throws -> WhisperTranscriptResult {
        if whisperKit == nil {
            try await loadModel()
        }
        guard let kit = whisperKit else {
            throw WhisperTranscriptionError.modelNotLoaded
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

        return Self.buildResult(from: results, modelID: loadedModelID ?? Self.defaultModelID)
    }

    /// Transcribe a float sample array. Runs entirely off the main thread.
    func transcribe(audioArray: [Float]) async throws -> WhisperTranscriptResult {
        if whisperKit == nil {
            try await loadModel()
        }
        guard let kit = whisperKit else {
            throw WhisperTranscriptionError.modelNotLoaded
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

        return Self.buildResult(from: results, modelID: loadedModelID ?? Self.defaultModelID)
    }

    // MARK: - Result Assembly (nonisolated — pure functions)

    private static func buildResult(from results: [TranscriptionResult], modelID: String) -> WhisperTranscriptResult {
        var allSegments: [WhisperTranscriptResult.Segment] = []
        var fullText = ""
        var language: String?

        for result in results {
            if language == nil, !result.language.isEmpty {
                language = result.language
            }
            fullText += cleanWhisperText(result.text)

            for segment in result.segments {
                let words: [WhisperTranscriptResult.Word] = (segment.words ?? []).map { w in
                    WhisperTranscriptResult.Word(
                        word: cleanWhisperText(w.word),
                        start: TimeInterval(w.start),
                        end: TimeInterval(w.end),
                        confidence: w.probability
                    )
                }
                let nonEmptyWords = words.filter { !$0.word.isEmpty }

                let cleanedText: String
                if !nonEmptyWords.isEmpty {
                    cleanedText = rebuildText(from: nonEmptyWords.map { $0.word })
                } else {
                    cleanedText = cleanWhisperText(segment.text)
                }

                guard !cleanedText.isEmpty else { continue }

                allSegments.append(WhisperTranscriptResult.Segment(
                    text: cleanedText,
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    words: nonEmptyWords
                ))
            }
        }

        return WhisperTranscriptResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: allSegments,
            detectedLanguage: language,
            modelID: modelID
        )
    }

    static func rebuildText(from words: [String]) -> String {
        let trimmed = words
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return trimmed.joined(separator: " ")
    }

    private static func cleanWhisperText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let tokenPattern = #"<\|[^|]*\|>"#
        var cleaned = text.replacingOccurrences(
            of: tokenPattern,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WhisperTranscriptionService (@MainActor state holder)

/// Thin @MainActor wrapper for SwiftUI observation. All heavy work is
/// delegated to `WhisperTranscriptionEngine` which runs on its own actor.
@MainActor
@Observable
final class WhisperTranscriptionService {

    static let shared = WhisperTranscriptionService()

    // MARK: - Observable State (SwiftUI watches these)

    var modelState: WhisperModelState = .notLoaded
    var currentModelID: String?

    // MARK: - Type Aliases (preserve API compatibility)

    typealias ModelState = WhisperModelState
    typealias TranscriptResult = WhisperTranscriptResult
    typealias TranscriptionError = WhisperTranscriptionError

    nonisolated static let defaultModelID = WhisperTranscriptionEngine.defaultModelID

    private init() {}

    // MARK: - Delegated API

    /// Load the Whisper model. Updates observable state on main actor,
    /// but the actual model loading runs off main thread.
    func loadModel(modelID: String = defaultModelID) async throws {
        try await WhisperTranscriptionEngine.shared.loadModel(modelID: modelID)
    }

    /// Unload the model to free memory.
    func unloadModel() async {
        await WhisperTranscriptionEngine.shared.unloadModel()
    }

    /// Transcribe an audio file. The heavy compute runs off main thread;
    /// only this call/return crosses the main actor.
    func transcribe(fileURL: URL) async throws -> TranscriptResult {
        try await WhisperTranscriptionEngine.shared.transcribe(fileURL: fileURL)
    }

    /// Transcribe a float sample array.
    func transcribe(audioArray: [Float]) async throws -> TranscriptResult {
        try await WhisperTranscriptionEngine.shared.transcribe(audioArray: audioArray)
    }

    /// Reconstruct text from word array (convenience — delegates to engine).
    static func rebuildText(from words: [String]) -> String {
        WhisperTranscriptionEngine.rebuildText(from: words)
    }
}
