//
//  SAMModels-Sphere.swift
//  SAM
//
//  Phase 1 of the relationship-model refactor (May 2026).
//
//  A Sphere is a hat the user wears in life — a context with its own people,
//  cadence, and definition of "doing well". A user with one Sphere sees today's
//  SAM unchanged; users with multiple Spheres get per-Sphere coaching once
//  Phase 5 lands.
//
//  This file defines:
//    • Mode — the five-shape taxonomy used to coach each relationship.
//    • SphereAccentColor — a fixed palette so Sphere chips stay visually
//      coherent in lists, briefings, and the graph.
//    • Sphere — the SwiftData model.
//
//  Trajectory, TrajectoryStage, PersonSphereMembership, and PersonTrajectoryEntry
//  live in SAMModels-Trajectory.swift.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - Mode

/// The five relationship shapes SAM coaches. Mode drives cadence sensitivity,
/// coaching tone, and which signals fire (e.g. Covenant never fires cadence-decay
/// alerts). See `relationship-model/relationship_model.md` and `relationship-model/relationship_synthesis.md` for the
/// taxonomy rationale.
public enum Mode: String, Codable, Sendable, CaseIterable {
    /// Moving someone toward a defined outcome (sale, hire, donation ask).
    case funnel      = "funnel"
    /// Ongoing tending of an active, valued relationship.
    case stewardship = "stewardship"
    /// Time-bounded gather-people-around-a-goal effort (ED search, capital campaign).
    case campaign    = "campaign"
    /// Customers/members who engage on their own rhythm.
    case service     = "service"
    /// Spouse, close kin, deep friendships — silence is fine, milestones matter.
    case covenant    = "covenant"

    public var displayName: String {
        switch self {
        case .funnel:      return "Funnel"
        case .stewardship: return "Stewardship"
        case .campaign:    return "Campaign"
        case .service:     return "Service"
        case .covenant:    return "Covenant"
        }
    }

    /// One-line user-facing explanation, surfaced in Sphere setup templates.
    public var explanation: String {
        switch self {
        case .funnel:
            return "Moving someone toward a defined outcome."
        case .stewardship:
            return "Ongoing tending of an active relationship."
        case .campaign:
            return "Time-bounded effort with a specific goal."
        case .service:
            return "Customers and members who engage on their own rhythm."
        case .covenant:
            return "Bonds where silence is fine and milestones matter."
        }
    }

    /// Default cadence in days for this Mode when no per-person baseline exists.
    /// Phase 3 will prefer personalBaselineCadence over this floor.
    public var defaultCadenceDays: Int {
        switch self {
        case .funnel:      return 14
        case .stewardship: return 30
        case .campaign:    return 7
        case .service:     return 90
        case .covenant:    return 0   // no cadence — milestones drive contact
        }
    }

    /// Whether SAM should ever generate cadence-decay alerts for this Mode.
    /// Phase 2 enforces this via the Covenant silence rule.
    public var generatesCadenceAlerts: Bool {
        self != .covenant
    }

    /// One-line tone hint prepended to coaching/draft prompts. Steers voice
    /// without rewriting the body of the prompt. Phase 2 introduces this;
    /// Phase 7 promotes it to a per-Trajectory `trustCurrency` field.
    public var coachingToneHint: String {
        switch self {
        case .funnel:
            return "Tone: confident and competent. Show you understand their situation and can move the conversation forward."
        case .stewardship:
            return "Tone: warm and competent. Demonstrate ongoing care and remember specific details from prior interactions."
        case .campaign:
            return "Tone: focused and urgent without pressuring. Reinforce the shared goal and the time-bounded nature of the effort."
        case .service:
            return "Tone: reliable and responsive. Make it easy for them to get what they need; never invasive."
        case .covenant:
            return "Tone: warm and human. This is an intimate relationship — no business framing, no follow-up scripts. Speak as a person, not a professional."
        }
    }

    /// Color used for Mode chips in person detail and briefing.
    public var color: Color {
        switch self {
        case .funnel:      return .orange
        case .stewardship: return .blue
        case .campaign:    return .purple
        case .service:     return .teal
        case .covenant:    return .pink
        }
    }

    /// SF Symbol for Mode chips.
    public var icon: String {
        switch self {
        case .funnel:      return "arrow.down.right.circle"
        case .stewardship: return "leaf"
        case .campaign:    return "flag.checkered"
        case .service:     return "wrench.and.screwdriver"
        case .covenant:    return "heart.circle"
        }
    }
}

