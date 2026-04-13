//
//  SAMModels-Transcription.swift
//  SAM
//
//  Speaker-diarized transcription system models.
//  TranscriptSession holds a complete recording session.
//  TranscriptSegment holds one speaker-attributed text span.
//  SpeakerProfile holds enrolled voice embeddings for speaker matching.
//

import SwiftData
import Foundation

// MARK: - TranscriptSessionStatus

public enum TranscriptSessionStatus: String, Codable, Sendable {
    case recording   = "recording"
    case processing  = "processing"
    case completed   = "completed"
    case failed      = "failed"
}

// MARK: - TranscriptSession

/// A complete recording + transcription session, linked to events and people.
@Model
public final class TranscriptSession {
    @Attribute(.unique) public var id: UUID

    /// When the recording started.
    public var recordedAt: Date

    /// Total recording duration in seconds.
    public var durationSeconds: TimeInterval

    /// Number of distinct speakers detected.
    public var speakerCount: Int

    /// Raw storage for TranscriptSessionStatus enum.
    public var statusRawValue: String

    /// Relative path to the audio file (from Application Support).
    public var audioFilePath: String?

    /// WhisperKit model identifier used for transcription.
    public var whisperModelID: String?

    /// ISO 639-1 language code detected by Whisper.
    public var detectedLanguage: String?

    /// JSON-encoded `MeetingSummary` produced by `MeetingSummaryService`.
    /// Populated automatically when a session ends; nil until the summary
    /// finishes generating.
    public var meetingSummaryJSON: String?

    /// When the meeting summary was generated.
    public var summaryGeneratedAt: Date?

    /// Polished, speaker-attributed transcript produced by
    /// `TranscriptPolishService`. Same "Speaker: text" paragraph format as
    /// the raw segments but with proper nouns corrected, window-seam
    /// sentence breaks stitched, and punctuation fixed.
    ///
    /// The raw `segments` remain the source of truth (word timings intact)
    /// so future reprocessing is still possible. `polishedText` is purely
    /// a display/consumption convenience.
    public var polishedText: String?

    /// When the polished transcript was generated.
    public var polishedAt: Date?

    // MARK: - Retention (Phase C)
    //
    // SAM keeps the recording, the raw segments, the polished transcript,
    // the summary, and the linked note for each meeting. That is enough
    // historical context to be useful but is also a privacy liability if
    // it sits forever. The retention fields below let the user explicitly
    // sign off on a meeting (locking the record) and let SAM auto-purge
    // the heavy parts (audio file, raw segments) after a configurable
    // grace window while keeping the lightweight summary + linked note.

    /// When the user explicitly reviewed and signed off on the transcript.
    /// nil while the meeting is still in flight or unreviewed. Once set,
    /// the audio purge timer starts counting from this date.
    public var signedOffAt: Date?

    /// When the audio file was purged from disk. nil while the audio is
    /// still present. Set by `RetentionService` after the configured
    /// grace window. Independent from session deletion — the transcript
    /// and summary can outlive the audio.
    public var audioPurgedAt: Date?

    /// User override: when true, RetentionService will never auto-purge
    /// the audio file for this session. The user can pin a specific
    /// meeting they want to keep listenable indefinitely.
    /// Default = false ensures lightweight SwiftData migration works
    /// against existing on-disk sessions.
    public var pinAudioRetention: Bool = false

    /// Whether the user has manually edited the polished text. When true,
    /// re-polish operations (e.g., from a prompt improvement) won't
    /// overwrite the user's corrections.
    public var polishedEditedByUser: Bool = false

