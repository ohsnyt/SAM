//
//  GuideContentService.swift
//  SAM
//
//  Help & Training System — Guide content loading, search, and navigation state
//

import Foundation
import os.log

@MainActor
@Observable
final class GuideContentService: @unchecked Sendable {

    static let shared = GuideContentService()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "GuideContent")

    // MARK: - Navigation State (shared for deep-linking)

    var selectedArticleID: String?
    var selectedSectionID: String?

    // MARK: - Data

    private(set) var sections: [GuideSection] = []
    private(set) var articles: [GuideArticle] = []

    /// In-memory search index: article ID → lowercased searchable text
    private var searchIndex: [String: String] = [:]

    // MARK: - Init

    private init() {
        loadManifest()
        buildSearchIndex()
    }

    // MARK: - Public API

    func article(id: String) -> GuideArticle? {
        articles.first { $0.id == id }
    }

    func articles(inSection sectionID: String) -> [GuideArticle] {
        articles
            .filter { $0.sectionID == sectionID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func search(query: String) -> [GuideArticle] {
        guard !query.isEmpty else { return [] }
        let lowered = query.lowercased()
        let terms = lowered.split(separator: " ").map(String.init)

        return articles.filter { article in
            guard let indexed = searchIndex[article.id] else { return false }
            return terms.allSatisfy { indexed.contains($0) }
        }
    }

    func markdownBody(for article: GuideArticle) -> String {
        let baseName = article.markdownFileName.replacingOccurrences(of: ".md", with: "")

        // Try subdirectory path first (folder references), then flat (Xcode groups)
        let url = Bundle.main.url(forResource: baseName, withExtension: "md", subdirectory: "Guide/\(article.sectionID)")
            ?? Bundle.main.url(forResource: baseName, withExtension: "md")

        guard let url else {
            logger.warning("Markdown not found: \(article.markdownFileName)")
            return "*Guide content not found.*"
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error("Failed to read markdown: \(error)")
            return "*Error loading guide content.*"
        }
    }

    /// Navigate to a specific article (opens guide window via notification)
    func navigateTo(articleID: String) {
        if let article = article(id: articleID) {
            selectedSectionID = article.sectionID
            selectedArticleID = articleID
        }
        NotificationCenter.default.post(name: .samOpenGuide, object: nil)
    }

    /// Navigate to a section (shows first article)
    func navigateTo(sectionID: String) {
        selectedSectionID = sectionID
        if let first = articles(inSection: sectionID).first {
            selectedArticleID = first.id
        }
        NotificationCenter.default.post(name: .samOpenGuide, object: nil)
    }

    // MARK: - Private

    private func loadManifest() {
        // Try subdirectory path first (folder references), then flat (Xcode groups)
        let url = Bundle.main.url(forResource: "GuideManifest", withExtension: "json", subdirectory: "Guide")
            ?? Bundle.main.url(forResource: "GuideManifest", withExtension: "json")

        guard let url else {
            logger.error("GuideManifest.json not found in bundle")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(GuideManifest.self, from: data)
            // The macOS reader hides iOS-only articles; iOS-only sections that
            // lose all their articles are also hidden so the sidebar stays clean.
            let visibleArticles = manifest.articles
                .filter { $0.isVisibleOnMac }
                .sorted { $0.sortOrder < $1.sortOrder }
            let visibleSectionIDs = Set(visibleArticles.map { $0.sectionID })
            sections = manifest.sections
                .filter { visibleSectionIDs.contains($0.id) }
                .sorted { $0.sortOrder < $1.sortOrder }
            articles = visibleArticles
            logger.debug("Loaded guide manifest: \(self.sections.count) sections, \(self.articles.count) articles (filtered for macOS)")
        } catch {
            logger.error("Failed to decode GuideManifest: \(error)")
        }
    }

    private func buildSearchIndex() {
        for article in articles {
            var text = article.title.lowercased()
            text += " " + article.searchKeywords.joined(separator: " ").lowercased()

            // Include body text in search index
            let body = markdownBody(for: article).lowercased()
            text += " " + body

            searchIndex[article.id] = text
        }
        logger.debug("Search index built for \(self.searchIndex.count) articles")
    }
}

// MARK: - Notification

extension Notification.Name {
    static let samOpenGuide = Notification.Name("samOpenGuide")
}
