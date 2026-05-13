//
//  SAMModels-Trajectory.swift
//  SAM
//
//  Phase 1 of the relationship-model refactor (May 2026).
//
//  A Trajectory is a named arc inside a Sphere (or freestanding) that people
//  move along. Examples: "Client Pipeline" (Funnel mode), "Past Clients —
//  Stewardship" (Stewardship mode), "Q3 ED Search" (Campaign mode).
//
//  A PersonTrajectoryEntry records a single person's current place on one
//  Trajectory. A person may be on multiple Trajectories simultaneously
//  (e.g. an Applicant who's also being recruited).
//
//  PersonSphereMembership records that a person belongs to a Sphere even
//  when they aren't actively on any Trajectory inside it (a contact in your
//  church Sphere who isn't being moved anywhere — just present).
//
//  Phase 1 writes these models through the bootstrap migration but no
//  existing system reads from them yet. Phase 8 promotes them to the
//  canonical source of truth, deprecating the roleBadges-as-stage usages
//  catalogued in relationship-model/phase0_audit.md §2.
//

import Foundation
import SwiftData

// MARK: - TrajectoryExitReason

/// Why a PersonTrajectoryEntry was closed. Drives Phase 4 follow-on behavior
/// (a `completed` Funnel entry auto-spawns a Stewardship entry).
public enum TrajectoryExitReason: String, Codable, Sendable, CaseIterable {
    /// Reached a terminal stage (Funnel: closed-won; Campaign: goal reached).
    case completed   = "completed"
    /// User decided this isn't moving forward (lead went cold, candidate declined).
    case abandoned   = "abandoned"
    /// Person moved to a different Trajectory (e.g., reassigned to another funnel).
    case transferred = "transferred"
    /// Trajectory itself ended (Campaign closed, all members revert).
    case trajectoryClosed = "trajectoryClosed"
    /// Any other reason, captured in notes.
    case other       = "other"

    public var displayName: String {
        switch self {
        case .completed:        return "Completed"
        case .abandoned:        return "Abandoned"
        case .transferred:      return "Transferred"
        case .trajectoryClosed: return "Trajectory Closed"
        case .other:            return "Other"
        }
    }
}

// MARK: - TrustCurrency

/// What kind of trust this Trajectory is primarily built on. Steers coaching
/// tone: a Funnel earning *competence* trust gets insight-driven prompts;
/// a Covenant relying on *warmth* gets connection-driven prompts. Phase 7 of
/// the relationship-model refactor.
public enum TrustCurrency: String, Codable, Sendable, CaseIterable {
    /// Connection and care — "I matter to you."
    case warmth      = "warmth"
    /// Expertise and judgment — "You know what you're doing."
    case competence  = "competence"
    /// Showing up consistently — "You do what you say."
    case reliability = "reliability"
    /// Combination of warmth + competence; default for long Stewardship arcs.
    case both        = "both"

    public var displayName: String {
        switch self {
        case .warmth:      return "Warmth"
        case .competence:  return "Competence"
        case .reliability: return "Reliability"
        case .both:        return "Warmth + Competence"
        }
    }

    /// One-line tone direction for coaching prompts.
    public var coachingTone: String {
        switch self {
        case .warmth:
            return "Lead with connection and personal care; reference shared context, ask about their world."
        case .competence:
            return "Lead with insight and clarity; demonstrate expertise, offer the next useful step."
        case .reliability:
            return "Lead with follow-through; reference prior commitments and close loops you've opened."
        case .both:
            return "Balance care with expertise; show you remember the person and the work."
        }
    }

    /// Default currency for a given Mode (per the Phase 7 plan).
    public static func defaultFor(mode: Mode) -> TrustCurrency {
        switch mode {
        case .funnel:      return .competence
        case .stewardship: return .both
        case .covenant:    return .warmth
        case .campaign:    return .competence
        case .service:     return .reliability
        }
    }
}

// MARK: - Trajectory

/// A named arc that people move along — the unit-of-progression inside a Sphere.
/// The Mode on a Trajectory governs coaching tone and which signals fire for
/// people currently on it; this beats the Sphere's defaultMode for those people.
@Model
public final class Trajectory {
    @Attribute(.unique) public var id: UUID

