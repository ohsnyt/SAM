//
//  SAMModels-PersonFiltering.swift
//  SAM
//
//  SamPerson signal-quality helpers used to gate costly inference (role
//  deduction, relationship graph rendering, people list, etc.) and to
//  bucket no-signal contacts by their origin so the user can audit what's
//  noise.
//

import Foundation

extension SamPerson {

    /// Returns true if there is meaningful signal beyond raw social-network
    /// connections. People who fail this check are typically LinkedIn /
    /// Facebook auto-imports (or stale Apple Contacts entries) with no real
    /// interaction history. Used to short-circuit costly inference passes.
    ///
    /// Deliberately excluded: `linkedInConnectedOn`, `facebookFriendedOn`.
    /// A bare connection or friend-add carries no relationship signal — it's
    /// the exact noise we're filtering. `facebookMessageCount > 0` *is*
    /// counted because that represents an actual conversation.
    public var hasMeaningfulSignal: Bool {
        !linkedEvidence.isEmpty
            || !linkedNotes.isEmpty
            || !roleBadges.isEmpty
            || !stageTransitions.isEmpty
            || !recruitingStages.isEmpty
            || !productionRecords.isEmpty
            || !participations.isEmpty
            || facebookMessageCount > 0
    }

    /// Origin attribution for contacts that fall through `hasMeaningfulSignal`.
    /// Lets the UI render an "Inactive contacts" aggregator broken down by
    /// where the noise came from. Multiple origins can be true for one
    /// person (e.g., a LinkedIn connection who's also in Apple Contacts);
    /// `noSignalBucket` resolves that by priority.
    public enum NoSignalBucket: String, CaseIterable, Sendable {
        case appleContacts = "Apple Contacts"
        case linkedIn = "LinkedIn"
        case facebook = "Facebook"
        case notes = "Notes"
        case other = "Other"
    }

    /// Categorizes the origin of a no-signal contact. Priority order:
    /// Apple Contacts → LinkedIn → Facebook → Notes (ghost) → Other.
    /// Defined for all people, but only meaningful when
    /// `hasMeaningfulSignal == false`; callers should gate accordingly.
    public var noSignalBucket: NoSignalBucket {
        if contactIdentifier != nil { return .appleContacts }
        if linkedInConnectedOn != nil { return .linkedIn }
        if facebookFriendedOn != nil { return .facebook }
        if !familyReferences.isEmpty { return .notes }
        return .other
    }
}
