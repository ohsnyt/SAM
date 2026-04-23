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
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class AudioStreamingService {

    static let shared = AudioStreamingService()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "AudioStreamingService")

    // MARK: - State

    enum ConnectionState: Sendable, Equatable {
        case disconnected
        case browsing
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    enum PinPairingState: Sendable, Equatable {
        case idle
        case searching
        case sending
        case success(macName: String)
        case failure(reason: String)
    }

    private(set) var connectionState: ConnectionState = .disconnected

    /// Name of the connected Mac (from Bonjour).
    private(set) var connectedMacName: String?

    /// Identifier of the Mac this phone is currently talking to (from the
    /// Bonjour TXT record). Non-nil from `.connecting` onwards and used to
    /// look up the right pairing token when answering the auth challenge.
    private(set) var connectedMacDeviceID: UUID?

    /// Human-readable reason the last connection attempt failed the auth
    /// gate (e.g., "This iPhone isn't paired with this Mac"). Displayed in
    /// Settings so the user knows to try pairing again.
    private(set) var lastAuthError: String?

    /// UI-facing state of an in-progress PIN pairing attempt. Idle unless
    /// the user has opened the PIN entry sheet and tapped Pair.
    private(set) var pinPairingState: PinPairingState = .idle

    /// Chunks queued but not yet sent (during reconnection).
    private(set) var bufferedChunkCount: Int = 0

    /// Fired when the Mac pushes a meeting summary back to the phone.
    /// MeetingCaptureCoordinator sets this to display the summary in the UI.
    var onMeetingSummary: (@Sendable (MeetingSummary) -> Void)?

    /// Fired when the Mac acknowledges that a pending upload finished
    /// processing (success or failure). `PendingUploadService` uses this
    /// to unblock the upload task and clean up the local WAV on success.
    var onSessionProcessed: (@Sendable (SessionProcessedAck) -> Void)?

    /// Fired when the Mac pushes workspace settings (calendar/contact config).
    var onWorkspaceSettingsReceived: (@Sendable () -> Void)?

    // MARK: - Private

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var heartbeatTimer: Timer?
    private var reconnectionAttempt: Int = 0
    private var sendQueue: [AudioChunk] = []
    private let maxBufferedChunks = 240 // ~120s at 0.5s chunks
    private var sessionID: UUID?
    private var receiveBuffer = Data()

    /// PIN waiting to be sent. Non-nil between `pairWithPIN(_:)` and the
    /// arrival of a `pinPairingResult` (success or failure). Drives both
    /// the connect-to-unpaired-Mac branch in the browse handler and the
    /// send-pinPairingRequest branch in `handleAuthChallenge`.
    private var pendingPin: String?

    /// NWPathMonitor watches for WiFi restored / network interface changes
    /// so we can re-kick the Bonjour browse when the user walks back into
    /// range. Without this, a long offline period leaves the iPhone stuck
    /// in `.disconnected` or `.reconnecting` state with no fresh browse.
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status = .requiresConnection

    private let networkQueue = DispatchQueue(label: "com.matthewsessions.SAMField.audioStreaming", qos: .userInitiated)

    // MARK: - Auth State

    private enum PhoneAuthState: Equatable {
        case none
        /// Connection is up; waiting for the Mac to send authChallenge.
        case awaitingChallenge
        /// We sent a pinPairingRequest; waiting for the Mac's pinPairingResult.
        case sendingPinRequest(pin: String)
        /// We answered authChallenge; waiting for the Mac's authResult.
        case awaitingResult
        case authenticated
    }
    private var authState: PhoneAuthState = .none

    private let authHandshakeTimeoutSeconds: TimeInterval = 15
    private var authTimeoutTask: Task<Void, Never>?

    /// Discovery timeout for PIN pairing. If the Bonjour browser can't find
    /// a SAM Mac within this window, we surface a helpful failure in the UI
    /// instead of spinning forever.
    private let pinDiscoveryTimeoutSeconds: TimeInterval = 30
    private var pinDiscoveryTimeoutTask: Task<Void, Never>?

    // MARK: - Browse & Connect

    /// Start browsing for Mac transcription services on the local network.
    func startBrowsing() {
        // Ensure the path monitor is running so we can recover from
        // walk-out-of-range scenarios. Safe to call repeatedly.
        startPathMonitor()

        guard connectionState == .disconnected else { return }

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: AudioStreamingConstants.bonjourServiceType, domain: AudioStreamingConstants.bonjourDomain),
            using: params
        )

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [self] in
                switch state {
                case .ready:
                    self.logger.info("Bonjour browser ready")
                case .waiting(let error):
                    // .waiting usually means iOS hasn't resolved Local Network
                    // permission yet or there's no network path. Log it so the
                    // user can see what's happening; don't fail immediately —
                    // the discovery timeout in pairWithPIN will clean up.
                    self.logger.warning("Bonjour browser waiting: \(error.localizedDescription)")
                case .failed(let error):
                    self.logger.error("Bonjour browser failed: \(error.localizedDescription)")
                    if self.pendingPin != nil {
                        self.pendingPin = nil
                        self.pinDiscoveryTimeoutTask?.cancel()
                        self.pinDiscoveryTimeoutTask = nil
                        self.pinPairingState = .failure(
                            reason: "Couldn't browse the local network (\(error.localizedDescription))."
                        )
                    }
                    self.connectionState = .disconnected
                case .cancelled:
                    self.logger.debug("Bonjour browser cancelled")
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor [self] in
                // Dedupe: the browse handler can fire multiple times in
                // rapid succession (IPv4 + IPv6 dual-stack, retransmitted
                // Bonjour announcements). If we already have a connection
                // in flight or established, ignore additional results —
                // otherwise we'd open parallel TCP sockets to the same Mac
                // and cause a race that kills the active stream.
                switch self.connectionState {
                case .connecting, .connected, .reconnecting:
                    return
                case .disconnected, .browsing:
                    break
                }

                let pairing = DevicePairingService.shared

                self.logger.debug("Browse results changed: \(results.count) endpoint(s)")

                // If a PIN is pending (user just tapped Pair), connect to
                // the first SAM Mac we see — the PIN is the gate, not
                // pre-existing trust. The TXT record may not be resolved
                // yet in the first browse event, and we don't need it here
                // anyway: the Mac's real identity (deviceID + displayName)
                // arrives in the PinPairingResult after we send the PIN.
                if self.pendingPin != nil {
                    for result in results {
                        let (macID, macName) = Self.extractMacIdentity(from: result)
                            ?? (UUID(), Self.endpointName(result.endpoint))
                        self.logger.info("PIN pairing: connecting to Mac \(macName) (provisional id \(macID))")
                        self.lastAuthError = nil
                        self.pinDiscoveryTimeoutTask?.cancel()
                        self.pinDiscoveryTimeoutTask = nil
                        self.browser?.cancel()
                        self.browser = nil
                        self.connectToEndpoint(result.endpoint, macDeviceID: macID, macDisplayName: macName)
                        return
                    }
                    // No SAM Macs among the results yet — keep browsing,
                    // the discovery timeout will fire if nothing ever shows up.
                    return
                }

                // Normal path: only connect to Macs we've already paired with.
                for result in results {
                    guard let (macID, macName) = Self.extractMacIdentity(from: result) else { continue }
                    if pairing.isPaired(with: macID) {
                        self.logger.info("Found paired Mac \(macID) (\(macName))")
                        self.lastAuthError = nil
                        self.browser?.cancel()
                        self.browser = nil
                        self.connectToEndpoint(result.endpoint, macDeviceID: macID, macDisplayName: macName)
                        return
                    }
                }

                if pairing.trustedMacs.isEmpty {
                    self.lastAuthError = "Open SAM on your Mac and tap Pair New iPhone to get a PIN."
                } else {
                    self.lastAuthError = "A SAM Mac is nearby but this iPhone isn't paired with it."
                }
            }
        }

        browser.start(queue: networkQueue)
        self.browser = browser
        connectionState = .browsing

        logger.info("Started browsing for Mac transcription service")
    }

    /// Tear down any in-flight browse/connection and kick a fresh browse.
    /// Used when the pairing list changes (e.g., immediately after a PIN
    /// pairing succeeds) so the new trust state takes effect without the
    /// user having to toggle anything.
    func restartBrowsing() {
        logger.info("Restarting browse after pairing change")
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
        authState = .none
        connectedMacDeviceID = nil
        connectedMacName = nil
        reconnectionAttempt = 0
        lastAuthError = nil
        connectionState = .disconnected
        startBrowsing()
    }

    /// Stop browsing and disconnect.
    func disconnect() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
        pinDiscoveryTimeoutTask?.cancel()
        pinDiscoveryTimeoutTask = nil
        authState = .none
        sendQueue.removeAll()
        bufferedChunkCount = 0
        connectedMacName = nil
        connectedMacDeviceID = nil
        reconnectionAttempt = 0
        connectionState = .disconnected
        pendingPin = nil
        pinPairingState = .idle
        pathMonitor?.cancel()
        pathMonitor = nil

        logger.info("Disconnected from Mac")
    }

    // MARK: - PIN Pairing

    /// Kick off a PIN pairing attempt. Tears down any existing connection,
    /// then browses for a SAM Mac and sends a `pinPairingRequest` carrying
    /// the PIN on the next `authChallenge`. On success the Mac replies with
    /// a `pinPairingResult` containing the 32-byte HMAC token plus its
    /// identity, and this connection becomes authenticated immediately.
    func pairWithPIN(_ pin: String) {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isNumber }) else {
            pinPairingState = .failure(reason: "PIN must be 6 digits.")
            return
        }

        logger.info("pairWithPIN: tearing down existing connection to try a fresh pair")
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
        pinDiscoveryTimeoutTask?.cancel()
        pinDiscoveryTimeoutTask = nil
        authState = .none
        connectedMacDeviceID = nil
        connectedMacName = nil
        reconnectionAttempt = 0
        lastAuthError = nil
        connectionState = .disconnected

        pendingPin = trimmed
        pinPairingState = .searching
        startBrowsing()
        armPinDiscoveryTimeout()
    }

    private func armPinDiscoveryTimeout() {
        pinDiscoveryTimeoutTask?.cancel()
        pinDiscoveryTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.pinDiscoveryTimeoutSeconds ?? 30))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.pendingPin != nil else { return }
            // Still browsing with no Mac found — time to give up.
            guard case .browsing = self.connectionState else { return }

            self.logger.warning("PIN pairing: no SAM Mac found within \(self.pinDiscoveryTimeoutSeconds)s — giving up")
            self.browser?.cancel()
            self.browser = nil
            self.pendingPin = nil
            self.connectionState = .disconnected
            self.pinPairingState = .failure(
                reason: "Couldn't find your Mac. Make sure SAM is running on your Mac, both devices are on the same Wi-Fi, and Local Network is allowed in Settings → SAM Field."
            )
        }
    }

    // MARK: - Network Path Monitoring

    /// Watch for network path changes (WiFi restored, interface swap,
    /// etc.) so we can re-trigger the Bonjour browse when connectivity
    /// returns after a disconnection. Without this, a user walking back
    /// into range with the app backgrounded might never reconnect.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handlePathUpdate(path)
            }
        }
        monitor.start(queue: networkQueue)
        pathMonitor = monitor
        logger.debug("NWPathMonitor started")
    }

    private func handlePathUpdate(_ path: NWPath) {
        let wasOffline = lastPathStatus != .satisfied
        lastPathStatus = path.status

        // Only interesting: we just went from offline → online
        guard path.status == .satisfied, wasOffline else { return }

        logger.info("Network path restored (interfaces: \(path.availableInterfaces.map { $0.name }.joined(separator: ", ")))")

        // If we're in a state where a new connection attempt would help,
        // kick the browse again. Avoid interrupting healthy live sessions.
        switch connectionState {
        case .disconnected, .reconnecting:
            logger.info("Restarting Bonjour browse after network restore")
            browser?.cancel()
            browser = nil
            reconnectionAttempt = 0
            connectionState = .disconnected
            startBrowsing()
        case .browsing, .connecting, .connected:
            break
        }
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

    /// Send a session start message with optional speaker metadata.
    func sendSessionStart(
        sessionID: UUID,
        sampleRate: UInt32,
        channels: UInt16,
        expectedSpeakerCount: Int? = nil,
        speakerNames: [String] = [],
        recordingContext: RecordingContext? = nil,
        calendarEventID: String? = nil
    ) {
        self.sessionID = sessionID
        let metadata = SessionStartMetadata(
            sessionID: sessionID.uuidString,
            expectedSpeakerCount: expectedSpeakerCount,
            speakerNames: speakerNames,
            recordingContext: recordingContext,
            calendarEventID: calendarEventID
        )
        let payload = metadata.toWireData() ?? Data(sessionID.uuidString.utf8)
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .sessionStart,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: sampleRate,
            channels: channels,
            payloadLength: UInt32(payload.count)
        )
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

    // MARK: - Pending Upload (Phase B)

    /// Send an `uploadStart` message with metadata describing the
    /// pending recording that's about to be streamed. Returns false
    /// if we're not currently connected.
    @discardableResult
    func sendUploadStart(metadata: PendingUploadMetadata) -> Bool {
        guard connectionState == .connected, let _ = connection else { return false }
        guard let payload = metadata.toWireData() else { return false }

        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .uploadStart,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: metadata.sampleRate,
            channels: metadata.channels,
            payloadLength: UInt32(payload.count)
        )
        sendPacket(header: header, payload: payload)
        return true
    }

    /// Send a single chunk of the pending upload. Typical size is
    /// `AudioStreamingConstants.uploadChunkSize` (128 KB).
    @discardableResult
    func sendUploadChunk(payload: Data) -> Bool {
        guard connectionState == .connected, let _ = connection else { return false }
        guard payload.count <= Int(AudioStreamingConstants.maxPayloadSize) else {
            logger.warning("uploadChunk: payload too large (\(payload.count) bytes)")
            return false
        }

        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .uploadChunk,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(payload.count)
        )
        sendPacket(header: header, payload: payload)
        return true
    }

    /// Tell the Mac that all chunks for the current upload have been sent
    /// and it can begin the reprocess pipeline.
    @discardableResult
    func sendUploadEnd() -> Bool {
        guard connectionState == .connected, let _ = connection else { return false }

        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .uploadEnd,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: 0
        )
        sendPacket(header: header, payload: Data())
        return true
    }

    // MARK: - Session Lifecycle (Phase C)

    /// Tell the Mac the user is done with this session. Mac ensures note
    /// is saved and analysis runs, but does not sign off.
    @discardableResult
    func sendSessionDone(sessionID: UUID) -> Bool {
        guard connectionState == .connected, let _ = connection else { return false }
        let payload = Data(sessionID.uuidString.utf8)
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .sessionDone,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(payload.count)
        )
        sendPacket(header: header, payload: payload)
        return true
    }

    /// Tell the Mac to delete this session entirely.
    @discardableResult
    func sendSessionDeleted(sessionID: UUID) -> Bool {
        guard connectionState == .connected, let _ = connection else { return false }
        let payload = Data(sessionID.uuidString.utf8)
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .sessionDeleted,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(payload.count)
        )
        sendPacket(header: header, payload: payload)
        return true
    }

    // MARK: - Private: Connection

    private func connectToEndpoint(
        _ endpoint: NWEndpoint,
        macDeviceID: UUID,
        macDisplayName: String
    ) {
        // Belt + suspenders: refuse to create a new NWConnection if we
        // already have one on file. The browse handler has a similar guard
        // based on connectionState, but this check catches any other path
        // that might call connectToEndpoint while a connection exists —
        // e.g. a stale attemptReconnection scheduled from before the
        // current connection was established.
        if connection != nil {
            logger.warning("connectToEndpoint: already have an NWConnection; ignoring duplicate create for \(endpoint.debugDescription)")
            return
        }

        connectionState = .connecting
        connectedMacDeviceID = macDeviceID
        connectedMacName = macDisplayName
        authState = .awaitingChallenge

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [self] in
                switch state {
                case .ready:
                    // TCP is up but the Mac still has to challenge us. Start
                    // receiving so we can catch the authChallenge, and arm a
                    // timeout so a silent Mac doesn't leave us hanging.
                    self.logger.info("TCP ready — awaiting auth challenge from \(macDisplayName)")
                    self.startReceiving()
                    self.armAuthTimeout(on: connection, endpoint: endpoint)

                case .failed(let error):
                    self.logger.error("Connection failed: \(error.localizedDescription)")
                    self.connection = nil
                    self.authState = .none
                    self.authTimeoutTask?.cancel()
                    self.authTimeoutTask = nil
                    if self.pendingPin != nil {
                        self.pendingPin = nil
                        self.pinPairingState = .failure(reason: "Couldn't reach the Mac.")
                        self.connectionState = .disconnected
                    } else {
                        self.attemptReconnection(to: endpoint, macDeviceID: macDeviceID, macDisplayName: macDisplayName)
                    }

                case .waiting(let error):
                    self.logger.warning("Connection waiting: \(error.localizedDescription)")

                default:
                    break
                }
            }
        }

        connection.start(queue: networkQueue)
        self.connection = connection
    }

    private func armAuthTimeout(on connection: NWConnection, endpoint: NWEndpoint) {
        authTimeoutTask?.cancel()
        authTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.authHandshakeTimeoutSeconds ?? 15))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.connection === connection else { return }
                if self.authState != .authenticated {
                    self.logger.warning("Auth handshake timed out — disconnecting")
                    if self.pendingPin != nil {
                        self.pendingPin = nil
                        self.pinPairingState = .failure(reason: "Mac didn't answer in time.")
                    } else {
                        self.lastAuthError = "Mac didn't answer the pairing handshake in time."
                    }
                    self.authState = .none
                    connection.cancel()
                    self.connection = nil
                }
            }
        }
    }

    private func attemptReconnection(to endpoint: NWEndpoint, macDeviceID: UUID, macDisplayName: String) {
        // Unbounded reconnection with an exponential backoff capped at ~30s.
        // A user can walk out of WiFi range for an hour, come back, and we
        // keep trying. The previous "give up after 4 attempts" behavior
        // broke that scenario entirely — the iPhone would stop trying after
        // ~30 seconds and never reconnect.
        //
        // Schedule: 2, 4, 8, 16, 30, 30, 30, 30, ...
        let backoffs = AudioStreamingConstants.reconnectionBackoffs  // [2, 4, 8, 16]
        let maxInterval: TimeInterval = 30
        let delay: TimeInterval = reconnectionAttempt < backoffs.count
            ? backoffs[reconnectionAttempt]
            : maxInterval

        reconnectionAttempt += 1
        connectionState = .reconnecting(attempt: reconnectionAttempt)

        logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectionAttempt))")

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard case .reconnecting = self.connectionState else { return }
            self.connectToEndpoint(endpoint, macDeviceID: macDeviceID, macDisplayName: macDisplayName)
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

        connection.send(content: packet, completion: .contentProcessed { [logger] error in
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
        guard let connection else { return }
        receiveBuffer = Data()
        receiveLoop(on: connection)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let content {
                    self.receiveBuffer.append(content)
                    self.processInboundBuffer()
                }

                if let error {
                    self.logger.error("Receive error: \(error.localizedDescription)")
                    return
                }

                if isComplete {
                    self.logger.info("Inbound stream closed")
                    return
                }

                // Continue as long as this is still the active connection
                if self.connection === connection {
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
        // Auth and PIN-pairing messages are always processed first.
        switch header.messageType {
        case .authChallenge:
            handleAuthChallenge(payload: payload)
            return
        case .authResult:
            handleAuthResult(payload: payload)
            return
        case .pinPairingResult:
            handlePinPairingResult(payload: payload)
            return
        default:
            break
        }
        if authState != .authenticated {
            logger.warning("Dropping \(String(describing: header.messageType)) — auth not complete")
            return
        }

        switch header.messageType {
        case .authChallenge, .authResponse, .authResult,
             .pinPairingRequest, .pinPairingResult:
            break  // handled above / outbound-only

        case .summaryPush:
            guard let summary = MeetingSummary.from(wireData: payload) else {
                logger.warning("Failed to decode inbound summary (\(payload.count) bytes)")
                return
            }
            logger.info("Received meeting summary from Mac: \(summary.actionItems.count) action items")
            onMeetingSummary?(summary)

        case .sessionProcessed:
            guard let ack = SessionProcessedAck.from(wireData: payload) else {
                logger.warning("Failed to decode sessionProcessed ack (\(payload.count) bytes)")
                return
            }
            logger.info("Received sessionProcessed ack: \(ack.sessionID) success=\(ack.success)")
            onSessionProcessed?(ack)

        case .settingsSync:
            guard let settings = WorkspaceSettings.from(wireData: payload) else {
                logger.warning("Failed to decode workspace settings (\(payload.count) bytes)")
                return
            }
            settings.cache()
            logger.info("Received workspace settings: calendars=\(settings.calendarNames.joined(separator: ", ")), groups=\(settings.contactGroupNames.joined(separator: ", "))")
            onWorkspaceSettingsReceived?()

        case .heartbeat:
            break // Mac acknowledging liveness

        default:
            // iPhone doesn't expect to receive audio/session packets — ignore.
            break
        }
    }

    // MARK: - Auth Handshake

    private func handleAuthChallenge(payload: Data) {
        guard authState == .awaitingChallenge else {
            logger.warning("authChallenge arrived in state \(String(describing: self.authState)) — ignoring")
            return
        }
        guard let challenge = AuthChallenge.from(wireData: payload) else {
            logger.error("authChallenge: failed to decode payload")
            lastAuthError = "Mac sent a malformed pairing challenge."
            connection?.cancel()
            return
        }
        guard let macDeviceID = connectedMacDeviceID else {
            logger.error("authChallenge arrived but no connectedMacDeviceID")
            return
        }
        let pairing = DevicePairingService.shared

        // Two paths: the user just entered a PIN (no stored token yet) → send
        // pinPairingRequest. Otherwise we must already have a token → compute
        // HMAC and send authResponse.
        if let pin = pendingPin {
            sendPinPairingRequest(pin: pin, pairing: pairing)
            return
        }

        guard let hmac = pairing.computeHMACResponse(for: macDeviceID, challengeB64: challenge.challengeB64) else {
            logger.error("No pairing token for Mac \(macDeviceID) — cannot respond")
            lastAuthError = "This iPhone isn't paired with that Mac anymore."
            connection?.cancel()
            return
        }

        let response = AuthResponse(
            phoneDeviceID: pairing.phoneDeviceID,
            phoneDisplayName: Self.phoneDisplayName(),
            hmacB64: hmac
        )
        guard let body = response.toWireData() else {
            logger.error("authResponse: failed to encode")
            return
        }
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .authResponse,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(body.count)
        )
        var packet = header.serialize()
        packet.append(body)
        connection?.send(content: packet, completion: .contentProcessed { [logger] error in
            if let error {
                logger.error("authResponse send failed: \(error.localizedDescription)")
            }
        })
        authState = .awaitingResult
        logger.info("Sent authResponse — waiting for result")
    }

    private func handleAuthResult(payload: Data) {
        guard let result = AuthResult.from(wireData: payload) else {
            logger.error("authResult: failed to decode")
            lastAuthError = "Mac sent a malformed auth result."
            connection?.cancel()
            return
        }
        authTimeoutTask?.cancel()
        authTimeoutTask = nil

        if result.success {
            authState = .authenticated
            connectionState = .connected
            if let name = result.macDisplayName { connectedMacName = name }
            reconnectionAttempt = 0
            lastAuthError = nil
            logger.info("Auth succeeded — stream is live")
            startHeartbeat()
            flushBufferedChunks()
        } else {
            authState = .none
            lastAuthError = result.reason ?? "Mac rejected this iPhone."
            logger.warning("Auth rejected: \(result.reason ?? "unknown")")
            // Don't automatically reconnect — the user needs to re-pair.
            connection?.cancel()
            connection = nil
            connectionState = .disconnected
            connectedMacDeviceID = nil
        }
    }

    // MARK: - PIN Pairing Handlers

    private func sendPinPairingRequest(pin: String, pairing: DevicePairingService) {
        let request = PinPairingRequest(
            pin: pin,
            phoneDeviceID: pairing.phoneDeviceID,
            phoneDisplayName: Self.phoneDisplayName()
        )
        guard let body = request.toWireData() else {
            logger.error("pinPairingRequest: failed to encode")
            pendingPin = nil
            pinPairingState = .failure(reason: "Couldn't encode PIN request.")
            connection?.cancel()
            return
        }
        let header = AudioPacketHeader(
            version: AudioPacketHeader.currentVersion,
            messageType: .pinPairingRequest,
            sequenceNumber: 0,
            timestamp: 0,
            sampleRate: 0,
            channels: 0,
            payloadLength: UInt32(body.count)
        )
        var packet = header.serialize()
        packet.append(body)
        authState = .sendingPinRequest(pin: pin)
        pinPairingState = .sending
        connection?.send(content: packet, completion: .contentProcessed { [logger] error in
            if let error {
                logger.error("pinPairingRequest send failed: \(error.localizedDescription)")
            } else {
                logger.info("pinPairingRequest sent — awaiting result")
            }
        })
    }

    private func handlePinPairingResult(payload: Data) {
        guard case .sendingPinRequest = authState else {
            logger.warning("pinPairingResult arrived in state \(String(describing: self.authState)) — ignoring")
            return
        }
        guard let result = try? JSONDecoder().decode(PinPairingResult.self, from: payload) else {
            logger.error("pinPairingResult: failed to decode payload")
            pendingPin = nil
            pinPairingState = .failure(reason: "Mac sent a malformed pairing result.")
            connection?.cancel()
            return
        }

        if result.success {
            let macName = result.macDisplayName ?? "Mac"
            Task { @MainActor in
                let record = await DevicePairingService.shared.acceptPinPairingResult(result)
                guard record != nil else {
                    self.logger.error("acceptPinPairingResult failed — aborting")
                    self.pendingPin = nil
                    self.pinPairingState = .failure(reason: "Couldn't save pairing credentials.")
                    self.connection?.cancel()
                    return
                }
                // Token is persisted — mark this connection authenticated.
                self.pendingPin = nil
                self.authTimeoutTask?.cancel()
                self.authTimeoutTask = nil
                self.authState = .authenticated
                self.connectionState = .connected
                self.connectedMacName = macName
                self.reconnectionAttempt = 0
                self.lastAuthError = nil
                self.pinPairingState = .success(macName: macName)
                self.logger.info("PIN pairing succeeded — stream is live")
                self.startHeartbeat()
                self.flushBufferedChunks()
            }
        } else {
            logger.warning("PIN pairing rejected: \(result.reason ?? "unknown")")
            pendingPin = nil
            pinPairingState = .failure(reason: result.reason ?? "Mac rejected the PIN.")
            authState = .none
            connection?.cancel()
            connection = nil
            connectionState = .disconnected
            connectedMacDeviceID = nil
            connectedMacName = nil
        }
    }

    // MARK: - TXT / Identity Helpers

    /// Pull the Mac's device ID + display name out of a Bonjour browse
    /// result's TXT record. Returns nil when the TXT record is missing or
    /// malformed — the TXT may not be resolved on the first browse event,
    /// so callers in PIN-pairing mode should fall back to the endpoint name
    /// and let the PinPairingResult carry the real identity.
    private static func extractMacIdentity(from result: NWBrowser.Result) -> (UUID, String)? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        guard let idString = txt[SAMMacDeviceIDTXTKey], let macID = UUID(uuidString: idString) else {
            return nil
        }
        let name = txt[SAMMacDisplayNameTXTKey] ?? "Mac"
        return (macID, name)
    }

    /// Best-effort human name for a Bonjour endpoint when no TXT record
    /// has been resolved. Strips the service-type suffix so we show
    /// "David's MacBook Pro" rather than the raw mDNS string.
    private static func endpointName(_ endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint {
            let decoded = name.replacingOccurrences(of: "\\032", with: " ")
            return decoded.isEmpty ? "Mac" : decoded
        }
        return "Mac"
    }

    /// User-visible name the Mac will show in its Paired iPhones list.
    /// `UIDevice.current.name` is the obvious choice, but Apple scrubs it
    /// to a generic "iPhone" in production builds on iOS 16+ — so we fall
    /// back through a couple of alternatives before settling for a literal.
    private static func phoneDisplayName() -> String {
        #if canImport(UIKit)
        let uiName = UIDevice.current.name
        if !uiName.isEmpty && uiName != "iPhone" && uiName != "iPad" {
            return uiName
        }
        return UIDevice.current.model   // "iPhone"
        #else
        return "iPhone"
        #endif
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: AudioStreamingConstants.heartbeatIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
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
