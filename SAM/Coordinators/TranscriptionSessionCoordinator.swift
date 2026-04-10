//
//  TranscriptionSessionCoordinator.swift
//  SAM
//
//  Manages the Mac side of a transcription session: starts the listener,
//  receives audio from iPhone, tracks session state, and saves completed
//  sessions to SwiftData. In M1 this handles audio pipeline only —
//  WhisperKit transcription and diarization come in M2–M4.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TranscriptionSessionCoordinator")

@MainActor
@Observable
final class TranscriptionSessionCoordinator {

    /// App-wide shared instance — the listener and Whisper model are
    /// process-wide resources, so the view re-uses this singleton rather
    /// than owning its own coordinator.
    static let shared = TranscriptionSessionCoordinator()

    // MARK: - State

    enum SessionState: Sendable, Equatable {
        case idle               // Not listening
        case listening          // Advertising, waiting for iPhone
        case connected          // iPhone connected, no active session
        case receiving          // Actively receiving audio
        case completed          // Session finished, audio saved
        case error(String)
    }

    private(set) var sessionState: SessionState = .idle

    /// Chunks received in the current session.
    var chunksReceived: Int { receivingService.chunksReceived }

    /// Connected device name.
    var connectedDeviceName: String? { receivingService.connectedDeviceName }

    /// Current session ID.
    private(set) var currentSessionID: UUID?

    /// Duration of the last completed session (estimated from chunks).
    private(set) var lastSessionDuration: TimeInterval = 0

    /// Audio file path for the last completed session.
    private(set) var lastSessionAudioPath: String?

    /// Pipeline state surfaced to the UI.
    var pipelineState: TranscriptionPipelineService.PipelineState {
        pipelineService.pipelineState
    }

    /// Live segments emitted by the pipeline for the current session.
    var liveSegments: [TranscriptionPipelineService.EmittedSegment] {
        pipelineService.emittedSegments
    }

    /// Distinct speakers detected this session.
    var detectedSpeakerCount: Int {
        pipelineService.detectedSpeakerCount
    }

    /// Number of transcription windows processed.
    var windowsProcessed: Int {
        pipelineService.windowsProcessed
    }

    // MARK: - Private