    // MARK: - Relationships

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.session)
    public var segments: [TranscriptSegment]?

    @Relationship(deleteRule: .nullify)
    public var linkedEvent: SamEvent?

    @Relationship(deleteRule: .nullify)
    public var linkedNote: SamNote?

    @Relationship(deleteRule: .nullify)
    public var linkedPeople: [SamPerson]?

    // MARK: - Computed

    @Transient
    public var status: TranscriptSessionStatus {
        get { TranscriptSessionStatus(rawValue: statusRawValue) ?? .recording }
        set { statusRawValue = newValue.rawValue }
    }

    /// Sorted segments by start time.
    @Transient
    public var sortedSegments: [TranscriptSegment] {
        (segments ?? []).sorted { $0.startTime < $1.startTime }
    }

    /// Full transcript as formatted text with speaker labels.
    @Transient
    public var formattedTranscript: String {
        sortedSegments.map { segment in
            "\(segment.speakerLabel): \(segment.text)"
        }.joined(separator: "\n")
    }

    public init(
        id: UUID = UUID(),
        recordedAt: Date = .now,
        durationSeconds: TimeInterval = 0,
        speakerCount: Int = 0,
        status: TranscriptSessionStatus = .recording,
        audioFilePath: String? = nil,
        whisperModelID: String? = nil,
        detectedLanguage: String? = nil,
        meetingSummaryJSON: String? = nil,
        summaryGeneratedAt: Date? = nil,
        polishedText: String? = nil,
        polishedAt: Date? = nil,
        signedOffAt: Date? = nil,
        audioPurgedAt: Date? = nil,
        pinAudioRetention: Bool = false
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.speakerCount = speakerCount
        self.statusRawValue = status.rawValue
        self.audioFilePath = audioFilePath
        self.whisperModelID = whisperModelID
        self.detectedLanguage = detectedLanguage
        self.meetingSummaryJSON = meetingSummaryJSON
        self.summaryGeneratedAt = summaryGeneratedAt
        self.polishedText = polishedText
        self.polishedAt = polishedAt
        self.signedOffAt = signedOffAt
        self.audioPurgedAt = audioPurgedAt
        self.pinAudioRetention = pinAudioRetention
    }
}

// MARK: - TranscriptSegment

/// One speaker-attributed text span within a transcript session.
@Model
public final class TranscriptSegment {
    @Attribute(.unique) public var id: UUID

    /// Display label for the speaker (e.g. "Agent", "Client", "Speaker 2").
    public var speakerLabel: String

    /// Cluster ID assigned by diarization (0-based).
    public var speakerClusterID: Int

    /// Transcribed text for this segment.
    public var text: String

    /// Start time offset from session beginning (seconds).
    public var startTime: TimeInterval

    /// End time offset from session beginning (seconds).
    public var endTime: TimeInterval

    /// Confidence score from speaker identification (0.0–1.0).
    public var speakerConfidence: Float

    /// Sequential index within the session for stable ordering.
    public var segmentIndex: Int

    /// JSON-encoded array of WordTiming for word-level timestamps.
    public var wordTimingsJSON: String?

    // MARK: - Relationships

    @Relationship(deleteRule: .nullify)
    public var session: TranscriptSession?

    /// Identified person for this speaker (if matched).
    @Relationship(deleteRule: .nullify)
    public var speakerPerson: SamPerson?

    // MARK: - Computed

    @Transient
    public var duration: TimeInterval { endTime - startTime }

    public init(
        id: UUID = UUID(),
        speakerLabel: String,
        speakerClusterID: Int,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerConfidence: Float = 0,
        segmentIndex: Int = 0,
        wordTimingsJSON: String? = nil
    ) {
        self.id = id
        self.speakerLabel = speakerLabel
        self.speakerClusterID = speakerClusterID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speakerConfidence = speakerConfidence
        self.segmentIndex = segmentIndex
        self.wordTimingsJSON = wordTimingsJSON
    }
}

// MARK: - MeetingSummary DTO

/// Structured meeting summary produced by `MeetingSummaryService` on the Mac.
///
/// Defined here (in the shared models file) so both the Mac and the iPhone
/// (SAM Field) targets can encode/decode the wire format when summaries are
/// pushed back to the phone over the TCP transcription connection.
///
/// Persisted as a JSON string on `TranscriptSession.meetingSummaryJSON`.
public struct MeetingSummary: Codable, Sendable, Equatable {
    /// 2-3 sentence high-level summary of what the meeting was about.
    public var tldr: String

    /// Key decisions that were made during the meeting.
    public var decisions: [String]

