//
//  AudioStreamingService.swift
//  SAM Field
//
//  Network.framework TCP client for streaming audio to the Mac.
//  Browses for the Mac's Bonjour service, connects via TCP,
//  and sends audio chunks with the SAM audio packet protocol.
//  Handles reconnection with exponential backoff.
//

import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "AudioStreamingService")

@MainActor
@Observable
final class AudioStreamingService {

    // MARK: - State

    enum ConnectionState: Sendable, Equatable {
        case disconnected
        case browsing
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    private(set) var connectionState: ConnectionState = .disconnected

    /// Name of the connected Mac (from Bonjour).
    private(set) var connectedMacName: String?

    /// Chunks queued but not yet sent (during reconnection).
    private(set) var bufferedChunkCount: Int = 0

    /// Fired when the Mac pushes a meeting summary back to the phone.
    /// MeetingCaptureCoordinator sets this to display the summary in the UI.
    var onMeetingSummary: (@Sendable (MeetingSummary) -> Void)?

    // MARK: - Private

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var heartbeatTimer: Timer?
    private var reconnectionAttempt: Int = 0
    private var sendQueue: [AudioChunk] = []
    private let maxBufferedChunks = 240 // ~120s at 0.5s chunks
    private var sessionID: UUID?
    private var receiveBuffer = Data()

    private let networkQueue = DispatchQueue(label: "com.matthewsessions.SAMField.audioStreaming", qos: .userInitiated)

    // MARK: - Browse & Connect

