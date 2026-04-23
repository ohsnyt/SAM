//
//  AudioReceivingService.swift
//  SAM
//
//  Network.framework TCP listener for receiving audio from iPhone.
//  Advertises via Bonjour, accepts connections, reassembles audio
//  chunks in sequence order, and saves completed sessions as WAV files.
//

import Foundation
import Network
import SwiftData
import os.log

@MainActor
@Observable
final class AudioReceivingService {

    // MARK: - Singleton

    /// Shared instance used by TranscriptionSessionCoordinator and the pairing UI.
    static let shared = AudioReceivingService()

    // MARK: - State

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "AudioReceivingService")

    enum ListenerState: Sendable, Equatable {
        case idle
        case advertising
        case connected
    }

    private(set) var listenerState: ListenerState = .idle

    /// Name/address of the connected iPhone.
    private(set) var connectedDeviceName: String?

    /// Total chunks received in current session.
    private(set) var chunksReceived: Int = 0

    /// Current session ID (from SessionStart message).
    private(set) var currentSessionID: UUID?

    /// Callback invoked on the main actor with each reassembled audio chunk.
    /// TranscriptionPipelineService will consume these.
    var onAudioChunk: ((AudioChunk) -> Void)?

    /// Callback invoked when a session starts (with session ID, sample rate, channels).
    var onSessionStart: ((UUID, UInt32, UInt16) -> Void)?

    /// Callback invoked when a session ends.
    var onSessionEnd: (() -> Void)?

    // MARK: - Private

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var receiveBuffer = Data()
    private let networkQueue = DispatchQueue(label: "com.matthewsessions.SAM.audioReceiving", qos: .userInitiated)

    // Reassembly: priority queue for out-of-order chunks
    private var expectedSequenceNumber: UInt64 = 0
    private var reorderBuffer: [UInt64: AudioChunk] = [:]
    private let maxReorderWindow: UInt64 = 20

    // WAV file writing
    private var audioFileHandle: FileHandle?
    private var audioFileURL: URL?
    private var totalAudioBytesWritten: UInt32 = 0
    private var sessionSampleRate: UInt32 = 0
    private var sessionChannels: UInt16 = 0

    // MARK: - Authentication

    /// Per-connection authentication state. All non-auth packets are dropped
    /// until the active connection reaches `.authenticated`. A failed or
    /// missing response causes us to close the connection without ever
    /// delivering any audio.
    private enum AuthState {
        case awaitingResponse(challengeB64: String)
        case authenticated(phoneDeviceID: UUID, phoneDisplayName: String)
        case failed
    }
    private var authState: AuthState = .failed

    /// Time the Mac waits for an `authResponse` after sending `authChallenge`.
    /// Long enough that a phone on a flaky link can still answer; short
    /// enough that a silent / wrong-token phone is evicted promptly.
    private let authTimeoutSeconds: TimeInterval = 15
    private var authTimeoutTask: Task<Void, Never>?

    // MARK: - Pending Upload (Phase B)

    /// Metadata for an in-flight pending upload. Non-nil only between
    /// `uploadStart` and `uploadEnd` messages.
    private var pendingUploadMetadata: PendingUploadMetadata?
    private var pendingUploadFileHandle: FileHandle?
    private var pendingUploadURL: URL?
    private var pendingUploadBytesReceived: Int64 = 0

    /// Callback fired when reprocess finishes (success or failure). The
    /// coordinator uses this to send the `sessionProcessed` ack back to
    /// the iPhone.
    var onPendingReprocessComplete: ((UUID, Bool, String?) -> Void)?

    // MARK: - Pending Ack Queue

    /// Acks for processed sessions. We keep every ack here until either a
    /// TTL expires or the phone reconnects — `NWConnection.send`'s
    /// completion fires when bytes enter the kernel buffer, *not* when the
    /// peer receives them, so a half-dead TCP connection can silently
    /// swallow an ack and strand the phone on "Mac is processing".
    ///
    /// Replaying on every reconnect is safe: the phone's ack handler is
    /// idempotent — if the PendingUpload row is already gone, the duplicate
    /// ack is a no-op.
    private struct PendingAck {
        let sessionID: UUID
        let success: Bool
        let reason: String?
        let queuedAt: Date
    }
    private var pendingAcks: [PendingAck] = []

    /// Acks older than this are pruned on reconnect drain. Two hours covers
    /// a worst-case reprocess + a long phone-side sleep without unbounded
    /// growth.
    private let pendingAckTTL: TimeInterval = 2 * 60 * 60

    // MARK: - Processed Session Lookup

    /// Result of looking up an incoming session against the Mac's
    /// SwiftData store. Replaces an earlier UserDefaults-backed shadow
    /// ledger that could diverge from the store after a reinstall or
    /// failed write — the session record itself is now authoritative.
    enum UploadSessionState: Sendable {
        /// No TranscriptSession exists for this sessionID. Accept the upload.
        case notFound
        /// Session exists but no model container is wired up yet. Accept the
        /// upload so we don't lose data; shouldn't happen post-configure.
        case containerUnavailable
        /// Session exists but `meetingSummaryJSON` is empty — prior
        /// reprocess or summary pass didn't finish. Accept the upload.
        case existsWithoutSummary(status: String, segmentCount: Int)
        /// Session exists and has a cached summary. Dedup: push the summary
        /// back and ack so the phone deletes its local WAV.
        case existsWithSummary(MeetingSummary)
        /// Session was processed and intentionally deleted on the Mac. Ack
        /// success immediately so the phone drops its local WAV — otherwise
        /// SAMField keeps re-uploading the same audio every launch.
        case tombstoned(deletedAt: Date)

        var shouldDedup: Bool {
            switch self {
            case .existsWithSummary, .tombstoned: return true
            default: return false
            }
        }

        var logDescription: String {
            switch self {
            case .notFound:
                return "not found (new session)"
            case .containerUnavailable:
                return "modelContainer nil — cannot dedup"
            case .existsWithoutSummary(let status, let segmentCount):
                return "exists without summary (status=\(status), segments=\(segmentCount))"
            case .existsWithSummary:
                return "exists with summary — will dedup"
            case .tombstoned(let deletedAt):
                return "tombstoned (deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))) — will ack immediately"
            }
        }
    }

    /// Classify an incoming session against the local SwiftData store.
    /// The return value is loggable so uploadStart can surface the decision
    /// in one line when diagnosing unexpected re-uploads.
    private func classifyUploadSession(_ sessionIDString: String) -> UploadSessionState {
        guard let sessionID = UUID(uuidString: sessionIDString) else {
            return .notFound
        }
        guard let container = modelContainer else {
            return .containerUnavailable
        }
        let context = ModelContext(container)

        // Tombstone check comes first. If the user deleted this session on
        // the Mac, we don't want a new TranscriptSession to spring into
        // existence just because SAMField re-sent the same audio.
        let tombstoneDescriptor = FetchDescriptor<ProcessedSessionTombstone>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        if let tombstone = try? context.fetch(tombstoneDescriptor).first {
            return .tombstoned(deletedAt: tombstone.deletedAt)
        }

        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        guard let session = try? context.fetch(descriptor).first else {
            return .notFound
        }
        let json = session.meetingSummaryJSON ?? ""
        if json.isEmpty {
            let statusString = String(describing: session.status)
            let segCount = session.segments?.count ?? 0
            return .existsWithoutSummary(status: statusString, segmentCount: segCount)
        }
        guard let summary = MeetingSummary.from(jsonString: json) else {
            // Summary JSON exists but failed to decode — treat as missing
            // so the phone's re-upload reprocesses it cleanly.
            logger.warning("Cached summaryJSON for \(sessionID.uuidString) failed to decode — treating as not-yet-processed")
            return .existsWithoutSummary(status: String(describing: session.status), segmentCount: session.segments?.count ?? 0)
        }
        return .existsWithSummary(summary)
    }

    /// Callback fired when the iPhone sends sessionDone for a session.
    var onSessionDone: ((UUID) -> Void)?

    /// Callback fired when the iPhone sends sessionDeleted for a session.
    var onSessionDeleted: ((UUID) -> Void)?

    /// Model container for persistence — set by the coordinator via
    /// `configure(container:)`. Only required for pending reprocess.
    private var modelContainer: ModelContainer?

    func configure(container: ModelContainer) {
        self.modelContainer = container
    }

    // MARK: - Outbound Messages (Mac → iPhone)

    /// Pending summary that couldn't be pushed because the phone wasn't
    /// connected. Retried when a new connection arrives.
    private var pendingSummary: MeetingSummary?

    /// Serialize a meeting summary as JSON and push it to the connected iPhone.
    /// If no connection is active, queues the summary and retries on next connect.
    /// Push workspace settings (calendars, contact groups) to the phone.
    /// Called once when the phone connects.
    func sendWorkspaceSettings(_ settings: WorkspaceSettings) {
        guard let connection = activeConnection, let payload = settings.toWireData() else {
            logger.info("sendWorkspaceSettings: no active connection")
            return
        }

        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .settingsSync,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(payload.count)
        )
        var packet = header.serialize()
        packet.append(payload)

        connection.send(content: packet, completion: .contentProcessed { [logger] error in
            if let error {
                logger.error("sendWorkspaceSettings failed: \(error.localizedDescription)")
            } else {
                logger.info("Workspace settings pushed to iPhone (\(payload.count) bytes)")
            }
        })
    }

    func sendMeetingSummary(_ summary: MeetingSummary) {
        guard let connection = activeConnection, let payload = summary.toWireData() else {
            pendingSummary = summary
            logger.info("sendMeetingSummary: no active connection — queued for next connect")
            return
        }
        pendingSummary = nil

        // Split large payloads? Summaries are ~1-3KB, well under maxPayloadSize.
        guard UInt32(payload.count) <= AudioStreamingConstants.maxPayloadSize else {
            logger.warning("Summary payload too large (\(payload.count) bytes), dropping")
            return
        }

        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .summaryPush,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(payload.count)
        )
        var packet = header.serialize()
        packet.append(payload)

        connection.send(content: packet, completion: .contentProcessed { [logger] error in
            if let error {
                logger.error("sendMeetingSummary failed: \(error.localizedDescription)")
            } else {
                logger.info("Meeting summary pushed to iPhone (\(payload.count) bytes)")
            }
        })
    }

    // MARK: - Auth Messages

    /// Send an `authChallenge` packet as the very first thing on a new
    /// connection. The phone MUST reply with `authResponse` carrying an HMAC
    /// over this challenge within `authTimeoutSeconds` or we drop it.
    private func sendAuthChallenge(on connection: NWConnection, challengeB64: String) {
        let challenge = AuthChallenge(challengeB64: challengeB64)
        guard let payload = challenge.toWireData() else {
            logger.error("sendAuthChallenge: failed to encode payload")
            return
        }
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .authChallenge,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(payload.count)
        )
        var packet = header.serialize()
        packet.append(payload)

        connection.send(content: packet, completion: .contentProcessed { [logger] error in
            if let error {
                logger.error("sendAuthChallenge failed: \(error.localizedDescription)")
            } else {
                logger.debug("authChallenge sent")
            }
        })
    }

    private func handleAuthResponse(payload: Data) {
        guard case .awaitingResponse(let challengeB64) = authState else {
            logger.warning("authResponse arrived in wrong state — ignoring")
            return
        }
        guard let response = AuthResponse.from(wireData: payload) else {
            logger.error("authResponse: failed to decode payload")
            authState = .failed
            sendAuthResult(success: false, reason: "Malformed auth response")
            activeConnection?.cancel()
            return
        }

        let result = DevicePairingService.shared.authenticate(
            phoneDeviceID: response.phoneDeviceID,
            phoneDisplayName: response.phoneDisplayName,
            challengeB64: challengeB64,
            responseHMACB64: response.hmacB64
        )

        if result.success {
            authTimeoutTask?.cancel()
            authTimeoutTask = nil
            authState = .authenticated(
                phoneDeviceID: response.phoneDeviceID,
                phoneDisplayName: response.phoneDisplayName
            )
            connectedDeviceName = response.phoneDisplayName
            sendAuthResult(success: true, reason: nil)
            logger.info("Phone \(response.phoneDeviceID) authenticated — audio stream enabled")
            flushPostAuthQueues()
        } else {
            authState = .failed
            sendAuthResult(success: false, reason: result.reason)
            logger.warning("Auth rejected: \(result.reason ?? "unknown")")
            // Give the send a moment to hit the wire before we tear down.
            let connection = activeConnection
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                connection?.cancel()
            }
        }
    }

    private func sendAuthResult(success: Bool, reason: String?) {
        guard let connection = activeConnection else { return }
        let result = AuthResult(
            success: success,
            reason: reason,
            macDisplayName: DevicePairingService.shared.macDisplayName
        )
        guard let payload = result.toWireData() else { return }
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .authResult,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(payload.count)
        )
        var packet = header.serialize()
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { [logger] error in
            if let error {
                logger.error("sendAuthResult failed: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - PIN Pairing

    /// Handle a `pinPairingRequest` from an unauthenticated phone. If the PIN
    /// matches an active pairing window on the Mac, register the phone, reply
    /// with the HMAC token, and transition this connection to authenticated
    /// without any reconnect.
    private func handlePinPairingRequest(payload: Data) {
        guard let request = PinPairingRequest.from(wireData: payload) else {
            logger.error("pinPairingRequest: failed to decode payload")
            activeConnection?.cancel()
            return
        }
        guard let connection = activeConnection else { return }

        let result = DevicePairingService.shared.verifyPIN(
            request.pin,
            phoneDeviceID: request.phoneDeviceID,
            phoneDisplayName: request.phoneDisplayName
        )

        sendPinPairingResult(result, on: connection)

        if result.success {
            authTimeoutTask?.cancel()
            authTimeoutTask = nil
            authState = .authenticated(
                phoneDeviceID: request.phoneDeviceID,
                phoneDisplayName: request.phoneDisplayName
            )
            connectedDeviceName = request.phoneDisplayName
            logger.info("PIN pairing success for \(request.phoneDeviceID) — audio stream enabled")
            flushPostAuthQueues()
        } else {
            authState = .failed
            logger.warning("PIN pairing rejected: \(result.reason ?? "unknown")")
            // Give the failure packet a moment to hit the wire before tearing down.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                connection.cancel()
            }
        }
    }

    private func sendPinPairingResult(_ result: PinPairingResult, on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(result) else {
            logger.error("sendPinPairingResult: failed to encode payload")
            return
        }
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .pinPairingResult,
            sequenceNumber: 0, timestamp: 0, sampleRate: 0, channels: 0,
            payloadLength: UInt32(payload.count)
        )
        var packet = header.serialize()
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { [logger] error in
            if let error { logger.error("sendPinPairingResult failed: \(error.localizedDescription)") }
            else { logger.debug("pinPairingResult sent (success=\(result.success))") }
        })
    }

    /// Replay whatever was pending when the phone was absent. Runs after a
    /// successful auth — previously this lived in the raw connection-ready
    /// callback, but we must not reveal summaries or reprocess acks to an
    /// unauthenticated peer.
    private func flushPostAuthQueues() {
        if let pending = pendingSummary {
            pendingSummary = nil
            logger.info("Flushing pending summary to newly authenticated iPhone")
            sendMeetingSummary(pending)
        }

        let now = Date()
        let ttl = pendingAckTTL
        let before = pendingAcks.count
        pendingAcks.removeAll { now.timeIntervalSince($0.queuedAt) > ttl }
        let pruned = before - pendingAcks.count
        if pruned > 0 {
            logger.info("Pruned \(pruned) expired ack(s) older than \(Int(ttl))s")
        }
        if !pendingAcks.isEmpty {
            let acks = pendingAcks
            logger.info("Replaying \(acks.count) queued ack(s) to authenticated iPhone")
            for ack in acks {
                sendSessionProcessed(
                    sessionID: ack.sessionID,
                    success: ack.success,
                    reason: ack.reason
                )
            }
        }
    }

    /// Directory for received meeting audio files.
    private var audioDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MeetingAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Advertising

    /// Build and start a new NWListener advertising the Mac via Bonjour.
    /// Idempotent caller guard is on the caller (`startAdvertising`).
    private func createAndStartListener() throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let newListener = try NWListener(using: params)

        let pairing = DevicePairingService.shared
        var txtRecord = NWTXTRecord()
        txtRecord[SAMMacDeviceIDTXTKey] = pairing.macDeviceID.uuidString
        txtRecord[SAMMacDisplayNameTXTKey] = pairing.macDisplayName

        newListener.service = NWListener.Service(
            type: AudioStreamingConstants.bonjourServiceType,
            domain: AudioStreamingConstants.bonjourDomain,
            txtRecord: txtRecord
        )

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [self] in
                switch state {
                case .ready:
                    if let port = self.listener?.port {
                        self.logger.info("Listening on port \(port.rawValue)")
                    }
                    self.listenerState = .advertising
                case .failed(let error):
                    self.logger.error("Listener failed: \(error.localizedDescription)")
                    self.listenerState = .idle
                default:
                    break
                }
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleNewConnection(connection)
            }
        }

        newListener.start(queue: networkQueue)
        self.listener = newListener
    }

    /// Start advertising the transcription service via Bonjour and listen for connections.
    func startAdvertising() throws {
        guard listenerState == .idle else { return }
        try createAndStartListener()
        logger.info("Started advertising transcription service")
    }

    /// Stop advertising and disconnect.
    func stopAdvertising() {
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
        authState = .failed
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        activeConnection = nil
        finalizeAudioFile()
        connectedDeviceName = nil
        chunksReceived = 0
        currentSessionID = nil
        listenerState = .idle

        logger.info("Stopped advertising")
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        // Duplicate-connection handling is session-aware:
        //
        //   - During an active recording (currentSessionID != nil) with a
        //     healthy existing connection, REJECT the new one so the live
        //     stream isn't disrupted.
        //
        //   - Otherwise (idle state, no active session), REPLACE the old
        //     connection. The iPhone might be legitimately reconnecting
        //     after a network flap, and the old connection could be a
        //     half-closed zombie that would otherwise block reconnection
        //     forever.
        //
        // This replaces an earlier "always reject if ready" rule that
        // caused a reconnection loop when the iPhone repeatedly tried to
        // establish a new connection and was always rejected.
        if let existing = activeConnection {
            let existingState = existing.state
            let isHealthy: Bool
            switch existingState {
            case .ready, .preparing, .setup:
                isHealthy = true
            default:
                isHealthy = false
            }

            if currentSessionID != nil && isHealthy {
                // Mid-session and healthy — protect the active stream.
                logger.warning("Rejecting duplicate connection from \(connection.endpoint.debugDescription) — recording in progress")
                connection.cancel()
                return
            }

            // Idle or unhealthy — replace freely.
            logger.info("Replacing existing connection (state=\(String(describing: existingState)), sessionActive=\(self.currentSessionID != nil))")
            existing.stateUpdateHandler = nil
            existing.cancel()
        }

        activeConnection = connection
        connectedDeviceName = connection.endpoint.debugDescription
        receiveBuffer = Data()
        listenerState = .connected

        // Always send an authChallenge on every new connection. A paired
        // phone responds with `authResponse` (HMAC); an unpaired phone in
        // PIN-entry mode will instead send a `pinPairingRequest` in the same
        // pre-auth window. Either message closes the challenge.
        let challenge = DevicePairingService.shared.makeChallenge()
        authState = .awaitingResponse(challengeB64: challenge.b64)
        authTimeoutTask?.cancel()
        authTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.authTimeoutSeconds ?? 15))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if case .awaitingResponse = self.authState, self.activeConnection === connection {
                    self.logger.warning("Auth timeout — closing unauthenticated connection")
                    self.authState = .failed
                    connection.cancel()
                }
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [self] in
                // If this connection has already been superseded (replaced by
                // a newer reconnect from the phone), silently ignore its
                // state updates. Otherwise the old .cancelled callback fires
                // after the replacement and clobbers the live connection's
                // state — which the connection watcher then misreads as a
                // mid-session disconnect and auto-finalizes the recording
                // with 0 chunks received.
                guard self.activeConnection === connection else { return }
                switch state {
                case .ready:
                    self.logger.info("iPhone connected: \(connection.endpoint.debugDescription)")
                    if case .awaitingResponse(let chal) = self.authState {
                        self.sendAuthChallenge(on: connection, challengeB64: chal)
                    }
                case .failed(let error):
                    self.logger.error("Connection failed: \(error.localizedDescription)")
                    self.authTimeoutTask?.cancel()
                    self.authTimeoutTask = nil
                    self.authState = .failed
                    self.activeConnection = nil
                    self.connectedDeviceName = nil
                    self.listenerState = .advertising
                case .cancelled:
                    self.authTimeoutTask?.cancel()
                    self.authTimeoutTask = nil
                    self.authState = .failed
                    self.activeConnection = nil
                    self.connectedDeviceName = nil
                    if self.listener != nil {
                        self.listenerState = .advertising
                    }
                default:
                    break
                }
            }
        }

        connection.start(queue: networkQueue)
        startReceiving(on: connection)
    }

    // MARK: - Receiving

    private func startReceiving(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor [self] in
                if let content {
                    self.receiveBuffer.append(content)
                    self.processReceiveBuffer()
                }

                if let error {
                    self.logger.error("Receive error: \(error.localizedDescription)")
                    return
                }

                if isComplete {
                    self.logger.info("Connection completed")
                    return
                }

                // Continue receiving
                self.startReceiving(on: connection)
            }
        }
    }

    /// Parse complete packets from the receive buffer.
    private func processReceiveBuffer() {
        while receiveBuffer.count >= AudioPacketHeader.byteSize {
            // Copy to a fresh Data so the slice's backing indices start at 0 —
            // AudioPacketHeader.deserialize uses raw pointer offsets and assumes
            // a zero-based buffer.
            let headerData = Data(receiveBuffer.prefix(AudioPacketHeader.byteSize))
            guard let header = AudioPacketHeader.deserialize(from: headerData) else {
                // Invalid data — try to find the next magic number
                if let magicOffset = findNextMagic(in: receiveBuffer, startingAt: 1) {
                    logger.warning("Skipping \(magicOffset) bytes to next packet")
                    receiveBuffer.removeFirst(magicOffset)
                } else {
                    receiveBuffer.removeAll()
                }
                break
            }

            // Check if we have the full payload
            let totalPacketSize = AudioPacketHeader.byteSize + Int(header.payloadLength)
            guard receiveBuffer.count >= totalPacketSize else {
                break // Wait for more data
            }

            // Extract payload
            let payloadStart = receiveBuffer.startIndex.advanced(by: AudioPacketHeader.byteSize)
            let payloadEnd = payloadStart.advanced(by: Int(header.payloadLength))
            let payload = Data(receiveBuffer[payloadStart..<payloadEnd])

            // Remove processed packet from buffer
            receiveBuffer.removeFirst(totalPacketSize)

            // Handle the message
            handleMessage(header: header, payload: payload)
        }
    }

    private func findNextMagic(in data: Data, startingAt offset: Int) -> Int? {
        let magicBytes: [UInt8] = [
            UInt8((AudioPacketHeader.magic >> 24) & 0xFF),
            UInt8((AudioPacketHeader.magic >> 16) & 0xFF),
            UInt8((AudioPacketHeader.magic >> 8) & 0xFF),
            UInt8(AudioPacketHeader.magic & 0xFF),
        ]

        for i in offset..<(data.count - 3) {
            if data[data.startIndex.advanced(by: i)] == magicBytes[0],
               data[data.startIndex.advanced(by: i + 1)] == magicBytes[1],
               data[data.startIndex.advanced(by: i + 2)] == magicBytes[2],
               data[data.startIndex.advanced(by: i + 3)] == magicBytes[3] {
                return i
            }
        }
        return nil
    }

    // MARK: - Message Handling

    private func handleMessage(header: AudioPacketHeader, payload: Data) {
        // Auth gate: until the connection is authenticated, the ONLY packets
        // we accept are `authResponse` (paired phone answering the challenge)
        // and `pinPairingRequest` (new phone joining via PIN). Everything
        // else is dropped and the connection closed.
        if case .authenticated = authState {
            // Pass-through below.
        } else {
            if header.messageType == .authResponse {
                handleAuthResponse(payload: payload)
                return
            }
            if header.messageType == .pinPairingRequest {
                handlePinPairingRequest(payload: payload)
                return
            }
            logger.warning("Dropping \(String(describing: header.messageType)) from unauthenticated peer")
            if case .failed = authState {
                activeConnection?.cancel()
            }
            return
        }

        switch header.messageType {
        case .authChallenge, .authResponse, .authResult:
            // Unexpected after auth completes. Ignore.
            break

        case .sessionStart:
            handleSessionStart(header: header, payload: payload)

        case .audioData:
            let chunk = AudioChunk(
                sequenceNumber: header.sequenceNumber,
                timestamp: header.timestamp,
                sampleRate: header.sampleRate,
                channels: header.channels,
                pcmData: payload
            )
            handleAudioChunk(chunk)

        case .sessionEnd:
            handleSessionEnd()

        case .heartbeat:
            break // Just confirms connection is alive

        case .summaryPush:
            // Mac doesn't expect to receive summaries — this is an outbound-only
            // message type. Ignore if the iPhone ever echoes one.
            break

        case .uploadStart:
            handleUploadStart(payload: payload)

        case .uploadChunk:
            handleUploadChunk(payload: payload)

        case .uploadEnd:
            handleUploadEnd()

        case .sessionProcessed:
            // Mac doesn't expect to receive this — it's an outbound-only ack
            // from the Mac to the iPhone. Ignore if the iPhone echoes one.
            break

        case .sessionDone:
            if let idString = String(data: payload, encoding: .utf8),
               let sessionID = UUID(uuidString: idString) {
                logger.info("sessionDone received for \(sessionID.uuidString)")
                // Phone acknowledges it owns this session — it no longer
                // needs us to resend the processed ack.
                pendingAcks.removeAll { $0.sessionID == sessionID }
                onSessionDone?(sessionID)
            } else {
                logger.warning("sessionDone: invalid payload")
            }

        case .sessionDeleted:
            if let idString = String(data: payload, encoding: .utf8),
               let sessionID = UUID(uuidString: idString) {
                logger.info("sessionDeleted received for \(sessionID.uuidString)")
                pendingAcks.removeAll { $0.sessionID == sessionID }
                onSessionDeleted?(sessionID)
            } else {
                logger.warning("sessionDeleted: invalid payload")
            }

        case .settingsSync:
            // Mac doesn't receive settings sync — it sends them. Ignore.
            break

        case .pinPairingRequest:
            // Handled before the auth gate. Ignore here.
            break

        case .pinPairingResult:
            // Mac-outbound only. Ignore if the phone echoes it.
            break
        }
    }

    // MARK: - Pending Upload Handlers (Phase B)

    /// Session currently being ignored because we already processed it and
    /// sent an immediate ack at uploadStart time. Chunks and uploadEnd for
    /// this session are discarded until the next uploadStart clears this.
    private var ignoringUploadSessionID: String?

    private func handleUploadStart(payload: Data) {
        guard let metadata = PendingUploadMetadata.from(wireData: payload) else {
            logger.error("uploadStart: could not decode metadata payload")
            return
        }

        // If we've already processed this session (ack was sent but lost,
        // or the phone's local record was never cleared), short-circuit
        // before the phone wastes bandwidth re-sending hundreds of MB.
        // Push the cached summary back alongside the ack so the phone has
        // something to show — it may have lost its in-memory copy.
        let state = classifyUploadSession(metadata.sessionID)
        logger.info("uploadStart classify: \(metadata.sessionID) — \(state.logDescription)")
        if case .existsWithSummary(let summary) = state,
           let sessionID = UUID(uuidString: metadata.sessionID) {
            logger.info("uploadStart: \(metadata.sessionID) dedup — pushing cached summary + immediate ack")
            ignoringUploadSessionID = metadata.sessionID
            sendMeetingSummary(summary)
            sendSessionProcessed(sessionID: sessionID, success: true, reason: nil)
            return
        }
        if case .tombstoned = state,
           let sessionID = UUID(uuidString: metadata.sessionID) {
            logger.info("uploadStart: \(metadata.sessionID) tombstoned — acking success to drop phone's local copy")
            ignoringUploadSessionID = metadata.sessionID
            sendSessionProcessed(sessionID: sessionID, success: true, reason: nil)
            return
        }
        ignoringUploadSessionID = nil

        // Clean up any stale upload state from a previous partial attempt
        pendingUploadFileHandle?.closeFile()
        pendingUploadFileHandle = nil
        if let oldURL = pendingUploadURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        pendingUploadURL = nil
        pendingUploadBytesReceived = 0

        // Create a fresh temp file to receive the WAV bytes
        let tempDir = pendingUploadDirectory
        let tempURL = tempDir.appendingPathComponent("upload-\(metadata.sessionID).wav")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            pendingUploadFileHandle = handle
            pendingUploadURL = tempURL
            pendingUploadMetadata = metadata
            logger.info("uploadStart: receiving session \(metadata.sessionID) — \(metadata.byteSize) bytes expected")
        } catch {
            logger.error("uploadStart: could not open temp file: \(error.localizedDescription)")
            pendingUploadMetadata = nil
        }
    }

    private func handleUploadChunk(payload: Data) {
        if ignoringUploadSessionID != nil { return }
        guard let handle = pendingUploadFileHandle else {
            logger.warning("uploadChunk received with no active upload")
            return
        }
        handle.write(payload)
        pendingUploadBytesReceived += Int64(payload.count)
    }

    private func handleUploadEnd() {
        if let ignoredID = ignoringUploadSessionID {
            ignoringUploadSessionID = nil
            logger.info("uploadEnd ignored for already-processed session \(ignoredID)")
            return
        }
        guard let metadata = pendingUploadMetadata,
              let url = pendingUploadURL,
              let handle = pendingUploadFileHandle else {
            logger.warning("uploadEnd with no active upload")
            return
        }

        // Close the file so AVAudioFile can open it for reading
        handle.closeFile()
        pendingUploadFileHandle = nil

        logger.info("uploadEnd: received \(self.pendingUploadBytesReceived) bytes for session \(metadata.sessionID)")

        // Clear the upload state before kicking off reprocess
        let capturedMetadata = metadata
        let capturedURL = url
        pendingUploadMetadata = nil
        pendingUploadURL = nil
        pendingUploadBytesReceived = 0

        // If we already processed this session (ack was sent but lost), ack
        // immediately without reprocessing — prevents duplicate
        // TranscriptSessions. Push the cached summary back alongside the
        // ack so a phone that lost its in-memory copy still gets one.
        let endState = classifyUploadSession(capturedMetadata.sessionID)
        logger.info("uploadEnd classify: \(capturedMetadata.sessionID) — \(endState.logDescription)")
        if case .existsWithSummary(let summary) = endState,
           let sessionID = UUID(uuidString: capturedMetadata.sessionID) {
            logger.info("uploadEnd: \(sessionID.uuidString) dedup — pushing cached summary + immediate ack, skipping reprocess")
            try? FileManager.default.removeItem(at: capturedURL)
            sendMeetingSummary(summary)
            sendSessionProcessed(sessionID: sessionID, success: true, reason: nil)
            return
        }
        if case .tombstoned = endState,
           let sessionID = UUID(uuidString: capturedMetadata.sessionID) {
            logger.info("uploadEnd: \(sessionID.uuidString) tombstoned — acking success and discarding bytes")
            try? FileManager.default.removeItem(at: capturedURL)
            sendSessionProcessed(sessionID: sessionID, success: true, reason: nil)
            return
        }

        // Parse the sessionID up front. Without a valid UUID we cannot ack
        // the phone at all, so bail now. Every other exit path below MUST
        // send an ack so the phone's "Mac is processing" spinner resolves.
        guard let sessionID = UUID(uuidString: capturedMetadata.sessionID) else {
            logger.error("uploadEnd: invalid sessionID '\(capturedMetadata.sessionID)' — cannot ack phone")
            try? FileManager.default.removeItem(at: capturedURL)
            return
        }

        // Fire the reprocess asynchronously.
        Task { [weak self] in
            guard let self else { return }

            var ackSuccess = false
            var ackReason: String? = "Unknown failure"

            defer {
                // Guarantees the phone always hears back, no matter which
                // early return or failure happens inside the Task.
                self.sendSessionProcessed(
                    sessionID: sessionID,
                    success: ackSuccess,
                    reason: ackReason
                )
                self.onPendingReprocessComplete?(sessionID, ackSuccess, ackReason)
            }

            guard let container = self.modelContainer else {
                self.logger.error("No model container configured for reprocess")
                try? FileManager.default.removeItem(at: capturedURL)
                ackReason = "Mac has no model container configured"
                return
            }

            let result = await PendingReprocessService.shared.reprocess(
                wavURL: capturedURL,
                metadata: capturedMetadata,
                modelContainer: container
            )

            // Move the temp WAV to the permanent audio directory so it's
            // still available for playback from the review view.
            if result.success {
                let destURL = self.audioDirectory.appendingPathComponent("\(sessionID.uuidString).wav")
                try? FileManager.default.removeItem(at: destURL)
                do {
                    try FileManager.default.moveItem(at: capturedURL, to: destURL)
                    let context = ModelContext(container)
                    let descriptor = FetchDescriptor<TranscriptSession>(
                        predicate: #Predicate { $0.id == sessionID }
                    )
                    if let session = try? context.fetch(descriptor).first {
                        session.audioFilePath = self.relativeAudioPath(for: sessionID)
                        try? context.save()
                    }
                } catch {
                    logger.warning("Could not move upload to audio dir: \(error.localizedDescription)")
                }
                // The session's `meetingSummaryJSON` is the authoritative
                // "already processed" marker going forward — set by the
                // summary-generation pass in TranscriptionSessionCoordinator.
                // If the ack fails to send, a re-upload will still dedup
                // via lookupProcessedSession once the summary lands.
            } else {
                try? FileManager.default.removeItem(at: capturedURL)
            }

            ackSuccess = result.success
            ackReason = result.reason
        }
    }

    /// Persistent temp directory for in-flight pending WAV uploads.
    private var pendingUploadDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PendingUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Send a `sessionProcessed` ack to the iPhone so it can delete the
    /// local WAV after a successful reprocess.
    ///
    /// The ack is ALWAYS enqueued (dedup'd by sessionID) and replayed on
    /// every reconnect until its TTL expires. `NWConnection.send`'s
    /// completion fires when bytes are accepted into the kernel send
    /// buffer, not when the peer receives them — a half-dead TCP
    /// connection can silently swallow a send and strand the phone on
    /// "Mac is processing". By keeping the ack queued, any fresh
    /// reconnect will replay it; the phone's handler is idempotent.
    func sendSessionProcessed(sessionID: UUID, success: Bool, reason: String?) {
        // 1. Always queue (or refresh) the ack first. Replace any prior
        //    entry for the same session so the latest state wins.
        pendingAcks.removeAll { $0.sessionID == sessionID }
        pendingAcks.append(PendingAck(
            sessionID: sessionID,
            success: success,
            reason: reason,
            queuedAt: .now
        ))

        // 2. Best-effort immediate send. A success here doesn't prove
        //    delivery, so we don't dequeue.
        guard let connection = activeConnection else {
            logger.info("sendSessionProcessed: no active connection — ack queued for \(sessionID.uuidString)")
            return
        }

        let ack = SessionProcessedAck(
            sessionID: sessionID.uuidString,
            success: success,
            reason: reason
        )
        guard let payload = ack.toWireData() else { return }

        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .sessionProcessed,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(payload.count)
        )
        var packet = header.serialize()
        packet.append(payload)

        connection.send(content: packet, completion: .contentProcessed { [logger] error in
            if let error {
                logger.error("sendSessionProcessed transport error: \(error.localizedDescription) — ack remains queued for replay")
            } else {
                logger.info("sessionProcessed ack handed to TCP for \(sessionID.uuidString) success=\(success) (queued pending reconnect replay)")
            }
        })
    }

    /// Most recent session start metadata (speaker count, names).
    private(set) var lastSessionMetadata: SessionStartMetadata?

    private func handleSessionStart(header: AudioPacketHeader, payload: Data) {
        let metadata = SessionStartMetadata.from(wireData: payload)
        let sessionIDString = metadata?.sessionID ?? String(data: payload, encoding: .utf8) ?? UUID().uuidString
        let sessionID = UUID(uuidString: sessionIDString) ?? UUID()

        self.currentSessionID = sessionID
        self.chunksReceived = 0
        self.expectedSequenceNumber = 0
        self.reorderBuffer.removeAll()
        self.sessionSampleRate = header.sampleRate
        self.sessionChannels = header.channels
        self.lastSessionMetadata = metadata

        // Start WAV file
        startAudioFile(sessionID: sessionID, sampleRate: header.sampleRate, channels: header.channels)

        onSessionStart?(sessionID, header.sampleRate, header.channels)

        let speakerDesc = metadata?.expectedSpeakerCount?.description ?? "auto"
        let namesDesc = metadata?.speakerNames.isEmpty == false ? metadata!.speakerNames.joined(separator: ", ") : "none"
        logger.info("Session started: \(sessionID.uuidString), \(header.sampleRate)Hz, \(header.channels)ch, speakers=\(speakerDesc), names=[\(namesDesc)]")
    }

    private func handleAudioChunk(_ chunk: AudioChunk) {
        chunksReceived += 1

        // Write to WAV file
        writeAudioData(chunk.pcmData)

        // Reassembly: handle out-of-order chunks
        if chunk.sequenceNumber == expectedSequenceNumber {
            // In order — deliver immediately
            onAudioChunk?(chunk)
            expectedSequenceNumber += 1

            // Deliver any buffered chunks that are now in order
            while let buffered = reorderBuffer.removeValue(forKey: expectedSequenceNumber) {
                onAudioChunk?(buffered)
                expectedSequenceNumber += 1
            }
        } else if chunk.sequenceNumber > expectedSequenceNumber {
            // Out of order — buffer it
            reorderBuffer[chunk.sequenceNumber] = chunk

            // If the gap is too large, skip ahead
            if chunk.sequenceNumber - expectedSequenceNumber > maxReorderWindow {
                logger.warning("Large sequence gap: expected \(self.expectedSequenceNumber), got \(chunk.sequenceNumber)")
                // Deliver everything we have in order
                let sorted = reorderBuffer.keys.sorted()
                for seq in sorted {
                    if let buffered = reorderBuffer.removeValue(forKey: seq) {
                        onAudioChunk?(buffered)
                    }
                }
                expectedSequenceNumber = chunk.sequenceNumber + 1
            }
        }
        // else: duplicate or old chunk — ignore
    }

    private func handleSessionEnd() {
        finalizeAudioFile()
        onSessionEnd?()

        let sessionID = currentSessionID
        currentSessionID = nil

        logger.info("Session ended: \(sessionID?.uuidString ?? "unknown"), \(self.chunksReceived) chunks received")
    }

    // MARK: - WAV File Writing

    private func startAudioFile(sessionID: UUID, sampleRate: UInt32, channels: UInt16) {
        let url = audioDirectory.appendingPathComponent("\(sessionID.uuidString).wav")

        // Write WAV header placeholder (will be updated on finalize)
        let header = wavHeader(sampleRate: sampleRate, channels: channels, dataSize: 0)
        FileManager.default.createFile(atPath: url.path, contents: nil)

        do {
            let handle = try FileHandle(forWritingTo: url)
            handle.write(header)
            self.audioFileHandle = handle
            self.audioFileURL = url
            self.totalAudioBytesWritten = 0
            logger.debug("Audio file created: \(url.lastPathComponent)")
        } catch {
            logger.error("Failed to create audio file: \(error.localizedDescription)")
        }
    }

    private func writeAudioData(_ data: Data) {
        audioFileHandle?.write(data)
        totalAudioBytesWritten += UInt32(data.count)
    }

    private func finalizeAudioFile() {
        guard let handle = audioFileHandle, let url = audioFileURL else { return }

        // Rewrite the WAV header with the correct data size
        let header = wavHeader(sampleRate: sessionSampleRate, channels: sessionChannels, dataSize: totalAudioBytesWritten)
        handle.seek(toFileOffset: 0)
        handle.write(header)
        handle.closeFile()

        audioFileHandle = nil
        audioFileURL = nil

        logger.info("Audio file finalized: \(url.lastPathComponent), \(self.totalAudioBytesWritten) bytes")
    }

    /// Build a standard 44-byte WAV header.
    private func wavHeader(sampleRate: UInt32, channels: UInt16, dataSize: UInt32) -> Data {
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let chunkSize = 36 + dataSize

        var header = Data(capacity: 44)

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndian: chunkSize)
        header.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndian: UInt32(16))     // Subchunk1Size (PCM)
        header.append(littleEndian: UInt16(1))      // AudioFormat (PCM)
        header.append(littleEndian: channels)
        header.append(littleEndian: sampleRate)
        header.append(littleEndian: byteRate)
        header.append(littleEndian: blockAlign)
        header.append(littleEndian: bitsPerSample)

        // data subchunk
        header.append(contentsOf: "data".utf8)
        header.append(littleEndian: dataSize)

        return header
    }

    /// URL of the saved WAV file for a session (if it exists).
    func audioFileURL(for sessionID: UUID) -> URL? {
        let url = audioDirectory.appendingPathComponent("\(sessionID.uuidString).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Relative path from Application Support for storage in TranscriptSession.
    func relativeAudioPath(for sessionID: UUID) -> String {
        "MeetingAudio/\(sessionID.uuidString).wav"
    }
}

// MARK: - Data Extension for WAV Header

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
}
