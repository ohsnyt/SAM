//
//  IntentionalTouchRepository.swift
//  SAM
//
//  SwiftData CRUD for IntentionalTouch records.
//  Provides bulk insert with deduplication, per-contact fetch,
//  and score computation from persisted records.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "IntentionalTouchRepository")

@MainActor
@Observable
final class IntentionalTouchRepository {

    // MARK: - Singleton

    static let shared = IntentionalTouchRepository()
    private init() {}

    // MARK: - Container

    @ObservationIgnored
    private var context: ModelContext?

    func configure(container: ModelContainer) {
        context = ModelContext(container)
    }

    // MARK: - Bulk Insert

    /// Bulk-insert IntentionalTouch records from a parsed import.
    ///
    /// Deduplication key: `(platformRawValue + touchTypeRawValue + contactProfileUrl + ISO8601 date rounded to minute)`.
    /// Existing records with matching keys are skipped (not updated), to preserve original
    /// weights and import attribution.
    ///
    /// - Returns: Number of net-new records inserted.
    @discardableResult
    func bulkInsert(_ candidates: [IntentionalTouchCandidate]) throws -> Int {
        guard let context else {
            logger.warning("bulkInsert called before configure(container:)")
            return 0
        }

        // Build a set of existing dedup keys to skip re-insertion
        let existingKeys = try fetchExistingDedupKeys()

        var insertCount = 0
        for candidate in candidates {
            let key = candidate.dedupKey
            guard !existingKeys.contains(key) else { continue }

            let touch = IntentionalTouch(
                platform: candidate.platform,
                touchType: candidate.touchType,
                direction: candidate.direction,
                contactProfileUrl: candidate.contactProfileUrl,
                samPersonID: candidate.samPersonID,
                date: candidate.date,
                snippet: candidate.snippet,
                weight: candidate.weight,
                source: candidate.source,
                sourceImportID: candidate.sourceImportID,
                sourceEmailID: candidate.sourceEmailID
            )
            context.insert(touch)
            insertCount += 1
        }

        if insertCount > 0 {
            try context.save()
            logger.info("Inserted \(insertCount) IntentionalTouch records")
        }

        return insertCount
    }

    // MARK: - Fetch

