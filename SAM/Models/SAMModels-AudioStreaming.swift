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

        // MARK: - Phase B: Pending upload / reprocess

        /// iPhone → Mac: the iPhone has a recording that was captured
        /// offline (or degraded from streaming) and wants the Mac to
        /// transcribe it. Payload is JSON metadata:
        /// `{ "sessionID": "...", "recordedAt": "...", "durationSeconds": N,
        ///   "sampleRate": N, "channels": N, "byteSize": N }`
        case uploadStart  = 0x06

        /// iPhone → Mac: a chunk of raw WAV bytes belonging to the
        /// currently-active upload. `sequenceNumber` in the header is the
        /// chunk index, `payloadLength` is the byte count.
        case uploadChunk  = 0x07

        /// iPhone → Mac: all chunks for the active upload have been sent,
        /// Mac can now run the full reprocess pipeline. Empty payload.
        case uploadEnd    = 0x08

        /// Mac → iPhone: a previously-uploaded session has been fully
        /// processed (transcribed, diarized, polished, summarized). The
        /// iPhone can safely delete its local WAV. Payload is JSON:
        /// `{ "sessionID": "...", "success": true, "reason": "..." }`
        case sessionProcessed = 0x09

        // MARK: - Phase C: Session lifecycle (iPhone → Mac)

        /// iPhone → Mac: user is done with this meeting. Mac should ensure
        /// note is saved and analysis is running, but does NOT sign off
        /// (no retention timer). Session stays available for review on Mac.
        /// Payload: session UUID string.
        case sessionDone    = 0x0A

        /// iPhone → Mac: user wants to delete this session entirely.
        /// Mac removes audio file, transcript, linked note, evidence.
        /// Payload: session UUID string.
        case sessionDeleted = 0x0B

        // MARK: - Phase D: Settings sync (Mac → iPhone)

        /// Mac → iPhone: push SAM's workspace settings (calendar IDs,
        /// contact group IDs) so the phone knows which calendars and
        /// groups to use. Sent once on connection. Payload: JSON
        /// `WorkspaceSettings`.
        case settingsSync   = 0x0C

        // MARK: - Phase E: Device pairing / auth (both directions)

        /// Mac → iPhone: challenge nonce (16 random bytes, base64 in JSON
        /// `AuthChallenge`). Sent immediately on TCP accept when the Mac is
        /// NOT in pairing mode. Phone must respond with `authResponse` or
        /// the connection is dropped.
        case authChallenge  = 0x0D

        /// iPhone → Mac: HMAC-SHA256 response keyed with the shared pairing
        /// token, carrying the phone's persistent device ID and display name
        /// so the Mac can update / whitelist it. Payload: JSON `AuthResponse`.
        case authResponse   = 0x0E

        /// Mac → iPhone: terminal auth result. On success, normal traffic
        /// resumes (settings sync, session messages). On failure the Mac
        /// closes the connection. Payload: JSON `AuthResult`.
        case authResult     = 0x0F

        // MARK: - Phase E2: PIN-based pairing

        /// iPhone → Mac: the user typed the 6-digit PIN shown on the Mac's
        /// pairing sheet and tapped Pair. Carries the PIN plus the phone's
        /// persistent identity. Replaces `authResponse` on a fresh (unpaired)
        /// connection — the Mac verifies the PIN, registers the phone in its
        /// trust list, and returns the HMAC token via `pinPairingResult`.
        /// Payload: JSON `PinPairingRequest`.
        case pinPairingRequest = 0x10

        /// Mac → iPhone: outcome of a PIN pairing attempt. On success,
        /// carries the 32-byte HMAC token (base64) so the phone can answer
        /// future `authChallenge`s. On failure the connection is closed.
        /// Payload: JSON `PinPairingResult`.
        case pinPairingResult  = 0x11
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

    /// Chunk size for pending WAV uploads. Smaller chunks keep per-packet
    /// latency low and let us show reasonable progress; 128 KB gives good
    /// throughput on local WiFi without hitting the maxPayloadSize ceiling.
    static let uploadChunkSize: Int = 128 * 1024
}

// MARK: - Workspace Settings (Mac → iPhone)

/// SAM's workspace configuration pushed to the phone on connection.
/// The phone caches this in UserDefaults so it works offline.
public struct WorkspaceSettings: Codable, Sendable {
    /// Calendar identifier(s) SAM monitors for events.
    public var calendarIdentifiers: [String]
    /// Calendar display name(s) — for UI display and fallback matching.
    public var calendarNames: [String]
    /// Contact group identifier(s) SAM uses.
    public var contactGroupIdentifiers: [String]
    /// Contact group display name(s).
    public var contactGroupNames: [String]
    /// User's practice type (e.g., "WFG Financial Advisor", "General").
    public var practiceType: String

