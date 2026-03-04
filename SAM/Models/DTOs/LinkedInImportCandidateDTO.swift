//
//  LinkedInImportCandidateDTO.swift
//  SAM
//
//  Data transfer objects for the LinkedIn import review UI.
//  These are Sendable structs that cross the actor boundary between
//  LinkedInImportCoordinator and the SwiftUI review sheet.
//

import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Import Candidate
// ─────────────────────────────────────────────────────────────────────

/// A single LinkedIn connection candidate presented in the import review sheet.
/// Carries enough information for the user to decide Add / Merge / Later.
public struct LinkedInImportCandidate: Sendable, Identifiable {
    public let id: UUID
    public let firstName: String
    public let lastName: String
    public var fullName: String { "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces) }

    public let profileURL: String
    public let email: String?
    public let company: String?
    public let position: String?
    public let connectedOn: Date?

    public let touchScore: IntentionalTouchScore?
    public let matchStatus: LinkedInMatchStatus
    /// The UI default for this contact (may be overridden by the user).
    public let defaultClassification: LinkedInClassification

    /// When matchStatus is a probable match, carries info about the existing
    /// SamPerson for side-by-side comparison in the review sheet.
    public let matchedPersonInfo: MatchedPersonInfo?

    public init(
        id: UUID = UUID(),
        firstName: String,
        lastName: String,
        profileURL: String,
        email: String? = nil,
        company: String? = nil,
        position: String? = nil,
        connectedOn: Date? = nil,
        touchScore: IntentionalTouchScore? = nil,
        matchStatus: LinkedInMatchStatus,
        defaultClassification: LinkedInClassification,
        matchedPersonInfo: MatchedPersonInfo? = nil
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.profileURL = profileURL
        self.email = email
        self.company = company
        self.position = position
        self.connectedOn = connectedOn
        self.touchScore = touchScore
        self.matchStatus = matchStatus
        self.defaultClassification = defaultClassification
        self.matchedPersonInfo = matchedPersonInfo
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Matched Person Info
// ─────────────────────────────────────────────────────────────────────

/// Lightweight snapshot of an existing SamPerson for display in the probable-match
/// side-by-side comparison UI. Deliberately minimal — only what the view needs.
public struct MatchedPersonInfo: Sendable {
    public let personID: UUID
    public let displayName: String
    public let email: String?
    public let company: String?
    public let position: String?
    public let linkedInURL: String?

    public init(
        personID: UUID,
        displayName: String,
        email: String? = nil,
        company: String? = nil,
        position: String? = nil,
        linkedInURL: String? = nil
    ) {
        self.personID = personID
        self.displayName = displayName
        self.email = email
        self.company = company
        self.position = position
        self.linkedInURL = linkedInURL
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Match Status
// ─────────────────────────────────────────────────────────────────────

/// How a LinkedIn connection was matched (or not) against existing SAM data.
/// Priority order matches the spec (Section 7).
public enum LinkedInMatchStatus: String, Sendable, Codable {
    /// Priority 1: Matched by LinkedIn profile URL stored on a SamPerson.
    case exactMatchURL
    /// Priority 2: Matched by LinkedIn URL found in Apple Contacts social profiles / URL fields.
    case exactMatchAppleContact
    /// Priority 3: Matched by email address (requires user confirmation).
    case probableMatchEmail
    /// Priority 4: Matched by accent-normalized name + fuzzy company (requires user confirmation).
    case probableMatchNameCompany
    /// No match found — new contact candidate.
    case noMatch

    /// True if this is a high-confidence match that can be silently enriched.
    public var isExact: Bool {
        self == .exactMatchURL || self == .exactMatchAppleContact
    }

    /// True if user confirmation is required before merging.
    public var isProbable: Bool {
        self == .probableMatchEmail || self == .probableMatchNameCompany
    }

    /// Human-readable reason shown in the probable-match comparison UI.
    public var matchReason: String {
        switch self {
        case .exactMatchURL:            return "Matched by LinkedIn URL"
        case .exactMatchAppleContact:   return "Matched via Apple Contacts LinkedIn URL"
        case .probableMatchEmail:       return "Matched by email address"
        case .probableMatchNameCompany: return "Matched by name and company"
        case .noMatch:                  return ""
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Classification
// ─────────────────────────────────────────────────────────────────────

/// User's intent for a LinkedIn connection in the import review.
public enum LinkedInClassification: String, Sendable, Codable {
    /// Create an Apple Contact and SamPerson record for this connection.
    case add
    /// Store in the UnknownSender triage queue for later review.
    case later
    /// Merge LinkedIn data into the existing matched SamPerson (probable match accepted).
    case merge
    /// Keep separate — user rejected the probable match; treat as a new contact.
    case skip
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Apple Contacts Sync Candidate (§13)
// ─────────────────────────────────────────────────────────────────────

/// An "Add" candidate whose Apple Contact does not yet have a LinkedIn URL.
/// Carries the minimum data needed to write the URL back to Apple Contacts.
public struct AppleContactsSyncCandidate: Sendable, Identifiable {
    public let id: UUID
    /// Display name for UI presentation.
    public let displayName: String
    /// Apple Contacts `CNContact.identifier` to update.
    public let appleContactIdentifier: String
    /// The LinkedIn profile URL to write into the Apple Contact's social profiles.
    public let linkedInProfileURL: String

    public init(
        id: UUID = UUID(),
        displayName: String,
        appleContactIdentifier: String,
        linkedInProfileURL: String
    ) {
        self.id = id
        self.displayName = displayName
        self.appleContactIdentifier = appleContactIdentifier
        self.linkedInProfileURL = linkedInProfileURL
    }
}
