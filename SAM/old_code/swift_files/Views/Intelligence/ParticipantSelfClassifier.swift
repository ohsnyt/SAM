import Foundation

/// Represents the role of a participant relative to the user.
public enum ParticipantRole {
    /// The participant is the user themself.
    case selfUser
    /// The participant is external to the user.
    case external
}

/// Utility for classifying participants with respect to the user (self).
public struct ParticipantSelfClassifier {
    /// Determines if a given email belongs to the user (self).
    ///
    /// - Parameters:
    ///   - email: The email to check.
    ///   - selfEmails: A list of emails representing the user.
    /// - Returns: True if the email matches one of the user emails after normalization.
    public static func isSelf(email: String, selfEmails: [String]) -> Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSelfEmails = selfEmails.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return normalizedSelfEmails.contains(normalizedEmail)
    }
    
    /// Classifies a list of emails as either belonging to the user (self) or external participants.
    ///
    /// - Parameters:
    ///   - emails: The list of emails to classify.
    ///   - selfEmails: A list of emails representing the user.
    /// - Returns: A dictionary mapping each normalized email to its `ParticipantRole`.
    public static func classify(emails: [String], selfEmails: [String]) -> [String: ParticipantRole] {
        let normalizedSelfEmails = Set(selfEmails.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        
        var classification: [String: ParticipantRole] = [:]
        for email in emails {
            let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            classification[normalizedEmail] = normalizedSelfEmails.contains(normalizedEmail) ? .selfUser : .external
        }
        return classification
    }
}