    private let receivingService = AudioReceivingService()
    private let pipelineService = TranscriptionPipelineService()
    private var modelContainer: ModelContainer?
    private var segmentIndexCounter: Int = 0

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        self.modelContainer = container
    }

    // MARK: - Listener Lifecycle

    /// Whether callbacks have been wired up yet (so startListening is idempotent).
    private var isWired = false

    /// The task watching for incoming connections — kept alive across sessions.
    private var connectionWatchTask: Task<Void, Never>?

    /// Start listening for iPhone connections. Safe to call repeatedly —
    /// subsequent calls are no-ops if already listening.
    func startListening() {
        // Already running? Fast-path no-op.
        if sessionState != .idle && sessionState != .error("") {
            switch sessionState {
            case .listening, .connected, .receiving:
                return
            default:
                break
            }
        }

        // Wire callbacks only once — they're retained for the coordinator lifetime
        // so that subsequent sessions reuse the same pipeline + listener.
        if !isWired {
            receivingService.onSessionStart = { [weak self] sessionID, sampleRate, channels in
                self?.handleSessionStart(sessionID: sessionID, sampleRate: sampleRate, channels: channels)
            }
            receivingService.onSessionEnd = { [weak self] in
                self?.handleSessionEnd()
            }
            receivingService.onAudioChunk = { [weak self] chunk in
                self?.handleAudioChunk(chunk)
            }
            pipelineService.onSegmentsEmitted = { [weak self] segments in
                self?.handleSegmentsEmitted(segments)
            }
            pipelineService.onLanguageDetected = { [weak self] lang in
                self?.handleLanguageDetected(lang)
            }
            isWired = true
        }

        // Load the Whisper model eagerly so it's hot when the first iPhone connects.
        Task {
            await pipelineService.start()
        }

        do {
            try receivingService.startAdvertising()
            sessionState = .listening
            logger.info("Listener started — advertising \(AudioStreamingConstants.bonjourServiceType)")

            // Watch for connection state transitions — kept alive across sessions.
            connectionWatchTask?.cancel()
            connectionWatchTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    // listenerState .connected means we have an active TCP peer,
                    // which can exist between sessions (iPhone keeps connection open)
                    if self.receivingService.listenerState == .connected,
                       self.sessionState == .listening {
                        self.sessionState = .connected
                    } else if self.receivingService.listenerState == .advertising,
                              (self.sessionState == .connected || self.sessionState == .completed) {
                        // Peer disconnected — go back to listening
                        self.sessionState = .listening
                    }
                }
            }
        } catch {
            sessionState = .error(error.localizedDescription)
            logger.error("Failed to start listener: \(error.localizedDescription)")
        }
    }

    /// Stop listening entirely. In always-on mode this is rarely called —
    /// the listener stays up for the life of the app.
    func stopListening() {
        connectionWatchTask?.cancel()
        connectionWatchTask = nil
        receivingService.stopAdvertising()
        pipelineService.reset()
        currentSessionID = nil
        sessionState = .idle
        logger.info("Listener stopped")
    }

    // MARK: - Session Handling

    private func handleSessionStart(sessionID: UUID, sampleRate: UInt32, channels: UInt16) {
        currentSessionID = sessionID
        sessionState = .receiving
        segmentIndexCounter = 0

        // Reset pipeline for the new session (model stays loaded)
        pipelineService.reset()

        // Load enrolled agent embedding (if any) so diarization can auto-label the agent
        pipelineService.enrolledAgentEmbedding = loadEnrolledAgentEmbedding()

        // Create TranscriptSession in SwiftData
        guard let container = modelContainer else {
            logger.error("No model container configured")
            return
        }

        let context = ModelContext(container)
        let session = TranscriptSession(
            id: sessionID,
            status: .recording,
            audioFilePath: receivingService.relativeAudioPath(for: sessionID),
            whisperModelID: WhisperTranscriptionService.defaultModelID
        )
        context.insert(session)

        do {
            try context.save()
            logger.info("TranscriptSession created: \(sessionID.uuidString)")
        } catch {
            logger.error("Failed to save TranscriptSession: \(error.localizedDescription)")
        }
    }

    private func handleAudioChunk(_ chunk: AudioChunk) {
        // Feed the chunk into the transcription pipeline for streaming Whisper processing.
        pipelineService.ingest(chunk: chunk)
    }

    private func handleSegmentsEmitted(_ segments: [TranscriptionPipelineService.EmittedSegment]) {
        guard let sessionID = currentSessionID, let container = modelContainer else { return }

        let context = ModelContext(container)
        do {
            let descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            guard let session = try context.fetch(descriptor).first else { return }

            let encoder = JSONEncoder()

            for seg in segments {
                let wordsJSON: String?
                if !seg.words.isEmpty {
                    let timings = seg.words.map { w in
                        WordTiming(word: w.word, start: w.start, end: w.end, confidence: w.confidence)
                    }
                    if let data = try? encoder.encode(timings), let str = String(data: data, encoding: .utf8) {
                        wordsJSON = str
                    } else {
                        wordsJSON = nil
                    }
                } else {
                    wordsJSON = nil
                }

                let segment = TranscriptSegment(
                    speakerLabel: seg.speakerLabel,
                    speakerClusterID: seg.speakerClusterID,
                    text: seg.text,
                    startTime: seg.start,
                    endTime: seg.end,
                    speakerConfidence: seg.speakerConfidence,
                    segmentIndex: segmentIndexCounter,
                    wordTimingsJSON: wordsJSON
                )
                segment.session = session
                context.insert(segment)
                segmentIndexCounter += 1
            }

            // Update session speaker count as diarization progresses
            session.speakerCount = max(session.speakerCount, pipelineService.detectedSpeakerCount)

            try context.save()
        } catch {
            logger.error("Failed to save transcript segments: \(error.localizedDescription)")
        }
    }

    /// Load the enrolled agent's speaker embedding from the current SwiftData state.
    /// Returns nil if no agent profile has been enrolled.
    private func loadEnrolledAgentEmbedding() -> [Float]? {
        guard let container = modelContainer else { return nil }
        let context = ModelContext(container)
        do {
            let descriptor = FetchDescriptor<SpeakerProfile>(
                predicate: #Predicate { $0.isAgent == true }
            )
            guard let profile = try context.fetch(descriptor).first else {
                logger.debug("No enrolled agent profile found")
                return nil
            }
            let embedding = SpeakerEmbeddingService.decode(profile.embeddingData)
            logger.info("Loaded enrolled agent embedding (\(embedding.count) dims)")
            return embedding
        } catch {
            logger.error("Failed to load enrolled agent embedding: \(error.localizedDescription)")
            return nil
        }
    }

    private func handleLanguageDetected(_ language: String) {
        guard let sessionID = currentSessionID, let container = modelContainer else { return }

        let context = ModelContext(container)
        do {
            let descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            if let session = try context.fetch(descriptor).first {
                session.detectedLanguage = language
                try context.save()
                logger.info("Detected language: \(language)")
            }
        } catch {
            logger.error("Failed to save detected language: \(error.localizedDescription)")
        }
    }

    private func handleSessionEnd() {
        guard let sessionID = currentSessionID else {
            // No active session — stay in whatever state we're in
            return
        }

        sessionState = .completed

        // Flush final window, auto-save as SamNote + trigger analysis,
        // then transition back to listening for the next session.
        Task { [weak self, sessionID] in
            guard let self else { return }
            await self.pipelineService.finishSession()

            guard let container = self.modelContainer else {
                self.currentSessionID = nil
                self.returnToListening()
                return
            }

            let context = ModelContext(container)
            var savedNote: SamNote?

            do {
                let descriptor = FetchDescriptor<TranscriptSession>(
                    predicate: #Predicate { $0.id == sessionID }
                )
                guard let session = try context.fetch(descriptor).first else {
                    self.currentSessionID = nil
                    self.returnToListening()
                    return
                }

                session.status = .completed
                session.durationSeconds = Double(self.receivingService.chunksReceived) * AudioStreamingConstants.chunkDurationSeconds
                session.speakerCount = max(1, self.pipelineService.detectedSpeakerCount)
                self.lastSessionDuration = session.durationSeconds
                self.lastSessionAudioPath = session.audioFilePath

                try context.save()

                // Phase 2: auto-save the session as a SamNote + SamEvidenceItem
                // and route it through the note analysis pipeline.
                savedNote = self.autoSaveAsNote(session: session, context: context)

                logger.info("Session completed: \(sessionID.uuidString), ~\(String(format: "%.0f", session.durationSeconds))s, \(self.segmentIndexCounter) segments, \(session.speakerCount) speakers, autoSavedNote=\(savedNote != nil)")
            } catch {
                logger.error("Failed to finalize TranscriptSession: \(error.localizedDescription)")
            }

            // Trigger background note analysis (action items, topics, mentions, etc.)
            if let note = savedNote {
                Task(priority: .utility) {
                    await NoteAnalysisCoordinator.shared.analyzeNote(note)
                }
            }

            // Trigger meeting summary generation (Phase 3) — this runs in parallel
            // with note analysis and persists the summary back onto the session.
            Task(priority: .utility) { [weak self, sessionID] in
                await self?.generateMeetingSummary(for: sessionID)
            }

            self.lastFinalizedSessionID = sessionID
            self.currentSessionID = nil
            self.returnToListening()
        }
    }

    // MARK: - Meeting Summary (Phase 3)

    /// Published so the UI can reactively show the summary as it completes.
    private(set) var lastMeetingSummary: MeetingSummary?

    /// Generation state for the active/last summary — useful for UI spinners.
    enum SummaryState: Sendable, Equatable {
        case idle
        case generating
        case ready
        case failed(String)
    }

    private(set) var summaryState: SummaryState = .idle

    /// Generate a `MeetingSummary` for the given session ID, persist it to
    /// the `TranscriptSession.meetingSummaryJSON` field, and (in Phase 4)
    /// push it back to the connected iPhone.
    ///
    /// Runs at `.utility` priority so it yields to any in-flight Whisper
    /// transcription on the next session.
    private func generateMeetingSummary(for sessionID: UUID) async {
        guard let container = modelContainer else { return }

        summaryState = .generating

        // Fetch the session + build the transcript on the main actor.
        let context = ModelContext(container)
        let (transcriptText, metadata) = buildSummaryInput(
            sessionID: sessionID,
            context: context
        )

        guard let transcriptText, !transcriptText.isEmpty else {
            logger.info("Meeting summary skipped — empty transcript")
            summaryState = .idle
            return
        }

        do {
            let summary = try await MeetingSummaryService.shared.summarize(
                transcript: transcriptText,
                metadata: metadata
            )

            // Persist to the session
            let descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            if let session = try context.fetch(descriptor).first {
                session.meetingSummaryJSON = summary.toJSONString()
                session.summaryGeneratedAt = .now
                try context.save()
            }

            lastMeetingSummary = summary
            summaryState = .ready
            logger.info("Meeting summary generated and saved for session \(sessionID.uuidString)")

            // Phase 4: push summary back to iPhone over the same TCP connection.
            receivingService.sendMeetingSummary(summary)
        } catch {
            logger.error("Meeting summary failed: \(error.localizedDescription)")
            summaryState = .failed(error.localizedDescription)
        }
    }

    /// Fetch a session and format its transcript + metadata for the summarizer.
    private func buildSummaryInput(
        sessionID: UUID,
        context: ModelContext
    ) -> (String?, MeetingSummaryService.Metadata) {
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        do {
            guard let session = try context.fetch(descriptor).first else {
                return (nil, MeetingSummaryService.Metadata())
            }

            let segments = session.sortedSegments
            guard !segments.isEmpty else { return (nil, MeetingSummaryService.Metadata()) }

            // Same grouping as autoSaveAsNote — consecutive segments from the
            // same speaker are joined on a single line.
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

            let metadata = MeetingSummaryService.Metadata(
                durationSeconds: session.durationSeconds,
                speakerCount: session.speakerCount,
                detectedLanguage: session.detectedLanguage,
                recordedAt: session.recordedAt
            )

            return (lines.joined(separator: "\n\n"), metadata)
        } catch {
            logger.error("buildSummaryInput fetch failed: \(error.localizedDescription)")
            return (nil, MeetingSummaryService.Metadata())
        }
    }

    /// Manual trigger for re-running the summary on the most recent session.
    /// Exposed for the "What have I covered?" button idea.
    func regenerateSummary() {
        guard let sessionID = lastFinalizedSessionID else { return }
        Task(priority: .utility) { [weak self, sessionID] in
            await self?.generateMeetingSummary(for: sessionID)
        }
    }

    /// The most recent session ID, even after `currentSessionID` has been cleared.
    /// Used for the regenerate-summary flow.
    private var lastFinalizedSessionID: UUID?

    /// After a session completes (or errors out), transition back to listening
    /// so the user can immediately start another recording without Mac intervention.
    private func returnToListening() {
        // The listener is still advertising — just reset the visible state.
        if receivingService.listenerState == .connected {
            sessionState = .connected
        } else if receivingService.listenerState == .advertising {
            sessionState = .listening
        } else {
            sessionState = .idle
        }
    }

    // MARK: - Auto Save (Phase 2)

    /// Build a formatted transcript + create a SamNote and SamEvidenceItem
    /// automatically from the completed session. Returns the created note so
    /// the caller can trigger downstream analysis.
    @discardableResult
    private func autoSaveAsNote(session: TranscriptSession, context: ModelContext) -> SamNote? {
        let segments = session.sortedSegments
        guard !segments.isEmpty else {
            logger.info("autoSaveAsNote skipped — no segments")
            return nil
        }

        // Format transcript with speaker labels, grouping consecutive segments from the same speaker.
        var lines: [String] = []
        var lastSpeaker: String? = nil
        var currentBuffer: [String] = []

        func flush() {
            guard let speaker = lastSpeaker, !currentBuffer.isEmpty else { return }
            let text = currentBuffer.joined(separator: " ")
            lines.append("\(speaker): \(text)")
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
        guard !transcriptText.isEmpty else { return nil }

        // Collect any pre-linked people from segments (speaker → SamPerson links)
        var linkedPeople: [SamPerson] = []
        var seenIDs = Set<PersistentIdentifier>()
        for segment in segments {
            if let person = segment.speakerPerson, !seenIDs.contains(person.persistentModelID) {
                linkedPeople.append(person)
                seenIDs.insert(person.persistentModelID)
            }
        }

        do {
            // Create SamNote
            let note = SamNote(
                content: transcriptText,
                sourceType: .dictated
            )
            note.linkedPeople = linkedPeople
            context.insert(note)

            // Create SamEvidenceItem with meetingTranscript source
            let titleDate = session.recordedAt.formatted(date: .abbreviated, time: .shortened)
            let evidence = SamEvidenceItem(
                id: UUID(),
                state: .done,
                source: .meetingTranscript,
                occurredAt: session.recordedAt,
                title: "Meeting transcript — \(titleDate)",
                snippet: String(transcriptText.prefix(200))
            )
            evidence.direction = .bidirectional
            evidence.linkedPeople = linkedPeople
            context.insert(evidence)

            // Cross-link note ↔ evidence
            note.linkedEvidence = [evidence]

            // Link session back to note + people for provenance
            session.linkedNote = note
            session.linkedPeople = linkedPeople

            try context.save()
            logger.info("Auto-saved transcript as SamNote (\(transcriptText.count) chars, \(linkedPeople.count) linked people)")
            return note
        } catch {
            logger.error("autoSaveAsNote failed: \(error.localizedDescription)")
            return nil
        }
    }
}