    public init(
        calendarIdentifiers: [String] = [],
        calendarNames: [String] = [],
        contactGroupIdentifiers: [String] = [],
        contactGroupNames: [String] = [],
        practiceType: String = "General"
    ) {
        self.calendarIdentifiers = calendarIdentifiers
        self.calendarNames = calendarNames
        self.contactGroupIdentifiers = contactGroupIdentifiers
        self.contactGroupNames = contactGroupNames
        self.practiceType = practiceType
    }

    public func toWireData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func from(wireData: Data) -> WorkspaceSettings? {
        try? JSONDecoder().decode(WorkspaceSettings.self, from: wireData)
    }

    /// Cache key for UserDefaults persistence on the phone.
    public static let cacheKey = "sam.cachedWorkspaceSettings"

    /// Save to UserDefaults.
    public func cache() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    /// Load from UserDefaults cache.
    public static func loadCached() -> WorkspaceSettings? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSettings.self, from: data)
    }
}

// MARK: - Session Start Metadata

/// JSON payload sent with `sessionStart` — carries speaker metadata
/// for diarization. Backwards compatible: if the payload is just a
/// UUID string (old format), the Mac creates a default metadata with
/// no speaker info.
public struct SessionStartMetadata: Codable, Sendable {
    public var sessionID: String
    /// Expected number of speakers (nil = auto-detect).
    public var expectedSpeakerCount: Int?
    /// Expected speaker names (e.g., ["Sarah", "John", "David"]).
    /// First entry is typically the agent/user.
    public var speakerNames: [String]
    /// Recording context selected by the user before starting.
    /// nil on legacy clients → defaults to .clientMeeting on the Mac.
    public var recordingContext: RecordingContext?
    /// EventKit `eventIdentifier` for the calendar event this recording is for.
    /// Populated when Sarah taps "Record this meeting" from the upcoming-events list.
    /// The Mac uses this to link the finished TranscriptSession to the matching
    /// SamEvidenceItem so the post-meeting capture flow can offer the transcript
    /// summary instead of asking her to type notes. nil for impromptu recordings.
    public var calendarEventID: String?

    public init(
        sessionID: String,
        expectedSpeakerCount: Int? = nil,
        speakerNames: [String] = [],
        recordingContext: RecordingContext? = nil,
        calendarEventID: String? = nil
    ) {
        self.sessionID = sessionID
        self.expectedSpeakerCount = expectedSpeakerCount
        self.speakerNames = speakerNames
        self.recordingContext = recordingContext
        self.calendarEventID = calendarEventID
    }

    public func toWireData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Parse from wire data. Falls back to treating the payload as a
    /// plain UUID string for backwards compatibility with older clients.
    public static func from(wireData: Data) -> SessionStartMetadata? {
        // Try JSON first (new format)
        if let decoded = try? JSONDecoder().decode(SessionStartMetadata.self, from: wireData) {
            return decoded
        }
        // Fall back to plain UUID string (old format)
        if let uuidString = String(data: wireData, encoding: .utf8) {
            return SessionStartMetadata(sessionID: uuidString)
        }
        return nil
    }
}

// MARK: - Upload Metadata

/// JSON payload sent with `uploadStart` — identifies the recording and
/// tells the Mac how to reconstruct the WAV.
public struct PendingUploadMetadata: Codable, Sendable {
    public var sessionID: String
    public var recordedAt: Date
    public var durationSeconds: Double
    public var sampleRate: UInt32
    public var channels: UInt16
    public var byteSize: Int64
    /// Recording context selected before the session. nil on legacy uploads → .clientMeeting.
    public var recordingContext: RecordingContext?
    /// EventKit `eventIdentifier` for the calendar event this recording covers.
    /// Mirrors `SessionStartMetadata.calendarEventID` for offline uploads where
    /// the session-start handshake may not have landed (e.g., recording done off-network).
    public var calendarEventID: String?

    public init(
        sessionID: String,
        recordedAt: Date,
        durationSeconds: Double,
        sampleRate: UInt32,
        channels: UInt16,
        byteSize: Int64,
        recordingContext: RecordingContext? = nil,
        calendarEventID: String? = nil
    ) {
        self.sessionID = sessionID
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channels = channels
        self.byteSize = byteSize
        self.recordingContext = recordingContext
        self.calendarEventID = calendarEventID
    }

    public func toWireData() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    public static func from(wireData: Data) -> PendingUploadMetadata? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingUploadMetadata.self, from: wireData)
    }
}

// MARK: - Session Processed Ack

/// JSON payload sent with `sessionProcessed` — tells the iPhone whether
/// its upload was successfully transcribed.
public struct SessionProcessedAck: Codable, Sendable {
    public var sessionID: String
    public var success: Bool
    public var reason: String?