    /// Action items with owner and optional due date.
    public var actionItems: [ActionItem]

    /// Open questions / things that still need answering.
    public var openQuestions: [String]

    /// Follow-ups needed per person (relationship touches, not tasks).
    public var followUps: [FollowUp]

    /// Life events mentioned (births, deaths, marriages, job changes, etc.).
    public var lifeEvents: [String]

    /// Topics the meeting covered, for tagging / search.
    public var topics: [String]

    /// Compliance flags (return claims, guarantees, comparative statements).
    public var complianceFlags: [String]

    /// Overall sentiment / affect of the meeting.
    public var sentiment: String?

    public struct ActionItem: Codable, Sendable, Equatable {
        public var task: String
        public var owner: String?
        public var dueDate: String?

        public init(task: String, owner: String? = nil, dueDate: String? = nil) {
            self.task = task
            self.owner = owner
            self.dueDate = dueDate
        }
    }

    public struct FollowUp: Codable, Sendable, Equatable {
        public var person: String
        public var reason: String

        public init(person: String, reason: String) {
            self.person = person
            self.reason = reason
        }
    }

    public init(
        tldr: String,
        decisions: [String],
        actionItems: [ActionItem],
        openQuestions: [String],
        followUps: [FollowUp],
        lifeEvents: [String],
        topics: [String],
        complianceFlags: [String],
        sentiment: String?
    ) {
        self.tldr = tldr
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.followUps = followUps
        self.lifeEvents = lifeEvents
        self.topics = topics
        self.complianceFlags = complianceFlags
        self.sentiment = sentiment
    }

    public static let empty = MeetingSummary(
        tldr: "",
        decisions: [],
        actionItems: [],
        openQuestions: [],
        followUps: [],
        lifeEvents: [],
        topics: [],
        complianceFlags: [],
        sentiment: nil
    )
}

public extension MeetingSummary {
    /// Encode to a JSON string suitable for storing on `TranscriptSession.meetingSummaryJSON`.
    func toJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// Decode from a stored JSON string.
    static func from(jsonString: String?) -> MeetingSummary? {
        guard let jsonString, !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    /// Compact binary encoding for wire transport.
    func toWireData() -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(self)
    }

    /// Decode from wire bytes.
    static func from(wireData: Data) -> MeetingSummary? {
        try? JSONDecoder().decode(MeetingSummary.self, from: wireData)
    }

    /// Non-empty check for UI gating.
    var hasContent: Bool {
        !tldr.isEmpty
        || !decisions.isEmpty
        || !actionItems.isEmpty
        || !openQuestions.isEmpty
        || !followUps.isEmpty
        || !lifeEvents.isEmpty
        || !topics.isEmpty
    }
}

// MARK: - SpeakerProfile

/// Enrolled voice embedding for speaker identification.
/// The agent's voice is pre-enrolled so SAM can label "Agent" automatically.
@Model
public final class SpeakerProfile {
    @Attribute(.unique) public var id: UUID

    /// Display label (e.g. "Agent", person's name).
    public var label: String

    /// Whether this is the agent (user) voice profile.
    public var isAgent: Bool

    /// ECAPA-TDNN embedding vector stored as raw Data.
    @Attribute(.externalStorage)
    public var embeddingData: Data

    /// Number of audio samples used to build this embedding.
    public var enrollmentSampleCount: Int

    /// When the profile was first created.
    public var enrolledAt: Date

    /// When the profile was last updated (re-enrollment).
    public var updatedAt: Date

    // MARK: - Relationships

    /// The person this voice belongs to (if known).
    @Relationship(deleteRule: .nullify)
    public var person: SamPerson?

    public init(
        id: UUID = UUID(),
        label: String,
        isAgent: Bool = false,
        embeddingData: Data = Data(),
        enrollmentSampleCount: Int = 0,
        enrolledAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.label = label
        self.isAgent = isAgent
        self.embeddingData = embeddingData
        self.enrollmentSampleCount = enrollmentSampleCount
        self.enrolledAt = enrolledAt
        self.updatedAt = updatedAt
    }
}