// MARK: - SphereAccentColor

/// A fixed palette so Sphere accent chips stay visually distinct in
/// lists, the briefing, and the relationship graph. User picks one
/// per Sphere at creation.
public enum SphereAccentColor: String, Codable, Sendable, CaseIterable {
    case slate    = "slate"
    case blue     = "blue"
    case teal     = "teal"
    case green    = "green"
    case amber    = "amber"
    case orange   = "orange"
    case rose     = "rose"
    case purple   = "purple"

    public var displayName: String {
        switch self {
        case .slate:  return "Slate"
        case .blue:   return "Blue"
        case .teal:   return "Teal"
        case .green:  return "Green"
        case .amber:  return "Amber"
        case .orange: return "Orange"
        case .rose:   return "Rose"
        case .purple: return "Purple"
        }
    }

    public var color: Color {
        switch self {
        case .slate:  return Color(red: 0.40, green: 0.45, blue: 0.50)
        case .blue:   return .blue
        case .teal:   return .teal
        case .green:  return .green
        case .amber:  return Color(red: 0.95, green: 0.75, blue: 0.20)
        case .orange: return .orange
        case .rose:   return Color(red: 0.95, green: 0.30, blue: 0.45)
        case .purple: return .purple
        }
    }
}

// MARK: - Sphere

/// A Sphere is a role/context the user inhabits, with its own people and rhythm.
/// Bootstrapped at Phase 1 first-launch as a single "My Practice" Sphere
/// containing every existing contact. Additional Spheres are user-created in
/// Phase 5+.
@Model
public final class Sphere {
    @Attribute(.unique) public var id: UUID

    /// User-facing name. Encouraged to be a role ("Chairman of ABT"), not a
    /// category ("Nonprofit Work"). Free text.
    public var name: String

    /// One-line purpose statement — why this Sphere exists in the user's life.
    /// Surfaced in Sphere card and feeds the Strategic Coordinator's per-Sphere
    /// system prompt.
    public var purpose: String

    /// Raw storage for SphereAccentColor enum.
    public var accentColorRaw: String

    /// Raw storage for Mode enum — the default Mode for people in this Sphere
    /// who aren't on an explicit Trajectory.
    public var defaultModeRaw: String

    /// Override for the Mode's defaultCadenceDays. Use the Mode default unless
    /// the user has explicitly tuned this Sphere. nil = use Mode default.
    public var defaultCadenceDays: Int?

    /// Sort order in the Spheres list / tab.
    public var sortOrder: Int

    /// Soft-archive flag. Archived Spheres are hidden from active UI but
    /// preserve their membership data for history and future reactivation.
    public var archived: Bool

    public var createdAt: Date

    /// True for the single Sphere auto-created at Phase 1 bootstrap. Used to
    /// suppress "Create your first Sphere" onboarding for migrated users and
    /// to identify the legacy default during Phase 5 Sphere-split flows.
    public var isBootstrapDefault: Bool

    // MARK: Typed accessors

    @Transient
    public var accentColor: SphereAccentColor {
        get { SphereAccentColor(rawValue: accentColorRaw) ?? .slate }
        set { accentColorRaw = newValue.rawValue }
    }

    @Transient
    public var defaultMode: Mode {
        get { Mode(rawValue: defaultModeRaw) ?? .stewardship }
        set { defaultModeRaw = newValue.rawValue }
    }

    /// Resolved cadence: per-Sphere override if set, otherwise the Mode's
    /// default. Phase 3 health math will prefer personalBaselineCadence over
    /// this when available.
    @Transient
    public var effectiveDefaultCadenceDays: Int {
        defaultCadenceDays ?? defaultMode.defaultCadenceDays
    }

    public init(
        id: UUID = UUID(),
        name: String,
        purpose: String = "",
        accentColor: SphereAccentColor = .slate,
        defaultMode: Mode = .stewardship,
        defaultCadenceDays: Int? = nil,
        sortOrder: Int = 0,
        archived: Bool = false,
        createdAt: Date = .now,
        isBootstrapDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.accentColorRaw = accentColor.rawValue
        self.defaultModeRaw = defaultMode.rawValue
        self.defaultCadenceDays = defaultCadenceDays
        self.sortOrder = sortOrder
        self.archived = archived
        self.createdAt = createdAt
        self.isBootstrapDefault = isBootstrapDefault
    }
}
