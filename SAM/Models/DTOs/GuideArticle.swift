//
//  GuideArticle.swift
//  SAM
//
//  Help & Training System — Guide content models
//

import Foundation

// MARK: - Guide Article

struct GuideArticle: Identifiable, Codable, Sendable {
    /// Dot-separated ID, e.g. "events.creating"
    let id: String
    let title: String
    /// Section this article belongs to, e.g. "events"
    let sectionID: String
    let sortOrder: Int
    /// File name within the section folder, e.g. "01-Creating-an-Event.md"
    let markdownFileName: String
    /// Extra keywords for search beyond the title
    let searchKeywords: [String]
    /// Maps back to a TipKit tip ID for cross-referencing
    let relatedTipID: String?
    /// Maps to a FeatureAdoptionTracker.Feature for cross-referencing
    let relatedFeatureID: String?
}

// MARK: - Guide Section

struct GuideSection: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    /// SF Symbol name
    let icon: String
    let sortOrder: Int
}

// MARK: - Guide Manifest

struct GuideManifest: Codable, Sendable {
    let sections: [GuideSection]
    let articles: [GuideArticle]
}
