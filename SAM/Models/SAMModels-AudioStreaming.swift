//
//  SAMModels-AudioStreaming.swift
//  SAM
//
//  Shared types for the iPhone → Mac audio streaming protocol.
//  Used by AudioStreamingService (iPhone) and AudioReceivingService (Mac).
//

import Foundation

// MARK: - AudioPacketHeader

/// 32-byte binary header for each TCP message in the audio streaming protocol.
///
/// Wire format:
/// ```
/// Magic(4) | Version(1) | MsgType(1) | SeqNum(8) | Timestamp(8) | SampleRate(4) | Channels(2) | PayloadLen(4)
/// ```
struct AudioPacketHeader: Sendable {
    static let magic: UInt32 = 0x53414D41 // "SAMA"
    static let currentVersion: UInt8 = 1
    static let byteSize = 32

    let version: UInt8
    let messageType: MessageType
    let sequenceNumber: UInt64
    let timestamp: UInt64       // Microseconds since session start
    let sampleRate: UInt32
    let channels: UInt16
    let payloadLength: UInt32

    enum MessageType: UInt8, Sendable {
        case audioData    = 0x01
        case sessionStart = 0x02
        case sessionEnd   = 0x03
        case heartbeat    = 0x04
        /// Mac → iPhone: JSON-encoded `MeetingSummary` payload pushed after
        /// summary generation completes.
        case summaryPush  = 0x05
    }

    /// Serialize to 32 bytes for transmission.
    func serialize() -> Data {
        var data = Data(capacity: Self.byteSize)
        var magic = Self.magic.bigEndian
        var version = self.version
        var msgType = self.messageType.rawValue
        var seqNum = self.sequenceNumber.bigEndian
        var timestamp = self.timestamp.bigEndian
        var sampleRate = self.sampleRate.bigEndian
        var channels = self.channels.bigEndian
        var payloadLen = self.payloadLength.bigEndian

        data.append(Data(bytes: &magic, count: 4))
        data.append(Data(bytes: &version, count: 1))
        data.append(Data(bytes: &msgType, count: 1))
        data.append(Data(bytes: &seqNum, count: 8))
        data.append(Data(bytes: &timestamp, count: 8))
        data.append(Data(bytes: &sampleRate, count: 4))
        data.append(Data(bytes: &channels, count: 2))
        data.append(Data(bytes: &payloadLen, count: 4))

        return data
    }

    /// Deserialize from 32 bytes.
    ///
    /// Uses `loadUnaligned` on a raw pointer base because the header fields
    /// are densely packed and not naturally aligned (UInt64 at offset 6, etc).
    /// Naturally-aligned `load(fromByteOffset:)` would trap on Apple Silicon.
    static func deserialize(from data: Data) -> AudioPacketHeader? {
        guard data.count >= byteSize else { return nil }

        return data.withUnsafeBytes { raw -> AudioPacketHeader? in
            guard let base = raw.baseAddress, raw.count >= byteSize else { return nil }

            let magic = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
            guard magic == Self.magic else { return nil }

            let version = base.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            let msgTypeRaw = base.loadUnaligned(fromByteOffset: 5, as: UInt8.self)
            guard let msgType = MessageType(rawValue: msgTypeRaw) else { return nil }

            let seqNum = base.loadUnaligned(fromByteOffset: 6, as: UInt64.self).bigEndian
            let timestamp = base.loadUnaligned(fromByteOffset: 14, as: UInt64.self).bigEndian
            let sampleRate = base.loadUnaligned(fromByteOffset: 22, as: UInt32.self).bigEndian
            let channels = base.loadUnaligned(fromByteOffset: 26, as: UInt16.self).bigEndian
            let payloadLen = base.loadUnaligned(fromByteOffset: 28, as: UInt32.self).bigEndian

            return AudioPacketHeader(
                version: version,
                messageType: msgType,
                sequenceNumber: seqNum,
                timestamp: timestamp,
                sampleRate: sampleRate,
                channels: channels,
                payloadLength: payloadLen
            )
        }
    }
}

// MARK: - AudioChunk

/// A timestamped chunk of PCM audio data, ready for processing.
struct AudioChunk: Sendable {
    let sequenceNumber: UInt64
    let timestamp: UInt64          // Microseconds since session start
    let sampleRate: UInt32
    let channels: UInt16
    let pcmData: Data              // Raw PCM bytes (Int16 interleaved)
}

extension AudioChunk: Comparable {
    static func < (lhs: AudioChunk, rhs: AudioChunk) -> Bool {
        lhs.sequenceNumber < rhs.sequenceNumber
    }
}

// MARK: - WordTiming

/// Word-level timestamp from WhisperKit transcription.
struct WordTiming: Codable, Sendable {
    let word: String
    let start: TimeInterval        // Seconds from session start
    let end: TimeInterval
    let confidence: Float
}

// MARK: - Streaming Constants

enum AudioStreamingConstants {
    /// Bonjour service type for transcript streaming.
    static let bonjourServiceType = "_samtranscript._tcp"

    /// Bonjour service domain (local network).
    static let bonjourDomain = "local."

    /// Chunk duration in seconds — iPhone accumulates this much audio before sending.
    static let chunkDurationSeconds: TimeInterval = 0.5

    /// Ring buffer duration in seconds — iPhone keeps this much audio on disk for resilience.
    static let ringBufferDurationSeconds: TimeInterval = 60.0

    /// Heartbeat interval in seconds.
    static let heartbeatIntervalSeconds: TimeInterval = 5.0

    /// Reconnection backoff intervals in seconds.
    static let reconnectionBackoffs: [TimeInterval] = [2, 4, 8, 16]

    /// Maximum payload size per packet (256KB — ~2.7s of stereo 48kHz 16-bit audio).
    static let maxPayloadSize: UInt32 = 256 * 1024
}