    public init(sessionID: String, success: Bool, reason: String? = nil) {
        self.sessionID = sessionID
        self.success = success
        self.reason = reason
    }

    public func toWireData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func from(wireData: Data) -> SessionProcessedAck? {
        try? JSONDecoder().decode(SessionProcessedAck.self, from: wireData)
    }
}

// MARK: - Device Pairing

/// Bonjour TXT record key under which the Mac advertises its persistent device UUID.
/// The iPhone uses this to filter discovered services to the Mac it was paired with.
public let SAMMacDeviceIDTXTKey = "devid"

/// Bonjour TXT record key for the Mac's human-readable display name (optional).
public let SAMMacDisplayNameTXTKey = "name"

// MARK: - PIN Pairing Messages

/// iPhone → Mac: the user typed the 6-digit PIN shown on the Mac's pairing
/// sheet and tapped Pair. Mac verifies the PIN, registers the phone, and
/// returns the HMAC token via `PinPairingResult`.
public struct PinPairingRequest: Codable, Sendable {
    public var pin: String
    public var phoneDeviceID: UUID
    public var phoneDisplayName: String

    public init(pin: String, phoneDeviceID: UUID, phoneDisplayName: String) {
        self.pin = pin
        self.phoneDeviceID = phoneDeviceID
        self.phoneDisplayName = phoneDisplayName
    }

    public func toWireData() -> Data? { try? JSONEncoder().encode(self) }
    public static func from(wireData: Data) -> PinPairingRequest? {
        try? JSONDecoder().decode(PinPairingRequest.self, from: wireData)
    }
}

/// Mac → iPhone: outcome of a PIN pairing attempt. On success, `tokenB64`,
/// `macDeviceID` and `macDisplayName` are populated and the phone persists
/// them as a trusted Mac. On failure `reason` explains why.
public struct PinPairingResult: Codable, Sendable {
    public var success: Bool
    public var reason: String?
    public var tokenB64: String?
    public var macDeviceID: UUID?
    public var macDisplayName: String?

    public init(
        success: Bool,
        reason: String? = nil,
        tokenB64: String? = nil,
        macDeviceID: UUID? = nil,
        macDisplayName: String? = nil
    ) {
        self.success = success
        self.reason = reason
        self.tokenB64 = tokenB64
        self.macDeviceID = macDeviceID
        self.macDisplayName = macDisplayName
    }

    public func toWireData() -> Data? { try? JSONEncoder().encode(self) }
    public static func from(wireData: Data) -> PinPairingResult? {
        try? JSONDecoder().decode(PinPairingResult.self, from: wireData)
    }
}

// MARK: - Auth Messages

/// Auth protocol — sent as the payload of the corresponding `MessageType`.
///
/// Challenge-response flow:
/// 1. TCP `.ready` → Mac sends `authChallenge` (16 bytes of fresh random base64).
/// 2. Phone computes `HMAC-SHA256(pairingToken, "SAM-AUTH-v1|" + phoneDeviceID + "|" + challengeB64)`
///    and sends `authResponse`.
/// 3. Mac verifies; sends `authResult`. On failure the connection is closed.
public struct AuthChallenge: Codable, Sendable {
    public static let hmacContext = "SAM-AUTH-v1"

    public var challengeB64: String

    public init(challengeB64: String) {
        self.challengeB64 = challengeB64
    }

    public func toWireData() -> Data? { try? JSONEncoder().encode(self) }
    public static func from(wireData: Data) -> AuthChallenge? {
        try? JSONDecoder().decode(AuthChallenge.self, from: wireData)
    }
}

public struct AuthResponse: Codable, Sendable {
    public var phoneDeviceID: UUID
    public var phoneDisplayName: String
    public var hmacB64: String

    public init(phoneDeviceID: UUID, phoneDisplayName: String, hmacB64: String) {
        self.phoneDeviceID = phoneDeviceID
        self.phoneDisplayName = phoneDisplayName
        self.hmacB64 = hmacB64
    }

    public func toWireData() -> Data? { try? JSONEncoder().encode(self) }
    public static func from(wireData: Data) -> AuthResponse? {
        try? JSONDecoder().decode(AuthResponse.self, from: wireData)
    }
}

public struct AuthResult: Codable, Sendable {
    public var success: Bool
    public var reason: String?
    /// Optional human-readable Mac name passed back so the phone can show it in UI.
    public var macDisplayName: String?

    public init(success: Bool, reason: String? = nil, macDisplayName: String? = nil) {
        self.success = success
        self.reason = reason
        self.macDisplayName = macDisplayName
    }

    public func toWireData() -> Data? { try? JSONEncoder().encode(self) }
    public static func from(wireData: Data) -> AuthResult? {
        try? JSONDecoder().decode(AuthResult.self, from: wireData)
    }
}
