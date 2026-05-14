//
//  PostMeetingCaptureCoordinator.swift
//  SAM
//
//  Phase 2 of the sheet-tear-down work loss fix.
//
//  Owns the editable state for one post-meeting capture session. The
//  view is now a thin renderer over this coordinator; every field that
//  used to be `@State` on `PostMeetingCaptureView` lives here instead.
//  This buys us three things:
//
//    1. **Sheet-flip recovery** — when ModalCoordinator displaces the
//       sheet, the view unmounts but the coordinator outlives it. On
//       re-presentation the same coordinator instance is reused and the
//       form re-appears exactly as Sarah left it. No I/O required.
//
//    2. **Crash / quit recovery** — every state change triggers a
//       debounced flush through `DraftBackedFormCoordinator`. A SwiftData
//       `FormDraft` row tracks the latest payload. On a fresh launch the
//       Today restore banner (Phase 4) lists any unfinished captures.
//
//    3. **Submit-failure protection** — `submit(...)` only clears the
//       draft after the underlying save succeeds. A failed save re-flushes
//       and leaves the draft intact so Sarah can retry.
//
//  Identity: the subject of a capture is the meeting itself. We key on
//  `payload.evidenceID` when present (calendar-driven captures) and fall
//  back to a deterministic UUID derived from
//  `eventTitle|eventDate.timeIntervalSinceReferenceDate` for impromptu
//  captures. This means the same logical meeting always resolves to the
//  same coordinator and the same draft, even across multiple notification
//  posts.
//
//  Defensive restore: stored UUIDs in `attendancePresent` may point at
//  attendees no longer attached to the meeting (someone was removed
//  between save and restore). The restore path filters out anything that
//  isn't in the current payload's attendee list, so we never render a
//  checkmark next to a person who isn't shown.
//

import Foundation
import SwiftUI
import CryptoKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PostMeetingCaptureCoordinator")

@MainActor
@Observable
final class PostMeetingCaptureCoordinator: DraftBackedFormCoordinator {

    // MARK: - DraftBackedFormCoordinator conformance

    typealias Payload = StoredPayload

    let formKind: FormKind = .postMeetingCapture
    let subjectID: UUID
    var payloadVersion: Int { 1 }
    let draftFlushScheduler = DraftFlushScheduler()

    /// Timestamp of the most recent edit, used by `isUserActive`.
    /// `nil` means no edits since the coordinator was built. Updated by
    /// `markUserEdit()` from every property's didSet observer.
    private(set) var lastEditAt: Date?

    /// How long after the last edit we still consider Sarah "actively
    /// working" for soft-displacement purposes. After this window
    /// elapses, the coordinator no longer blocks autonomous sheets from
    /// taking the slot — the draft remains on disk, so when she returns
    /// her work is still safe; it just may have a coaching sheet on top.
    private let idleWindow: TimeInterval = 15 * 60  // 15 minutes

    /// When true, the `didSet` observers on editable properties skip
    /// `markUserEdit()`. Used during init seeding and draft restore so
    /// programmatic state changes don't masquerade as user activity for
    /// the soft-displacement guard.
    private var suppressEditTracking: Bool = false

    // MARK: - Identity helper