    /// Start browsing for Mac transcription services on the local network.
    func startBrowsing() {
        guard connectionState == .disconnected else { return }

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: AudioStreamingConstants.bonjourServiceType, domain: AudioStreamingConstants.bonjourDomain),
            using: params
        )

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    logger.info("Bonjour browser ready")
                case .failed(let error):
                    logger.error("Bonjour browser failed: \(error.localizedDescription)")
                    self.connectionState = .disconnected
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                guard let self else { return }
                // Connect to the first available Mac
                if let result = results.first {
                    logger.info("Found Mac transcription service: \(result.endpoint.debugDescription)")
                    self.browser?.cancel()
                    self.browser = nil
                    self.connectToEndpoint(result.endpoint)
                }
            }
        }

        browser.start(queue: networkQueue)
        self.browser = browser
        connectionState = .browsing

        logger.info("Started browsing for Mac transcription service")
    }

    /// Stop browsing and disconnect.
    func disconnect() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        sendQueue.removeAll()
        bufferedChunkCount = 0
        connectedMacName = nil
        reconnectionAttempt = 0
        connectionState = .disconnected

        logger.info("Disconnected from Mac")
    }

    // MARK: - Sending

    /// Send an audio chunk to the Mac. Buffers if disconnected.
    func send(chunk: AudioChunk) {
        if connectionState == .connected, let connection {
            sendChunk(chunk, on: connection)
        } else {
            // Buffer for replay after reconnection
            sendQueue.append(chunk)
            if sendQueue.count > maxBufferedChunks {
                sendQueue.removeFirst()
            }
            bufferedChunkCount = sendQueue.count
        }
    }

    /// Send a session start message.
    func sendSessionStart(sessionID: UUID, sampleRate: UInt32, channels: UInt16) {
        self.sessionID = sessionID
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .sessionStart,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: sampleRate,
            channels: channels,
            payloadLength: UInt32(sessionID.uuidString.utf8.count)
        )
        let payload = Data(sessionID.uuidString.utf8)
        sendPacket(header: header, payload: payload)
    }

    /// Send a session end message.
    func sendSessionEnd() {
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .sessionEnd,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: 0
        )
        sendPacket(header: header, payload: Data())
        sessionID = nil
    }

    // MARK: - Private: Connection

    private func connectToEndpoint(_ endpoint: NWEndpoint) {
        connectionState = .connecting

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    logger.info("Connected to Mac")
                    self.connectionState = .connected
                    self.connectedMacName = endpoint.debugDescription
                    self.reconnectionAttempt = 0
                    self.startHeartbeat()
                    self.flushBufferedChunks()
                    self.startReceiving()

                case .failed(let error):
                    logger.error("Connection failed: \(error.localizedDescription)")
                    self.connection = nil
                    self.attemptReconnection(to: endpoint)

                case .waiting(let error):
                    logger.warning("Connection waiting: \(error.localizedDescription)")

                default:
                    break
                }
            }
        }

        connection.start(queue: networkQueue)
        self.connection = connection
    }

    private func attemptReconnection(to endpoint: NWEndpoint) {
        let backoffs = AudioStreamingConstants.reconnectionBackoffs
        guard reconnectionAttempt < backoffs.count else {
            logger.error("Max reconnection attempts reached — giving up")
            connectionState = .disconnected
            return
        }

        let delay = backoffs[reconnectionAttempt]
        reconnectionAttempt += 1
        connectionState = .reconnecting(attempt: reconnectionAttempt)

        logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectionAttempt))")

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard case .reconnecting = self.connectionState else { return }
            self.connectToEndpoint(endpoint)
        }
    }

    // MARK: - Private: Sending

    private func sendChunk(_ chunk: AudioChunk, on connection: NWConnection) {
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .audioData,
            sequenceNumber: chunk.sequenceNumber,
            timestamp: chunk.timestamp,
            sampleRate: chunk.sampleRate,
            channels: chunk.channels,
            payloadLength: UInt32(chunk.pcmData.count)
        )

        sendPacket(header: header, payload: chunk.pcmData)
    }

    private func sendPacket(header: AudioPacketHeader, payload: Data) {
        guard let connection, connectionState == .connected else { return }

        var packet = header.serialize()
        packet.append(payload)

        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                logger.error("Send error: \(error.localizedDescription)")
            }
        })
    }

    private func flushBufferedChunks() {
        guard let connection, connectionState == .connected else { return }

        let buffered = sendQueue
        sendQueue.removeAll()
        bufferedChunkCount = 0

        logger.info("Flushing \(buffered.count) buffered chunks")

        for chunk in buffered {
            sendChunk(chunk, on: connection)
        }
    }

    // MARK: - Receiving (Mac → iPhone)

    /// Kick off a continuous receive loop on the connection. Parses incoming
    /// packets (currently just summaryPush messages) and dispatches them to
    /// the registered callbacks.
    private func startReceiving() {
        guard let connection, connectionState == .connected else { return }
        receiveBuffer = Data()
        receiveLoop(on: connection)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let content {
                    self.receiveBuffer.append(content)
                    self.processInboundBuffer()
                }

                if let error {
                    logger.error("Receive error: \(error.localizedDescription)")
                    return
                }

                if isComplete {
                    logger.info("Inbound stream closed")
                    return
                }

                // Only continue receiving if still connected
                if self.connectionState == .connected {
                    self.receiveLoop(on: connection)
                }
            }
        }
    }

    /// Parse complete packets from the receive buffer.
    private func processInboundBuffer() {
        while receiveBuffer.count >= AudioPacketHeader.byteSize {
            // Copy to a fresh Data so indices are zero-based (same defensive
            // pattern the Mac uses — avoids slice-index surprises).
            let headerData = Data(receiveBuffer.prefix(AudioPacketHeader.byteSize))
            guard let header = AudioPacketHeader.deserialize(from: headerData) else {
                logger.warning("Invalid header in inbound buffer — clearing")
                receiveBuffer.removeAll()
                break
            }

            let totalPacketSize = AudioPacketHeader.byteSize + Int(header.payloadLength)
            guard receiveBuffer.count >= totalPacketSize else {
                break // Wait for more bytes
            }

            let payloadStart = receiveBuffer.startIndex.advanced(by: AudioPacketHeader.byteSize)
            let payloadEnd = payloadStart.advanced(by: Int(header.payloadLength))
            let payload = Data(receiveBuffer[payloadStart..<payloadEnd])

            receiveBuffer.removeFirst(totalPacketSize)

            handleInbound(header: header, payload: payload)
        }
    }

    private func handleInbound(header: AudioPacketHeader, payload: Data) {
        switch header.messageType {
        case .summaryPush:
            guard let summary = MeetingSummary.from(wireData: payload) else {
                logger.warning("Failed to decode inbound summary (\(payload.count) bytes)")
                return
            }
            logger.info("Received meeting summary from Mac: \(summary.actionItems.count) action items")
            onMeetingSummary?(summary)

        case .heartbeat:
            break // Mac acknowledging liveness

        default:
            // iPhone doesn't expect to receive audio/session packets — ignore.
            break
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: AudioStreamingConstants.heartbeatIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .heartbeat,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: 0
        )
        sendPacket(header: header, payload: Data())
    }
}