    /// Fetch all IntentionalTouch records for a specific contact profile URL.
    func fetchTouches(forProfileURL profileURL: String) throws -> [IntentionalTouch] {
        guard let context else { return [] }
        let normalizedURL = profileURL.lowercased()
        let descriptor = FetchDescriptor<IntentionalTouch>(
            predicate: #Predicate { $0.contactProfileUrl == normalizedURL },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetch all IntentionalTouch records attributed to a specific SamPerson.
    func fetchTouches(forPersonID personID: UUID) throws -> [IntentionalTouch] {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<IntentionalTouch>(
            predicate: #Predicate { $0.samPersonID == personID },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Score Computation from Persisted Records

    /// Compute a touch score from persisted IntentionalTouch records for a profile URL.
    func computeScore(forProfileURL profileURL: String) throws -> IntentionalTouchScore {
        let touches = try fetchTouches(forProfileURL: profileURL)
        return scoreFromTouches(touches, profileURL: profileURL)
    }

    /// Compute scores for all persisted profile URLs.
    /// Returns a dictionary keyed by normalized profile URL.
    func computeAllScores() throws -> [String: IntentionalTouchScore] {
        guard let context else { return [:] }
        let descriptor = FetchDescriptor<IntentionalTouch>()
        let all = try context.fetch(descriptor)

        // Group by contactProfileUrl
        var byURL: [String: [IntentionalTouch]] = [:]
        for touch in all {
            guard let url = touch.contactProfileUrl else { continue }
            byURL[url, default: []].append(touch)
        }

        return byURL.mapValues { scoreFromTouches($0, profileURL: $0.first?.contactProfileUrl ?? "") }
    }

    // MARK: - Attribution Update

    /// Backfill samPersonID on all IntentionalTouch records for a given profile URL.
    /// Called when a Later-bucket contact is promoted to a SamPerson.
    func attributeTouches(forProfileURL profileURL: String, to personID: UUID) throws {
        guard let context else { return }
        let normalizedURL = profileURL.lowercased()
        let descriptor = FetchDescriptor<IntentionalTouch>(
            predicate: #Predicate { $0.contactProfileUrl == normalizedURL }
        )
        let touches = try context.fetch(descriptor)
        guard !touches.isEmpty else { return }
        for touch in touches {
            touch.samPersonID = personID
        }
        try context.save()
        logger.info("Attributed \(touches.count) touches to person \(personID)")
    }

    // MARK: - Email Notification Type Detection (Phase 6)

    /// Fetch the distinct set of TouchType rawValues seen from email notification touches
    /// within the specified date range. Used by OutcomeEngine to detect missing notification types.
    func emailNotificationTypesSeenSince(_ since: Date) throws -> Set<String> {
        guard let context else { return [] }
        let sourceRaw = TouchSource.emailNotification.rawValue
        let descriptor = FetchDescriptor<IntentionalTouch>(
            predicate: #Predicate { $0.sourceRawValue == sourceRaw && $0.date >= since }
        )
        let touches = try context.fetch(descriptor)
        return Set(touches.map(\.touchTypeRawValue))
    }

    /// Returns true if ANY IntentionalTouch records exist with source=emailNotification.
    /// Uses fetchLimit=1 for efficiency. Used to detect "no LinkedIn emails at all" state.
    func hasAnyEmailNotificationTouches() throws -> Bool {
        guard let context else { return false }
        let sourceRaw = TouchSource.emailNotification.rawValue
        var descriptor = FetchDescriptor<IntentionalTouch>(
            predicate: #Predicate { $0.sourceRawValue == sourceRaw }
        )
        descriptor.fetchLimit = 1
        return !(try context.fetch(descriptor)).isEmpty
    }

    // MARK: - LinkedIn Import Record

    /// Insert a LinkedInImport audit record.
    func insertLinkedInImport(_ record: LinkedInImport) throws {
        guard let context else { return }
        context.insert(record)
        try context.save()
    }

    // MARK: - Private Helpers

    private func fetchExistingDedupKeys() throws -> Set<String> {
        guard let context else { return [] }
        // Fetch all touches and compute keys in-memory.
        // For large datasets a SQL-level dedup would be better, but for
        // expected import volumes (< 10k touches) this is acceptable.
        let descriptor = FetchDescriptor<IntentionalTouch>()
        let all = try context.fetch(descriptor)
        return Set(all.map { IntentionalTouchCandidate.makeDedupKey(
            platform: $0.platform,
            touchType: $0.touchType,
            profileURL: $0.contactProfileUrl ?? "",
            date: $0.date
        )})
    }

    private func scoreFromTouches(_ touches: [IntentionalTouch], profileURL: String) -> IntentionalTouchScore {
        var totalScore = 0
        var mostRecent: Date?
        var types: Set<String> = []
        var typeCounts: [String: Int] = [:]
        var hasMessage = false
        var hasRecommendation = false

        for touch in touches {
            totalScore += touch.weight
            types.insert(touch.touchTypeRawValue)
            typeCounts[touch.touchTypeRawValue, default: 0] += 1

            if mostRecent == nil || touch.date > mostRecent! {
                mostRecent = touch.date
            }
            if touch.touchType == .message { hasMessage = true }
            if touch.touchType == .recommendationReceived || touch.touchType == .recommendationGiven {
                hasRecommendation = true
            }
        }

        return IntentionalTouchScore(
            contactProfileUrl: profileURL,
            totalScore: totalScore,
            touchCount: touches.count,
            mostRecentTouch: mostRecent,
            touchTypes: types,
            hasDirectMessage: hasMessage,
            hasRecommendation: hasRecommendation,
            typeCounts: typeCounts
        )
    }
}

// MARK: - IntentionalTouchCandidate DTO

/// A value-type candidate for bulk insertion. Built by the coordinator from parsed CSV data.
struct IntentionalTouchCandidate: Sendable {
    let platform: TouchPlatform
    let touchType: TouchType
    let direction: TouchDirection
    let contactProfileUrl: String?
    let samPersonID: UUID?
    let date: Date
    let snippet: String?
    /// Weight is derived from touchType.baseWeight if not explicitly provided.
    let weight: Int
    let source: TouchSource
    let sourceImportID: UUID?
    let sourceEmailID: String?

    init(
        platform: TouchPlatform,
        touchType: TouchType,
        direction: TouchDirection,
        contactProfileUrl: String? = nil,
        samPersonID: UUID? = nil,
        date: Date,
        snippet: String? = nil,
        weight: Int? = nil,
        source: TouchSource = .bulkImport,
        sourceImportID: UUID? = nil,
        sourceEmailID: String? = nil
    ) {
        self.platform = platform
        self.touchType = touchType
        self.direction = direction
        self.contactProfileUrl = contactProfileUrl
        self.samPersonID = samPersonID
        self.date = date
        self.snippet = snippet
        self.weight = weight ?? touchType.baseWeight
        self.source = source
        self.sourceImportID = sourceImportID
        self.sourceEmailID = sourceEmailID
    }

    /// Dedup key used to avoid re-inserting the same touch on subsequent imports.
    var dedupKey: String {
        Self.makeDedupKey(platform: platform, touchType: touchType,
                          profileURL: contactProfileUrl ?? "", date: date)
    }

    static func makeDedupKey(
        platform: TouchPlatform,
        touchType: TouchType,
        profileURL: String,
        date: Date
    ) -> String {
        // Round to the nearest minute to tolerate minor timestamp drift
        let rounded = Int(date.timeIntervalSince1970 / 60)
        return "\(platform.rawValue):\(touchType.rawValue):\(profileURL.lowercased()):\(rounded)"
    }
}
