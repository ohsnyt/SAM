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
nonisolated public struct UserFacebookProfileDTO: Codable, Sendable {

    public var fullName: String
    public var firstName: String
    public var lastName: String
    public var currentCity: String?
    public var hometown: String?
    public var birthday: Birthday?
    public var relationship: Relationship?
    public var familyMembers: [FamilyMember]
    public var workExperiences: [WorkExperience]
    public var educationExperiences: [EducationExperience]
    public var websites: [String]
    public var profileUri: String?

    /// AI-generated 1-2 sentence writing voice analysis from user posts.
    public var writingVoiceSummary: String
    /// Last 5 post texts (up to 500 chars each) for voice re-analysis.
    public var recentPostSnippets: [String]

    public init(
        fullName: String,
        firstName: String,
        lastName: String,
        currentCity: String? = nil,
        hometown: String? = nil,
        birthday: Birthday? = nil,
        relationship: Relationship? = nil,
        familyMembers: [FamilyMember] = [],
        workExperiences: [WorkExperience] = [],
        educationExperiences: [EducationExperience] = [],
        websites: [String] = [],
        profileUri: String? = nil,
        writingVoiceSummary: String = "",
        recentPostSnippets: [String] = []
    ) {
        self.fullName = fullName
        self.firstName = firstName
        self.lastName = lastName
        self.currentCity = currentCity
        self.hometown = hometown
        self.birthday = birthday
        self.relationship = relationship
        self.familyMembers = familyMembers
        self.workExperiences = workExperiences
        self.educationExperiences = educationExperiences
        self.websites = websites
        self.profileUri = profileUri
        self.writingVoiceSummary = writingVoiceSummary
        self.recentPostSnippets = recentPostSnippets
    }

    // MARK: - Nested Types

    public struct Birthday: Codable, Sendable {
        public let year: Int
        public let month: Int
        public let day: Int
    }

    public struct Relationship: Codable, Sendable {
        public let status: String
        public let partner: String?
    }

    public struct FamilyMember: Codable, Sendable {
        public let name: String
        public let relation: String
    }

    public struct WorkExperience: Codable, Sendable {
        public let employer: String
        public let title: String?
        public let location: String?
    }

    public struct EducationExperience: Codable, Sendable {
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
        if !writingVoiceSummary.isEmpty {
            let truncated = writingVoiceSummary.count > 200
                ? String(writingVoiceSummary.prefix(200)) + "…"
                : writingVoiceSummary
            lines.append("Writing voice: \(truncated)")
        }

        return lines.joined(separator: "\n")
    }
}
