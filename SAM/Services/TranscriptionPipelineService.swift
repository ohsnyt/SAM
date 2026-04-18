//
//  TranscriptionPipelineService.swift
//  SAM
//
//  Buffers incoming audio chunks, triggers WhisperKit transcription on
//  sliding windows, and emits transcript segments with de-duplicated text.
//
//  Windowing strategy:
//    - Accumulate ~30 seconds of audio
//    - Every (windowDuration - overlapDuration) seconds, transcribe the last windowDuration seconds
//    - Dedupe by tracking the latest committed word end-time from the previous window
//    - Keep the overlap for context so WhisperKit has continuity
//

import Foundation
import os.log

@MainActor
@Observable
final class TranscriptionPipelineService {

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TranscriptionPipelineService")

    // MARK: - Types

    /// A transcript segment emitted by the pipeline with speaker attribution.
    struct EmittedSegment: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let words: [WhisperTranscriptionService.TranscriptResult.Word]
        let speakerClusterID: Int
        let speakerLabel: String
        let speakerConfidence: Float
    }

    // MARK: - Configuration

    /// Duration of each transcription window (seconds).
    static let windowDuration: TimeInterval = 30.0

    /// Overlap between adjacent windows (seconds) — gives WhisperKit continuity.
    static let overlapDuration: TimeInterval = 5.0

    /// How often to trigger a new transcription = windowDuration - overlapDuration.
    static var stepDuration: TimeInterval { windowDuration - overlapDuration }

    /// Maximum buffer retention in seconds (safety cap — drops old audio if processing falls behind).
    static let maxBufferDuration: TimeInterval = 90.0

    // MARK: - State

    enum PipelineState: Sendable, Equatable {
        case idle
        case loadingModel    // Downloading / loading Whisper model
        case ready           // Model loaded, waiting for audio
        case processing      // Transcribing a window
        case error(String)
    }

    private(set) var pipelineState: PipelineState = .idle

    /// Segments emitted so far for the current session (ordered by start time).
    private(set) var emittedSegments: [EmittedSegment] = []

    /// Windows processed so far this session.
    private(set) var windowsProcessed: Int = 0

    /// Number of distinct speaker clusters detected this session.
    private(set) var detectedSpeakerCount: Int = 0

    /// Enrolled agent embedding used to label segments — nil if no profile enrolled.
    var enrolledAgentEmbedding: [Float]?

    /// Expected speaker names from the phone's session prep screen.
    /// Used to label diarization clusters with real names.
    var expectedSpeakerNames: [String] = []

    /// Callback fired on the main actor when new segments are emitted.
    var onSegmentsEmitted: (([EmittedSegment]) -> Void)?

    /// Callback fired when language is first detected.
    var onLanguageDetected: ((String) -> Void)?

    // MARK: - Private

    /// Accumulated PCM samples as Int16 interleaved, at the session's native sample rate.
    private var pcmBuffer = Data()

    /// Session audio format captured from the first chunk.
    private var sessionSampleRate: UInt32 = 0
    private var sessionChannels: UInt16 = 0

    /// Time offset (in seconds) of the start of pcmBuffer relative to session start.
    private var bufferStartOffset: TimeInterval = 0

    /// End time (relative to session start) of the last word we've committed.
    /// Any new window's words with end <= this are discarded as duplicates.
    private var lastCommittedEndTime: TimeInterval = 0

    /// Last window trigger timestamp in seconds. Reset in `reset()` so the first window triggers as soon as enough audio arrives.
    private var lastWindowTriggerOffset: TimeInterval = -100

    /// Is a transcription currently running?
    private var isTranscribing = false

    /// Temp directory for window WAV files.
    private var tempDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptionWindows", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Lifecycle

    /// Prepare the pipeline and load the Whisper model.
    func start() async {
        pipelineState = .loadingModel
        reset()
        logger.info("Pipeline start() — loading Whisper model (first run downloads, may take a minute)…")
        do {
            try await WhisperTranscriptionService.shared.loadModel()
            pipelineState = .ready
            logger.info("Transcription pipeline ready — waiting for audio")
        } catch {
            pipelineState = .error(error.localizedDescription)
            logger.error("Failed to prepare pipeline: \(error.localizedDescription)")
        }
    }

    /// Feed a new audio chunk into the pipeline.
    func ingest(chunk: AudioChunk) {
        // Capture session format on first chunk
        if sessionSampleRate == 0 {
            sessionSampleRate = chunk.sampleRate
            sessionChannels = chunk.channels
            logger.info("First chunk: \(chunk.sampleRate)Hz \(chunk.channels)ch, \(chunk.pcmData.count) bytes")
        }

        pcmBuffer.append(chunk.pcmData)

        // Cap buffer size
        let bufferDuration = currentBufferDuration()
        if bufferDuration > Self.maxBufferDuration {
            let excess = bufferDuration - Self.maxBufferDuration
            dropFromFront(seconds: excess)
        }

        // Check if we should trigger a new window
        let currentEndOffset = bufferStartOffset + bufferDuration
        let timeSinceLast = currentEndOffset - lastWindowTriggerOffset
        let canTrigger = timeSinceLast >= TranscriptionPipelineService.stepDuration
                      && bufferDuration >= TranscriptionPipelineService.windowDuration
                      && !isTranscribing

        if canTrigger {
            logger.info("Triggering window at \(String(format: "%.1f", currentEndOffset))s (buffer=\(String(format: "%.1f", bufferDuration))s)")
            lastWindowTriggerOffset = currentEndOffset
            triggerWindowProcessing()
        }
    }

    /// Stop the pipeline and process any remaining audio as a final window.
    /// Waits for any in-flight window transcription to complete first to avoid
    /// racing on shared state (pcmBuffer, emittedSegments, lastCommittedEndTime).
    func finishSession() async {
        // Wait for any in-flight window to finish.
        var safetyCounter = 0
        while isTranscribing, safetyCounter < 600 { // max 60s wait
            try? await Task.sleep(for: .milliseconds(100))
            safetyCounter += 1
        }
        if isTranscribing {
            logger.warning("finishSession timed out waiting for in-flight window; proceeding anyway")
        }

        // Transcribe any remaining audio that hasn't been windowed.
        let bufferDuration = currentBufferDuration()
        let processedThrough = lastWindowTriggerOffset
        let bufferEnd = bufferStartOffset + bufferDuration

        if bufferEnd > processedThrough, bufferDuration > 1.0 {
            logger.info("Processing final window (remaining: \(String(format: "%.1f", bufferEnd - processedThrough))s)")
            await processFinalWindow()
        }

        pipelineState = .ready // stay ready for the next session — model is loaded
    }

    /// Reset all state for a new session.
    ///
    /// IMPORTANT: This clobbers in-flight state. Callers must ensure no window
    /// is currently being transcribed before calling this — use
    /// `waitForQuiescence()` first. The coordinator does this via
    /// `handleSessionStart`.
    func reset() {
        pcmBuffer = Data()
        sessionSampleRate = 0
        sessionChannels = 0
        bufferStartOffset = 0
        lastCommittedEndTime = 0
        lastWindowTriggerOffset = -TranscriptionPipelineService.stepDuration
        isTranscribing = false
        emittedSegments = []
        windowsProcessed = 0
        detectedSpeakerCount = 0
        cleanupTempFiles()
    }

    /// Wait until no window is currently being transcribed. Returns true if
    /// the pipeline went quiet within `timeout` seconds, false on timeout.
    /// Used before `reset()` to avoid the race where a prior session's
    /// in-flight window would clobber the new session's state.
    func waitForQuiescence(timeout: TimeInterval = 60) async -> Bool {
        let step: TimeInterval = 0.1
        let maxIterations = Int(timeout / step)
        var i = 0
        while isTranscribing && i < maxIterations {
            try? await Task.sleep(for: .milliseconds(100))
            i += 1
        }
        if isTranscribing {
            logger.warning("waitForQuiescence timed out after \(timeout)s — pipeline still busy")
            return false
        }
        return true
    }

    // MARK: - Window Processing

    private func triggerWindowProcessing() {
        guard !isTranscribing else { return }
        isTranscribing = true

        // Snapshot the window data (last windowDuration seconds)
        let bufferDuration = currentBufferDuration()
        let windowStartInBuffer = max(0, bufferDuration - Self.windowDuration)
        let windowStartOffset = bufferStartOffset + windowStartInBuffer

        let bytesPerSecond = bytesPerSecondInBuffer()
        let startByte = Int(windowStartInBuffer * Double(bytesPerSecond))
        let windowData = pcmBuffer.suffix(pcmBuffer.count - startByte)

        let sampleRate = sessionSampleRate
        let channels = sessionChannels

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.processWindow(
                data: Data(windowData),
                sampleRate: sampleRate,
                channels: channels,
                absoluteStartOffset: windowStartOffset
            )
        }
    }

    private func processFinalWindow() async {
        guard !pcmBuffer.isEmpty else { return }
        isTranscribing = true

        // Process whatever audio has arrived since the last window trigger
        let bufferDuration = currentBufferDuration()
        let triggerOffsetInBuffer = max(0, lastWindowTriggerOffset - bufferStartOffset)

        // Take everything from (last trigger - overlap) to end, so we have context
        let contextStartInBuffer = max(0, triggerOffsetInBuffer - Self.overlapDuration)
        let windowStartOffset = bufferStartOffset + contextStartInBuffer

        let bytesPerSecond = bytesPerSecondInBuffer()
        let startByte = Int(contextStartInBuffer * Double(bytesPerSecond))
        let startIndex = pcmBuffer.startIndex.advanced(by: min(startByte, pcmBuffer.count))
        let windowData = Data(pcmBuffer[startIndex..<pcmBuffer.endIndex])

        _ = bufferDuration // silence unused warning if compiler optimizes it out

        await processWindow(
            data: windowData,
            sampleRate: sessionSampleRate,
            channels: sessionChannels,
            absoluteStartOffset: windowStartOffset
        )
    }

    private func processWindow(
        data: Data,
        sampleRate: UInt32,
        channels: UInt16,
        absoluteStartOffset: TimeInterval
    ) async {
        do {
            pipelineState = .processing
            logger.info("processWindow: \(data.count) bytes @ \(sampleRate)Hz/\(channels)ch, startOffset=\(String(format: "%.1f", absoluteStartOffset))s")

            // Write window to temp WAV file — WhisperKit handles resampling
            let tempURL = tempDirectory.appendingPathComponent("window-\(UUID().uuidString).wav")
            try writeWAV(pcmData: data, sampleRate: sampleRate, channels: channels, to: tempURL)

            // Transcribe via WhisperKit
            logger.info("Calling WhisperKit.transcribe…")
            let result = try await WhisperTranscriptionService.shared.transcribe(fileURL: tempURL)
            logger.info("WhisperKit returned \(result.segments.count) segments, text=\"\(result.text.prefix(120))\"")

            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)

            // Language detection (once)
            if windowsProcessed == 0, let lang = result.detectedLanguage {
                onLanguageDetected?(lang)
            }

            // Run diarization on the same audio. Prefer SpeakerKit (neural)
            // with 16kHz resampled audio for best speaker separation.
            // Falls back to MFCC if SpeakerKit isn't available.
            let monoFloats = convertInt16PCMToMonoFloat(pcmData: data, channels: Int(channels))
            let diarization: DiarizationService.DiarizationResult
            if DiarizationService.shared.preferNeuralDiarization {
                do {
                    diarization = try await DiarizationService.shared.diarizeWithSpeakerKit(
                        samples: monoFloats,
                        sampleRate: Double(sampleRate),
                        startOffset: absoluteStartOffset,
                        enrolledAgentEmbedding: enrolledAgentEmbedding
                    )
                } catch {
                    logger.warning("SpeakerKit diarization failed on window, falling back to MFCC: \(error.localizedDescription)")
                    diarization = DiarizationService.shared.diarize(
                        samples: monoFloats,
                        sampleRate: Double(sampleRate),
                        startOffset: absoluteStartOffset,
                        enrolledAgentEmbedding: enrolledAgentEmbedding
                    )
                }
            } else {
                diarization = DiarizationService.shared.diarize(
                    samples: monoFloats,
                    sampleRate: Double(sampleRate),
                    startOffset: absoluteStartOffset,
                    enrolledAgentEmbedding: enrolledAgentEmbedding
                )
            }

            // Merge: assign speaker labels to WhisperKit segments based on diarization
            let newSegments = dedupeAndOffsetSegments(
                result.segments,
                absoluteStartOffset: absoluteStartOffset,
                diarization: diarization
            )

            if !newSegments.isEmpty {
                emittedSegments.append(contentsOf: newSegments)
                if let lastEnd = newSegments.last?.end {
                    lastCommittedEndTime = max(lastCommittedEndTime, lastEnd)
                }
                detectedSpeakerCount = max(detectedSpeakerCount, diarization.speakerCount)
                onSegmentsEmitted?(newSegments)
            }

            windowsProcessed += 1
            isTranscribing = false
            pipelineState = .ready

            logger.info("Window \(self.windowsProcessed) processed: \(newSegments.count) new segments, \(diarization.speakerCount) speakers, up to \(String(format: "%.1f", self.lastCommittedEndTime))s")
        } catch {
            logger.error("Window processing failed: \(error.localizedDescription)")
            isTranscribing = false
            pipelineState = .error(error.localizedDescription)
        }
    }

    /// Dedupe segments against lastCommittedEndTime, offset timestamps to absolute session time,
    /// and attach speaker labels from the diarization result using midpoint overlap.
    private func dedupeAndOffsetSegments(
        _ segments: [WhisperTranscriptionService.TranscriptResult.Segment],
        absoluteStartOffset: TimeInterval,
        diarization: DiarizationService.DiarizationResult
    ) -> [EmittedSegment] {
        var result: [EmittedSegment] = []
        for seg in segments {
            let absStart = seg.start + absoluteStartOffset
            let absEnd = seg.end + absoluteStartOffset

            // Skip segments fully inside already-committed territory
            if absEnd <= lastCommittedEndTime + 0.1 { continue }

            // Filter words to only those past the commit line
            let words: [WhisperTranscriptionService.TranscriptResult.Word] = seg.words.compactMap { w -> WhisperTranscriptionService.TranscriptResult.Word? in
                let wordStart = w.start + absoluteStartOffset
                let wordEnd = w.end + absoluteStartOffset
                guard wordEnd > lastCommittedEndTime else { return nil }
                return WhisperTranscriptionService.TranscriptResult.Word(
                    word: w.word,
                    start: wordStart,
                    end: wordEnd,
                    confidence: w.confidence
                )
            }

            // If the whole segment's words were already committed, skip
            if !seg.words.isEmpty && words.isEmpty { continue }

            // Rebuild segment text from surviving words if we trimmed any.
            // IMPORTANT: join with explicit single spaces and trim each
            // individual word first, otherwise words without leading spaces
            // smash together (produces things like "daysbefore").
            let text: String
            if words.count < seg.words.count, !words.isEmpty {
                text = WhisperTranscriptionService.rebuildText(from: words.map { $0.word })
            } else {
                text = seg.text
            }

            let finalStart = max(absStart, lastCommittedEndTime)
            let finalEnd = absEnd

            // Assign speaker based on diarization — find the voice segment whose
            // midpoint most closely matches this transcript segment's midpoint.
            let (clusterID, label, confidence) = assignSpeaker(
                segmentStart: finalStart,
                segmentEnd: finalEnd,
                diarization: diarization
            )

            result.append(EmittedSegment(
                text: text,
                start: finalStart,
                end: finalEnd,
                words: words,
                speakerClusterID: clusterID,
                speakerLabel: label,
                speakerConfidence: confidence
            ))
        }
        return result
    }

    // MARK: - Speaker Assignment

    private func assignSpeaker(
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval,
        diarization: DiarizationService.DiarizationResult
    ) -> (clusterID: Int, label: String, confidence: Float) {
        // Find the voice segment with the largest time overlap with this transcript segment.
        // If there's no overlap, fall back to the closest voice segment by midpoint.
        let segMid = (segmentStart + segmentEnd) / 2

        var bestOverlap: TimeInterval = 0
        var bestSegment: DiarizationService.VoiceSegment? = nil
        for vSeg in diarization.segments {
            let overlap = max(0, min(segmentEnd, vSeg.end) - max(segmentStart, vSeg.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSegment = vSeg
            }
        }

        // Fall back to nearest by midpoint distance
        if bestSegment == nil {
            var bestDistance: TimeInterval = .infinity
            for vSeg in diarization.segments {
                let vMid = (vSeg.start + vSeg.end) / 2
                let distance = abs(segMid - vMid)
                if distance < bestDistance {
                    bestDistance = distance
                    bestSegment = vSeg
                }
            }
        }

        guard let match = bestSegment else {
            return (0, "Speaker", 0)
        }

        let label = diarization.label(for: match.clusterID)
        // Confidence heuristic: overlap-to-segment ratio (1.0 if fully overlapping)
        let segDuration = max(0.001, segmentEnd - segmentStart)
        let confidence = Float(min(1.0, bestOverlap / segDuration))

        return (match.clusterID, label, confidence)
    }

    // MARK: - PCM Conversion

    /// Convert interleaved Int16 PCM data to mono Float32 samples in [-1, 1].
    private func convertInt16PCMToMonoFloat(pcmData: Data, channels: Int) -> [Float] {
        guard channels > 0 else { return [] }
        let sampleCount = pcmData.count / 2
        let frameCount = sampleCount / channels
        guard frameCount > 0 else { return [] }

        var result = [Float](repeating: 0, count: frameCount)
        pcmData.withUnsafeBytes { raw in
            let int16Buffer = raw.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += Float(int16Buffer[frame * channels + ch]) / Float(Int16.max)
                }
                result[frame] = sum / Float(channels)
            }
        }
        return result
    }

    // MARK: - Buffer Math

    private func bytesPerSecondInBuffer() -> Int {
        Int(sessionSampleRate) * Int(sessionChannels) * 2 // 16-bit PCM
    }

    private func currentBufferDuration() -> TimeInterval {
        let bps = bytesPerSecondInBuffer()
        guard bps > 0 else { return 0 }
        return TimeInterval(pcmBuffer.count) / TimeInterval(bps)
    }

    private func dropFromFront(seconds: TimeInterval) {
        let bytesToDrop = Int(seconds * Double(bytesPerSecondInBuffer()))
        guard bytesToDrop > 0, bytesToDrop < pcmBuffer.count else { return }
        pcmBuffer.removeFirst(bytesToDrop)
        bufferStartOffset += seconds
        logger.debug("Dropped \(String(format: "%.1f", seconds))s from buffer front")
    }

    // MARK: - WAV Writing

    private func writeWAV(pcmData: Data, sampleRate: UInt32, channels: UInt16, to url: URL) throws {
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE(chunkSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE(UInt32(16))
        header.appendLE(UInt16(1))
        header.appendLE(channels)
        header.appendLE(sampleRate)
        header.appendLE(byteRate)
        header.appendLE(blockAlign)
        header.appendLE(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendLE(dataSize)

        var file = header
        file.append(pcmData)
        try file.write(to: url)
    }

    private func cleanupTempFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Data Extension

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
}
