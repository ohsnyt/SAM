//
//  SAMModels-IntentionalTouch.swift
//  SAM
//
//  Intentional touch events sourced from LinkedIn (and future social platforms).
//  An IntentionalTouch records a single directed, deliberate interaction between
//  the user and a contact — messages, endorsements, recommendations, invitations,
//  reactions, and comments. These feed the touch-scoring system that determines
//  Add vs. Later classification during LinkedIn import.
//
//  Unlike SamEvidenceItem (which models full interaction records with bodies,
//  participant hints, and AI signals), IntentionalTouch is lightweight — just
//  the facts needed to score a relationship.
//

import Foundation
import SwiftData

// MARK: - Supporting Enums

/// The social platform this touch originated from.
public enum TouchPlatform: String, Codable, Sendable, CaseIterable {
    case linkedIn = "linkedin"
    case facebook = "facebook"
    case twitter  = "twitter"
    case instagram = "instagram"
    case substack  = "substack"
    case manual    = "manual"

    public var displayName: String {
        switch self {
        case .linkedIn:  return "LinkedIn"
        case .facebook:  return "Facebook"
        case .twitter:   return "X / Twitter"
        case .instagram: return "Instagram"
        case .substack:  return "Substack"
        case .manual:    return "Manual"
        }
    }
}

/// The type of intentional touch.
public enum TouchType: String, Codable, Sendable, CaseIterable {
    case message                  = "message"
    case invitationPersonalized   = "invitationPersonalized"
    case invitationGeneric        = "invitationGeneric"
    case recommendationReceived   = "recommendationReceived"
    case recommendationGiven      = "recommendationGiven"
    case endorsementReceived      = "endorsementReceived"
    case endorsementGiven         = "endorsementGiven"
    case comment                  = "comment"
    case reaction                 = "reaction"
    case mention                  = "mention"
    case newsletterSubscription   = "newsletterSubscription"

    public var displayName: String {
        switch self {
        case .message:                 return "Message"
        case .invitationPersonalized:  return "Personalized Invitation"
        case .invitationGeneric:       return "Connection Request"
        case .recommendationReceived:  return "Recommendation Received"
        case .recommendationGiven:     return "Recommendation Written"
        case .endorsementReceived:     return "Endorsement Received"
        case .endorsementGiven:        return "Endorsement Given"
        case .comment:                 return "Comment"
        case .reaction:                return "Reaction"
        case .mention:                 return "Mention"
        case .newsletterSubscription:  return "Newsletter Subscription"
        }
    }

    /// The base weight for this touch type (before recency bonus).
    /// Weights from spec Section 5.1.
    public var baseWeight: Int {
        switch self {
        case .message:                 return 10
        case .invitationPersonalized:  return 8
        case .invitationGeneric:       return 2
        case .recommendationReceived:  return 15
        case .recommendationGiven:     return 15
        case .endorsementReceived:     return 5
        case .endorsementGiven:        return 5
        case .comment:                 return 6
        case .reaction:                return 3
        case .mention:                 return 4
        case .newsletterSubscription:  return 4
        }
    }
}

/// Whether the touch was initiated by the contact (inbound), by the user
/// (outbound), or is inherently mutual (e.g. a mutual endorsement exchange).
public enum TouchDirection: String, Codable, Sendable {
    case inbound  = "inbound"
    case outbound = "outbound"
    case mutual   = "mutual"
}

/// Where this touch record was created from.
public enum TouchSource: String, Codable, Sendable {
    case bulkImport        = "bulkImport"
    case emailNotification = "emailNotification"
    case manual            = "manual"
}

// MARK: - IntentionalTouch @Model

/// A single intentional touch event between the user and a contact on a social platform.
///
/// One touch per import event (e.g., each message row, each endorsement row).
/// Multiple touches per contact accumulate to produce a score.
///
/// Dedup note: The coordinator should avoid re-inserting touches from a previous
/// import for the same contact + type + date. Use `sourceImportID` to scope queries.
@Model
public final class IntentionalTouch {

    @Attribute(.unique) public var id: UUID

    /// Platform (rawValue of TouchPlatform).
    public var platformRawValue: String

    /// Touch type (rawValue of TouchType).
    public var touchTypeRawValue: String

    /// Direction (rawValue of TouchDirection).
    public var directionRawValue: String

    /// The contact's profile URL on the platform (normalized, lowercased).
    /// This is the primary key for matching touches to contacts.
    public var contactProfileUrl: String?

    /// The resolved SAM contact ID, if this touch has been attributed to a SamPerson.
    /// May be nil for Later-bucket contacts or unresolved touches from email notifications.
    public var samPersonID: UUID?

