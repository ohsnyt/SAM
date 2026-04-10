//
//  MeetingCaptureCoordinator.swift
//  SAM Field
//
//  Orchestrates the meeting recording flow: connect to Mac,
//  record audio, stream to Mac for transcription.
//  State machine: idle → connecting → recording → paused → stopping → completed
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "MeetingCaptureCoordinator")

@MainActor
@Observable
final class MeetingCaptureCoordinator {

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

    /// Whether we're still waiting on the summary to arrive.
    private(set) var isAwaitingSummary: Bool = false

    // MARK: - Services

    private let recordingService = MeetingRecordingService()
    private let streamingService = AudioStreamingService()
    private var sessionID: UUID?

    // MARK: - Init

    init() {
        // Wire up the summary callback once — retained for the coordinator's lifetime.
        streamingService.onMeetingSummary = { [weak self] summary in
            Task { @MainActor in
                self?.lastSummary = summary
                self?.isAwaitingSummary = false
            }
        }
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
    /// stay put. Otherwise start browsing automatically so the user never has
    /// to tap a "Connect" button on the happy path.
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

        // Otherwise start browsing.
        connectToMac()
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

    /// Start recording and streaming to the Mac.
    /// Callable from `.connected` (after a fresh connection) or `.completed`
    /// (after a previous recording — connection is still alive).
    func startRecording() {
        guard captureState == .connected || captureState == .completed || captureState == .idle else {
            logger.warning("Cannot start recording in state: \(String(describing: self.captureState))")
            return
        }

        // Clear state from any previous session
        lastSummary = nil
        isAwaitingSummary = false

        let id = UUID()
        self.sessionID = id

        // Wire up audio chunks to streaming service
        recordingService.onAudioChunk = { [weak self] chunk in
            Task { @MainActor in
                self?.streamingService.send(chunk: chunk)
            }
        }

        do {
            try recordingService.startRecording()

            // Send session start to Mac
            streamingService.sendSessionStart(
                sessionID: id,
                sampleRate: UInt32(recordingService.sampleRate),
                channels: UInt16(recordingService.channelCount)
            )

            captureState = .recording
            logger.info("Meeting capture started: \(id.uuidString)")
        } catch {
            captureState = .error(error.localizedDescription)
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
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

        // Send session end to Mac
        streamingService.sendSessionEnd()

        // Clear any stale summary and start waiting for the new one
        lastSummary = nil
        isAwaitingSummary = true

        captureState = .completed
        logger.info("Meeting capture completed. Ring buffer: \(ringBufferURL?.lastPathComponent ?? "none") — awaiting summary from Mac")
    }

    /// Cancel the current recording.
    func cancelRecording() {
        recordingService.cancelRecording()
        streamingService.sendSessionEnd()
        sessionID = nil
        captureState = .idle
    }

    /// Reset for a new session.
    func reset() {
        streamingService.disconnect()
        sessionID = nil
        lastSummary = nil
        isAwaitingSummary = false
        captureState = .idle
    }
}
