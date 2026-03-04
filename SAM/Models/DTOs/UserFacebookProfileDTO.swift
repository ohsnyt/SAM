//
//  UserFacebookProfileDTO.swift
//  SAM
//
//  Phase FB-1: Data transfer object for the user's own Facebook profile.
//  Parsed from personal_information/profile_information/profile_information.json.
//
//  Mirrors UserLinkedInProfileDTO.swift architecture.
//

import Foundation

/// The user's own Facebook profile data, extracted from the data export.
/// Used for the Facebook Profile Analysis Agent and cross-platform consistency checks.
public struct UserFacebookProfileDTO: Sendable {

    public let fullName: String
    public let firstName: String
    public let lastName: String
    public let currentCity: String?
    public let hometown: String?
    public let birthday: Birthday?
    public let relationship: Relationship?
    public let familyMembers: [FamilyMember]
    public let workExperiences: [WorkExperience]
    public let educationExperiences: [EducationExperience]
    public let websites: [String]
    public let profileUri: String?

    // MARK: - Nested Types

    public struct Birthday: Sendable {
        public let year: Int
        public let month: Int
        public let day: Int
    }

    public struct Relationship: Sendable {
        public let status: String
        public let partner: String?
    }

    public struct FamilyMember: Sendable {
        public let name: String
        public let relation: String
    }

    public struct WorkExperience: Sendable {
        public let employer: String
        public let title: String?
        public let location: String?
    }

    public struct EducationExperience: Sendable {
        public let name: String
        public let schoolType: String?
        public let concentrations: [String]
    }

    // MARK: - Coaching Context

    /// Generates a text fragment for injection into AI coaching prompts.
    /// Provides the AI with the user's Facebook profile context.
    public var coachingContextFragment: String {
        var lines: [String] = []
        lines.append("## Facebook Profile")
        lines.append("Name: \(fullName)")

        if let city = currentCity {
            lines.append("Location: \(city)")
        }
        if let hometown = hometown {
            lines.append("Hometown: \(hometown)")
        }

        if !workExperiences.isEmpty {
            lines.append("Work:")
            for w in workExperiences {
                var parts = [w.employer]
                if let t = w.title { parts.insert(t + " at", at: 0) }
                if let l = w.location { parts.append("(\(l))") }
                lines.append("  - \(parts.joined(separator: " "))")
            }
        }

        if !educationExperiences.isEmpty {
            lines.append("Education:")
            for e in educationExperiences {
                var desc = e.name
                if let t = e.schoolType { desc += " (\(t))" }
                if !e.concentrations.isEmpty { desc += " — \(e.concentrations.joined(separator: ", "))" }
                lines.append("  - \(desc)")
            }
        }

        if let r = relationship {
            var desc = r.status
            if let partner = r.partner { desc += " to \(partner)" }
            lines.append("Relationship: \(desc)")
        }

        if !familyMembers.isEmpty {
            lines.append("Family: \(familyMembers.map { "\($0.name) (\($0.relation))" }.joined(separator: ", "))")
        }

        if !websites.isEmpty {
            lines.append("Websites: \(websites.joined(separator: ", "))")
        }

        if let uri = profileUri {
            lines.append("Profile URL: \(uri)")
        }

        return lines.joined(separator: "\n")
    }
}
