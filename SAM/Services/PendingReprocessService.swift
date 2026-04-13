//
//  PendingReprocessService.swift
//  SAM
//
//  Phase B: batch-process a pre-recorded WAV file uploaded from the iPhone.
//
//  The live path (AudioReceivingService → TranscriptionPipelineService)
//  is designed for incremental, time-bounded streaming. This service is
//  for the OTHER path — a full WAV file arrives all at once from an
//  iPhone's pending queue, and we process it as a single batch job:
//
//    1. Read the WAV from disk
//    2. Run Whisper on the full audio (sliding windows internally)
//    3. Run diarization on the full audio
//    4. Merge transcript segments with speaker clusters
//    5. Create or update the TranscriptSession
//    6. Run polish + summary
//    7. Return success/failure to the caller (which sends the ack back
//       to the iPhone)
//
//  Crucially, this service DOES NOT touch the live pipeline — if the user
//  is simultaneously recording a live session, reprocessing runs
//  independently without disturbing it.
//

import Foundation
import AVFoundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PendingReprocessService")

@MainActor
@Observable
final class PendingReprocessService {

    static let shared = PendingReprocessService()

    private init() {}

    // MARK: - State

    enum ReprocessState: Sendable, Equatable {
        case idle
        case loadingWAV
        case transcribing
        case diarizing
        case persisting
        case polishing
        case summarizing
        case completed
        case failed(String)
    }

    private(set) var state: ReprocessState = .idle

    /// ID of the session currently being reprocessed (nil when idle).
    private(set) var currentSessionID: UUID?

