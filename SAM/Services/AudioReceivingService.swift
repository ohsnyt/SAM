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

    // MARK: - Outbound Messages (Mac → iPhone)

    /// Serialize a meeting summary as JSON and push it to the connected iPhone.
    /// Silently drops if no iPhone is currently connected.
    func sendMeetingSummary(_ summary: MeetingSummary) {
        guard let connection = activeConnection, let payload = summary.toWireData() else {
            logger.info("sendMeetingSummary: no active connection or empty payload")
            return
        }

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
        // Accept only one connection at a time
        if let existing = activeConnection {
            logger.info("Replacing existing connection")
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
        }
    }

    private func handleSessionStart(header: AudioPacketHeader, payload: Data) {
        let sessionIDString = String(data: payload, encoding: .utf8) ?? UUID().uuidString
        let sessionID = UUID(uuidString: sessionIDString) ?? UUID()

        self.currentSessionID = sessionID
        self.chunksReceived = 0
        self.expectedSequenceNumber = 0
        self.reorderBuffer.removeAll()
        self.sessionSampleRate = header.sampleRate
        self.sessionChannels = header.channels

        // Start WAV file
        startAudioFile(sessionID: sessionID, sampleRate: header.sampleRate, channels: header.channels)

        onSessionStart?(sessionID, header.sampleRate, header.channels)
        logger.info("Session started: \(sessionID.uuidString), \(header.sampleRate)Hz, \(header.channels)ch")
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