    /// When this touch occurred.
    public var date: Date

    /// Up to 200 characters of content (message snippet, endorsement skill name, etc.).
    public var snippet: String?

    /// Final computed weight (base weight × recency multiplier, rounded to Int).
    public var weight: Int

    /// Source (rawValue of TouchSource).
    public var sourceRawValue: String

    /// FK to the LinkedInImport record that produced this touch, if from a bulk import.
    public var sourceImportID: UUID?

    /// Gmail message ID, if this touch was detected from an email notification.
    public var sourceEmailID: String?

    /// When this record was inserted.
    public var createdAt: Date

    // MARK: - Transient computed wrappers

    @Transient public var platform: TouchPlatform {
        TouchPlatform(rawValue: platformRawValue) ?? .linkedIn
    }

    @Transient public var touchType: TouchType {
        TouchType(rawValue: touchTypeRawValue) ?? .message
    }

    @Transient public var direction: TouchDirection {
        TouchDirection(rawValue: directionRawValue) ?? .inbound
    }

    @Transient public var source: TouchSource {
        TouchSource(rawValue: sourceRawValue) ?? .bulkImport
    }

    // MARK: - Init

    public init(
        platform: TouchPlatform,
        touchType: TouchType,
        direction: TouchDirection,
        contactProfileUrl: String?,
        samPersonID: UUID? = nil,
        date: Date,
        snippet: String? = nil,
        weight: Int,
        source: TouchSource,
        sourceImportID: UUID? = nil,
        sourceEmailID: String? = nil
    ) {
        self.id = UUID()
        self.platformRawValue = platform.rawValue
        self.touchTypeRawValue = touchType.rawValue
        self.directionRawValue = direction.rawValue
        self.contactProfileUrl = contactProfileUrl
        self.samPersonID = samPersonID
        self.date = date
        self.snippet = snippet
        self.weight = weight
        self.sourceRawValue = source.rawValue
        self.sourceImportID = sourceImportID
        self.sourceEmailID = sourceEmailID
        self.createdAt = Date()
    }
}

// MARK: - IntentionalTouchScore DTO

/// Aggregated touch score for a single contact profile URL.
/// Computed in-memory from IntentionalTouch records or from pending parsed data;
/// not stored in SwiftData directly.
public struct IntentionalTouchScore: Sendable {
    public let contactProfileUrl: String
    public let totalScore: Int
    public let touchCount: Int
    public let mostRecentTouch: Date?
    public let touchTypes: Set<String>        // TouchType.rawValue strings
    public let hasDirectMessage: Bool
    public let hasRecommendation: Bool

    /// Human-readable summary for the import review UI.
    /// E.g. "12 messages, 1 recommendation, 2 endorsements"
    public var touchSummary: String {
        var parts: [String] = []

        let messageCount = _countForTypes([.message])
        if messageCount > 0 {
            parts.append("\(messageCount) message\(messageCount == 1 ? "" : "s")")
        }

        let recCount = _countForTypes([.recommendationReceived, .recommendationGiven])
        if recCount > 0 {
            parts.append("\(recCount) recommendation\(recCount == 1 ? "" : "s")")
        }

        let endorseCount = _countForTypes([.endorsementReceived, .endorsementGiven])
        if endorseCount > 0 {
            parts.append("\(endorseCount) endorsement\(endorseCount == 1 ? "" : "s")")
        }

        let invCount = _countForTypes([.invitationPersonalized, .invitationGeneric])
        if invCount > 0 {
            parts.append("\(invCount) invitation\(invCount == 1 ? "" : "s")")
        }

        let commentCount = _countForTypes([.comment])
        if commentCount > 0 {
            parts.append("\(commentCount) comment\(commentCount == 1 ? "" : "s")")
        }

        return parts.isEmpty ? "No interactions" : parts.joined(separator: ", ")
    }

    // The raw per-type counts used to build the summary.
    private let typeCounts: [String: Int]

    private func _countForTypes(_ types: [TouchType]) -> Int {
        types.reduce(0) { $0 + (typeCounts[$1.rawValue] ?? 0) }
    }

    public init(
        contactProfileUrl: String,
        totalScore: Int,
        touchCount: Int,
        mostRecentTouch: Date?,
        touchTypes: Set<String>,
        hasDirectMessage: Bool,
        hasRecommendation: Bool,
        typeCounts: [String: Int]
    ) {
        self.contactProfileUrl = contactProfileUrl
        self.totalScore = totalScore
        self.touchCount = touchCount
        self.mostRecentTouch = mostRecentTouch
        self.touchTypes = touchTypes
        self.hasDirectMessage = hasDirectMessage
        self.hasRecommendation = hasRecommendation
        self.typeCounts = typeCounts
    }
}