    /// Progress text for the UI, refreshed as stages advance.
    var statusText: String {
        switch state {
        case .idle: return "Idle"
        case .loadingWAV: return "Loading recording…"
        case .transcribing: return "Transcribing…"
        case .diarizing: return "Identifying speakers…"
        case .persisting: return "Saving transcript…"
        case .polishing: return "Polishing…"
        case .summarizing: return "Generating summary…"
        case .completed: return "Done"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    // MARK: - Public API

    /// Reprocess a WAV file that was uploaded from the iPhone's pending queue.
    ///
    /// - Parameters:
    ///   - wavURL: the WAV file on disk (Mac filesystem)
    ///   - metadata: session identity + original recording time
    ///   - modelContainer: SwiftData container to persist into
    /// - Returns: success flag + optional error message
    @discardableResult
    func reprocess(
        wavURL: URL,
        metadata: PendingUploadMetadata,
        modelContainer: ModelContainer
    ) async -> (success: Bool, reason: String?) {
        guard let sessionID = UUID(uuidString: metadata.sessionID) else {
            state = .failed("Invalid session ID")
            return (false, "Invalid session ID")
        }

        currentSessionID = sessionID
        defer { currentSessionID = nil }

        let startTime = Date()
        logger.notice("🟢 REPROCESS START sessionID=\(sessionID.uuidString) duration=\(metadata.durationSeconds)s wavBytes=\(metadata.byteSize)")
        logger.notice("WAV URL: \(wavURL.path)")
        logger.notice("WAV exists: \(FileManager.default.fileExists(atPath: wavURL.path))")
        let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL.path)
        logger.notice("WAV file size on disk: \(attrs?[.size] as? Int64 ?? -1) bytes")

        #if DEBUG
        // Compute the WAV content hash once if the stage cache is enabled —
        // it's the input shared by Whisper and diarization, and the file
        // SHA256 dominates cache-key cost on multi-MB recordings.
        let wavHash: String? = StageCache.enabled ? StageCache.sha256(file: wavURL) : nil
        let stageCache = StageCache()
        #endif

        // MARK: 1. Ensure Whisper model is loaded
        state = .loadingWAV
        let stage1Start = Date()
        do {
            try await WhisperTranscriptionService.shared.loadModel()
        } catch {
            logger.error("❌ Reprocess: Whisper model load failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return (false, "Whisper model load failed: \(error.localizedDescription)")
        }
        logger.notice("✅ Stage 1 (model load): \(String(format: "%.1f", Date().timeIntervalSince(stage1Start)))s")

        // MARK: 1b. Preprocess audio (noise gate + AGC + high-pass filter)
        //
        // Load the WAV into a float buffer, run the preprocessing pipeline,
        // write the cleaned audio back to a temp file for Whisper to read.
        // Diarization uses the same cleaned samples directly.
        let preprocessStart = Date()
        let rawSamples = loadMonoFloatSamples(
            from: wavURL,
            expectedSampleRate: Double(metadata.sampleRate),
            expectedChannels: Int(metadata.channels)
        )

        var preprocessedSamples: [Float]?
        var preprocessedWavURL = wavURL
        if let raw = rawSamples, !raw.isEmpty {
            let cleaned = AudioPreprocessingService.preprocess(
                samples: raw,
                sampleRate: Float(metadata.sampleRate)
            )
            preprocessedSamples = cleaned

            // Write preprocessed audio to a temp file so Whisper can read it
            // (Whisper takes a file URL, not a sample array, in the reprocess path).
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent("preprocessed-\(sessionID.uuidString).wav")
            if writeWAV(samples: cleaned, sampleRate: metadata.sampleRate, to: tempURL) {
                preprocessedWavURL = tempURL
                logger.notice("✅ Stage 1b (preprocess): \(String(format: "%.1f", Date().timeIntervalSince(preprocessStart)))s — \(raw.count) samples cleaned")
            } else {
                logger.warning("Stage 1b: failed to write preprocessed WAV, using original")
            }
        } else {
            logger.warning("Stage 1b: could not load raw samples for preprocessing")
        }

        // MARK: 2. Transcribe the full WAV (Whisper handles its own windowing)
        state = .transcribing
        let stage2Start = Date()
        logger.notice("⏳ Stage 2 (Whisper transcription) starting on \(metadata.durationSeconds)s of audio...")

        let modelID = WhisperTranscriptionService.shared.currentModelID
            ?? WhisperTranscriptionService.defaultModelID

        #if DEBUG
        let whisperKey: String? = {
            guard StageCache.enabled, let wavHash else { return nil }
            return StageCache.compositeKey(
                "whisper",
                StageCache.Version.whisper,
                modelID,
                wavHash
            )
        }()

        let whisperResult: WhisperTranscriptionService.TranscriptResult
        if let key = whisperKey,
           let cached = stageCache.get(
               stage: "whisper",
               key: key,
               as: WhisperTranscriptionService.TranscriptResult.self
           ) {
            whisperResult = cached
            logger.notice("✅ Stage 2 (Whisper): CACHE HIT — \(cached.segments.count) segments restored")
        } else {
            do {
                whisperResult = try await WhisperTranscriptionService.shared.transcribe(fileURL: preprocessedWavURL)
            } catch {
                logger.error("❌ Reprocess: Whisper transcription failed after \(String(format: "%.1f", Date().timeIntervalSince(stage2Start)))s: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
                return (false, "Transcription failed: \(error.localizedDescription)")
            }
            if let key = whisperKey {
                stageCache.put(stage: "whisper", key: key, value: whisperResult)
            }
            logger.notice("✅ Stage 2 (Whisper): \(String(format: "%.1f", Date().timeIntervalSince(stage2Start)))s — returned \(whisperResult.segments.count) segments")
        }
        #else
        let whisperResult: WhisperTranscriptionService.TranscriptResult
        do {
            whisperResult = try await WhisperTranscriptionService.shared.transcribe(fileURL: preprocessedWavURL)
        } catch {
            logger.error("❌ Reprocess: Whisper transcription failed after \(String(format: "%.1f", Date().timeIntervalSince(stage2Start)))s: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return (false, "Transcription failed: \(error.localizedDescription)")
        }
        logger.notice("✅ Stage 2 (Whisper): \(String(format: "%.1f", Date().timeIntervalSince(stage2Start)))s — returned \(whisperResult.segments.count) segments")
        #endif

        // MARK: 3. Diarize — load PCM, run full-file clustering
        state = .diarizing
        let stage3Start = Date()
        logger.notice("⏳ Stage 3 (diarization) starting...")
        // Use preprocessed samples if available (same cleaning that Whisper
        // got). Falls back to loading raw from the original WAV.
        let monoSamples: [Float]? = preprocessedSamples ?? loadMonoFloatSamples(
            from: wavURL,
            expectedSampleRate: Double(metadata.sampleRate),
            expectedChannels: Int(metadata.channels)
        )
        logger.notice("Diarization: loaded \(monoSamples?.count ?? 0) mono float samples (preprocessed=\(preprocessedSamples != nil))")

        let enrolledEmbedding = loadEnrolledAgentEmbedding(container: modelContainer)

        #if DEBUG
        // Diarization key includes the WAV hash, the agent embedding hash
        // (so re-enrolling invalidates), and the tunable thresholds. We
        // intentionally include the floats so threshold tuning sweeps don't
        // see stale results.
        let diarizationKey: String? = {
            guard StageCache.enabled, let wavHash else { return nil }
            let svc = DiarizationService.shared
            let enrolledHash: String = {
                guard let e = enrolledEmbedding, !e.isEmpty else { return "none" }
                return StageCache.sha256(e.map { String($0) }.joined(separator: ",")).prefix(16).description
            }()
            return StageCache.compositeKey(
                "diarization",
                StageCache.Version.diarization,
                wavHash,
                "sr=\(metadata.sampleRate)",
                "ch=\(metadata.channels)",
                "merge=\(svc.clusterMergeThreshold)",
                "agent=\(svc.agentMatchThreshold)",
                "vad=\(svc.vadEnergyThreshold)",
                "minSeg=\(svc.minSegmentDuration)",
                "minSil=\(svc.minSilenceGap)",
                "enrolled=\(enrolledHash)"
            )
        }()

        let diarization: DiarizationService.DiarizationResult
        if let key = diarizationKey,
           let cached = stageCache.get(
               stage: "diarization",
               key: key,
               as: DiarizationService.DiarizationResult.self
           ) {
            diarization = cached
            logger.notice("✅ Stage 3 (diarization): CACHE HIT — \(cached.segments.count) voice segments, \(cached.centroids.count) clusters")
        } else if let monoSamples, !monoSamples.isEmpty {
            // Try SpeakerKit (neural Pyannote) first. Falls back to MFCC
            // if SpeakerKit isn't available or fails to load.
            if DiarizationService.shared.preferNeuralDiarization {
                do {
                    diarization = try await DiarizationService.shared.diarizeWithSpeakerKit(
                        samples: monoSamples,
                        sampleRate: Double(metadata.sampleRate),
                        startOffset: 0
                    )
                    logger.notice("✅ Stage 3 (neural diarization): \(String(format: "%.1f", Date().timeIntervalSince(stage3Start)))s — \(diarization.segments.count) voice segments, \(diarization.centroids.count) clusters")
                } catch {
                    logger.warning("SpeakerKit diarization failed (\(error.localizedDescription)), falling back to MFCC")
                    diarization = DiarizationService.shared.diarize(
                        samples: monoSamples,
                        sampleRate: Double(metadata.sampleRate),
                        startOffset: 0,
                        enrolledAgentEmbedding: enrolledEmbedding
                    )
                    logger.notice("✅ Stage 3 (MFCC fallback): \(String(format: "%.1f", Date().timeIntervalSince(stage3Start)))s — \(diarization.segments.count) voice segments, \(diarization.centroids.count) clusters")
                }
            } else {
                diarization = DiarizationService.shared.diarize(
                    samples: monoSamples,
                    sampleRate: Double(metadata.sampleRate),
                    startOffset: 0,
                    enrolledAgentEmbedding: enrolledEmbedding
                )
                logger.notice("✅ Stage 3 (MFCC diarization): \(String(format: "%.1f", Date().timeIntervalSince(stage3Start)))s — \(diarization.segments.count) voice segments, \(diarization.centroids.count) clusters")
            }
            if let key = diarizationKey {
                stageCache.put(stage: "diarization", key: key, value: diarization)
            }
        } else {
            logger.warning("Reprocess: could not load PCM for diarization; all segments will be single speaker")
            diarization = DiarizationService.DiarizationResult(
                segments: [],
                centroids: [:],
                agentClusterID: nil
            )
        }
        #else
        let diarization: DiarizationService.DiarizationResult
        if let monoSamples, !monoSamples.isEmpty {
            if DiarizationService.shared.preferNeuralDiarization {
                do {
                    diarization = try await DiarizationService.shared.diarizeWithSpeakerKit(
                        samples: monoSamples,
                        sampleRate: Double(metadata.sampleRate),
                        startOffset: 0
                    )
                } catch {
                    logger.warning("SpeakerKit failed, falling back to MFCC: \(error.localizedDescription)")
                    diarization = DiarizationService.shared.diarize(
                        samples: monoSamples,
                        sampleRate: Double(metadata.sampleRate),
                        startOffset: 0,
                        enrolledAgentEmbedding: enrolledEmbedding
                    )
                }
            } else {
                diarization = DiarizationService.shared.diarize(
                    samples: monoSamples,
                    sampleRate: Double(metadata.sampleRate),
                    startOffset: 0,
                    enrolledAgentEmbedding: enrolledEmbedding
                )
            }
        } else {
            logger.warning("Reprocess: could not load PCM for diarization; all segments will be single speaker")
            diarization = DiarizationService.DiarizationResult(
                segments: [],
                centroids: [:],
                agentClusterID: nil
            )
        }
        logger.notice("✅ Stage 3 (diarization): \(String(format: "%.1f", Date().timeIntervalSince(stage3Start)))s — \(diarization.segments.count) voice segments, \(diarization.centroids.count) clusters")
        #endif

        // MARK: 4. Persist transcript to SwiftData
        state = .persisting
        let context = ModelContext(modelContainer)
        var savedSession: TranscriptSession?
        do {
            let session = try findOrCreateSession(sessionID: sessionID, metadata: metadata, context: context)

            // SAFETY: refuse to wipe an existing partial transcript if the
            // new Whisper result is suspiciously empty or much shorter than
            // what we already have. This prevents catastrophic data loss
            // when WhisperKit silently returns nothing on long files
            // (memory pressure, internal model errors, etc.).
            let existingSegmentCount = session.segments?.count ?? 0
            let newSegmentCount = whisperResult.segments.count

            if existingSegmentCount > 0 && newSegmentCount == 0 {
                let msg = "Whisper returned 0 segments for a \(metadata.durationSeconds)s audio file, but existing session has \(existingSegmentCount) segments. Refusing to overwrite — keeping the partial transcript intact."
                logger.error("SAFETY REJECT: \(msg)")
                state = .failed(msg)
                return (false, msg)
            }

            if existingSegmentCount > 0 && newSegmentCount < (existingSegmentCount / 4) {
                // New result is less than 25% of the existing segment count.
                // Suspicious — likely a partial transcription failure. Refuse
                // and ask the user to retry.
                let msg = "Whisper produced only \(newSegmentCount) segments vs \(existingSegmentCount) in the existing partial — this looks like a partial transcription failure. Refusing to overwrite."
                logger.error("SAFETY REJECT: \(msg)")
                state = .failed(msg)
                return (false, msg)
            }

            // Sanity check: a 1-hour audio file should produce hundreds of
            // segments at minimum. If we got fewer than ~10 per minute of
            // audio, something is wrong.
            let minExpectedSegments = max(5, Int(metadata.durationSeconds / 6))
            if newSegmentCount < minExpectedSegments && metadata.durationSeconds > 60 {
                let msg = "Whisper returned \(newSegmentCount) segments for \(Int(metadata.durationSeconds))s of audio — far below the expected ~\(minExpectedSegments). Treating as a transcription failure to avoid data loss."
                logger.error("SAFETY REJECT: \(msg)")
                state = .failed(msg)
                return (false, msg)
            }

            session.status = .completed
            session.durationSeconds = metadata.durationSeconds
            session.speakerCount = max(1, diarization.speakerCount)
            session.detectedLanguage = whisperResult.detectedLanguage
            session.whisperModelID = whisperResult.modelID

            // Now safe to remove any old segments — the new ones are at
            // least as good or better.
            if let oldSegments = session.segments {
                logger.info("Reprocess: removing \(oldSegments.count) existing segment(s) before insertion")
                for seg in oldSegments {
                    context.delete(seg)
                }
            }

            // Insert new segments with speaker labels from diarization
            var segmentIndex = 0
            for wseg in whisperResult.segments {
                let (clusterID, label, confidence) = assignSpeaker(
                    segmentStart: wseg.start,
                    segmentEnd: wseg.end,
                    diarization: diarization
                )

                let wordsJSON: String? = encodeWordTimings(wseg.words)

                let segment = TranscriptSegment(
                    speakerLabel: label,
                    speakerClusterID: clusterID,
                    text: wseg.text,
                    startTime: wseg.start,
                    endTime: wseg.end,
                    speakerConfidence: confidence,
                    segmentIndex: segmentIndex,
                    wordTimingsJSON: wordsJSON
                )
                segment.session = session
                context.insert(segment)
                segmentIndex += 1
            }

            try context.save()
            savedSession = session
            logger.info("Reprocess: saved \(segmentIndex) segments for session \(sessionID.uuidString)")
        } catch {
            logger.error("Reprocess: persistence failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return (false, "Persistence failed: \(error.localizedDescription)")
        }

        // MARK: 5. Polish the transcript
        state = .polishing
        let stage5Start = Date()
        logger.notice("⏳ Stage 5 (polish) starting...")
        if let session = savedSession {
            await polishSession(session: session, container: modelContainer)
        }
        logger.notice("✅ Stage 5 (polish): \(String(format: "%.1f", Date().timeIntervalSince(stage5Start)))s")

        // MARK: 6. Generate the summary
        state = .summarizing
        let stage6Start = Date()
        logger.notice("⏳ Stage 6 (summary) starting...")
        if let session = savedSession {
            await summarizeSession(session: session, container: modelContainer)
        }
        logger.notice("✅ Stage 6 (summary): \(String(format: "%.1f", Date().timeIntervalSince(stage6Start)))s")

        // MARK: 7. Auto-save as SamNote (same path as live sessions)
        let stage7Start = Date()
        if let session = savedSession {
            await createLinkedNote(for: session, container: modelContainer)
        }
        logger.notice("✅ Stage 7 (save note): \(String(format: "%.1f", Date().timeIntervalSince(stage7Start)))s")

        state = .completed
        let totalElapsed = Date().timeIntervalSince(startTime)
        logger.notice("🎉 REPROCESS COMPLETE sessionID=\(sessionID.uuidString) totalElapsed=\(String(format: "%.1f", totalElapsed))s")
        return (true, nil)
    }

    // MARK: - Helpers

    /// Find an existing TranscriptSession with the given ID (from a partial
    /// live attempt) or create a new one. Either way we get a record ready
    /// to receive segments.
    private func findOrCreateSession(
        sessionID: UUID,
        metadata: PendingUploadMetadata,
        context: ModelContext
    ) throws -> TranscriptSession {
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        if let existing = try context.fetch(descriptor).first {
            logger.info("Reprocess: reusing existing TranscriptSession \(sessionID.uuidString)")
            return existing
        }
        let session = TranscriptSession(
            id: sessionID,
            recordedAt: metadata.recordedAt,
            durationSeconds: metadata.durationSeconds,
            speakerCount: 0,
            status: .processing,
            audioFilePath: nil,
            whisperModelID: WhisperTranscriptionService.defaultModelID,
            detectedLanguage: nil
        )
        context.insert(session)
        try context.save()
        logger.info("Reprocess: created new TranscriptSession \(sessionID.uuidString)")
        return session
    }

    /// Load the enrolled agent's embedding from SwiftData (if any).
    private func loadEnrolledAgentEmbedding(container: ModelContainer) -> [Float]? {
        let context = ModelContext(container)
        do {
            let descriptor = FetchDescriptor<SpeakerProfile>(
                predicate: #Predicate { $0.isAgent == true }
            )
            guard let profile = try context.fetch(descriptor).first else { return nil }
            return SpeakerEmbeddingService.decode(profile.embeddingData)
        } catch {
            return nil
        }
    }

    /// Decode a WAV file to mono Float samples. Uses AVAudioFile which
    /// handles both linear PCM and various container formats.
    private func loadMonoFloatSamples(
        from url: URL,
        expectedSampleRate: Double,
        expectedChannels: Int
    ) -> [Float]? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return nil
            }
            try file.read(into: buffer, frameCount: frameCount)

            guard let channelData = buffer.floatChannelData else { return nil }
            let frames = Int(buffer.frameLength)
            let channels = Int(format.channelCount)

            if channels == 1 {
                var samples = [Float](repeating: 0, count: frames)
                for i in 0..<frames { samples[i] = channelData[0][i] }
                return samples
            } else {
                // Mix channels down to mono by averaging
                var samples = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels {
                        sum += channelData[ch][i]
                    }
                    samples[i] = sum / Float(channels)
                }
                return samples
            }
        } catch {
            logger.error("loadMonoFloatSamples failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Write a Float sample array to a WAV file on disk. Used to feed
    /// preprocessed audio to Whisper (which takes a file URL).
    private func writeWAV(samples: [Float], sampleRate: UInt32, to url: URL) -> Bool {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return false
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channelData[i] = samples[i]
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return true
        } catch {
            logger.warning("writeWAV failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Same algorithm as `TranscriptionPipelineService.assignSpeaker`:
    /// match a transcript segment to the diarization voice segment with
    /// the largest time overlap.
    private func assignSpeaker(
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval,
        diarization: DiarizationService.DiarizationResult
    ) -> (clusterID: Int, label: String, confidence: Float) {
        guard !diarization.segments.isEmpty else {
            return (0, "Speaker", 0)
        }

        var bestOverlap: TimeInterval = 0
        var bestSegment: DiarizationService.VoiceSegment? = nil
        for vSeg in diarization.segments {
            let overlap = max(0, min(segmentEnd, vSeg.end) - max(segmentStart, vSeg.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSegment = vSeg
            }
        }

        if bestSegment == nil {
            // Fall back to nearest by midpoint
            let segMid = (segmentStart + segmentEnd) / 2
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
        let segDuration = max(0.001, segmentEnd - segmentStart)
        let confidence = Float(min(1.0, bestOverlap / segDuration))
        return (match.clusterID, label, confidence)
    }

    private func encodeWordTimings(_ words: [WhisperTranscriptionService.TranscriptResult.Word]) -> String? {
        guard !words.isEmpty else { return nil }
        let timings = words.map { WordTiming(word: $0.word, start: $0.start, end: $0.end, confidence: $0.confidence) }
        guard let data = try? JSONEncoder().encode(timings),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Run polish service on the saved session, persisting `polishedText`.
    private func polishSession(session: TranscriptSession, container: ModelContainer) async {
        let sessionID = session.id

        // Build the same speaker-grouped transcript format polish expects
        let segments = session.sortedSegments
        guard !segments.isEmpty else { return }

        var lines: [String] = []
        var lastSpeaker: String? = nil
        var currentBuffer: [String] = []
        func flush() {
            guard let speaker = lastSpeaker, !currentBuffer.isEmpty else { return }
            lines.append("\(speaker): \(currentBuffer.joined(separator: " "))")
            currentBuffer.removeAll()
        }
        for segment in segments {
            if segment.speakerLabel != lastSpeaker {
                flush()
                lastSpeaker = segment.speakerLabel
            }
            currentBuffer.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        flush()
        let transcriptText = lines.joined(separator: "\n\n")
        guard !transcriptText.isEmpty else { return }

        // NOTE: Cache lookup happens BEFORE gatherKnownNouns. The known nouns
        // list comes from SwiftData (BusinessProfileService + SamPerson fetch)
        // and can take 10–20 seconds in a populated database — long enough to
        // wipe out the entire cache speedup if we paid for it on every hit.
        // The cache key intentionally excludes nouns: in the test harness's
        // primary use case (iterating polish PROMPTS), the noun list is
        // irrelevant to what we're testing. If you need to invalidate after
        // a known-nouns change, wipe the cache directory or bump
        // StageCache.Version.polish.
        #if DEBUG
        let stageCache = StageCache()
        let polishKey: String? = {
            guard StageCache.enabled else { return nil }
            let promptHash = StageCache.sha256(TranscriptPolishService.systemInstruction())
            let transcriptHash = StageCache.sha256(transcriptText)
            return StageCache.compositeKey(
                "polish",
                StageCache.Version.polish,
                transcriptHash,
                promptHash
            )
        }()

        if let key = polishKey,
           let cached = stageCache.get(stage: "polish", key: key, as: String.self) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            if let fresh = try? context.fetch(descriptor).first {
                fresh.polishedText = cached
                fresh.polishedAt = .now
                try? context.save()
                logger.notice("✅ Polish: CACHE HIT — \(cached.count) chars restored")
            }
            return
        }
        #endif

        // Cache miss path — now we pay for known nouns + actual polish call.
        let knownNouns = await TranscriptPolishService.gatherKnownNouns(from: container, maxContacts: 60)

        do {
            // Apple Intelligence may not be available immediately after a
            // cold launch — checkAvailability returns .unavailable for the
            // first ~30-60s while the foundation model warms up. Without
            // a retry, the very first polish call after launch silently
            // fails and polishedText stays nil. Retry once after a short
            // delay so cold-launch test runs (and real first sessions
            // after the user opens SAM) actually get polished output.
            var polished: String
            do {
                polished = try await TranscriptPolishService.shared.polish(
                    transcript: transcriptText,
                    knownNouns: knownNouns
                )
            } catch TranscriptPolishService.PolishError.modelUnavailable {
                logger.notice("Polish: model not ready, waiting 3s and retrying once...")
                try? await Task.sleep(for: .seconds(3))
                polished = try await TranscriptPolishService.shared.polish(
                    transcript: transcriptText,
                    knownNouns: knownNouns
                )
            }

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            if let fresh = try context.fetch(descriptor).first {
                fresh.polishedText = polished
                fresh.polishedAt = .now
                try context.save()
                logger.info("Reprocess polish: saved \(polished.count) chars")
            }

            #if DEBUG
            if let key = polishKey {
                stageCache.put(stage: "polish", key: key, value: polished)
            }
            #endif
        } catch {
            logger.warning("Reprocess polish failed: \(error.localizedDescription)")
        }
    }

    /// Run the meeting summary service on the saved session.
    private func summarizeSession(session: TranscriptSession, container: ModelContainer) async {
        let sessionID = session.id

        let segments = session.sortedSegments
        guard !segments.isEmpty else { return }

        // Build the transcript — prefer polished if we have it
        let transcriptText: String
        if let polished = session.polishedText, !polished.isEmpty {
            transcriptText = polished
        } else {
            var lines: [String] = []
            var lastSpeaker: String? = nil
            var currentBuffer: [String] = []
            func flush() {
                guard let speaker = lastSpeaker, !currentBuffer.isEmpty else { return }
                lines.append("\(speaker): \(currentBuffer.joined(separator: " "))")
                currentBuffer.removeAll()
            }
            for segment in segments {
                if segment.speakerLabel != lastSpeaker {
                    flush()
                    lastSpeaker = segment.speakerLabel
                }
                currentBuffer.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            flush()
            transcriptText = lines.joined(separator: "\n\n")
        }

        guard !transcriptText.isEmpty else { return }

        let metadata = MeetingSummaryService.Metadata(
            durationSeconds: session.durationSeconds,
            speakerCount: session.speakerCount,
            detectedLanguage: session.detectedLanguage,
            recordedAt: session.recordedAt
        )

        #if DEBUG
        let stageCache = StageCache()
        let summaryKey: String? = {
            guard StageCache.enabled else { return nil }
            let promptHash = StageCache.sha256(MeetingSummaryService.systemInstruction())
            let transcriptHash = StageCache.sha256(transcriptText)
            // Metadata fields that affect the prompt body. recordedAt
            // intentionally excluded — it's display-only and would defeat
            // caching across re-runs of the same fixture.
            let metaKey = "dur=\(Int(metadata.durationSeconds))|spk=\(metadata.speakerCount)|lang=\(metadata.detectedLanguage ?? "")"
            return StageCache.compositeKey(
                "summary",
                StageCache.Version.summary,
                transcriptHash,
                metaKey,
                promptHash
            )
        }()

        if let key = summaryKey,
           let cached = stageCache.get(stage: "summary", key: key, as: MeetingSummary.self) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            if let fresh = try? context.fetch(descriptor).first {
                fresh.meetingSummaryJSON = cached.toJSONString()
                fresh.summaryGeneratedAt = .now
                try? context.save()
                logger.notice("✅ Summary: CACHE HIT — \(cached.actionItems.count) action items restored")
            }
            return
        }
        #endif

        do {
            // Same warmup-retry as polish: AI may not be ready on first
            // launch and the first call after a fresh process start can
            // throw .modelUnavailable. Retry once after a short delay.
            var summary: MeetingSummary
            do {
                summary = try await MeetingSummaryService.shared.summarize(
                    transcript: transcriptText,
                    metadata: metadata
                )
            } catch MeetingSummaryService.SummaryError.modelUnavailable {
                logger.notice("Summary: model not ready, waiting 3s and retrying once...")
                try? await Task.sleep(for: .seconds(3))
                summary = try await MeetingSummaryService.shared.summarize(
                    transcript: transcriptText,
                    metadata: metadata
                )
            }

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            if let fresh = try context.fetch(descriptor).first {
                fresh.meetingSummaryJSON = summary.toJSONString()
                fresh.summaryGeneratedAt = .now
                try context.save()
                logger.info("Reprocess summary: saved (\(summary.actionItems.count) action items)")
            }

            #if DEBUG
            if let key = summaryKey {
                stageCache.put(stage: "summary", key: key, value: summary)
            }
            #endif
        } catch {
            logger.warning("Reprocess summary failed: \(error.localizedDescription)")
        }
    }

    /// Auto-create the SamNote + SamEvidenceItem for the reprocessed session,
    /// same as the live handleSessionEnd path. Skipped if the session already
    /// has a linked note (from a previous partial live attempt).
    private func createLinkedNote(for session: TranscriptSession, container: ModelContainer) async {
        let sessionID = session.id

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        do {
            guard let fresh = try context.fetch(descriptor).first else { return }
            if fresh.linkedNote != nil {
                logger.info("Reprocess: session already has linked note, skipping auto-create")
                return
            }

            // Build transcript text — prefer polished
            let transcriptText: String
            if let polished = fresh.polishedText, !polished.isEmpty {
                transcriptText = polished
            } else {
                var lines: [String] = []
                var lastSpeaker: String? = nil
                var buf: [String] = []
                func flush() {
                    guard let speaker = lastSpeaker, !buf.isEmpty else { return }
                    lines.append("\(speaker): \(buf.joined(separator: " "))")
                    buf.removeAll()
                }
                for segment in fresh.sortedSegments {
                    if segment.speakerLabel != lastSpeaker {
                        flush()
                        lastSpeaker = segment.speakerLabel
                    }
                    buf.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                flush()
                transcriptText = lines.joined(separator: "\n\n")
            }

            guard !transcriptText.isEmpty else { return }

            let note = SamNote(content: transcriptText, sourceType: .dictated)
            context.insert(note)

            let titleDate = fresh.recordedAt.formatted(date: .abbreviated, time: .shortened)
            let evidence = SamEvidenceItem(
                id: UUID(),
                state: .done,
                source: .meetingTranscript,
                occurredAt: fresh.recordedAt,
                title: "Meeting transcript — \(titleDate)",
                snippet: String(transcriptText.prefix(200))
            )
            evidence.direction = .bidirectional
            context.insert(evidence)

            note.linkedEvidence = [evidence]
            fresh.linkedNote = note

            try context.save()
            logger.info("Reprocess: auto-saved SamNote for session \(sessionID.uuidString)")

            // Route through the existing note-analysis pipeline
            Task(priority: .utility) {
                await NoteAnalysisCoordinator.shared.analyzeNote(note)
            }
        } catch {
            logger.warning("Reprocess auto-save failed: \(error.localizedDescription)")
        }
    }
}