    /// The Sphere this Trajectory belongs to. Optional so user-created
    /// stand-alone Trajectories remain valid if the Sphere is later deleted.
    @Relationship(deleteRule: .nullify)
    public var sphere: Sphere?

    /// User-facing name. Encouraged to be the arc itself ("Q3 ED Search"),
    /// not the people on it.
    public var name: String

    /// Raw storage for Mode enum.
    public var modeRaw: String

    /// Raw storage for TrustCurrency enum. Defaults to the Mode's currency
    /// (set in init) and may be overridden per Trajectory. Phase 7 of the
    /// relationship-model refactor.
    public var trustCurrencyRaw: String = TrustCurrency.competence.rawValue

    /// Soft-archive flag. Archived Trajectories are hidden from active UI
    /// but preserve their stages and historical entries.
    public var archived: Bool

    public var createdAt: Date

    /// When the Trajectory itself ended (Campaign closed, replaced by successor).
    /// Setting this should cascade `TrajectoryExitReason.trajectoryClosed` to
    /// any still-active PersonTrajectoryEntry on this Trajectory.
    public var completedAt: Date?

    /// Optional notes on the Trajectory's purpose / scope.
    public var notes: String?

    /// Stages belonging to this Trajectory. Cascade-delete when the Trajectory
    /// itself is deleted (rare — archive is preferred).
    @Relationship(deleteRule: .cascade, inverse: \TrajectoryStage.trajectory)
    public var stages: [TrajectoryStage] = []

    /// All person entries on this Trajectory. Nullify so the entry survives
    /// Trajectory deletion for history.
    @Relationship(deleteRule: .nullify, inverse: \PersonTrajectoryEntry.trajectory)
    public var entries: [PersonTrajectoryEntry] = []

    // MARK: Typed accessors

    @Transient
    public var mode: Mode {
        get { Mode(rawValue: modeRaw) ?? .stewardship }
        set { modeRaw = newValue.rawValue }
    }

    @Transient
    public var trustCurrency: TrustCurrency {
        get { TrustCurrency(rawValue: trustCurrencyRaw) ?? TrustCurrency.defaultFor(mode: mode) }
        set { trustCurrencyRaw = newValue.rawValue }
    }

    /// True when `completedAt` has been set.
    @Transient
    public var isClosed: Bool {
        completedAt != nil
    }

    public init(
        id: UUID = UUID(),
        sphere: Sphere?,
        name: String,
        mode: Mode,
        trustCurrency: TrustCurrency? = nil,
        archived: Bool = false,
        createdAt: Date = .now,
        completedAt: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.sphere = sphere
        self.name = name
        self.modeRaw = mode.rawValue
        self.trustCurrencyRaw = (trustCurrency ?? TrustCurrency.defaultFor(mode: mode)).rawValue
        self.archived = archived
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.notes = notes
    }
}

// MARK: - TrajectoryStage

/// A single stage on a Trajectory. For a Funnel-mode Trajectory the stages
/// form a directed sequence; for Stewardship or Campaign Modes a Trajectory
/// may have a single stage ("Active") and rely on cadence rather than
/// stage progression.
@Model
public final class TrajectoryStage {
    @Attribute(.unique) public var id: UUID

    @Relationship(deleteRule: .nullify)
    public var trajectory: Trajectory?

    /// User-facing stage name. Examples: "Lead", "Applicant", "Client",
    /// "Initial Conversation", "Final Round", "Active".
    public var name: String

    /// Position in the stage sequence (0-based).
    public var sortOrder: Int

    /// True when reaching this stage closes the Trajectory for the person.
    /// Phase 4 uses this signal to auto-spawn a Stewardship entry when a
    /// Funnel-mode Trajectory terminates.
    public var isTerminal: Bool

    /// Optional cadence override for people currently on this stage —
    /// used when a single stage warrants a different rhythm than the
    /// Trajectory's default (e.g., "Negotiating" demands faster touch).
    public var stageCadenceDaysOverride: Int?

    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        trajectory: Trajectory?,
        name: String,
        sortOrder: Int,
        isTerminal: Bool = false,
        stageCadenceDaysOverride: Int? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.trajectory = trajectory
        self.name = name
        self.sortOrder = sortOrder
        self.isTerminal = isTerminal
        self.stageCadenceDaysOverride = stageCadenceDaysOverride
        self.createdAt = createdAt
    }
}