// MARK: - Touch Scoring Engine (pure Swift, no LLM)

/// Computes IntentionalTouchScore values from raw parsed DTO arrays.
/// All numerical computation stays in Swift per architecture guidelines.
public enum TouchScoringEngine {

    /// Recency cutoff for the 1.5x bonus (spec Section 5.2).
    private static let recencyMonths: Int = 6

    /// Compute scores for all profile URLs found in the provided touch arrays.
    /// Returns a dictionary keyed by normalized profile URL.
    public static func computeScores(
        messages:                 [(profileURL: String, direction: TouchDirection, date: Date, snippet: String?)],
        invitations:              [(profileURL: String, isPersonalized: Bool, date: Date)],
        endorsementsReceived:     [(profileURL: String, date: Date?, skillName: String?)],
        endorsementsGiven:        [(profileURL: String, date: Date?, skillName: String?)],
        recommendationsReceived:  [(profileURL: String, date: Date?)],
        recommendationsGiven:     [(profileURL: String, date: Date?)],
        reactions:                [(profileURL: String?, date: Date)],
        comments:                 [(profileURL: String?, date: Date)]
    ) -> [String: IntentionalTouchScore] {

        let cutoff = Calendar.current.date(byAdding: .month, value: -recencyMonths, to: Date())!

        // Accumulate per-profile data
        var scoreAccumulator: [String: (
            totalScore: Double,
            touchCount: Int,
            mostRecent: Date?,
            types: Set<String>,
            typeCounts: [String: Int],
            hasMessage: Bool,
            hasRecommendation: Bool
        )] = [:]

        func addTouch(profileURL: String, type: TouchType, direction: TouchDirection, date: Date?) {
            let url = profileURL.lowercased()
            guard !url.isEmpty else { return }

            let base = Double(type.baseWeight)
            let date = date ?? Date.distantPast
            let multiplier: Double = date > cutoff ? 1.5 : 1.0
            let weight = base * multiplier

            if scoreAccumulator[url] == nil {
                scoreAccumulator[url] = (0, 0, nil, [], [:], false, false)
            }

            scoreAccumulator[url]!.totalScore += weight
            scoreAccumulator[url]!.touchCount += 1
            scoreAccumulator[url]!.types.insert(type.rawValue)
            scoreAccumulator[url]!.typeCounts[type.rawValue, default: 0] += 1

            if scoreAccumulator[url]!.mostRecent == nil || date > scoreAccumulator[url]!.mostRecent! {
                scoreAccumulator[url]!.mostRecent = date
            }
            if type == .message {
                scoreAccumulator[url]!.hasMessage = true
            }
            if type == .recommendationReceived || type == .recommendationGiven {
                scoreAccumulator[url]!.hasRecommendation = true
            }
        }

        for m in messages {
            addTouch(profileURL: m.profileURL, type: .message, direction: m.direction, date: m.date)
        }
        for i in invitations {
            let t: TouchType = i.isPersonalized ? .invitationPersonalized : .invitationGeneric
            addTouch(profileURL: i.profileURL, type: t, direction: .inbound, date: i.date)
        }
        for e in endorsementsReceived {
            addTouch(profileURL: e.profileURL, type: .endorsementReceived, direction: .inbound, date: e.date)
        }
        for e in endorsementsGiven {
            addTouch(profileURL: e.profileURL, type: .endorsementGiven, direction: .outbound, date: e.date)
        }
        for r in recommendationsReceived {
            addTouch(profileURL: r.profileURL, type: .recommendationReceived, direction: .inbound, date: r.date)
        }
        for r in recommendationsGiven {
            addTouch(profileURL: r.profileURL, type: .recommendationGiven, direction: .outbound, date: r.date)
        }
        for r in reactions {
            guard let url = r.profileURL else { continue }
            addTouch(profileURL: url, type: .reaction, direction: .outbound, date: r.date)
        }
        for c in comments {
            guard let url = c.profileURL else { continue }
            addTouch(profileURL: url, type: .comment, direction: .outbound, date: c.date)
        }

        // Convert accumulators to IntentionalTouchScore
        var result: [String: IntentionalTouchScore] = [:]
        for (url, acc) in scoreAccumulator {
            result[url] = IntentionalTouchScore(
                contactProfileUrl: url,
                totalScore: Int(acc.totalScore.rounded()),
                touchCount: acc.touchCount,
                mostRecentTouch: acc.mostRecent,
                touchTypes: acc.types,
                hasDirectMessage: acc.hasMessage,
                hasRecommendation: acc.hasRecommendation,
                typeCounts: acc.typeCounts
            )
        }
        return result
    }
}
