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
import FoundationModels

// MARK: - TranscriptSessionStatus

public enum TranscriptSessionStatus: String, Codable, Sendable {
    case recording   = "recording"
    case processing  = "processing"
    case completed   = "completed"
    case failed      = "failed"
}

// MARK: - RecordingContext

/// The purpose of a recording session. Drives summary prompts, output fields,
/// compliance scanning, and people-linking behavior.
public nonisolated enum RecordingContext: String, Codable, Sendable, CaseIterable {
    /// Standard client or team meeting — full pipeline including compliance scanning
    /// and person-linking. Default for calendar-matched meetings.
    case clientMeeting   = "ClientMeeting"
    /// Training session, lecture, or professional development — key points and
    /// learning objectives only; no compliance scan, no person-linking.
    case trainingLecture = "TrainingLecture"
    /// Board or governance meeting — agenda items, votes, and minutes;
    /// no compliance scan; attendee list but no CRM person-linking.
    case boardMeeting    = "BoardMeeting"

    public nonisolated var displayName: String {
        switch self {
        case .clientMeeting:   return "Client / Team Meeting"
        case .trainingLecture: return "Training / Lecture"
        case .boardMeeting:    return "Board Meeting"
        }
    }

    public nonisolated var systemIcon: String {
        switch self {
        case .clientMeeting:   return "person.2"
        case .trainingLecture: return "graduationcap"
        case .boardMeeting:    return "building.columns"
        }
    }

    /// Whether this context requires compliance flag extraction.
    public nonisolated var requiresCompliance: Bool { self == .clientMeeting }

    /// Whether participants should be linked to SamPerson CRM records.
    public nonisolated var supportsPersonLinking: Bool { self != .trainingLecture }
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

    /// A short (2-5 word) editable title for the session, auto-generated as
    /// part of the meeting summary and user-editable from the review UI.
    /// nil on legacy sessions until a summary is (re)generated.
    public var title: String?

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

    /// Raw storage for RecordingContext enum. nil on legacy sessions → defaults to .clientMeeting.
    public var recordingContextRawValue: String?

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

    @Transient
    public var recordingContext: RecordingContext {
        get { RecordingContext(rawValue: recordingContextRawValue ?? "") ?? .clientMeeting }
        set { recordingContextRawValue = newValue.rawValue }
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
        recordingContext: RecordingContext = .clientMeeting,
        audioFilePath: String? = nil,
        whisperModelID: String? = nil,
        detectedLanguage: String? = nil,
        meetingSummaryJSON: String? = nil,
        title: String? = nil,
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
        self.recordingContextRawValue = recordingContext.rawValue
        self.audioFilePath = audioFilePath
        self.whisperModelID = whisperModelID
        self.detectedLanguage = detectedLanguage
        self.meetingSummaryJSON = meetingSummaryJSON
        self.title = title
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
///
/// Conforms to `Generable` so Apple FoundationModels can produce this type
/// directly via constrained decoding — eliminating free-form JSON parse errors.
@Generable
public nonisolated struct MeetingSummary: Codable, Sendable, Equatable {
    @Guide(description: "A concise 2-5 word title capturing the central subject of the meeting or lecture. Title case, no trailing punctuation.")
    public var title: String

    @Guide(description: "Two or three sentence high-level summary of what the meeting was about.")
    public var tldr: String

    // MARK: - Client/Team Meeting fields

    @Guide(description: "Key decisions that were made during the meeting. Empty if none.")
    public var decisions: [String]

    @Guide(description: "Action items with owner and optional due date. Empty if none.")
    public var actionItems: [ActionItem]

    @Guide(description: "Open questions or things that still need answering. Empty if none.")
    public var openQuestions: [String]

    @Guide(description: "Follow-ups needed per person (relationship touches, not tasks). Empty if none.")
    public var followUps: [FollowUp]

    @Guide(description: "Life events mentioned (births, deaths, marriages, job changes, etc.). Empty if none.")
    public var lifeEvents: [String]

    @Guide(description: "Topics the meeting covered, for tagging and search. Empty if none.")
    public var topics: [String]

    @Guide(description: "Compliance flags (return claims, guarantees, comparative statements). Always empty for non-client meetings.")
    public var complianceFlags: [String]

    @Guide(description: "Overall sentiment or affect of the meeting. Nil if not applicable.")
    public var sentiment: String?

    // MARK: - Training/Lecture fields

    @Guide(description: "Major takeaways from the lecture or training session. Empty unless this is a training or lecture.")
    public var keyPoints: [String]

    @Guide(description: "What the lecture or training session was designed to teach. Empty unless this is a training or lecture.")
    public var learningObjectives: [String]

    @Guide(description: "Prose study guide paragraph summarizing key concepts for review. Nil unless this is a training or lecture.")
    public var reviewNotes: String?

    // MARK: - Board Meeting fields

    @Guide(description: "Names of attendees present at the board meeting. Empty unless this is a board meeting.")
    public var attendees: [String]

    @Guide(description: "Formal agenda items discussed with outcomes. Empty unless this is a board meeting.")
    public var agendaItems: [AgendaItem]

    @Guide(description: "Formal votes taken during the meeting. Empty unless this is a board meeting.")
    public var votes: [VoteRecord]

    // MARK: - Nested types

    @Generable
    public struct ActionItem: Codable, Sendable, Equatable {
        @Guide(description: "What needs to be done.")
        public var task: String
        @Guide(description: "Name of the person responsible. Nil if unassigned.")
        public var owner: String?
        @Guide(description: "Due date or timeframe as a short string (e.g. 'Friday', 'end of month'). Nil if none.")
        public var dueDate: String?

        public init(task: String, owner: String? = nil, dueDate: String? = nil) {
            self.task = task
            self.owner = owner
            self.dueDate = dueDate
        }
    }

    @Generable
    public struct FollowUp: Codable, Sendable, Equatable {
        @Guide(description: "Name of the person to follow up with.")
        public var person: String
        @Guide(description: "Short reason for the follow-up.")
        public var reason: String

        public init(person: String, reason: String) {
            self.person = person
            self.reason = reason
        }
    }

    @Generable
    public struct AgendaItem: Codable, Sendable, Equatable {
        @Guide(description: "Short title of the agenda item.")
        public var title: String
        @Guide(description: "One or two sentence description of what was discussed under this agenda item. Nil if not applicable.")
        public var summary: String?
        @Guide(description: "Outcome, e.g. 'Approved', 'Tabled', 'Discussed', 'Deferred'. Nil if not applicable.")
        public var outcome: String?
        @Guide(description: "Additional notes about this agenda item. Nil if none.")
        public var notes: String?

        public init(title: String, summary: String? = nil, outcome: String? = nil, notes: String? = nil) {
            self.title = title
            self.summary = summary
            self.outcome = outcome
            self.notes = notes
        }
    }

    @Generable
    public struct VoteRecord: Codable, Sendable, Equatable {
        @Guide(description: "The motion that was voted on.")
        public var motion: String
        @Guide(description: "Name of the person who moved the motion. Nil if unknown.")
        public var movedBy: String?
        @Guide(description: "Name of the person who seconded the motion. Nil if unknown.")
        public var secondedBy: String?
        @Guide(description: "Result, e.g. 'Passed', 'Failed', 'Tabled', 'No vote taken'.")
        public var result: String
        @Guide(description: "Additional notes about the vote. Nil if none.")
        public var notes: String?

        public init(motion: String, movedBy: String? = nil, secondedBy: String? = nil, result: String, notes: String? = nil) {
            self.motion = motion
            self.movedBy = movedBy
            self.secondedBy = secondedBy
            self.result = result
            self.notes = notes
        }
    }

    // MARK: - Init

    public nonisolated init(
        title: String = "",
        tldr: String,
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = [],
        followUps: [FollowUp] = [],
        lifeEvents: [String] = [],
        topics: [String] = [],
        complianceFlags: [String] = [],
        sentiment: String? = nil,
        keyPoints: [String] = [],
        learningObjectives: [String] = [],
        reviewNotes: String? = nil,
        attendees: [String] = [],
        agendaItems: [AgendaItem] = [],
        votes: [VoteRecord] = []
    ) {
        self.title = title
        self.tldr = tldr
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.followUps = followUps
        self.lifeEvents = lifeEvents
        self.topics = topics
        self.complianceFlags = complianceFlags
        self.sentiment = sentiment
        self.keyPoints = keyPoints
        self.learningObjectives = learningObjectives
        self.reviewNotes = reviewNotes
        self.attendees = attendees
        self.agendaItems = agendaItems
        self.votes = votes
    }

    // MARK: - Codable (custom decoder for backward compatibility)

    private enum CodingKeys: String, CodingKey {
        case title, tldr, decisions, actionItems, openQuestions, followUps
        case lifeEvents, topics, complianceFlags, sentiment
        case keyPoints, learningObjectives, reviewNotes
        case attendees, agendaItems, votes
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title              = try c.decodeIfPresent(String.self,       forKey: .title)              ?? ""
        tldr               = try c.decodeIfPresent(String.self,       forKey: .tldr)               ?? ""
        decisions          = try c.decodeIfPresent([String].self,      forKey: .decisions)          ?? []
        actionItems        = try c.decodeIfPresent([ActionItem].self,  forKey: .actionItems)        ?? []
        openQuestions      = try c.decodeIfPresent([String].self,      forKey: .openQuestions)      ?? []
        followUps          = try c.decodeIfPresent([FollowUp].self,    forKey: .followUps)          ?? []
        lifeEvents         = try c.decodeIfPresent([String].self,      forKey: .lifeEvents)         ?? []
        topics             = try c.decodeIfPresent([String].self,      forKey: .topics)             ?? []
        complianceFlags    = try c.decodeIfPresent([String].self,      forKey: .complianceFlags)    ?? []
        sentiment          = try c.decodeIfPresent(String.self,        forKey: .sentiment)
        keyPoints          = try c.decodeIfPresent([String].self,      forKey: .keyPoints)          ?? []
        learningObjectives = try c.decodeIfPresent([String].self,      forKey: .learningObjectives) ?? []
        reviewNotes        = try c.decodeIfPresent(String.self,        forKey: .reviewNotes)
        attendees          = try c.decodeIfPresent([String].self,      forKey: .attendees)          ?? []
        agendaItems        = try c.decodeIfPresent([AgendaItem].self,  forKey: .agendaItems)        ?? []
        votes              = try c.decodeIfPresent([VoteRecord].self,  forKey: .votes)              ?? []
    }

    public nonisolated static let empty = MeetingSummary(tldr: "")
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
        || !keyPoints.isEmpty
        || !learningObjectives.isEmpty
        || !(reviewNotes?.isEmpty ?? true)
        || !attendees.isEmpty
        || !agendaItems.isEmpty
        || !votes.isEmpty
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