    /// Resolves a stable subject UUID for a payload. Used by the
    /// presenting view to look up or create a coordinator.
    static func resolveSubjectID(for payload: CapturePayload) -> UUID {
        if let evidenceID = payload.evidenceID { return evidenceID }
        let basis = "\(payload.eventTitle)|\(payload.eventDate.timeIntervalSinceReferenceDate)"
        let digest = SHA256.hash(data: Data(basis.utf8))
        var bytes = Array(digest).prefix(16).map { $0 }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Static context (mirrors the payload, not user-editable)

    /// The most recent `CapturePayload` seen for this subject. Updated
    /// every time the sheet re-presents so attendees/talking points stay
    /// current; the editable fields below are NOT reset by this update.
    private(set) var payload: CapturePayload

    // MARK: - Mode

    enum CaptureMode: String, CaseIterable, Codable {
        case guided = "Guided"
        case freeform = "Freeform"
    }

    var mode: CaptureMode = .guided { didSet { markUserEdit() } }

    // MARK: - Guided state

    var guidedStep: Int = 0 { didSet { markUserEdit() } }
    var attendancePresent: Set<UUID> = [] { didSet { markUserEdit() } }
    var extraAttendeeNames: [String] = [] { didSet { markUserEdit() } }
    var callAnswered: Bool = true { didSet { markUserEdit() } }
    var occurrenceDecision: OccurrenceDecision = .happened { didSet { markUserEdit() } }
    var mainOutcomeText: String = "" { didSet { markUserEdit() } }
    var talkingPointResponses: [String: String] = [:] { didSet { markUserEdit() } }
    var actionItemResponses: [String: String] = [:] { didSet { markUserEdit() } }
    var guidedActionItemsText: String = "" { didSet { markUserEdit() } }
    var guidedFollowUpText: String = "" { didSet { markUserEdit() } }
    var guidedLifeEventsText: String = "" { didSet { markUserEdit() } }
    var voicemailNoteText: String = "" { didSet { markUserEdit() } }

    // MARK: - Freeform state

    var discussionText: String = "" { didSet { markUserEdit() } }
    var actionItemEntries: [ActionItemEntry] = [ActionItemEntry()] { didSet { markUserEdit() } }
    var followUpText: String = "" { didSet { markUserEdit() } }
    var lifeEventsText: String = "" { didSet { markUserEdit() } }

    // MARK: - Transient UI state (not persisted)

    /// True while a save is in flight. Not part of the persisted payload —
    /// a draft restored on launch should never come back stuck in
    /// "saving" state.
    var isSaving: Bool = false

    /// Error text from the last failed save. Cleared on next attempt.
    var errorMessage: String?

    // MARK: - Types

    enum OccurrenceDecision: String, CaseIterable, Identifiable, Hashable, Codable {
        case happened, rescheduled, cancelled, didNotHappen
        var id: String { rawValue }

        var label: String {
            switch self {
            case .happened:     return "Yes, it happened"
            case .rescheduled:  return "Rescheduled"
            case .cancelled:    return "Cancelled"
            case .didNotHappen: return "Didn't happen"
            }
        }

        var evidenceStatus: EvidenceReviewStatus {
            switch self {
            case .happened:     return .confirmed
            case .rescheduled:  return .rescheduled
            case .cancelled:    return .cancelled
            case .didNotHappen: return .didNotHappen
            }
        }

        var primaryButtonLabel: String {
            switch self {
            case .happened:     return "Save"
            case .rescheduled:  return "Mark rescheduled"
            case .cancelled:    return "Mark cancelled"
            case .didNotHappen: return "Mark no-show"
            }
        }
    }

    struct ActionItemEntry: Identifiable, Codable {
        var id: UUID = UUID()
        var description: String = ""
    }

    /// Codable mirror of `CapturePayload`. The form has been reconstructed
    /// from a draft enough times now that we need the immutable meeting
    /// metadata (title, date, attendees, talking points, open action
    /// items) to live alongside the user's typed responses — otherwise
    /// the Resume button on the Today restore banner can't rebuild a
    /// payload to re-present the sheet. Snapshot is taken on every save
    /// from `coordinator.payload`.
    struct CapturePayloadSnapshot: Codable {
        var captureKindRaw: String   // "meeting" or "call:<source>"
        var eventTitle: String
        var eventDate: Date
        var attendees: [AttendeeSnapshot]
        var talkingPoints: [String]
        var openActionItems: [String]
        var evidenceID: UUID?
        var unknownAttendeeNames: [String]
        var isQueueWalk: Bool

        struct AttendeeSnapshot: Codable {
            var personID: UUID
            var displayName: String
            var roleBadges: [String]
            var pendingActionItems: [String]
            var recentLifeEvents: [String]
        }

        /// Rehydrate a `CapturePayload` from the snapshot. Used by the
        /// Today restore banner's Resume action.
        func toCapturePayload() -> CapturePayload {
            let kind: CapturePayload.CaptureKind
            if captureKindRaw == "meeting" {
                kind = .meeting
            } else if captureKindRaw.hasPrefix("call:") {
                kind = .call(source: String(captureKindRaw.dropFirst("call:".count)))
            } else {
                kind = .meeting
            }
            var payload = CapturePayload(
                captureKind: kind,
                eventTitle: eventTitle,
                eventDate: eventDate,
                attendees: attendees.map {
                    CaptureAttendeeInfo(
                        personID: $0.personID,
                        displayName: $0.displayName,
                        roleBadges: $0.roleBadges,
                        pendingActionItems: $0.pendingActionItems,
                        recentLifeEvents: $0.recentLifeEvents
                    )
                },
                talkingPoints: talkingPoints,
                openActionItems: openActionItems,
                evidenceID: evidenceID
            )
            payload.unknownAttendeeNames = unknownAttendeeNames
            payload.isQueueWalk = isQueueWalk
            return payload
        }

        init(from payload: CapturePayload) {
            switch payload.captureKind {
            case .meeting: captureKindRaw = "meeting"
            case .call(let source): captureKindRaw = "call:\(source)"
            }
            eventTitle = payload.eventTitle
            eventDate = payload.eventDate
            attendees = payload.attendees.map {
                AttendeeSnapshot(
                    personID: $0.personID,
                    displayName: $0.displayName,
                    roleBadges: $0.roleBadges,
                    pendingActionItems: $0.pendingActionItems,
                    recentLifeEvents: $0.recentLifeEvents
                )
            }
            talkingPoints = payload.talkingPoints
            openActionItems = payload.openActionItems
            evidenceID = payload.evidenceID
            unknownAttendeeNames = payload.unknownAttendeeNames
            isQueueWalk = payload.isQueueWalk
        }
    }

    // MARK: - Init

    /// Build a coordinator for a payload. Initial state is seeded from
    /// the payload (pre-check attendees, copy unknown attendee names).
    /// Then `restoreFromDraft()` overrides any seeded state with the
    /// stored draft if one exists.
    init(payload: CapturePayload) {
        self.payload = payload
        self.subjectID = Self.resolveSubjectID(for: payload)
        // Programmatic state setup during init should NOT look like user
        // activity. Suppress edit tracking around the whole boot dance;
        // after we re-enable it, `lastEditAt` is still nil, so the soft-
        // displacement guard correctly reports "no recent user edits."
        suppressEditTracking = true
        seedFromPayload(payload)
        restoreFromDraft()
        sanitizeAgainstPayload(payload)
        suppressEditTracking = false
    }

    /// Refresh the static context when the same coordinator is reused
    /// for a re-presentation (e.g., the meeting got new attendees on a
    /// later notification). Editable user fields are preserved; only the
    /// dangling-reference filter runs.
    func updatePayload(_ newPayload: CapturePayload) {
        self.payload = newPayload
        sanitizeAgainstPayload(newPayload)
    }

    private func seedFromPayload(_ payload: CapturePayload) {
        attendancePresent = Set(payload.attendees.map(\.personID))
        if !payload.unknownAttendeeNames.isEmpty {
            extraAttendeeNames = payload.unknownAttendeeNames
        }
    }

    /// Drop UUIDs and dictionary keys that no longer match the current
    /// payload. Called after restore and on payload refresh. Does not
    /// reschedule a flush — the filtered values are equivalent to what
    /// the user already has on screen.
    private func sanitizeAgainstPayload(_ payload: CapturePayload) {
        let validIDs = Set(payload.attendees.map(\.personID))
        let filtered = attendancePresent.intersection(validIDs)
        if filtered != attendancePresent {
            // Avoid triggering didSet's flush — direct backing-store
            // mutations aren't exposed, so we accept one extra flush
            // for correctness over cleverness.
            attendancePresent = filtered
        }
        // Talking point and action item responses use the string itself as
        // the key. If the meeting renames a talking point, the old key
        // becomes orphaned but is harmless — nothing renders it and
        // composeGuidedContent only iterates current payload entries.
    }

    // MARK: - Edit tracking

    /// Called from every editable property's didSet. Stamps `lastEditAt`
    /// (used by the idle-decay check) and schedules a debounced flush
    /// to disk. Bundled into one call so each field's didSet stays a
    /// single line.
    private func markUserEdit() {
        guard !suppressEditTracking else { return }
        lastEditAt = .now
        scheduleDraftFlush()
    }

    // MARK: - Banner display

    /// Title for the Today restore banner: "Coffee with Bob".
    var draftDisplayTitle: String? { payload.eventTitle }

    /// Subtitle for the Today restore banner: "Tue, Mar 5 at 3:00 PM".
    var draftDisplaySubtitle: String? {
        payload.eventDate.formatted(date: .abbreviated, time: .shortened)
    }

    /// True while the user has typed real content **and** has touched
    /// the form within the idle window. Outside that window, autonomous
    /// sheets are again allowed to take the slot; the on-disk draft
    /// keeps the work safe so the only consequence of displacement-
    /// after-idle is finding another sheet on top when she returns.
    var hasUserContentForDisplacement: Bool {
        guard hasUserContent else { return false }
        guard let lastEditAt else { return false }
        return Date.now.timeIntervalSince(lastEditAt) < idleWindow
    }

    // MARK: - DraftBackedFormCoordinator hooks

    /// Anything the user has typed or chosen counts. Used by Phase 3 to
    /// downgrade `.replaceLowerPriority` to `.queue` when this sheet is
    /// active.
    var hasUserContent: Bool {
        if mode == .guided {
            if !payload.captureKind.isMeeting && !callAnswered { return true }
            if !mainOutcomeText.trimmedNonEmpty &&
                !guidedActionItemsText.trimmedNonEmpty &&
                !guidedFollowUpText.trimmedNonEmpty &&
                !guidedLifeEventsText.trimmedNonEmpty &&
                !voicemailNoteText.trimmedNonEmpty &&
                !talkingPointResponses.values.contains(where: { $0.trimmedNonEmpty }) &&
                !actionItemResponses.values.contains(where: { $0.trimmedNonEmpty }) {
                return false
            }
            return true
        }
        return discussionText.trimmedNonEmpty
            || actionItemEntries.contains(where: { $0.description.trimmedNonEmpty })
            || followUpText.trimmedNonEmpty
            || lifeEventsText.trimmedNonEmpty
    }

    func capturePayload() -> StoredPayload {
        StoredPayload(
            mode: mode,
            guidedStep: guidedStep,
            attendancePresent: Array(attendancePresent),
            extraAttendeeNames: extraAttendeeNames,
            callAnswered: callAnswered,
            occurrenceDecision: occurrenceDecision,
            mainOutcomeText: mainOutcomeText,
            talkingPointResponses: talkingPointResponses,
            actionItemResponses: actionItemResponses,
            guidedActionItemsText: guidedActionItemsText,
            guidedFollowUpText: guidedFollowUpText,
            guidedLifeEventsText: guidedLifeEventsText,
            voicemailNoteText: voicemailNoteText,
            discussionText: discussionText,
            actionItemEntries: actionItemEntries,
            followUpText: followUpText,
            lifeEventsText: lifeEventsText,
            payloadSnapshot: CapturePayloadSnapshot(from: payload)
        )
    }

    func applyPayload(_ payload: StoredPayload) {
        mode = payload.mode
        guidedStep = payload.guidedStep
        attendancePresent = Set(payload.attendancePresent)
        extraAttendeeNames = payload.extraAttendeeNames
        callAnswered = payload.callAnswered
        occurrenceDecision = payload.occurrenceDecision
        mainOutcomeText = payload.mainOutcomeText
        talkingPointResponses = payload.talkingPointResponses
        actionItemResponses = payload.actionItemResponses
        guidedActionItemsText = payload.guidedActionItemsText
        guidedFollowUpText = payload.guidedFollowUpText
        guidedLifeEventsText = payload.guidedLifeEventsText
        voicemailNoteText = payload.voicemailNoteText
        discussionText = payload.discussionText
        actionItemEntries = payload.actionItemEntries.isEmpty
            ? [ActionItemEntry()]
            : payload.actionItemEntries
        followUpText = payload.followUpText
        lifeEventsText = payload.lifeEventsText
    }

    // MARK: - Stored payload

    /// Snapshot of every editable field. Decode tolerance: every field is
    /// optional / has a default so older drafts continue to decode after
    /// new fields are added. Bump `payloadVersion` on shape changes.
    struct StoredPayload: Codable {
        var mode: CaptureMode = .guided
        var guidedStep: Int = 0
        var attendancePresent: [UUID] = []
        var extraAttendeeNames: [String] = []
        var callAnswered: Bool = true
        var occurrenceDecision: OccurrenceDecision = .happened
        var mainOutcomeText: String = ""
        var talkingPointResponses: [String: String] = [:]
        var actionItemResponses: [String: String] = [:]
        var guidedActionItemsText: String = ""
        var guidedFollowUpText: String = ""
        var guidedLifeEventsText: String = ""
        var voicemailNoteText: String = ""
        var discussionText: String = ""
        var actionItemEntries: [ActionItemEntry] = []
        var followUpText: String = ""
        var lifeEventsText: String = ""
        /// Frozen copy of the immutable meeting metadata (title, date,
        /// attendees, talking points, action items). Lets the Today
        /// restore banner reconstruct a `CapturePayload` for Resume
        /// without re-querying evidence — robust against evidence
        /// pruning, transcript purge, etc.
        var payloadSnapshot: CapturePayloadSnapshot?

        init(
            mode: CaptureMode,
            guidedStep: Int,
            attendancePresent: [UUID],
            extraAttendeeNames: [String],
            callAnswered: Bool,
            occurrenceDecision: OccurrenceDecision,
            mainOutcomeText: String,
            talkingPointResponses: [String: String],
            actionItemResponses: [String: String],
            guidedActionItemsText: String,
            guidedFollowUpText: String,
            guidedLifeEventsText: String,
            voicemailNoteText: String,
            discussionText: String,
            actionItemEntries: [ActionItemEntry],
            followUpText: String,
            lifeEventsText: String,
            payloadSnapshot: CapturePayloadSnapshot? = nil
        ) {
            self.mode = mode
            self.guidedStep = guidedStep
            self.attendancePresent = attendancePresent
            self.extraAttendeeNames = extraAttendeeNames
            self.callAnswered = callAnswered
            self.occurrenceDecision = occurrenceDecision
            self.mainOutcomeText = mainOutcomeText
            self.talkingPointResponses = talkingPointResponses
            self.actionItemResponses = actionItemResponses
            self.guidedActionItemsText = guidedActionItemsText
            self.guidedFollowUpText = guidedFollowUpText
            self.guidedLifeEventsText = guidedLifeEventsText
            self.voicemailNoteText = voicemailNoteText
            self.discussionText = discussionText
            self.actionItemEntries = actionItemEntries
            self.followUpText = followUpText
            self.lifeEventsText = lifeEventsText
            self.payloadSnapshot = payloadSnapshot
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = (try c.decodeIfPresent(CaptureMode.self, forKey: .mode)) ?? .guided
            guidedStep = (try c.decodeIfPresent(Int.self, forKey: .guidedStep)) ?? 0
            attendancePresent = (try c.decodeIfPresent([UUID].self, forKey: .attendancePresent)) ?? []
            extraAttendeeNames = (try c.decodeIfPresent([String].self, forKey: .extraAttendeeNames)) ?? []
            callAnswered = (try c.decodeIfPresent(Bool.self, forKey: .callAnswered)) ?? true
            occurrenceDecision = (try c.decodeIfPresent(OccurrenceDecision.self, forKey: .occurrenceDecision)) ?? .happened
            mainOutcomeText = (try c.decodeIfPresent(String.self, forKey: .mainOutcomeText)) ?? ""
            talkingPointResponses = (try c.decodeIfPresent([String: String].self, forKey: .talkingPointResponses)) ?? [:]
            actionItemResponses = (try c.decodeIfPresent([String: String].self, forKey: .actionItemResponses)) ?? [:]
            guidedActionItemsText = (try c.decodeIfPresent(String.self, forKey: .guidedActionItemsText)) ?? ""
            guidedFollowUpText = (try c.decodeIfPresent(String.self, forKey: .guidedFollowUpText)) ?? ""
            guidedLifeEventsText = (try c.decodeIfPresent(String.self, forKey: .guidedLifeEventsText)) ?? ""
            voicemailNoteText = (try c.decodeIfPresent(String.self, forKey: .voicemailNoteText)) ?? ""
            discussionText = (try c.decodeIfPresent(String.self, forKey: .discussionText)) ?? ""
            actionItemEntries = (try c.decodeIfPresent([ActionItemEntry].self, forKey: .actionItemEntries)) ?? []
            followUpText = (try c.decodeIfPresent(String.self, forKey: .followUpText)) ?? ""
            lifeEventsText = (try c.decodeIfPresent(String.self, forKey: .lifeEventsText)) ?? ""
            payloadSnapshot = try c.decodeIfPresent(CapturePayloadSnapshot.self, forKey: .payloadSnapshot)
        }
    }
}

private extension String {
    var trimmedNonEmpty: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
