//
//  MeetingCaptureCoordinator.swift
//  SAM Field
//
//  Orchestrates the meeting recording flow: connect to Mac,
//  record audio, stream to Mac for transcription.
//  State machine: idle → connecting → recording → paused → stopping → completed
//

import Foundation
import AVFoundation
import AudioToolbox
import SwiftData
import UIKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "MeetingCaptureCoordinator")

@MainActor
@Observable
final class MeetingCaptureCoordinator {

    /// App-wide shared instance. Recording state, the TCP connection, and
    /// the last meeting summary all live here so they survive tab switches,
    /// the view being rebuilt, and backgrounding.
    static let shared = MeetingCaptureCoordinator()

    // MARK: - State

    enum CaptureState: Sendable, Equatable {
        case idle
        case connecting          // Browsing for Mac
        case connected           // Mac found, ready to record
        case recording
        case paused
        case stopping
        case completed
        case error(String)
    }

    private(set) var captureState: CaptureState = .idle

    /// Elapsed recording time.
    var elapsedTime: TimeInterval {
        recordingService.elapsedTime
    }

    /// Audio level for waveform.
    var audioLevel: Float {
        recordingService.audioLevel
    }

    /// Connection status text.
    var connectionStatus: String {
        switch streamingService.connectionState {
        case .disconnected: return "Disconnected"
        case .browsing: return "Searching for Mac…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected to Mac"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))…"
        }
    }

    /// Whether the Mac is connected.
    var isMacConnected: Bool {
        streamingService.connectionState == .connected
    }

    /// Number of buffered chunks (pending during reconnection).
    var bufferedChunkCount: Int {
        streamingService.bufferedChunkCount
    }

    /// Name of the connected Mac.
    var connectedMacName: String? {
        streamingService.connectedMacName
    }

    /// Meeting summary pushed back from the Mac after session end. Nil until
    /// the Mac finishes generating and sends it — typically 5-20 seconds after
    /// recording stops.
    private(set) var lastSummary: MeetingSummary?

    /// Whether we're still waiting on the summary to arrive. Auto-clears
    /// after 60 seconds to prevent the phone from showing a spinner forever
    /// if the Mac-side connection dropped before the summary could be pushed.
    private(set) var isAwaitingSummary: Bool = false

    /// Watchdog task that auto-clears `isAwaitingSummary` after a timeout.
    private var summaryWatchdog: Task<Void, Never>?

    /// How the current (or most recent) session is being captured.
    enum RecordingMode: Sendable, Equatable {
        /// Streaming to Mac — full live transcription + summary pipeline.
        case streaming
        /// Recording locally with no Mac involvement. Will need to be
        /// uploaded later for transcription + summary.
        case localOnly
        /// Started streaming but the connection was lost mid-session.
        /// Now recording locally. The partial Mac transcript exists but
        /// will be discarded on re-processing.
        case degradedToLocal
    }

    private(set) var recordingMode: RecordingMode = .streaming

    /// True if the current session had any streaming failure or was never
    /// streamed — means it needs pending-queue upload when Mac is reachable.
    var currentSessionNeedsUpload: Bool {
        switch recordingMode {
        case .streaming: return false
        case .localOnly, .degradedToLocal: return true
        }
    }

    /// URL of the local WAV file for the current/last session. Persistent —
    /// survives app restarts until explicitly deleted.
    private(set) var currentSessionLocalURL: URL?

    /// Non-nil when a visible warning should be shown in the UI because the
    /// streaming connection dropped mid-session. Cleared when the user starts
    /// a new recording. The view watches this to display an orange pill.
    private(set) var connectionLossWarning: String?

    /// True when autoConnectIfNeeded() has been browsing for at least 5s
    /// without finding the Mac. The view shows a prompt sheet offering
    /// Retry or Record Locally. Cleared when either path is taken or the
    /// Mac becomes reachable.
    private(set) var showConnectionTimeoutPrompt: Bool = false

    // MARK: - Services

    private let recordingService = MeetingRecordingService()
    private let streamingService = AudioStreamingService()
    private var sessionID: UUID?

    // MARK: - Speaker Prep

    /// Expected number of speakers for the next recording. Set from
    /// calendar event attendees or user input before recording starts.
    var expectedSpeakerCount: Int? = nil

    /// Expected speaker names for the next recording. Set from
    /// calendar event attendees or user input before recording starts.
    var expectedSpeakerNames: [String] = []

    /// Recording context selected by the user before starting.
    /// Calendar-matched meetings always use .clientMeeting.
    var expectedRecordingContext: RecordingContext = .clientMeeting

    /// Model container — needed to create PendingUpload records and so
    /// PendingUploadService can enumerate + upload them.
    private var modelContainer: ModelContainer?

    /// Call on app launch to wire the coordinator into the data layer.
    func configure(container: ModelContainer) {
        self.modelContainer = container
        PendingUploadService.shared.configure(
            container: container,
            streaming: streamingService
        )
        // Scan for orphaned WAV files from prior crashes / force-quits
        PendingUploadService.shared.recoverOrphanedRecordings()
    }

    /// iOS background task identifier — requested for the duration of each
    /// recording so iOS gives us runtime even if the user backgrounds the
    /// app to check another app during a meeting.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Task that watches the streaming connection state during a recording
    /// and detects drops. Cancelled on stop/cancel.
    private var connectionWatchTask: Task<Void, Never>?

    /// True while a phone call (or Siri, or alarm) is preempting our audio
    /// session. The engine is paused during this time; we auto-resume
    /// when the interruption ends.
    private(set) var isInterruptedByPhoneCall: Bool = false

    // MARK: - Init

    init() {
        // Wire up the summary callback once — retained for the coordinator's lifetime.
        streamingService.onMeetingSummary = { [weak self] summary in
            Task { @MainActor in
                self?.summaryWatchdog?.cancel()
                self?.summaryWatchdog = nil
                self?.lastSummary = summary
                self?.isAwaitingSummary = false
            }
        }

        // Refresh calendar when workspace settings arrive from Mac
        streamingService.onWorkspaceSettingsReceived = {
            Task { @MainActor in
                FieldCalendarService.shared.refreshToday()
            }
        }

        registerForAudioInterruptions()
    }

    // MARK: - Audio Session Interruptions

    private func registerForAudioInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAudioInterruption(notification)
            }
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // A phone call or similar is taking over the audio session.
            // We CANNOT continue recording during this — iOS won't let us.
            // The local WAV file is safely closed via pauseRecording;
            // no data is lost.
            guard captureState == .recording else { return }
            logger.warning("Audio interrupted (phone call?) — pausing recording")
            isInterruptedByPhoneCall = true
            recordingService.pauseRecording()
            // Don't change captureState to .paused — it's still semantically
            // recording from the user's perspective, just briefly paused.

        case .ended:
            guard isInterruptedByPhoneCall else { return }
            isInterruptedByPhoneCall = false
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), captureState == .recording {
                logger.info("Audio interruption ended — resuming recording")
                do {
                    try recordingService.resumeRecording()
                } catch {
                    logger.error("Failed to auto-resume after interruption: \(error.localizedDescription)")
                    captureState = .error("Couldn't resume after interruption: \(error.localizedDescription)")
                }
            }

        @unknown default:
            break
        }
    }

    // MARK: - Background Task

    /// Ask iOS for extended runtime while a recording is active. Without this,
    /// aggressive backgrounding could suspend the app mid-meeting.
    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SAM Field Recording") { [weak self] in
            // Expiration handler — iOS is telling us we've run out of background time.
            logger.warning("Background task expired — iOS is reclaiming runtime")
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }
        if backgroundTaskID != .invalid {
            logger.info("Acquired background task id=\(self.backgroundTaskID.rawValue)")
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        logger.info("Released background task")
    }

    // MARK: - Lifecycle

    /// Start browsing for the Mac transcription service.
    func connectToMac() {
        guard captureState == .idle || captureState == .completed else { return }

        captureState = .connecting
        streamingService.startBrowsing()

        // Watch for connection
        Task {
            // Poll for connection state changes
            while captureState == .connecting {
                try? await Task.sleep(for: .milliseconds(200))
                if streamingService.connectionState == .connected {
                    captureState = .connected
                    // We made it — dismiss any pending timeout prompt.
                    showConnectionTimeoutPrompt = false
                    connectionTimeoutTask?.cancel()
                    connectionTimeoutTask = nil
                    // Kick the pending upload queue now that the Mac is
                    // reachable. Safe to call any time — it's a no-op if
                    // the queue is empty or we're recording.
                    maybeProcessPendingQueue()
                    break
                }
                if case .disconnected = streamingService.connectionState,
                   captureState == .connecting {
                    // Browser may have given up
                    continue
                }
            }
        }
    }

    /// Called when the Meeting tab appears. If we're already connected from
    /// a previous session (view dismissed then re-shown, or app backgrounded),
    /// stay put. Otherwise start browsing automatically and, if the browse
    /// takes longer than 5 seconds, show a user-facing prompt offering
    /// Retry / Record Locally.
    func autoConnectIfNeeded() {
        // Already active in some form — nothing to do
        switch captureState {
        case .connecting, .connected, .recording, .paused, .stopping, .completed:
            return
        case .idle, .error:
            break
        }

        // Even if captureState is .idle, the streaming service may already be
        // connected from a prior session. Sync up state if so.
        if streamingService.connectionState == .connected {
            captureState = .connected
            return
        }

        // Start browsing + arm a 5s timeout.
        connectToMac()
        startConnectionTimeoutWatch()
    }

    private var connectionTimeoutTask: Task<Void, Never>?

    /// Wait 5 seconds after browse begins; if still not connected, flip
    /// `showConnectionTimeoutPrompt` so the view presents the sheet.
    private func startConnectionTimeoutWatch() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            // Still not connected? Prompt the user.
            if self.captureState == .connecting || self.captureState == .idle,
               self.streamingService.connectionState != .connected {
                logger.info("Connection timeout after 5s — prompting user")
                self.showConnectionTimeoutPrompt = true
            }
        }
    }

    /// User tapped Retry in the connection timeout prompt.
    func dismissConnectionTimeoutAndRetry() {
        showConnectionTimeoutPrompt = false
        // Restart the browse
        streamingService.disconnect()
        captureState = .idle
        connectToMac()
        startConnectionTimeoutWatch()
    }

    /// User tapped Record Locally in the connection timeout prompt.
    func dismissConnectionTimeoutAndRecordLocally() {
        showConnectionTimeoutPrompt = false
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        startLocalOnlyRecording()
    }

    /// User tapped Cancel / dismissed the prompt without choosing.
    func dismissConnectionTimeoutPrompt() {
        showConnectionTimeoutPrompt = false
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
    }

    /// Single-tap "record another meeting" path. Skips the browse/connect
    /// steps entirely if the TCP connection is still alive from the previous
    /// session — which it always is unless the user explicitly disconnected
    /// or the network dropped.
    func recordAgain() {
        // Fast path: connection still open from the previous session
        if streamingService.connectionState == .connected {
            logger.info("recordAgain: reusing existing connection")
            startRecording()
            return
        }

        // Slow path: connection was lost — reconnect then recording will be
        // one more tap. Happens after network flaps or if the Mac app quit.
        logger.info("recordAgain: connection lost, reconnecting")
        lastSummary = nil
        isAwaitingSummary = false
        captureState = .idle
        connectToMac()
    }

    /// Start recording.
    ///
    /// Always records locally to a persistent WAV file. Streams to the Mac
    /// as an overlay if and only if the TCP connection is currently live.
    /// If the connection drops mid-session, local recording continues
    /// uninterrupted and the session gets queued for later upload.
    ///
    /// Callable from `.connected`, `.completed`, `.idle`, or `.connecting`
    /// (user tapped Record before Mac was found — cancels the search, goes local).
    func startRecording() {
        // User tapped Record while still searching — cancel browse and go local.
        if captureState == .connecting {
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            showConnectionTimeoutPrompt = false
            streamingService.disconnect()
            captureState = .idle
        }

        guard captureState == .connected || captureState == .completed || captureState == .idle else {
            logger.warning("Cannot start recording in state: \(String(describing: self.captureState))")
            return
        }

        // Clear state from any previous session
        lastSummary = nil
        isAwaitingSummary = false
        connectionLossWarning = nil

        let id = UUID()
        self.sessionID = id

        // Determine initial mode based on connection state
        let startingStreaming = streamingService.connectionState == .connected
        recordingMode = startingStreaming ? .streaming : .localOnly

        // Audio chunks always flow through this closure. If streaming mode
        // is active, they also go to the Mac. If we drop to degraded mode
        // mid-session, subsequent chunks simply stop being forwarded.
        recordingService.onAudioChunk = { [weak self] chunk in
            Task { @MainActor in
                guard let self else { return }
                switch self.recordingMode {
                case .streaming:
                    self.streamingService.send(chunk: chunk)
                case .localOnly, .degradedToLocal:
                    // Local-only: chunks still get written to the ring buffer
                    // WAV by MeetingRecordingService itself; we just don't
                    // forward them to the Mac.
                    break
                }
            }
        }

        do {
            try recordingService.startRecording(sessionID: id)
            currentSessionLocalURL = recordingService.currentRingBufferURL

            // Streaming overlay — tell the Mac we're starting if connected
            if startingStreaming {
                streamingService.sendSessionStart(
                    sessionID: id,
                    sampleRate: UInt32(recordingService.sampleRate),
                    channels: UInt16(recordingService.channelCount),
                    expectedSpeakerCount: expectedSpeakerCount,
                    speakerNames: expectedSpeakerNames,
                    recordingContext: expectedRecordingContext
                )
            }

            // Ask iOS for extended background runtime for the duration of
            // the recording. Released in stopRecording/cancelRecording.
            beginBackgroundTask()

            // If streaming, watch the connection and detect mid-session drops.
            if startingStreaming {
                startConnectionWatch()
            }

            captureState = .recording
            logger.info("Meeting capture started: \(id.uuidString) mode=\(String(describing: self.recordingMode))")
        } catch {
            captureState = .error(error.localizedDescription)
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection Monitoring

    /// Poll the streaming connection every half-second while recording.
    /// Only declares the session degraded if the connection has been
    /// unhealthy for longer than `gracePeriodSeconds` — gives the
    /// AudioStreamingService reconnect logic (exponential backoff up to
    /// ~14 seconds total) a chance to recover from brief blips without
    /// tripping the user-facing alert.
    private func startConnectionWatch() {
        connectionWatchTask?.cancel()
        connectionWatchTask = Task { [weak self] in
            let pollInterval: TimeInterval = 0.5
            let gracePeriodSeconds: TimeInterval = 10.0
            var unhealthySeconds: TimeInterval = 0

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
                guard let self else { return }

                // Only interesting during a live recording in streaming mode
                guard self.captureState == .recording || self.captureState == .paused,
                      self.recordingMode == .streaming else {
                    return
                }

                if self.streamingService.connectionState == .connected {
                    // Reset timer — brief drops that self-heal don't count
                    unhealthySeconds = 0
                } else {
                    unhealthySeconds += pollInterval
                    if unhealthySeconds >= gracePeriodSeconds {
                        logger.warning("Connection unhealthy for \(String(format: "%.1f", unhealthySeconds))s, flipping to degraded mode")
                        self.handleStreamingConnectionLost()
                        return
                    }
                }
            }
        }
    }

    private func stopConnectionWatch() {
        connectionWatchTask?.cancel()
        connectionWatchTask = nil
    }

    /// Called when we detect the streaming connection was lost during a
    /// recording. Flips mode, alerts user, keeps recording locally.
    private func handleStreamingConnectionLost() {
        // Guard against double-firing
        guard recordingMode == .streaming else { return }

        logger.warning("Streaming connection lost mid-session — falling back to local-only recording")
        recordingMode = .degradedToLocal
        connectionLossWarning = "Mac connection lost. Recording continues on your phone — the meeting will sync when you're back in range."

        // Fire feedback — one chime, one haptic, then done. Honors silent
        // switch for the sound; haptic always fires.
        playConnectionLossAlert()
    }

    /// Play a short chime + distinctive haptic to alert the user that the
    /// connection dropped. Silent switch suppresses the sound automatically.
    private func playConnectionLossAlert() {
        // SystemSoundID 1053 is "Tweet" — a short, clean two-tone chirp.
        // 1521 is "Vibrate" which pairs naturally. Using AudioServicesPlaySystemSound
        // means iOS honors the ringer switch automatically.
        let soundID: SystemSoundID = 1053
        AudioServicesPlaySystemSound(soundID)

        // Distinctive 3-tap warning haptic pattern.
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// Start a recording that explicitly does NOT stream to the Mac — used
    /// when the user chose "Record Locally" from the timeout prompt on
    /// startup, or from elsewhere when the Mac is not reachable.
    func startLocalOnlyRecording() {
        // Disconnect any pending browse so the streaming service doesn't
        // flip to .connected mid-session and confuse us.
        streamingService.disconnect()
        captureState = .idle
        startRecording()
    }

    // MARK: - Pending Upload

    /// Enqueue the current (just-stopped) session into the pending upload
    /// queue so it can be sent to the Mac later for full transcription.
    private func enqueueCurrentSessionForUpload() {
        guard let sessionID, let localURL = currentSessionLocalURL else {
            logger.warning("enqueueCurrentSessionForUpload: missing sessionID or local URL")
            return
        }
        PendingUploadService.shared.enqueue(
            sessionID: sessionID,
            localWAVURL: localURL,
            recordedAt: Date().addingTimeInterval(-recordingService.elapsedTime),
            durationSeconds: recordingService.elapsedTime,
            sampleRate: recordingService.sampleRate,
            channelCount: recordingService.channelCount,
            recordingContext: expectedRecordingContext
        )
        logger.info("Enqueued session \(sessionID.uuidString) for upload (\(String(format: "%.1f", self.recordingService.elapsedTime))s local)")
    }

    /// Try to upload the oldest pending session. Called from:
    ///   - `connectToMac` success path (so we drain the queue when the
    ///     Mac first becomes reachable)
    ///   - `startConnectionWatch` on reconnect recovery
    ///   - The Record tab's `.onAppear`
    func maybeProcessPendingQueue() {
        // Don't interrupt an active recording
        let isRecording: Bool
        switch captureState {
        case .recording, .paused, .stopping, .connecting:
            isRecording = true
        default:
            isRecording = false
        }
        Task {
            await PendingUploadService.shared.attemptNextUpload(isRecording: isRecording)
        }
    }

    /// Number of pending uploads for UI badge display.
    var pendingUploadCount: Int {
        PendingUploadService.shared.pendingCount
    }

    /// Pause recording.
    func pauseRecording() {
        guard captureState == .recording else { return }
        recordingService.pauseRecording()
        captureState = .paused
    }

    /// Resume recording.
    func resumeRecording() {
        guard captureState == .paused else { return }
        do {
            try recordingService.resumeRecording()
            captureState = .recording
        } catch {
            captureState = .error(error.localizedDescription)
        }
    }

    /// Stop recording and finalize the session.
    func stopRecording() {
        guard captureState == .recording || captureState == .paused else { return }

        captureState = .stopping

        // Stop recording (flushes final chunk)
        let ringBufferURL = recordingService.stopRecording()
        currentSessionLocalURL = ringBufferURL

        // Send session end to Mac based on the current mode.
        switch recordingMode {
        case .streaming:
            streamingService.sendSessionEnd()
            isAwaitingSummary = true
            lastSummary = nil
            startSummaryWatchdog()
        case .degradedToLocal:
            // We dropped mid-session, but the reconnect logic may have
            // restored the connection in the meantime. If so, tell the
            // Mac to clean up its partial session — otherwise it stays
            // in "recording" state forever. We don't expect a useful
            // summary since the Mac only got part of the audio.
            if streamingService.connectionState == .connected {
                streamingService.sendSessionEnd()
            }
            isAwaitingSummary = false
            lastSummary = nil
            enqueueCurrentSessionForUpload()
        case .localOnly:
            // No Mac involvement — nothing to notify. Session goes to
            // pending queue for upload later.
            isAwaitingSummary = false
            lastSummary = nil
            enqueueCurrentSessionForUpload()
        }

        // Release the iOS background task; recording is done.
        endBackgroundTask()
        stopConnectionWatch()

        captureState = .completed
        logger.info("Meeting capture completed. Local file: \(ringBufferURL?.lastPathComponent ?? "none") mode=\(String(describing: self.recordingMode))")
    }

    /// Cancel the current recording. Deletes the local WAV file and tells
    /// the Mac to discard its partial session (if we were streaming).
    func cancelRecording() {
        recordingService.cancelRecording()
        if recordingMode == .streaming {
            streamingService.sendSessionEnd()
        }
        endBackgroundTask()
        stopConnectionWatch()
        sessionID = nil
        currentSessionLocalURL = nil
        connectionLossWarning = nil
        captureState = .idle
    }

    /// Reset for a new session.
    func reset() {
        streamingService.disconnect()
        sessionID = nil
        lastSummary = nil
        isAwaitingSummary = false
        summaryWatchdog?.cancel()
        summaryWatchdog = nil
        captureState = .idle
    }

    /// Manually clear the "Generating summary" state. Called by
    /// pull-to-refresh when the phone is stuck on the spinner because the
    /// Mac never pushed the result. The watchdog auto-fires after 60s, but
    /// pull-to-refresh lets Sarah clear it immediately.
    func clearStaleSummaryState() {
        summaryWatchdog?.cancel()
        summaryWatchdog = nil
        isAwaitingSummary = false
        logger.info("Cleared stale summary-awaiting state via pull-to-refresh")
    }

    // MARK: - Session Lifecycle (Done / Delete)

    /// Sessions that have been marked done, to prevent double-sends.
    private var doneSentSessionIDs: Set<UUID> = []

    /// Brief checkmark confirmation after marking done.
    private(set) var showDoneConfirmation: Bool = false

    /// Mark the current session as done. Tells Mac to ensure note is saved
    /// and analysis runs, but does not sign off — session stays available
    /// for review/editing on the Mac.
    func markSessionDone() {
        guard let id = sessionID else { return }
        guard !doneSentSessionIDs.contains(id) else { return }

        doneSentSessionIDs.insert(id)
        let sent = streamingService.sendSessionDone(sessionID: id)

        if sent {
            showDoneConfirmation = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                showDoneConfirmation = false
                // Clear session state → view returns to ready-to-record
                sessionID = nil
                lastSummary = nil
                isAwaitingSummary = false
                summaryWatchdog?.cancel()
                summaryWatchdog = nil
                captureState = streamingService.connectionState == .connected
                    ? .connected : .idle
            }
        }

        logger.info("sessionDone sent=\(sent) for \(id.uuidString)")
    }

    /// Delete the current session. Tells Mac to remove audio, transcript,
    /// note, and evidence. Resets local state to idle.
    func deleteSession() {
        guard let id = sessionID else { return }
        let sent = streamingService.sendSessionDeleted(sessionID: id)

        // Clean up local state
        sessionID = nil
        lastSummary = nil
        isAwaitingSummary = false
        summaryWatchdog?.cancel()
        summaryWatchdog = nil
        doneSentSessionIDs.remove(id)
        captureState = streamingService.connectionState == .connected
            ? .connected : .idle

        logger.info("sessionDeleted sent=\(sent) for \(id.uuidString)")
    }

    // MARK: - Summary Watchdog

    /// Start a 60-second watchdog that auto-clears the "Generating summary"
    /// spinner if the Mac never pushes the result (e.g., connection dropped
    /// before the summary was ready). Without this the phone shows a spinner
    /// forever. If the Mac reconnects and pushes the summary later, the
    /// onMeetingSummary callback will populate lastSummary regardless of
    /// whether the watchdog already fired.
    private func startSummaryWatchdog() {
        summaryWatchdog?.cancel()
        summaryWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.isAwaitingSummary {
                self.isAwaitingSummary = false
                logger.info("Summary watchdog: timed out after 60s, clearing awaiting state")
            }
        }
    }
}