// MARK: - PersonSphereMembership

/// Records that a Person is a member of a Sphere. A person may be in
/// multiple Spheres (e.g., a council colleague who is also a client).
/// Membership is independent of Trajectory: you can be "in" a Sphere
/// without being on any active Trajectory in it.
@Model
public final class PersonSphereMembership {
    @Attribute(.unique) public var id: UUID

    @Relationship(deleteRule: .nullify)
    public var person: SamPerson?

    @Relationship(deleteRule: .nullify)
    public var sphere: Sphere?

    public var addedAt: Date

    /// Optional per-person notes about why this person sits in this Sphere.
    public var notes: String?

    /// Ordering of this membership relative to the person's other
    /// memberships. Lowest `order` value is the person's **default**
    /// sphere — used when evidence has no explicit `contextSphere` and
    /// when no per-sphere lens is active. Drag-to-reorder in the person
    /// detail view rewrites these values. Defaults to a large constant so
    /// memberships created before the migration sort after any explicitly
    /// ordered membership; the migration backfills sane values by
    /// `addedAt`.
    public var order: Int = 1_000

    public init(
        id: UUID = UUID(),
        person: SamPerson?,
        sphere: Sphere?,
        addedAt: Date = .now,
        notes: String? = nil,
        order: Int = 1_000
    ) {
        self.id = id
        self.person = person
        self.sphere = sphere
        self.addedAt = addedAt
        self.notes = notes
        self.order = order
    }
}

// MARK: - PersonTrajectoryEntry

/// Records a single person's place on a Trajectory. While active
/// (`exitedAt == nil`) the entry contributes that person's Mode to Health
/// scoring and surfaces stage-progression coaching. Once exited, the entry
/// is preserved for historical conversion-rate computation.
@Model
public final class PersonTrajectoryEntry {
    @Attribute(.unique) public var id: UUID

    @Relationship(deleteRule: .nullify)
    public var person: SamPerson?

    @Relationship(deleteRule: .nullify)
    public var trajectory: Trajectory?

    /// Current stage on the Trajectory. Nil between transitions or when
    /// the Trajectory uses a stageless-cadence model (Mode == .stewardship
    /// with a single stage often won't bother).
    @Relationship(deleteRule: .nullify)
    public var currentStage: TrajectoryStage?

    /// Optional per-person cadence override on this Trajectory. nil means
    /// "use the Trajectory's mode default or the stage override".
    public var cadenceDaysOverride: Int?

    public var enteredAt: Date

    /// When the entry was closed. nil = currently active.
    public var exitedAt: Date?

    /// Raw storage for TrajectoryExitReason. nil when active.
    public var exitReasonRaw: String?

    /// Optional notes captured at entry-close time.
    public var exitNotes: String?

    /// True once `exitedAt` is set. Convenience for queries.
    @Transient
    public var isActive: Bool {
        exitedAt == nil
    }

    @Transient
    public var exitReason: TrajectoryExitReason? {
        get {
            guard let raw = exitReasonRaw else { return nil }
            return TrajectoryExitReason(rawValue: raw)
        }
        set { exitReasonRaw = newValue?.rawValue }
    }

    public init(
        id: UUID = UUID(),
        person: SamPerson?,
        trajectory: Trajectory?,
        currentStage: TrajectoryStage? = nil,
        cadenceDaysOverride: Int? = nil,
        enteredAt: Date = .now,
        exitedAt: Date? = nil,
        exitReason: TrajectoryExitReason? = nil,
        exitNotes: String? = nil
    ) {
        self.id = id
        self.person = person
        self.trajectory = trajectory
        self.currentStage = currentStage
        self.cadenceDaysOverride = cadenceDaysOverride
        self.enteredAt = enteredAt
        self.exitedAt = exitedAt
        self.exitReasonRaw = exitReason?.rawValue
        self.exitNotes = exitNotes
    }
}
