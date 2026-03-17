//
//  UserLinkedInProfileDTO.swift
//  SAM
//
//  Data Transfer Objects for the user's own LinkedIn profile data.
//  Parsed from LinkedIn archive CSVs and stored in BusinessProfileService
//  to enrich AI coaching context.
//

import Foundation

// MARK: - Top-level user profile

/// The user's own LinkedIn profile, assembled from multiple CSV files.
nonisolated public struct UserLinkedInProfileDTO: Codable, Sendable {
    public var firstName: String
    public var lastName: String
    public var headline: String
    public var summary: String
    public var industry: String
    public var geoLocation: String

    public var positions: [LinkedInPositionDTO]
    public var education: [LinkedInEducationDTO]
    public var skills: [String]
    public var certifications: [LinkedInCertificationDTO]

    /// AI-generated 1-2 sentence writing voice analysis from share comments.
    public var writingVoiceSummary: String
    /// Last 5 share comments (up to 500 chars each) for voice re-analysis.
    public var recentShareSnippets: [String]

    public init(
        firstName: String = "",
        lastName: String = "",
        headline: String = "",
        summary: String = "",
        industry: String = "",
        geoLocation: String = "",
        positions: [LinkedInPositionDTO] = [],
        education: [LinkedInEducationDTO] = [],
        skills: [String] = [],
        certifications: [LinkedInCertificationDTO] = [],
        writingVoiceSummary: String = "",
        recentShareSnippets: [String] = []
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.headline = headline
        self.summary = summary
        self.industry = industry
        self.geoLocation = geoLocation
        self.positions = positions
        self.education = education
        self.skills = skills
        self.certifications = certifications
        self.writingVoiceSummary = writingVoiceSummary
        self.recentShareSnippets = recentShareSnippets
    }

    /// The most recent position (started most recently, or no finish date).
    public var currentPosition: LinkedInPositionDTO? {
        positions.first(where: { $0.isCurrent }) ?? positions.first
    }

    /// A compact coaching context fragment for injection into AI system prompts.
    public var coachingContextFragment: String {
        var lines: [String] = []

        if !headline.isEmpty {
            lines.append("LinkedIn headline: \(headline)")
        }
        if let current = currentPosition {
            lines.append("Current role: \(current.title) at \(current.companyName)")
        }
        if !industry.isEmpty {
            lines.append("Industry: \(industry)")
        }
        if !geoLocation.isEmpty {
            lines.append("Location: \(geoLocation)")
        }
        if !certifications.isEmpty {
            let certs = certifications.map { "\($0.name) (\($0.authority))" }.joined(separator: ", ")
            lines.append("Certifications: \(certs)")
        }
        let recentSkills = skills.prefix(10)
        if !recentSkills.isEmpty {
            lines.append("Skills: \(recentSkills.joined(separator: ", "))")
        }
        if !summary.isEmpty {
            // Truncate to ~300 chars
            let truncated = summary.count > 300 ? String(summary.prefix(300)) + "…" : summary
            lines.append("LinkedIn summary: \(truncated)")
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

// MARK: - Position

nonisolated public struct LinkedInPositionDTO: Codable, Sendable {
    public var companyName: String
    public var title: String
    public var description: String
    public var location: String
    public var startedOn: String       // Raw string from CSV e.g. "Aug 2021"
    public var finishedOn: String      // Empty string = current

    public var isCurrent: Bool { finishedOn.isEmpty }

    public init(
        companyName: String,
        title: String,
        description: String = "",
        location: String = "",
        startedOn: String = "",
        finishedOn: String = ""
    ) {
        self.companyName = companyName
        self.title = title
        self.description = description
        self.location = location
        self.startedOn = startedOn
        self.finishedOn = finishedOn
    }
}

// MARK: - Education

nonisolated public struct LinkedInEducationDTO: Codable, Sendable {
    public var schoolName: String
    public var startDate: String
    public var endDate: String
    public var notes: String
    public var degreeName: String
    public var activities: String

    public init(
        schoolName: String,
        startDate: String = "",
        endDate: String = "",
        notes: String = "",
        degreeName: String = "",
        activities: String = ""
    ) {
        self.schoolName = schoolName
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.degreeName = degreeName
        self.activities = activities
    }
}

// MARK: - Certification

nonisolated public struct LinkedInCertificationDTO: Codable, Sendable {
    public var name: String
    public var url: String
    public var authority: String
    public var startedOn: String
    public var finishedOn: String
    public var licenseNumber: String

    public init(
        name: String,
        url: String = "",
        authority: String = "",
        startedOn: String = "",
        finishedOn: String = "",
        licenseNumber: String = ""
    ) {
        self.name = name
        self.url = url
        self.authority = authority
        self.startedOn = startedOn
        self.finishedOn = finishedOn
        self.licenseNumber = licenseNumber
    }
}
