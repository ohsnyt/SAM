//
//  UserSubstackProfileDTO.swift
//  SAM
//
//  Data Transfer Object for the user's own Substack publication data.
//  Parsed from RSS feed and stored in BusinessProfileService
//  to enrich AI coaching context.
//

import Foundation

/// The user's Substack publication profile, assembled from RSS feed data.
public struct UserSubstackProfileDTO: Codable, Sendable {
    public var publicationName: String
    public var publicationDescription: String
    public var authorName: String
    public var feedURL: String
    public var totalPosts: Int
    public var topicSummary: [String]
    public var writingVoiceSummary: String
    public var lastFetchDate: Date
    public var recentPostTitles: [RecentPost]

    public struct RecentPost: Codable, Sendable {
        public var title: String
        public var date: Date

        public init(title: String, date: Date) {
            self.title = title
            self.date = date
        }
    }

    public init(
        publicationName: String = "",
        publicationDescription: String = "",
        authorName: String = "",
        feedURL: String = "",
        totalPosts: Int = 0,
        topicSummary: [String] = [],
        writingVoiceSummary: String = "",
        lastFetchDate: Date = .now,
        recentPostTitles: [RecentPost] = []
    ) {
        self.publicationName = publicationName
        self.publicationDescription = publicationDescription
        self.authorName = authorName
        self.feedURL = feedURL
        self.totalPosts = totalPosts
        self.topicSummary = topicSummary
        self.writingVoiceSummary = writingVoiceSummary
        self.lastFetchDate = lastFetchDate
        self.recentPostTitles = recentPostTitles
    }

    /// A compact coaching context fragment for injection into AI system prompts.
    public var coachingContextFragment: String {
        var lines: [String] = []

        if !publicationName.isEmpty {
            lines.append("Substack publication: \"\(publicationName)\" (\(totalPosts) posts)")
        }
        if !publicationDescription.isEmpty {
            let truncated = publicationDescription.count > 200
                ? String(publicationDescription.prefix(200)) + "…"
                : publicationDescription
            lines.append("Publication focus: \(truncated)")
        }
        if !topicSummary.isEmpty {
            lines.append("Core topics: \(topicSummary.joined(separator: ", "))")
        }
        if !writingVoiceSummary.isEmpty {
            let truncated = writingVoiceSummary.count > 200
                ? String(writingVoiceSummary.prefix(200)) + "…"
                : writingVoiceSummary
            lines.append("Writing voice: \(truncated)")
        }
        if !recentPostTitles.isEmpty {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            let recent = recentPostTitles.prefix(3).map { "\"\($0.title)\" (\(formatter.string(from: $0.date)))" }
            lines.append("Recent articles: \(recent.joined(separator: "; "))")
        }

        return lines.joined(separator: "\n")
    }
}
