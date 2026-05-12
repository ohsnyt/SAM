//
//  SAMModels-Bundles.swift
//  SAM
//
//  Per-person bundled coaching outcomes. Replaces the old "one row per
//  reconnect/birthday/anniversary" pattern of SamOutcome for outreach-class
//  outcomes that target a single person. Each bundle holds N sub-items
//  (distinct topics: cadence reconnect, birthday, life-event touch, etc.);
//  bundle priority is max(sub-item priority) with a small bump when two
//  unrelated topic groups stack.
//
//  Non-person outcomes (preparation, training, compliance, contentCreation,
//  setup, growth) continue to live on SamOutcome.
//

import SwiftData
import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - OutcomeSubItemKind
// ─────────────────────────────────────────────────────────────────────

/// Discrete coaching topic that can be bundled with other topics for the
/// same person. Distinct from `OutcomeKind` — that vocabulary covers all
/// outcome types (including non-bundleable ones like training/compliance);
/// this vocabulary only covers things that fold into a per-person bundle.
public enum OutcomeSubItemKind: String, Codable, Sendable, CaseIterable {
    /// Person has gone past their preferred cadence threshold.
    case cadenceReconnect
    /// Birthday today, tomorrow, or within a small window.
    case birthday
    /// Wedding anniversary today or within a small window.
    case anniversary
    /// Annual policy / business review due.
    case annualReview
    /// Recent life event signal (new job, baby, move, illness, loss, etc.).
    case lifeEventTouch
    /// Funnel-terminal person (Client) lacks an active Stewardship arc.
    case stewardshipArc
    /// Pipeline stage hasn't moved in the configured stall window.
    case stalledPipeline
    /// Sarah promised something to this person and the due date is near.
    case openCommitment
    /// Open action item carried from a meeting / note that targets this person.
    case openActionItem
    /// Proposal needs to be built or delivered.
    case proposalPrep
    /// Recruiting prospect needs a touch in their licensing / activation arc.
    case recruitTouch

    /// Topic group used by the bundle priority bump — sub-items in
    /// different groups count as "unrelated" so stacking them bumps the
    /// bundle. Stacking two birthday/anniversary items doesn't bump.
    public var topicGroup: TopicGroup {
        switch self {
        case .cadenceReconnect, .stewardshipArc:               return .relationship
        case .birthday, .anniversary, .lifeEventTouch:         return .lifeEvent
        case .annualReview, .stalledPipeline, .proposalPrep:   return .pipeline
        case .openCommitment, .openActionItem:                 return .commitment
        case .recruitTouch:                                    return .recruiting
        }
    }

    public enum TopicGroup: String, Sendable {
        case relationship
        case lifeEvent
        case pipeline
        case commitment
        case recruiting
    }

