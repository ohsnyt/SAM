//
//  FacebookImportCandidateDTO.swift
//  SAM
//
//  Phase FB-1: Data transfer objects for the Facebook import review UI.
//  These are Sendable structs that cross the actor boundary between
//  FacebookImportCoordinator and the SwiftUI review sheet.
//
//  Mirrors LinkedInImportCandidateDTO.swift architecture.
//

import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Import Candidate
// ─────────────────────────────────────────────────────────────────────

/// A single Facebook friend candidate presented in the import review sheet.
/// Carries enough information for the user to decide Add / Merge / Later.
public struct FacebookImportCandidate: Sendable, Identifiable {
    public let id: UUID
    /// Display name from Facebook (single string — Facebook doesn't split first/last in the friends list).
    public let displayName: String

    public let friendedOn: Date?
    /// Messenger thread directory name suffix (e.g., "ruthsnyder_10153029279158403").
    public let messengerThreadId: String?
    /// Total messages exchanged across all threads with this person.
    public let messageCount: Int
    /// Most recent message timestamp.
    public let lastMessageDate: Date?

    public let touchScore: IntentionalTouchScore?
    public let matchStatus: FacebookMatchStatus
    /// The UI default for this contact (may be overridden by the user).
    public let defaultClassification: FacebookClassification

    /// When matchStatus is a probable match, carries info about the existing
    /// SamPerson for side-by-side comparison in the review sheet.
    public let matchedPersonInfo: MatchedPersonInfo?

    public init(
        id: UUID = UUID(),
        displayName: String,
        friendedOn: Date? = nil,
        messengerThreadId: String? = nil,
        messageCount: Int = 0,
        lastMessageDate: Date? = nil,
        touchScore: IntentionalTouchScore? = nil,
        matchStatus: FacebookMatchStatus,
        defaultClassification: FacebookClassification,
        matchedPersonInfo: MatchedPersonInfo? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.friendedOn = friendedOn
        self.messengerThreadId = messengerThreadId
        self.messageCount = messageCount
        self.lastMessageDate = lastMessageDate
        self.touchScore = touchScore
        self.matchStatus = matchStatus
        self.defaultClassification = defaultClassification
        self.matchedPersonInfo = matchedPersonInfo
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Match Status
// ─────────────────────────────────────────────────────────────────────

/// How a Facebook friend was matched (or not) against existing SAM data.
/// Priority order matches the Facebook Integration Spec (Section 7).
public enum FacebookMatchStatus: String, Sendable, Codable {
    /// Priority 1: Matched by Facebook profile URL stored on a SamPerson.
    case exactMatchFacebookURL
    /// Priority 2: Matched by name + Facebook social profile URL found in Apple Contacts.
    case probableMatchAppleContact
    /// Priority 3: Cross-platform match — name matches a SamPerson with LinkedIn data.
    case probableMatchCrossPlatform
    /// Priority 4: Fuzzy name-only match against existing SamPerson records.
    case probableMatchName
    /// No match found — new contact candidate.
    case noMatch

    /// True if this is a high-confidence match that can be silently enriched.
    public var isExact: Bool {
        self == .exactMatchFacebookURL
    }

    /// True if user confirmation is required before merging.
    public var isProbable: Bool {
        switch self {
        case .probableMatchAppleContact, .probableMatchCrossPlatform, .probableMatchName:
            return true
        default:
            return false
        }
    }

    /// Human-readable reason shown in the probable-match comparison UI.
    public var matchReason: String {
        switch self {
        case .exactMatchFacebookURL:       return "Matched by Facebook URL"
        case .probableMatchAppleContact:   return "Matched via Apple Contacts"
        case .probableMatchCrossPlatform:  return "Name matches a LinkedIn connection"
        case .probableMatchName:           return "Matched by name"
        case .noMatch:                     return ""
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Classification
// ─────────────────────────────────────────────────────────────────────

/// User's intent for a Facebook friend in the import review.
public enum FacebookClassification: String, Sendable, Codable {
    /// Create a standalone SamPerson record for this friend.
    case add
    /// Store in the UnknownSender triage queue for later review.
    case later
    /// Merge Facebook data into the existing matched SamPerson (probable match accepted).
    case merge
    /// Keep separate — user rejected the probable match; treat as a new contact.
    case skip
}
