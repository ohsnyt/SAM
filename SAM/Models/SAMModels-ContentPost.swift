//
//  SAMModels-ContentPost.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase W: Content Assist & Social Media Coaching
//
//  Lightweight model for tracking posted social media content.
//  Uses UUID reference (not @Relationship) to source outcome.
//

import SwiftData
import Foundation
import SwiftUI

// MARK: - ContentPlatform

/// Social media platforms for content posting.
public enum ContentPlatform: String, Codable, Sendable, CaseIterable {
    case linkedin  = "LinkedIn"
    case facebook  = "Facebook"
    case instagram = "Instagram"
    case other     = "Other"

    /// Display color for badges and charts.
    public var color: Color {
        switch self {
        case .linkedin:  return .blue
        case .facebook:  return .indigo
        case .instagram: return .pink
        case .other:     return .secondary
        }
    }

    /// SF Symbol icon.
    public var icon: String {
        switch self {
        case .linkedin:  return "link.circle.fill"
        case .facebook:  return "person.2.circle.fill"
        case .instagram: return "camera.circle.fill"
        case .other:     return "globe"
        }
    }
}

// MARK: - ContentPost

/// A single logged social media post, tracking platform, topic, and when it was posted.
///
/// Uses UUID reference (`sourceOutcomeID`) instead of `@Relationship` to avoid
/// requiring inverses on SamOutcome.
@Model
public final class ContentPost {
    @Attribute(.unique) public var id: UUID

    /// Raw storage for ContentPlatform enum.
    public var platformRawValue: String

    /// Typed platform accessor.
    @Transient
    public var platform: ContentPlatform {
        get { ContentPlatform(rawValue: platformRawValue) ?? .other }
        set { platformRawValue = newValue.rawValue }
    }

    /// Topic or title of the posted content.
    public var topic: String

    /// When the content was posted.
    public var postedAt: Date

    /// Optional link back to the outcome that prompted this post.
    public var sourceOutcomeID: UUID?

    /// When this record was created.
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        platform: ContentPlatform,
        topic: String,
        postedAt: Date = .now,
        sourceOutcomeID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.platformRawValue = platform.rawValue
        self.topic = topic
        self.postedAt = postedAt
        self.sourceOutcomeID = sourceOutcomeID
        self.createdAt = createdAt
    }
}