    /// Human label used in bundle UI and combined drafts.
    public var displayLabel: String {
        switch self {
        case .cadenceReconnect:  return "Reconnect"
        case .birthday:          return "Birthday"
        case .anniversary:       return "Anniversary"
        case .annualReview:      return "Annual review"
        case .lifeEventTouch:    return "Life event"
        case .stewardshipArc:    return "Stewardship arc"
        case .stalledPipeline:   return "Pipeline stalled"
        case .openCommitment:    return "Open commitment"
        case .openActionItem:    return "Action item"
        case .proposalPrep:      return "Proposal"
        case .recruitTouch:      return "Recruiting touch"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - OutcomeBundle
// ─────────────────────────────────────────────────────────────────────

/// One person's bundle of outreach-class coaching outcomes. The bundle is
/// the unit the user sees in the queue. Sub-items are tick-each-completable
/// (or skip-able); when all close, the bundle closes and is regenerated on
/// the next evidence pass.
@Model
public final class OutcomeBundle {
    @Attribute(.unique) public var id: UUID

    /// Sub-items that make up this bundle. Cascade delete so closing the
    /// bundle removes its history.
    @Relationship(deleteRule: .cascade, inverse: \OutcomeSubItem.bundle)
    public var subItems: [OutcomeSubItem] = []

    @Relationship(deleteRule: .nullify)
    public var person: SamPerson?

    /// Cached personID so dismissal/dedup logic can run without faulting `person`.
    public var personID: UUID

    /// max(open sub-items) + bump when ≥2 unrelated topic groups are open.
    /// 0.0–1.0; the queue sorts on this.
    public var priorityScore: Double

    /// Nearest dueDate across open sub-items (nil when none have deadlines).
    public var nearestDueDate: Date?

    public var createdAt: Date
    public var updatedAt: Date

    /// Set when every sub-item is completed or skipped; bundle exits the
    /// active queue. Next evidence cycle is free to spawn a new bundle.
    public var closedAt: Date?

    /// Last time the bundle appeared in the queue (used for surfacing fatigue).
    public var lastSurfacedAt: Date?

    /// AI-generated combined draft that weaves all open sub-items into one
    /// natural message. Refreshed when the open sub-item set changes.
    public var combinedDraftMessage: String?

    /// Last time `combinedDraftMessage` was regenerated. Used to avoid
    /// re-asking the model when the bundle hasn't gained / lost a sub-item.
    public var draftRefreshedAt: Date?

    /// Signature of the open sub-item set when the draft was last generated.
    /// Stored as a sorted comma-joined `kindRawValue:title` so a change in
    /// title or kind triggers regeneration.
    public var draftSignature: String?

    /// Suggested channel for the combined draft (text / email / call / DM).
    public var suggestedChannelRawValue: String?

    @Transient
    public var suggestedChannel: CommunicationChannel? {
        get { suggestedChannelRawValue.flatMap { CommunicationChannel(rawValue: $0) } }
        set { suggestedChannelRawValue = newValue?.rawValue }
    }

    /// Open (not completed, not skipped) sub-items, highest priority first.
    @Transient
    public var openSubItems: [OutcomeSubItem] {
        subItems
            .filter { $0.completedAt == nil && $0.skippedAt == nil }
            .sorted { $0.priorityScore > $1.priorityScore }
    }

    public init(person: SamPerson, priorityScore: Double = 0.5) {
        self.id = UUID()
        self.person = person
        self.personID = person.id
        self.priorityScore = priorityScore
        self.createdAt = .now
        self.updatedAt = .now
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - OutcomeSubItem
// ─────────────────────────────────────────────────────────────────────

/// One discrete topic inside an OutcomeBundle. The user ticks or skips
/// each sub-item independently; completion / skip drives the per-kind
/// recurrence rule that sets `nextDueAt` for the next firing.
@Model
public final class OutcomeSubItem {
    @Attribute(.unique) public var id: UUID

    /// Parent bundle. Inverse of OutcomeBundle.subItems.
    public var bundle: OutcomeBundle?

    /// Stored raw for SwiftData; use `kind` transient property.
    public var kindRawValue: String

    /// Short imperative title (e.g. "Wish happy birthday").
    public var title: String

    /// Why this sub-item is firing (e.g. "Turns 50 in 3 days — milestone.").
    public var rationale: String

    /// 0.0–1.0 priority for this topic alone.
    public var priorityScore: Double

    /// Specific deadline for this topic (e.g. the birthday date).
    public var dueDate: Date?

    public var createdAt: Date

    /// User ticked "done".
    public var completedAt: Date?
    /// User skipped (suppresses regeneration until `nextDueAt`).
    public var skippedAt: Date?

    /// Next time this sub-item kind should fire for this person, computed
    /// from the per-kind recurrence rule when the sub-item closes.
    public var nextDueAt: Date?

    /// True for milestone birthdays / round-number anniversaries / etc.
    /// Drives an extra priority bump and survives in next year's regen.
    public var isMilestone: Bool

    @Transient
    public var kind: OutcomeSubItemKind {
        get { OutcomeSubItemKind(rawValue: kindRawValue) ?? .openActionItem }
        set { kindRawValue = newValue.rawValue }
    }

    public init(
        kind: OutcomeSubItemKind,
        title: String,
        rationale: String,
        priorityScore: Double = 0.5,
        dueDate: Date? = nil,
        isMilestone: Bool = false
    ) {
        self.id = UUID()
        self.kindRawValue = kind.rawValue
        self.title = title
        self.rationale = rationale
        self.priorityScore = priorityScore
        self.dueDate = dueDate
        self.isMilestone = isMilestone
        self.createdAt = .now
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - OutcomeDismissalRecord
// ─────────────────────────────────────────────────────────────────────

/// Persistent record of a (personID, kind) the user explicitly dismissed
/// or skipped. Survives the v34→bundle wipe so previously-dismissed items
/// don't immediately re-fire. Suppression is time-bounded — once
/// `suppressUntil` passes the same kind can fire again.
@Model
public final class OutcomeDismissalRecord {
    @Attribute(.unique) public var id: UUID

    public var personID: UUID

    /// OutcomeSubItemKind rawValue (preferred) or legacy OutcomeKind rawValue
    /// when migrated from pre-bundle SamOutcome rows.
    public var kindRawValue: String

    public var dismissedAt: Date

    /// Don't regenerate this (personID, kind) until on or after this date.
    /// Nil means "suppressed indefinitely" — only the user can clear it.
    public var suppressUntil: Date?

    /// True if this row came from the one-time legacy SamOutcome wipe.
    public var migratedFromLegacy: Bool

    public init(
        personID: UUID,
        kindRawValue: String,
        dismissedAt: Date = .now,
        suppressUntil: Date? = nil,
        migratedFromLegacy: Bool = false
    ) {
        self.id = UUID()
        self.personID = personID
        self.kindRawValue = kindRawValue
        self.dismissedAt = dismissedAt
        self.suppressUntil = suppressUntil
        self.migratedFromLegacy = migratedFromLegacy
    }
}
