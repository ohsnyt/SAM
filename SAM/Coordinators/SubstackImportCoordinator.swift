//
//  SubstackImportCoordinator.swift
//  SAM
//
//  Orchestrates Substack integration across two tracks:
//  Track 1 — Content Voice Intelligence: RSS feed parsing → ContentPost + voice analysis.
//  Track 2 — Subscriber-as-Lead Pipeline: CSV import → match/triage subscribers.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SubstackImportCoordinator")

@MainActor
@Observable
final class SubstackImportCoordinator {

    // MARK: - Singleton

    static let shared = SubstackImportCoordinator()

    // MARK: - State

    var importStatus: ImportStatus = .idle
    var statusMessage: String = ""

    /// Parsed posts from the most recent feed fetch.
    var parsedPosts: [SubstackPostDTO] = []

    /// Subscriber candidates from the most recent CSV import.
    var subscriberCandidates: [SubstackSubscriberCandidate] = []

    // MARK: - Persisted Settings

    var feedURL: String {
        get { UserDefaults.standard.string(forKey: "sam.substack.feedURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sam.substack.feedURL") }
    }

    var lastFeedFetchDate: Date? {
        get { UserDefaults.standard.object(forKey: "sam.substack.lastFeedFetchDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "sam.substack.lastFeedFetchDate") }
    }

    var lastSubscriberImportDate: Date? {
        get { UserDefaults.standard.object(forKey: "sam.substack.lastSubscriberImportDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "sam.substack.lastSubscriberImportDate") }
    }

    // MARK: - Container

    private var container: ModelContainer?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Track 1: RSS Feed Fetch

    /// Fetch the RSS feed, log posts as ContentPost records, and analyze voice.
    func fetchFeed() async {
        let rawURL = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            importStatus = .failed("No feed URL configured")
            return
        }

        // Normalize URL: ensure https:// prefix and /feed suffix
        var urlString = rawURL
        if !urlString.hasPrefix("http") {
            urlString = "https://\(urlString)"
        }
        if !urlString.hasSuffix("/feed") {
            if urlString.hasSuffix("/") {
                urlString += "feed"
            } else {
                urlString += "/feed"
            }
        }

        guard let url = URL(string: urlString) else {
            importStatus = .failed("Invalid feed URL")
            return
        }

        importStatus = .importing
        statusMessage = "Fetching RSS feed..."
        logger.info("Starting Substack feed fetch: \(urlString)")

        do {
            let (profile, posts) = try await SubstackService.shared.fetchAndParseFeed(url: url)
            parsedPosts = posts

            statusMessage = "Logging posts..."

            // Log posts as ContentPost records (dedup by link URL)
            let newPosts = try logPostsAsContentRecords(posts)

            statusMessage = "Saving publication profile..."

            // Build and save profile DTO
            let recentPosts = posts.prefix(5).map {
                UserSubstackProfileDTO.RecentPost(title: $0.title, date: $0.pubDate)
            }
            let topics = extractTopics(from: posts)

            let profileDTO = UserSubstackProfileDTO(
                publicationName: profile.publicationName,
                publicationDescription: profile.publicationDescription,
                authorName: profile.authorName,
                feedURL: urlString,
                totalPosts: posts.count,
                topicSummary: topics,
                lastFetchDate: .now,
                recentPostTitles: Array(recentPosts)
            )

            // Save profile without voice analysis first
            await BusinessProfileService.shared.saveSubstackProfile(profileDTO)

            // Create import record
            try createImportRecord(
                archiveFileName: "RSS feed",
                postCount: posts.count,
                subscriberCount: 0,
                matchedSubscriberCount: 0,
                newLeadsFound: 0,
                touchEventsCreated: 0,
                status: .complete
            )

            lastFeedFetchDate = .now
            importStatus = .complete
            statusMessage = "Fetched \(posts.count) posts (\(newPosts) new)"
            logger.info("Feed fetch complete: \(posts.count) posts (\(newPosts) new)")

            // Background: voice analysis + profile update + profile analysis
            let postsForAnalysis = posts
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                if !postsForAnalysis.isEmpty {
                    let voiceSummary = await self.analyzeWritingVoice(posts: postsForAnalysis)
                    if !voiceSummary.isEmpty {
                        var updatedProfile = profileDTO
                        updatedProfile.writingVoiceSummary = voiceSummary
                        await BusinessProfileService.shared.saveSubstackProfile(updatedProfile)
                    }
                }
                await self.runProfileAnalysis()
            }

        } catch {
            importStatus = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
            logger.error("Feed fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Track 2: Subscriber CSV Import

    /// Parse a subscriber CSV and match against existing contacts.
    func loadSubscriberCSV(url: URL) async {
        importStatus = .importing
        statusMessage = "Parsing subscriber CSV..."
        logger.info("Starting Substack subscriber import")

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            // Find the subscribers CSV in the selected file/directory
            let csvURL = try findSubscriberCSV(at: url)
            let subscribers = try await SubstackService.shared.parseSubscriberCSV(at: csvURL)

            statusMessage = "Matching subscribers..."

            // Match against known emails
            let knownEmails = try PeopleRepository.shared.allKnownEmails()
            var candidates: [SubstackSubscriberCandidate] = []

            let context = container.map { ModelContext($0) }

            for sub in subscribers {
                let emailLower = sub.email.lowercased()

                if knownEmails.contains(emailLower) {
                    // Find the matching person
                    let personInfo = try findPersonInfo(email: emailLower, context: context)
                    candidates.append(SubstackSubscriberCandidate(
                        id: UUID(),
                        email: sub.email,
                        subscribedAt: sub.createdAt,
                        planType: sub.planType,
                        isActive: sub.isActive,
                        matchStatus: personInfo.map { .exactMatchEmail(personID: $0.personID) } ?? .noMatch,
                        classification: .later,
                        matchedPersonInfo: personInfo
                    ))
                } else {
                    candidates.append(SubstackSubscriberCandidate(
                        id: UUID(),
                        email: sub.email,
                        subscribedAt: sub.createdAt,
                        planType: sub.planType,
                        isActive: sub.isActive,
                        matchStatus: .noMatch,
                        classification: sub.planType == "paid" ? .add : .later,
                        matchedPersonInfo: nil
                    ))
                }
            }

            subscriberCandidates = candidates
            importStatus = .awaitingReview
            let matched = candidates.filter { if case .exactMatchEmail = $0.matchStatus { return true }; return false }.count
            statusMessage = "\(subscribers.count) subscribers (\(matched) matched)"
            logger.info("Subscriber parse complete: \(subscribers.count) total, \(matched) matched")

        } catch {
            importStatus = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
            logger.error("Subscriber import failed: \(error.localizedDescription)")
        }
    }

    /// Confirm the subscriber import — create touch records for matched, route unmatched to UnknownSender.
    func confirmSubscriberImport() async {
        guard importStatus == .awaitingReview else { return }

        importStatus = .importing
        statusMessage = "Processing subscribers..."
        logger.info("Confirming Substack subscriber import")

        do {
            guard let container else { throw SubstackError.invalidFeedURL }
            let context = ModelContext(container)

            var touchesCreated = 0
            var leadsCreated = 0
            var matchedCount = 0

            for candidate in subscriberCandidates {
                switch candidate.matchStatus {
                case .exactMatchEmail(let personID):
                    // Create IntentionalTouch for matched subscribers
                    matchedCount += 1
                    let touch = IntentionalTouch(
                        platform: .substack,
                        touchType: .newsletterSubscription,
                        direction: .inbound,
                        contactProfileUrl: nil,
                        samPersonID: personID,
                        date: candidate.subscribedAt,
                        snippet: candidate.planType == "paid" ? "Paid subscriber" : "Free subscriber",
                        weight: TouchType.newsletterSubscription.baseWeight,
                        source: .bulkImport
                    )
                    context.insert(touch)
                    touchesCreated += 1

                case .noMatch:
                    if candidate.classification == .add || candidate.classification == .later {
                        // Route to UnknownSender
                        try UnknownSenderRepository.shared.upsertSubstackLater(
                            email: candidate.email,
                            subscribedAt: candidate.subscribedAt,
                            planType: candidate.planType,
                            isActive: candidate.isActive
                        )
                        leadsCreated += 1
                    }
                }
            }

            try context.save()

            // Create import record
            try createImportRecord(
                archiveFileName: "Subscriber CSV",
                postCount: 0,
                subscriberCount: subscriberCandidates.count,
                matchedSubscriberCount: matchedCount,
                newLeadsFound: leadsCreated,
                touchEventsCreated: touchesCreated,
                status: .complete
            )

            lastSubscriberImportDate = .now
            importStatus = .complete
            statusMessage = "\(matchedCount) matched, \(leadsCreated) new leads, \(touchesCreated) touches"
            subscriberCandidates = []
            logger.info("Subscriber import confirmed: \(matchedCount) matched, \(leadsCreated) leads, \(touchesCreated) touches")

        } catch {
            importStatus = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
            logger.error("Subscriber import confirmation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Profile Analysis (Grow Section)

    /// Run a profile analysis on the Substack publication for the Grow section.
    /// Produces a ProfileAnalysisDTO with platform "substack" and saves it via BusinessProfileService.
    func runProfileAnalysis() async {
        guard let profile = await BusinessProfileService.shared.substackProfile() else {
            // No Substack profile — silently skip (user hasn't connected Substack)
            return
        }
        guard profile.totalPosts > 0 else { return }

        do {
            let data = buildSubstackAnalysisInput(profile: profile)
            let previousAnalysis = await BusinessProfileService.shared.profileAnalysis(for: "substack")
            let previousJSON: String? = {
                guard let prev = previousAnalysis,
                      let encoded = try? JSONEncoder().encode(prev) else { return nil }
                return String(data: encoded, encoding: .utf8)
            }()

            let result = try await SubstackProfileAnalystService.shared.analyze(
                data: data,
                previousAnalysisJSON: previousJSON
            )
            await BusinessProfileService.shared.saveProfileAnalysis(result)
            logger.info("Substack profile analysis complete: score \(result.overallScore)")
        } catch {
            logger.error("Substack profile analysis failed: \(error.localizedDescription)")
        }
    }

    /// Assembles the text block sent to the AI for Substack publication analysis.
    private func buildSubstackAnalysisInput(profile: UserSubstackProfileDTO) -> String {
        var lines: [String] = []

        lines.append("Substack Publication: \(profile.publicationName)")
        if !profile.authorName.isEmpty { lines.append("Author: \(profile.authorName)") }
        if !profile.publicationDescription.isEmpty {
            lines.append("Description: \(profile.publicationDescription)")
        }
        lines.append("Total articles published: \(profile.totalPosts)")

        if !profile.topicSummary.isEmpty {
            lines.append("\nTopics covered: \(profile.topicSummary.joined(separator: ", "))")
        }

        if !profile.writingVoiceSummary.isEmpty {
            lines.append("Writing voice: \(profile.writingVoiceSummary)")
        }

        if !profile.recentPostTitles.isEmpty {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            lines.append("\nRecent articles:")
            for post in profile.recentPostTitles.prefix(10) {
                lines.append("- \"\(post.title)\" (\(formatter.string(from: post.date)))")
            }
        }

        // Add posting cadence info from ContentPostRepository
        if let daysSince = try? ContentPostRepository.shared.daysSinceLastPost(platform: .substack) {
            lines.append("\nDays since last article: \(daysSince)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Log parsed posts as ContentPost records, deduplicating by link URL.
    private func logPostsAsContentRecords(_ posts: [SubstackPostDTO]) throws -> Int {
        guard let container else { return 0 }
        let context = ModelContext(container)

        // Fetch existing Substack posts to dedup
        let descriptor = FetchDescriptor<ContentPost>(
            predicate: #Predicate { $0.platformRawValue == "Substack" }
        )
        let existing = try context.fetch(descriptor)
        let existingTopics = Set(existing.map(\.topic))

        var created = 0
        for post in posts {
            // Dedup by title (link URLs may change)
            guard !existingTopics.contains(post.title) else { continue }

            let record = ContentPost(
                platform: .substack,
                topic: post.title,
                postedAt: post.pubDate
            )
            context.insert(record)
            created += 1
        }

        if created > 0 {
            try context.save()
        }
        return created
    }

    /// Extract common topics from post tags and titles.
    private func extractTopics(from posts: [SubstackPostDTO]) -> [String] {
        // Collect all tags
        var tagCounts: [String: Int] = [:]
        for post in posts {
            for tag in post.tags {
                let normalized = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    tagCounts[normalized, default: 0] += 1
                }
            }
        }

        // Return top tags sorted by frequency
        let sorted = tagCounts.sorted { $0.value > $1.value }
        return Array(sorted.prefix(10).map(\.key))
    }

    /// Analyze writing voice using AI from concatenated post text.
    private func analyzeWritingVoice(posts: [SubstackPostDTO]) async -> String {
        // Take first 5 posts, truncate each to ~500 chars for manageable context
        let samples = posts.prefix(5).map { post in
            let text = post.plainTextContent
            return text.count > 500 ? String(text.prefix(500)) + "…" : text
        }
        let combined = samples.joined(separator: "\n\n---\n\n")

        let prompt = """
            Analyze the writing voice and style of these Substack article excerpts. \
            Provide a 1-2 sentence summary of the author's voice, tone, and style. \
            Focus on: formality level, emotional tone, use of stories/examples, \
            target audience, and any distinctive patterns.

            Excerpts:
            \(combined)
            """

        let instructions = "You are a writing style analyst. Respond with only the voice summary, no preamble."

        do {
            let result = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.warning("Voice analysis failed: \(error.localizedDescription)")
            return ""
        }
    }

    /// Find the subscriber CSV file at the given URL (handles both direct file and directory).
    private func findSubscriberCSV(at url: URL) throws -> URL {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            // Look for subscribers.csv or similar in the directory
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                if let csv = contents.first(where: { $0.lastPathComponent.lowercased().contains("subscriber") && $0.pathExtension.lowercased() == "csv" }) {
                    return csv
                }
                // Fallback: first CSV file
                if let csv = contents.first(where: { $0.pathExtension.lowercased() == "csv" }) {
                    return csv
                }
            }
            throw SubstackError.csvMissingEmailColumn
        }

        return url
    }

    /// Find person info by email for display in candidate list.
    private func findPersonInfo(email: String, context: ModelContext?) throws -> MatchedPersonInfo? {
        guard let context else { return nil }
        let descriptor = FetchDescriptor<SamPerson>()
        let people = try context.fetch(descriptor)
        guard let person = people.first(where: { $0.emailAliases.contains(email) || $0.emailCache?.lowercased() == email }) else {
            return nil
        }
        return MatchedPersonInfo(
            personID: person.id,
            displayName: person.displayName,
            email: email,
            company: nil,
            position: nil,
            linkedInURL: nil
        )
    }

    /// Create a SubstackImport record.
    private func createImportRecord(
        archiveFileName: String,
        postCount: Int,
        subscriberCount: Int,
        matchedSubscriberCount: Int,
        newLeadsFound: Int,
        touchEventsCreated: Int,
        status: SubstackImportStatus
    ) throws {
        guard let container else { return }
        let context = ModelContext(container)
        let record = SubstackImport(
            archiveFileName: archiveFileName,
            postCount: postCount,
            subscriberCount: subscriberCount,
            matchedSubscriberCount: matchedSubscriberCount,
            newLeadsFound: newLeadsFound,
            touchEventsCreated: touchEventsCreated,
            status: status
        )
        context.insert(record)
        try context.save()
    }
}

// MARK: - ImportStatus

extension SubstackImportCoordinator {
    enum ImportStatus: Equatable {
        case idle
        case importing
        case awaitingReview
        case complete
        case failed(String)
    }
}
