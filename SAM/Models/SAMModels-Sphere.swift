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

    /// Seed prompt SAM uses to classify which Sphere a piece of evidence
    /// belongs to when a person has multiple active memberships. Shipped
    /// with a default for the five canonical spheres (Work / Family & Close
    /// Friends / Church / Volunteer / Hobby) and refined over time as the
    /// classifier accumulates confirmed examples. User-editable in the
    /// Spheres management panel (People → Relationship Graph). Empty for
    /// user-created custom spheres until populated.
    public var classificationProfile: String = ""

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
        classificationProfile: String = "",
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
        self.classificationProfile = classificationProfile
        self.accentColorRaw = accentColor.rawValue
        self.defaultModeRaw = defaultMode.rawValue
        self.defaultCadenceDays = defaultCadenceDays
        self.sortOrder = sortOrder
        self.archived = archived
        self.createdAt = createdAt
        self.isBootstrapDefault = isBootstrapDefault
    }
}

// MARK: - LifeSphereTemplate

/// Shipped templates surfaced in the first-run sphere-selection flow and
/// the "Add sphere" UI in People → Relationship Graph. Each template
/// carries a real `classificationProfile` so SAM has classification
/// context the moment the user adopts it.
public struct LifeSphereTemplate: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let purpose: String
    public let classificationProfile: String
    public let accentColor: SphereAccentColor
    public let defaultMode: Mode
    public let icon: String
    /// Suggested by default in onboarding.
    public let suggestedAtOnboarding: Bool

    public static let work = LifeSphereTemplate(
        id: "work",
        name: "Work",
        purpose: "Business activities: clients, recruits, vendors, agents.",
        classificationProfile: """
        Business activities related to financial services, recruiting, client meetings, \
        policy work, WFG events, and agent training. Topics include insurance, mortgages, \
        retirement planning, licensing, AMS, BPM, codes, leads, prospects, commission, \
        carriers, applications, and underwriting. Tone is professional or quasi-professional. \
        Exclude purely personal/family content even with the same person.
        """,
        accentColor: .blue,
        defaultMode: .stewardship,
        icon: "briefcase",
        suggestedAtOnboarding: true
    )

    public static let familyAndCloseFriends = LifeSphereTemplate(
        id: "family",
        name: "Family & Close Friends",
        purpose: "Covenantal relationships — no quota, no funnel.",
        classificationProfile: """
        Personal relationship maintenance with family members and close friends. \
        Topics include life events, emotional support, family logistics, shared meals, \
        milestones (birthdays, anniversaries, deaths), faith conversations not tied to \
        church duties, parenting, marriage, household decisions, vacations, holidays. \
        No transactional, sales, or recruiting content even with the same person. \
        Tone is warm, intimate, unstructured.
        """,
        accentColor: .rose,
        defaultMode: .covenant,
        icon: "house.fill",
        suggestedAtOnboarding: true
    )

    public static let church = LifeSphereTemplate(
        id: "church",
        name: "Church",
        purpose: "Local church community: ministries, elder duties, member care.",
        classificationProfile: """
        Local church community life: Sunday services, midweek ministries, prayer requests, \
        elder/deacon duties, member care, theology and doctrine discussions, church events, \
        small groups, missions, giving. Spiritual content even with non-church people belongs \
        here when the discussion is overtly faith-formational. Exclude private family faith \
        conversations (those belong in Family & Close Friends).
        """,
        accentColor: .purple,
        defaultMode: .stewardship,
        icon: "building.columns",
        suggestedAtOnboarding: false
    )

    public static let volunteer = LifeSphereTemplate(
        id: "volunteer",
        name: "Volunteer / Civic",
        purpose: "Non-profit boards, civic engagement, community service.",
        classificationProfile: """
        Non-profit boards, civic engagement, charitable causes, school PTA, neighborhood \
        associations, community service. Topics include board meetings, fundraising, \
        volunteer coordination, mission-driven projects, advocacy. Distinct from Work \
        (no commercial relationship) and from Church (no faith framing).
        """,
        accentColor: .green,
        defaultMode: .campaign,
        icon: "hand.raised",
        suggestedAtOnboarding: false
    )

    public static let hobby = LifeSphereTemplate(
        id: "hobby",
        name: "Hobby",
        purpose: "Shared recreational interest with a defined group.",
        classificationProfile: """
        Shared recreational interest with a defined group: band practice, running club \
        meetups, gaming sessions, book club, sports league, craft group. The topic is the \
        hobby itself and its logistics — not "we both happen to like X." Rename this sphere \
        to the specific activity once adopted (e.g., "Jazz Band", "Run Club").
        """,
        accentColor: .amber,
        defaultMode: .stewardship,
        icon: "music.note",
        suggestedAtOnboarding: false
    )

    public static let all: [LifeSphereTemplate] = [
        .work,
        .familyAndCloseFriends,
        .church,
        .volunteer,
        .hobby
    ]

    public static let onboardingDefaults: [LifeSphereTemplate] =
        all.filter { $0.suggestedAtOnboarding }

    public static let onboardingOptionals: [LifeSphereTemplate] =
        all.filter { !$0.suggestedAtOnboarding }
}

public extension Sphere {
    /// Create a Sphere from a shipped template. Used by the onboarding
    /// flow and the "Add sphere" UI; preserves classificationProfile so
    /// the classifier has real context from day one.
    convenience init(template: LifeSphereTemplate, sortOrder: Int = 0) {
        self.init(
            name: template.name,
            purpose: template.purpose,
            classificationProfile: template.classificationProfile,
            accentColor: template.accentColor,
            defaultMode: template.defaultMode,
            sortOrder: sortOrder
        )
    }
}
