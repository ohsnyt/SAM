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

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "AudioReceivingService")

@MainActor
@Observable
final class AudioReceivingService {

    // MARK: - State

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

    /// Acks that couldn't be sent because the iPhone wasn't connected when
    /// reprocess finished. Drained the next time the phone connects.
    private struct PendingAck {
        let sessionID: UUID
        let success: Bool
        let reason: String?
    }
    private var pendingAcks: [PendingAck] = []

    // MARK: - Processed Session Ledger

    /// Session IDs the Mac has already successfully reprocessed. Persisted
    /// to UserDefaults so we survive app restarts. If the iPhone re-uploads
    /// a session we already processed (ack was lost), we immediately ack
    /// success without reprocessing again.
    private static let processedLedgerKey = "sam.processedUploadSessions"
    private static let processedLedgerMax = 500

    private var processedSessionIDs: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: processedLedgerKey) ?? []
        return Set(stored)
    }()

    private func markSessionProcessed(_ sessionID: UUID) {
        processedSessionIDs.insert(sessionID.uuidString)
        var list = Array(processedSessionIDs)
        if list.count > Self.processedLedgerMax {
            list = Array(list.suffix(Self.processedLedgerMax))
            processedSessionIDs = Set(list)
        }
        UserDefaults.standard.set(list, forKey: Self.processedLedgerKey)
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

        connection.send(content: packet, completion: .contentProcessed { error in
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

        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                logger.error("sendMeetingSummary failed: \(error.localizedDescription)")
            } else {
                logger.info("Meeting summary pushed to iPhone (\(payload.count) bytes)")
            }
        })
    }

    /// Directory for received meeting audio files.
    private var audioDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MeetingAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Advertising

    /// Start advertising the transcription service via Bonjour and listen for connections.
    func startAdvertising() throws {
        guard listenerState == .idle else { return }

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let listener = try NWListener(using: params)

        // Advertise via Bonjour
        listener.service = NWListener.Service(
            type: AudioStreamingConstants.bonjourServiceType,
            domain: AudioStreamingConstants.bonjourDomain
        )

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener?.port {
                        logger.info("Listening on port \(port.rawValue)")
                    }
                    self.listenerState = .advertising
                case .failed(let error):
                    logger.error("Listener failed: \(error.localizedDescription)")
                    self.listenerState = .idle
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }

        listener.start(queue: networkQueue)
        self.listener = listener

        logger.info("Started advertising transcription service")
    }

    /// Stop advertising and disconnect.
    func stopAdvertising() {
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
            existing.cancel()
        }

        activeConnection = connection
        connectedDeviceName = connection.endpoint.debugDescription
        receiveBuffer = Data()
        listenerState = .connected

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    logger.info("iPhone connected: \(connection.endpoint.debugDescription)")
                    // Flush any pending summary that couldn't be pushed because
                    // the phone wasn't connected when the Mac finished generating.
                    if let pending = self.pendingSummary {
                        self.pendingSummary = nil
                        logger.info("Flushing pending summary to newly connected iPhone")
                        self.sendMeetingSummary(pending)
                    }
                    // Drain any queued sessionProcessed acks whose sends were
                    // skipped because the phone disconnected before reprocess
                    // finished. This is the primary fix for the "Mac is
                    // processing" spinner that never resolves.
                    if !self.pendingAcks.isEmpty {
                        let acks = self.pendingAcks
                        self.pendingAcks = []
                        logger.info("Draining \(acks.count) pending ack(s) to reconnected iPhone")
                        for ack in acks {
                            self.sendSessionProcessed(
                                sessionID: ack.sessionID,
                                success: ack.success,
                                reason: ack.reason
                            )
                        }
                    }
                case .failed(let error):
                    logger.error("Connection failed: \(error.localizedDescription)")
                    self.activeConnection = nil
                    self.connectedDeviceName = nil
                    self.listenerState = .advertising
                case .cancelled:
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
            Task { @MainActor in
                guard let self else { return }

                if let content {
                    self.receiveBuffer.append(content)
                    self.processReceiveBuffer()
                }

                if let error {
                    logger.error("Receive error: \(error.localizedDescription)")
                    return
                }

                if isComplete {
                    logger.info("Connection completed")
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
        switch header.messageType {
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
                onSessionDone?(sessionID)
            } else {
                logger.warning("sessionDone: invalid payload")
            }

        case .sessionDeleted:
            if let idString = String(data: payload, encoding: .utf8),
               let sessionID = UUID(uuidString: idString) {
                logger.info("sessionDeleted received for \(sessionID.uuidString)")
                onSessionDeleted?(sessionID)
            } else {
                logger.warning("sessionDeleted: invalid payload")
            }

        case .settingsSync:
            // Mac doesn't receive settings sync — it sends them. Ignore.
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

        // If we've already processed this session (ack was sent but lost),
        // send an immediate ack at uploadStart time so the phone doesn't
        // waste bandwidth re-uploading all the bytes.
        if processedSessionIDs.contains(metadata.sessionID) {
            logger.info("uploadStart: \(metadata.sessionID) already in processed ledger — acking immediately, ignoring chunks")
            ignoringUploadSessionID = metadata.sessionID
            if let sessionID = UUID(uuidString: metadata.sessionID) {
                sendSessionProcessed(sessionID: sessionID, success: true, reason: nil)
            }
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
        // immediately without reprocessing — prevents duplicate TranscriptSessions.
        if let sessionID = UUID(uuidString: capturedMetadata.sessionID),
           processedSessionIDs.contains(sessionID.uuidString) {
            logger.info("uploadEnd: session \(sessionID.uuidString) already in processed ledger — sending immediate ack, skipping reprocess")
            try? FileManager.default.removeItem(at: capturedURL)
            sendSessionProcessed(sessionID: sessionID, success: true, reason: nil)
            return
        }

        // Fire the reprocess asynchronously.
        Task { [weak self] in
            guard let self, let container = self.modelContainer else {
                logger.error("No model container configured for reprocess")
                return
            }
            let result = await PendingReprocessService.shared.reprocess(
                wavURL: capturedURL,
                metadata: capturedMetadata,
                modelContainer: container
            )

            guard let sessionID = UUID(uuidString: capturedMetadata.sessionID) else { return }

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
                // Record in the processed ledger before sending the ack so
                // that even if the ack send fails, we won't reprocess again.
                self.markSessionProcessed(sessionID)
            } else {
                try? FileManager.default.removeItem(at: capturedURL)
            }

            self.sendSessionProcessed(
                sessionID: sessionID,
                success: result.success,
                reason: result.reason
            )
            self.onPendingReprocessComplete?(sessionID, result.success, result.reason)
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
    /// local WAV after a successful reprocess. If the iPhone is not currently
    /// connected, the ack is queued and sent the next time the phone connects.
    func sendSessionProcessed(sessionID: UUID, success: Bool, reason: String?) {
        guard let connection = activeConnection else {
            logger.info("sendSessionProcessed: no active connection — queuing ack for \(sessionID.uuidString)")
            pendingAcks.append(PendingAck(sessionID: sessionID, success: success, reason: reason))
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

        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                logger.error("sendSessionProcessed failed: \(error.localizedDescription)")
            } else {
                logger.info("sessionProcessed ack sent for \(sessionID.uuidString) success=\(success)")
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
        var header = wavHeader(sampleRate: sampleRate, channels: channels, dataSize: 0)
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
