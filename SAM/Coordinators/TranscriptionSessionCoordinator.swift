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

    /// True when any heavy transcription work is in progress — either a
    /// live session receiving audio, OR a pending-upload reprocess
    /// crunching through Whisper / diarization / polish / summary.
    /// Background importers (Mail, Communications, PostImportOrchestrator)
    /// gate on this to avoid competing with single-core transcription work.
    var isSessionActive: Bool {
        if sessionState == .receiving { return true }
        if PendingReprocessService.shared.state != .idle { return true }
        return false
    }

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

    /// Partial summaries produced incrementally while the recording is
    /// still running. The session-end summary folds these into the final
    /// result instead of re-summarizing the entire transcript, collapsing
    /// the perceived wait from "N chunks × summary time" to "tail chunk
    /// only". Only the final merged summary is pushed to the phone.
    private var partialSummaries: [MeetingSummary] = []

    /// First segment index not yet included in a partial summary. Segments
    /// at or after this index form the tail that the final pass summarizes.
    private var lastSummarizedSegmentIndex: Int = 0

    /// Rough running count of transcript characters since the last partial
    /// summary was kicked off. Triggers an incremental summary task once
    /// it crosses `TranscriptPolishService.maxChunkChars`.
    private var charsSinceLastSummary: Int = 0

    /// True while a background partial-summary task is mid-inference.
    /// Prevents overlapping inference calls from piling up on the same
    /// FoundationModels pipeline.
    private var incrementalSummaryInFlight: Bool = false

    /// True while a new session's pipeline reset is in progress. Any audio
    /// chunks that arrive in this window are buffered in `pendingChunks`
    /// and replayed into the pipeline once the reset completes. Prevents
    /// chunks from the new session leaking into the prior session's buffer.
    private var sessionTransitionInProgress = false
    private var pendingChunks: [AudioChunk] = []

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        self.modelContainer = container
        // Propagate the container to the receiving service so it can
        // reprocess pending uploads against the same store.
        receivingService.configure(container: container)
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
            receivingService.onSessionDone = { [weak self] sessionID in
                self?.handleSessionDone(sessionID: sessionID)
            }
            receivingService.onSessionDeleted = { [weak self] sessionID in
                self?.handleSessionDeleted(sessionID: sessionID)
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
            // Also detects mid-session disconnects and auto-finalizes orphaned sessions.
            connectionWatchTask?.cancel()
            connectionWatchTask = Task { [weak self] in
                // Require the watcher to see a disconnect for several
                // consecutive ticks before auto-finalizing. Brief flaps
                // during a connection replacement (see AudioReceivingService
                // handleNewConnection) or during phone-side network
                // hand-offs are normal and should not tear down an active
                // recording. At 500ms per tick, 6 ticks = 3 seconds.
                var disconnectTicks = 0
                let disconnectThreshold = 6
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }

                    let listenerState = self.receivingService.listenerState

                    if listenerState == .connected,
                       self.sessionState == .listening {
                        self.sessionState = .connected
                        // Push workspace settings to phone on first connect
                        self.pushWorkspaceSettings()
                    } else if listenerState == .advertising,
                              (self.sessionState == .connected || self.sessionState == .completed) {
                        self.sessionState = .listening
                    }

                    // Auto-finalize if the connection dropped during an active session.
                    // The phone may have disconnected, crashed, or lost network —
                    // without this the Mac stays stuck on "Recording" forever.
                    if listenerState != .connected,
                       self.sessionState == .receiving,
                       self.currentSessionID != nil {
                        disconnectTicks += 1
                        if disconnectTicks >= disconnectThreshold {
                            logger.warning("Connection dropped during active session — auto-finalizing (observed for \(disconnectTicks * 500)ms)")
                            disconnectTicks = 0
                            self.handleSessionEnd()
                        }
                    } else {
                        disconnectTicks = 0
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
        // Immediately reflect that a session is beginning so the UI flips out
        // of any .completed state from a prior session. The actual pipeline
        // setup is deferred until any in-flight window from the prior session
        // has finished — otherwise `pipelineService.reset()` would clobber
        // its buffers mid-transcription.
        sessionState = .receiving
        sessionTransitionInProgress = true
        pendingChunks.removeAll()

        Task { [weak self, sessionID, sampleRate, channels] in
            guard let self else { return }

            // Wait for any in-flight window from the previous session to
            // complete before resetting state. If it's already idle this is
            // an immediate no-op.
            let wentQuiet = await self.pipelineService.waitForQuiescence(timeout: 30)
            if !wentQuiet {
                logger.warning("Pipeline did not go quiescent before new session \(sessionID.uuidString) — proceeding anyway")
            }

            self.currentSessionID = sessionID
            self.segmentIndexCounter = 0
            self.partialSummaries.removeAll()
            self.lastSummarizedSegmentIndex = 0
            self.charsSinceLastSummary = 0
            self.incrementalSummaryInFlight = false

            // Reset pipeline for the new session (model stays loaded).
            self.pipelineService.reset()

            // Apply speaker metadata from the phone (if provided).
            // This sets expectedSpeakerCount on the diarization engine
            // so SpeakerKit produces the right number of clusters.
            if let metadata = self.receivingService.lastSessionMetadata {
                let diarService = DiarizationService.shared
                diarService.expectedSpeakerCount = metadata.expectedSpeakerCount
                // Store speaker names on the pipeline for cluster labeling
                self.pipelineService.expectedSpeakerNames = metadata.speakerNames
                if let count = metadata.expectedSpeakerCount {
                    logger.info("Session speaker prep: \(count) speakers, names=\(metadata.speakerNames)")
                }
            } else {
                DiarizationService.shared.expectedSpeakerCount = nil
                self.pipelineService.expectedSpeakerNames = []
            }

            // Load enrolled agent embedding (if any) so diarization can
            // auto-label the agent in the new session.
            self.pipelineService.enrolledAgentEmbedding = self.loadEnrolledAgentEmbedding()

            // Create TranscriptSession in SwiftData.
            if let container = self.modelContainer {
                let context = ModelContext(container)
                let recordingContext = self.receivingService.lastSessionMetadata?.recordingContext ?? .clientMeeting
                // Phone passes through EKEvent.eventIdentifier when Sarah started the recording
                // from an upcoming-meeting row. Persisting it here lets downstream consumers
                // (post-meeting capture, evidence timeline) join the recording to its calendar event.
                let calendarEventID = self.receivingService.lastSessionMetadata?.calendarEventID
                let session = TranscriptSession(
                    id: sessionID,
                    status: .recording,
                    recordingContext: recordingContext,
                    audioFilePath: self.receivingService.relativeAudioPath(for: sessionID),
                    whisperModelID: WhisperTranscriptionService.defaultModelID,
                    calendarEventID: calendarEventID
                )
                context.insert(session)
                do {
                    try context.save()
                    if let eventID = calendarEventID {
                        logger.info("TranscriptSession created: \(sessionID.uuidString) linked to event \(eventID) (format: \(sampleRate)Hz \(channels)ch)")
                    } else {
                        logger.info("TranscriptSession created: \(sessionID.uuidString) (impromptu, format: \(sampleRate)Hz \(channels)ch)")
                    }
                } catch {
                    logger.error("Failed to save TranscriptSession: \(error.localizedDescription)")
                }
            } else {
                logger.error("No model container configured")
            }

            // Replay any chunks that arrived while the pipeline was being
            // reset. Order is preserved because `pendingChunks` is a simple
            // FIFO array appended to in order, and both append + drain run
            // on the main actor.
            let queued = self.pendingChunks
            self.pendingChunks.removeAll()
            self.sessionTransitionInProgress = false
            if !queued.isEmpty {
                logger.info("Draining \(queued.count) chunks buffered during session transition")
                for chunk in queued {
                    self.pipelineService.ingest(chunk: chunk)
                }
            }
        }
    }

    private func handleAudioChunk(_ chunk: AudioChunk) {
        // If we're mid-transition (new session starting, old one still
        // winding down), buffer the chunk instead of ingesting it into the
        // stale pipeline state. It'll be replayed once reset completes.
        if sessionTransitionInProgress {
            pendingChunks.append(chunk)
            return
        }
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

        // Track the running char count for the incremental-summary trigger.
        // Add a tiny overhead per segment to cover the "Speaker: " prefix +
        // newlines that buildSpeakerTurns will add to the final text.
        for seg in segments {
            charsSinceLastSummary += seg.text.count + 12
        }

        maybeTriggerIncrementalSummary(sessionID: sessionID)
    }

    /// If enough new transcript has accumulated since the last partial
    /// summary, snapshot the window of segments produced since then and
    /// kick off a background summarization. The result is appended to
    /// `partialSummaries` and the final session-end pass merges them in
    /// instead of re-summarizing the whole transcript.
    private func maybeTriggerIncrementalSummary(sessionID: UUID) {
        guard !incrementalSummaryInFlight else { return }
        guard charsSinceLastSummary >= TranscriptPolishService.maxChunkChars else { return }
        // Defensive: need at least one segment's worth of new material.
        guard segmentIndexCounter > lastSummarizedSegmentIndex else { return }

        let windowStart = lastSummarizedSegmentIndex
        let windowEnd = segmentIndexCounter  // exclusive
        incrementalSummaryInFlight = true
        lastSummarizedSegmentIndex = windowEnd
        charsSinceLastSummary = 0

        logger.info("Kicking off incremental summary for segments [\(windowStart), \(windowEnd))")

        Task(priority: .background) { [weak self] in
            await self?.runIncrementalSummary(
                sessionID: sessionID,
                fromIndex: windowStart,
                toIndex: windowEnd
            )
        }
    }

    /// Builds transcript text for the given segment window and runs a
    /// summary pass against it. On success, appends the result to
    /// `partialSummaries`. On failure, resets `lastSummarizedSegmentIndex`
    /// so the failed window is re-tried at session end (it folds into the
    /// tail summary there).
    private func runIncrementalSummary(
        sessionID: UUID,
        fromIndex: Int,
        toIndex: Int
    ) async {
        defer {
            incrementalSummaryInFlight = false
        }

        guard let container = modelContainer else {
            lastSummarizedSegmentIndex = fromIndex
            return
        }

        let context = ModelContext(container)
        let (text, metadata) = buildSummaryWindow(
            sessionID: sessionID,
            fromIndex: fromIndex,
            toIndex: toIndex,
            context: context
        )

        guard let text, !text.isEmpty else {
            // Window produced no text (e.g. silent window). Nothing to
            // summarize, but we've already advanced the cursor — that's
            // fine, those segments aren't worth a pass.
            return
        }

        do {
            let summary = try await MeetingSummaryService.shared.summarize(
                transcript: text,
                metadata: metadata
            )
            partialSummaries.append(summary)
            logger.info("Incremental summary produced (partials now: \(self.partialSummaries.count))")
        } catch {
            logger.warning("Incremental summary failed: \(error.localizedDescription) — reverting cursor so tail pass picks up these segments")
            lastSummarizedSegmentIndex = fromIndex
            // charsSinceLastSummary stays at 0; the next segment batch
            // will begin accumulating again and may retrigger if the
            // recording keeps going.
        }
    }

    /// Build a tail transcript — segments from `lastSummarizedSegmentIndex`
    /// onward — for the final-summary incremental path. Returns the text
    /// plus the char count the timeout helper should base its budget on.
    /// The char count is the tail length when a tail exists, or a minimal
    /// floor when nothing remains (the synthesis call is cheap).
    private func buildTailSummaryInput(
        sessionID: UUID,
        context: ModelContext,
        metadata: MeetingSummaryService.Metadata
    ) -> (String?, Int) {
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        guard let session = try? context.fetch(descriptor).first else {
            return (nil, 0)
        }
        let tailStart = lastSummarizedSegmentIndex
        let tailSegments = session.sortedSegments.filter { $0.segmentIndex >= tailStart }
        guard !tailSegments.isEmpty else { return (nil, 1000) }
        let turns = Self.buildSpeakerTurns(from: tailSegments)
        guard !turns.isEmpty else { return (nil, 1000) }
        let text = turns.joined(separator: "\n\n")
        return (text, text.count)
    }

    /// Fetch segments in the index range `[fromIndex, toIndex)` and build
    /// a speaker-attributed transcript string the summary service can
    /// consume. Returns `(nil, metadata)` if the window is empty.
    private func buildSummaryWindow(
        sessionID: UUID,
        fromIndex: Int,
        toIndex: Int,
        context: ModelContext
    ) -> (String?, MeetingSummaryService.Metadata) {
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        do {
            guard let session = try context.fetch(descriptor).first else {
                return (nil, MeetingSummaryService.Metadata())
            }

            let windowed = session.sortedSegments.filter { seg in
                seg.segmentIndex >= fromIndex && seg.segmentIndex < toIndex
            }
            guard !windowed.isEmpty else { return (nil, MeetingSummaryService.Metadata()) }

            let turns = Self.buildSpeakerTurns(from: windowed)
            guard !turns.isEmpty else { return (nil, MeetingSummaryService.Metadata()) }

            let windowDuration = (windowed.last?.endTime ?? 0) - (windowed.first?.startTime ?? 0)
            let metadata = MeetingSummaryService.Metadata(
                durationSeconds: windowDuration,
                speakerCount: session.speakerCount,
                detectedLanguage: session.detectedLanguage,
                recordedAt: session.recordedAt,
                recordingContext: session.recordingContext
            )

            return (turns.joined(separator: "\n\n"), metadata)
        } catch {
            logger.error("buildSummaryWindow fetch failed: \(error.localizedDescription)")
            return (nil, MeetingSummaryService.Metadata())
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

        // Capture chunk count synchronously — the receiving service resets
        // `chunksReceived` to 0 on any new sessionStart or stopAdvertising,
        // and `finishSession()` below can await for many seconds flushing
        // the final Whisper window. Reading the counter after the await
        // raced with reconnects produced 0-duration saves.
        let capturedChunkCount = receivingService.chunksReceived

        // Flush final window, auto-save as SamNote + trigger analysis,
        // then transition back to listening for the next session.
        Task { [weak self, sessionID, capturedChunkCount] in
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
                let chunkDuration = Double(capturedChunkCount) * AudioStreamingConstants.chunkDurationSeconds
                let segmentDuration = (session.segments ?? []).map(\.endTime).max() ?? 0
                session.durationSeconds = max(chunkDuration, segmentDuration)
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

            // Trigger transcript polish (fixes proper nouns, window-seam
            // sentence breaks, punctuation). Runs in parallel with summary.
            Task(priority: .utility) { [weak self, sessionID] in
                await self?.generatePolishedTranscript(for: sessionID)
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

    // MARK: - Transcript Polish (Layer 2 cleanup)

    /// Generation state for the polish pass — useful for UI spinners.
    enum PolishState: Sendable, Equatable {
        case idle
        case polishing
        case ready
        case failed(String)
    }

    private(set) var polishState: PolishState = .idle

    /// Generate a polished transcript for the session and persist it to
    /// `TranscriptSession.polishedText`. The review view and summary can
    /// prefer this over the raw segment text.
    ///
    /// Runs at `.utility` priority in parallel with summary generation.
    private func generatePolishedTranscript(for sessionID: UUID) async {
        guard let container = modelContainer else { return }

        polishState = .polishing

        // Build the same speaker-grouped transcript we feed to the summary,
        // then hand it to the polish service along with known proper nouns
        // pulled from SAM's business profile + contacts.
        let context = ModelContext(container)
        let (transcriptText, _) = buildSummaryInput(
            sessionID: sessionID,
            context: context
        )

        guard let transcriptText, !transcriptText.isEmpty else {
            logger.info("Polish skipped — empty transcript")
            polishState = .idle
            return
        }

        let knownNouns = await TranscriptPolishService.gatherKnownNouns(
            from: container,
            maxContacts: 60
        )

        do {
            let polished = try await TranscriptPolishService.shared.polish(
                transcript: transcriptText,
                knownNouns: knownNouns
            )

            // Persist to the session
            let descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            if let session = try context.fetch(descriptor).first {
                session.polishedText = polished
                session.polishedAt = .now
                try context.save()
            }

            polishState = .ready
            logger.info("Polished transcript generated and saved for session \(sessionID.uuidString)")
        } catch {
            logger.error("Transcript polish failed: \(error.localizedDescription)")
            polishState = .failed(error.localizedDescription)
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

    /// Hard ceiling for a single summary generation attempt. The summary
    /// service can occasionally hang on cold-start Apple Intelligence. After
    /// this timeout the UI surfaces a "Try again" button so the user isn't
    /// stuck staring at a spinner.
    /// Per-chunk watchdog for a single `AIService.generate` call. The overall
    /// timeout scales linearly with chunk count (see `summaryTimeout(for:)`).
    private static let summaryGenerationTimeout: TimeInterval = 30

    /// Scale the summary watchdog by the number of chunks the transcript will
    /// be split into. Long recordings (e.g. a 50-minute lecture → ~10 chunks)
    /// need far more than 30s wall-clock, but each individual chunk still
    /// gets the same per-call budget so a truly stuck FoundationModels call
    /// is still caught.
    private static func summaryTimeout(forTranscriptLength length: Int) -> TimeInterval {
        let chunkCount = max(1, Int((Double(length) / Double(TranscriptPolishService.maxChunkChars)).rounded(.up)))
        return summaryGenerationTimeout * Double(chunkCount)
    }

    /// Generate a `MeetingSummary` for the given session ID, persist it to
    /// the `TranscriptSession.meetingSummaryJSON` field, and (in Phase 4)
    /// push it back to the connected iPhone.
    ///
    /// Runs at `.utility` priority so it yields to any in-flight Whisper
    /// transcription on the next session. Wrapped in a 30s watchdog so a
    /// stuck FoundationModels call doesn't leave the UI in `.generating`
    /// forever.
    private func generateMeetingSummary(for sessionID: UUID) async {
        guard let container = modelContainer else { return }

        summaryState = .generating

        // If an incremental summary is still running, wait briefly so we
        // don't double-summarize the same window or miss a partial that's
        // about to land.
        var waited: TimeInterval = 0
        while incrementalSummaryInFlight, waited < 60 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 0.25
        }
        if incrementalSummaryInFlight {
            logger.warning("Proceeding with final summary while incremental task still in flight after 60s")
        }

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

        // If we produced partial summaries during recording, only summarize
        // the tail (segments past the last summarized boundary) and merge
        // instead of re-summarizing the whole transcript. This collapses
        // the stop-to-summary wait from "N chunks" to "1 chunk".
        let useIncrementalPath = !partialSummaries.isEmpty
        let (summarizeText, summarizeTimeoutLen) = useIncrementalPath
            ? buildTailSummaryInput(sessionID: sessionID, context: context, metadata: metadata)
            : (transcriptText, transcriptText.count)

        let timeout = Self.summaryTimeout(forTranscriptLength: summarizeTimeoutLen)
        do {
            let summary = try await Self.withTimeout(seconds: timeout) { [partialSummaries] in
                if useIncrementalPath {
                    // Summarize the tail (if any) and fold into the partials.
                    var allPartials = partialSummaries
                    if let tail = summarizeText, !tail.isEmpty {
                        let tailSummary = try await MeetingSummaryService.shared.summarize(
                            transcript: tail,
                            metadata: metadata
                        )
                        allPartials.append(tailSummary)
                    }
                    return try await MeetingSummaryService.shared.synthesize(
                        from: allPartials,
                        metadata: metadata
                    )
                } else {
                    return try await MeetingSummaryService.shared.summarize(
                        transcript: transcriptText,
                        metadata: metadata
                    )
                }
            }

            // Persist to the session
            let descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            if let session = try context.fetch(descriptor).first {
                session.meetingSummaryJSON = summary.toJSONString()
                session.summaryGeneratedAt = .now
                if (session.title ?? "").isEmpty, !summary.title.isEmpty {
                    session.title = summary.title
                }
                try context.save()

                // Block 3: extract commitments into durable SamCommitment rows
                // so follow-through can be coached even after the summary JSON
                // is updated. Skipped silently if the session wasn't a
                // client meeting or had no actionable items.
                if session.recordingContext == .clientMeeting || session.recordingContext == .boardMeeting {
                    let sarah = try? PeopleRepository.shared.fetchMe()
                    CommitmentExtractionService.extract(
                        from: summary,
                        session: session,
                        context: context,
                        sarah: sarah,
                        recordedAt: session.recordedAt
                    )
                }

                // Block 4: if the recording wasn't tied to a calendar event,
                // ask Sarah for a quick attribution before we let it age into
                // the library. Posts a notification the shell listens for; the
                // sheet fetches the session by id so this payload stays cheap.
                if session.isImpromptu && session.impromptuReviewShownAt == nil {
                    let payload = ImpromptuReviewPayload(
                        sessionID: session.id,
                        summaryTLDR: summary.tldr.isEmpty ? nil : summary.tldr,
                        suggestedTitle: summary.title.isEmpty ? nil : summary.title,
                        recordedAt: session.recordedAt,
                        durationSeconds: session.durationSeconds
                    )
                    session.impromptuReviewShownAt = .now
                    session.impromptuReviewOutcome = .pending
                    try? context.save()
                    NotificationCenter.default.post(
                        name: .samOpenImpromptuReview,
                        object: nil,
                        userInfo: ["payload": payload]
                    )
                }
            }

            lastMeetingSummary = summary
            summaryState = .ready
            logger.info("Meeting summary generated and saved for session \(sessionID.uuidString)")

            // Phase 4: push summary back to iPhone over the same TCP connection.
            receivingService.sendMeetingSummary(summary)
        } catch is SummaryTimeoutError {
            logger.warning("Meeting summary timed out after \(timeout)s — surfacing retry to user")
            summaryState = .failed("Summary timed out after \(Int(timeout))s. Apple Intelligence may not be ready yet — try again in a moment.")
        } catch {
            logger.error("Meeting summary failed: \(error.localizedDescription)")
            summaryState = .failed(error.localizedDescription)
        }
    }

    /// Sentinel thrown by the timeout helper. Caught by the summary loop so
    /// it can present a friendlier "try again" message instead of the raw
    /// error path.
    private struct SummaryTimeoutError: Error {}

    /// Race the operation against a sleep. If the sleep wins, throw a
    /// timeout error and let the caller decide how to recover. The
    /// underlying operation may still complete in the background — we
    /// just stop waiting on it.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SummaryTimeoutError()
            }
            // First to finish wins; cancel the other.
            guard let result = try await group.next() else {
                throw SummaryTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    /// Fetch a session and build speaker-attributed transcript as an array
    /// of speaker turns. Each turn is a natural chunk boundary for downstream
    /// AI processing (polish, summary, analysis).
    ///
    /// A "turn" is a group of consecutive same-speaker Whisper segments.
    /// Speaker changes always start a new turn. Within a single speaker's
    /// run, a new turn is forced at sentence-final punctuation after ~2000
    /// chars (safety valve for long monologues).
    ///
    /// Returns `([turn strings], metadata)`. Each turn is formatted as
    /// `"Speaker: text"` and turns are joined with `"\n\n"` for the
    /// final transcript string.
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

            let turns = Self.buildSpeakerTurns(from: session.sortedSegments)
            guard !turns.isEmpty else { return (nil, MeetingSummaryService.Metadata()) }

            let metadata = MeetingSummaryService.Metadata(
                durationSeconds: session.durationSeconds,
                speakerCount: session.speakerCount,
                detectedLanguage: session.detectedLanguage,
                recordedAt: session.recordedAt,
                recordingContext: session.recordingContext
            )

            return (turns.joined(separator: "\n\n"), metadata)
        } catch {
            logger.error("buildSummaryInput fetch failed: \(error.localizedDescription)")
            return (nil, MeetingSummaryService.Metadata())
        }
    }

    /// Build speaker turns from Whisper segments. Each turn is a group of
    /// consecutive same-speaker segments formatted as "Speaker: text".
    /// Turns break on speaker changes and at sentence boundaries after
    /// ~2000 chars (so no single turn overflows the AI context window).
    static func buildSpeakerTurns(from segments: [TranscriptSegment]) -> [String] {
        guard !segments.isEmpty else { return [] }

        let sentenceEnd: Set<Character> = [".", "!", "?"]
        let maxTurnChars = 2000
        var turns: [String] = []
        var lastSpeaker: String? = nil
        var buffer: [String] = []
        var charCount = 0

        func flush() {
            guard let speaker = lastSpeaker, !buffer.isEmpty else { return }
            turns.append("\(speaker): \(buffer.joined(separator: " "))")
            buffer.removeAll()
            charCount = 0
        }

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Speaker change → new turn
            if segment.speakerLabel != lastSpeaker {
                flush()
                lastSpeaker = segment.speakerLabel
            }

            buffer.append(text)
            charCount += text.count

            // Long monologue safety: break at sentence end after ~2000 chars
            if charCount >= maxTurnChars,
               let lastChar = text.last,
               sentenceEnd.contains(lastChar) {
                flush()
                lastSpeaker = segment.speakerLabel
            }
        }
        flush()
        return turns
    }

    /// Manual trigger for re-running the summary on the most recent session.
    /// Exposed for the "What have I covered?" button idea.
    func regenerateSummary() {
        guard let sessionID = lastFinalizedSessionID else { return }
        Task(priority: .utility) { [weak self, sessionID] in
            await self?.generateMeetingSummary(for: sessionID)
        }
    }

    /// Progress of the backfill pass. `nil` when idle.
    private(set) var backfillProgress: (done: Int, total: Int)?

    /// Backfill summaries for every session that has segments but no
    /// `meetingSummaryJSON`. Runs sequentially at `.utility` priority so the
    /// Mac's AI backend isn't saturated while the user is doing other work.
    /// Safe to call multiple times — in-flight calls short-circuit.
    func regenerateMissingSummaries() {
        guard backfillProgress == nil else { return }
        guard let container = modelContainer else { return }

        Task(priority: .utility) { [weak self, container] in
            guard let self else { return }
            let context = ModelContext(container)
            let ids: [UUID]
            do {
                let descriptor = FetchDescriptor<TranscriptSession>(
                    predicate: #Predicate { session in
                        session.meetingSummaryJSON == nil
                            || session.meetingSummaryJSON == ""
                    },
                    sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
                )
                ids = try context.fetch(descriptor)
                    .filter { ($0.segments?.count ?? 0) > 0 }
                    .map(\.id)
            } catch {
                logger.error("Backfill fetch failed: \(error.localizedDescription)")
                return
            }
            guard !ids.isEmpty else {
                logger.info("Backfill: no sessions need summaries")
                return
            }

            logger.info("Backfill: regenerating summaries for \(ids.count) session(s)")
            await MainActor.run { self.backfillProgress = (0, ids.count) }
            for (i, id) in ids.enumerated() {
                await self.generateMeetingSummary(for: id)
                await MainActor.run { self.backfillProgress = (i + 1, ids.count) }
            }
            await MainActor.run { self.backfillProgress = nil }
            logger.info("Backfill: done")
        }
    }

    /// The most recent session ID, even after `currentSessionID` has been cleared.
    /// Used for the regenerate-summary flow.
    private var lastFinalizedSessionID: UUID?

    // MARK: - Workspace Settings Sync

    /// Push SAM's calendar and contact group settings to the phone
    /// so it knows which calendars and groups to access.
    private func pushWorkspaceSettings() {
        let calendarID = UserDefaults.standard.string(forKey: "selectedCalendarIdentifier") ?? ""
        let contactGroupID = UserDefaults.standard.string(forKey: "sam.contacts.groupIdentifier") ?? ""
        let contactGroupName = UserDefaults.standard.string(forKey: "sam.contacts.groupName") ?? ""

        let practiceType: String
        if let data = UserDefaults.standard.data(forKey: "sam.businessProfile"),
           let profile = try? JSONDecoder().decode(BusinessProfile.self, from: data) {
            practiceType = profile.practiceType.rawValue
        } else {
            practiceType = "General"
        }

        // Calendar name lookup: the phone will match by identifier first,
        // then by name as fallback. We send both so the phone works even
        // if calendar identifiers differ across devices.
        let calendarName = UserDefaults.standard.string(forKey: "selectedCalendarName") ?? ""

        let settings = WorkspaceSettings(
            calendarIdentifiers: calendarID.isEmpty ? [] : [calendarID],
            calendarNames: calendarName.isEmpty ? [] : [calendarName],
            contactGroupIdentifiers: contactGroupID.isEmpty ? [] : [contactGroupID],
            contactGroupNames: contactGroupName.isEmpty ? [] : [contactGroupName],
            practiceType: practiceType
        )

        receivingService.sendWorkspaceSettings(settings)

        // Also push to CloudKit so the phone has them even when offline
        Task(priority: .utility) {
            await CloudSyncService.shared.pushWorkspaceSettings(settings)
        }
    }

    // MARK: - Phone Session Lifecycle (Done / Delete)

    /// Handle sessionDone from iPhone. Ensures note is saved and analysis
    /// has started, but does NOT sign off — the session stays available for
    /// review and editing on the Mac.
    private func handleSessionDone(sessionID: UUID) {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)

        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        guard let session = try? context.fetch(descriptor).first else {
            logger.warning("sessionDone: session \(sessionID.uuidString) not found")
            return
        }

        // If autoSaveAsNote hasn't run yet (edge case: sessionDone arrives
        // before handleSessionEnd finishes), trigger it now.
        if session.linkedNote == nil {
            let note = autoSaveAsNote(session: session, context: context)
            if let note {
                Task(priority: .utility) {
                    await NoteAnalysisCoordinator.shared.analyzeNote(note)
                }
            }
        }

        logger.info("sessionDone acknowledged for \(sessionID.uuidString)")
    }

    /// Handle sessionDeleted from iPhone. Removes audio file, linked note +
    /// evidence, and the session itself. Mirrors TranscriptionReviewView.performDelete().
    private func handleSessionDeleted(sessionID: UUID) {
        // If this is the currently active session, clear coordinator state
        if currentSessionID == sessionID {
            currentSessionID = nil
            sessionState = .listening
        }

        guard let container = modelContainer else { return }
        let context = ModelContext(container)

        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        guard let session = try? context.fetch(descriptor).first else {
            logger.warning("sessionDeleted: session \(sessionID.uuidString) not found — may already be deleted")
            return
        }

        // 1. Delete audio file on disk
        if let relativePath = session.audioFilePath {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let audioURL = appSupport.appendingPathComponent(relativePath)
            try? FileManager.default.removeItem(at: audioURL)
        }

        // 2. Delete linked note + evidence
        if let note = session.linkedNote {
            for evidence in note.linkedEvidence {
                context.delete(evidence)
            }
            context.delete(note)
        }

        // Mirror the Mac-side performDelete: write a tombstone so a retry
        // upload from SAMField doesn't resurrect this session.
        let tombstoneDescriptor = FetchDescriptor<ProcessedSessionTombstone>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        if (try? context.fetch(tombstoneDescriptor).first) == nil {
            context.insert(ProcessedSessionTombstone(sessionID: sessionID))
        }

        // 3. Delete the session (segments cascade automatically)
        context.delete(session)

        do {
            try context.save()
            logger.info("sessionDeleted: successfully deleted session \(sessionID.uuidString)")
        } catch {
            logger.error("sessionDeleted: save failed: \(error.localizedDescription)")
        }
    }

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

        // Collect pre-linked people from segments (speaker → SamPerson links).
        // Skipped for training lectures — no CRM person-linking.
        var linkedPeople: [SamPerson] = []
        if session.recordingContext.supportsPersonLinking {
            var seenIDs = Set<PersistentIdentifier>()
            for segment in segments {
                if let person = segment.speakerPerson, !seenIDs.contains(person.persistentModelID) {
                    linkedPeople.append(person)
                    seenIDs.insert(person.persistentModelID)
                }
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

            // Context-specific evidence title
            let titleDate = session.recordedAt.formatted(date: .abbreviated, time: .shortened)
            let evidenceTitle: String
            switch session.recordingContext {
            case .clientMeeting:       evidenceTitle = "Meeting transcript — \(titleDate)"
            case .prospectingCall:     evidenceTitle = "Prospecting call — \(titleDate)"
            case .recruitingInterview: evidenceTitle = "Recruiting interview — \(titleDate)"
            case .annualReview:        evidenceTitle = "Annual review — \(titleDate)"
            case .trainingLecture:     evidenceTitle = "Training recording — \(titleDate)"
            case .boardMeeting:        evidenceTitle = "Board meeting recording — \(titleDate)"
            }

            // Create SamEvidenceItem with meetingTranscript source
            let evidence = SamEvidenceItem(
                id: UUID(),
                state: .done,
                source: .meetingTranscript,
                occurredAt: session.recordedAt,
                title: evidenceTitle,
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
            logger.info("Auto-saved transcript as SamNote (\(transcriptText.count) chars, \(linkedPeople.count) linked people, context=\(session.recordingContext.rawValue))")
            return note
        } catch {
            logger.error("autoSaveAsNote failed: \(error.localizedDescription)")
            return nil
        }
    }
}
