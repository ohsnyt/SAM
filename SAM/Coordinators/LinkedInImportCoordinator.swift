//
//  LinkedInImportCoordinator.swift
//  SAM
//
//  Phase S+: LinkedIn Archive Import
//
//  Orchestrates importing LinkedIn data export CSV files into SwiftData.
//  - Messages from messages.csv → SamEvidenceItem (source: .linkedIn)
//  - Connections from Connections.csv → enriches SamPerson.linkedInProfileURL
//  - Watermark: stores last-import date so re-imports only process new records
//  - Contact matching: exact profile URL match, then email match, then fuzzy name
//

import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LinkedInImportCoordinator")

@MainActor
@Observable
final class LinkedInImportCoordinator {

    // MARK: - Singleton

    static let shared = LinkedInImportCoordinator()

    // MARK: - Dependencies

    private let linkedInService    = LinkedInService.shared
    private let evidenceRepo       = EvidenceRepository.shared
    private let peopleRepo         = PeopleRepository.shared
    private let unknownSenderRepo  = UnknownSenderRepository.shared

    // MARK: - Settings (UserDefaults)

    @ObservationIgnored
    var importEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "sam.linkedin.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.linkedin.enabled") }
    }

    /// Watermark: only messages newer than this date are imported on subsequent runs.
    /// When nil, all available messages are imported.
    @ObservationIgnored
    var lastMessageImportAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: "sam.linkedin.messages.lastImportAt")
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0,
                                      forKey: "sam.linkedin.messages.lastImportAt")
        }
    }

    /// Watermark for connections import — when connections were last synced.
    @ObservationIgnored
    var lastConnectionImportAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: "sam.linkedin.connections.lastImportAt")
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0,
                                      forKey: "sam.linkedin.connections.lastImportAt")
        }
    }

    // MARK: - State

    enum ImportStatus: Equatable {
        case idle, parsing, importing, success, failed
        var displayText: String {
            switch self {
            case .idle:      "Ready"
            case .parsing:   "Reading file..."
            case .importing: "Importing..."
            case .success:   "Done"
            case .failed:    "Failed"
            }
        }
        var isActive: Bool { self == .parsing || self == .importing }
    }

    private(set) var importStatus: ImportStatus = .idle
    private(set) var lastError: String?
    private(set) var lastImportedAt: Date?
    private(set) var lastImportCount: Int = 0
    private(set) var parsedMessageCount: Int = 0
    private(set) var newMessageCount: Int = 0
    private(set) var duplicateMessageCount: Int = 0
    private(set) var matchedConnectionCount: Int = 0
    private(set) var unmatchedConnectionCount: Int = 0

    // MARK: - Parsed state (held between preview and confirm)

    private var pendingMessages: [LinkedInMessageDTO] = []
    private var pendingConnections: [LinkedInConnectionDTO] = []

    /// Exposed for the settings preview UI.
    var pendingConnectionCount: Int { pendingConnections.count }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Parse a LinkedIn data export folder. Call from Settings UI after user selects folder.
    /// Populates pending counts for preview before the user confirms import.
    func loadFolder(url: URL) async {
        guard importStatus != .parsing && importStatus != .importing else { return }

        importStatus = .parsing
        lastError = nil
        parsedMessageCount = 0
        newMessageCount = 0
        duplicateMessageCount = 0
        pendingMessages = []
        pendingConnections = []

        let messagesURL     = url.appendingPathComponent("messages.csv")
        let connectionsURL  = url.appendingPathComponent("Connections.csv")

        // Parse messages (applying watermark for incremental import)
        let allMessages = await linkedInService.parseMessages(
            at: messagesURL,
            since: lastMessageImportAt
        )

        // Check which messages are already imported (dedup by sourceUID)
        var newMessages: [LinkedInMessageDTO] = []
        var duplicateCount = 0
        for msg in allMessages {
            if (try? evidenceRepo.fetch(sourceUID: msg.sourceUID)) != nil {
                duplicateCount += 1
            } else {
                newMessages.append(msg)
            }
        }

        // Parse connections (always full re-parse — just updates existing records)
        let connections: [LinkedInConnectionDTO]
        if FileManager.default.fileExists(atPath: connectionsURL.path) {
            connections = await linkedInService.parseConnections(at: connectionsURL)
        } else {
            connections = []
            logger.info("No Connections.csv found in folder")
        }

        parsedMessageCount    = allMessages.count
        newMessageCount       = newMessages.count
        duplicateMessageCount = duplicateCount
        pendingMessages       = newMessages
        pendingConnections    = connections
        importStatus          = .idle  // Ready for user to confirm

        logger.info("Folder parsed: \(allMessages.count) messages (\(newMessages.count) new), \(connections.count) connections")
    }

    /// Confirm and execute the import. Called after user reviews preview counts.
    func confirmImport() async {
        guard !pendingMessages.isEmpty || !pendingConnections.isEmpty else {
            importStatus = .idle
            return
        }

        importStatus = .importing
        lastError = nil

        var importedCount = 0
        var matched = 0

        do {
            // 1. Enrich SamPerson records from connections (always, even without messages)
            var unmatchedConnections: [LinkedInConnectionDTO] = []
            if !pendingConnections.isEmpty {
                let result = try enrichPeopleFromConnections(pendingConnections)
                matched = result.matched
                unmatchedConnections = result.unmatched
                lastConnectionImportAt = Date()
                if !unmatchedConnections.isEmpty {
                    logger.info("\(unmatchedConnections.count) LinkedIn connection(s) unmatched — queuing for triage")
                }
            }

            // 2. Import messages as SamEvidenceItem records
            var unmatchedMessageSenders: [(profileURL: String, name: String, date: Date)] = []
            if !pendingMessages.isEmpty {
                // Build lookup tables once for all messages
                let allPeople = try peopleRepo.fetchAll()
                let byLinkedInURL  = Dictionary(uniqueKeysWithValues: allPeople.compactMap { p -> (String, SamPerson)? in
                    guard let url = p.linkedInProfileURL else { return nil }
                    return (url.lowercased(), p)
                })
                let byEmail: [String: SamPerson] = allPeople.reduce(into: [:]) { dict, p in
                    if let e = p.emailCache?.lowercased() { dict[e] = p }
                    for alias in p.emailAliases { dict[alias.lowercased()] = p }
                }
                let byFullName: [String: SamPerson] = allPeople.reduce(into: [:]) { dict, p in
                    let name = (p.displayNameCache ?? p.displayName).lowercased()
                    dict[name] = p
                }

                for msg in pendingMessages {
                    let person = matchPerson(
                        profileURL: msg.senderProfileURL,
                        name: msg.senderName,
                        byLinkedInURL: byLinkedInURL,
                        byEmail: [:],
                        byFullName: byFullName
                    )

                    if person == nil && !msg.senderName.isEmpty {
                        // Track unmatched message senders for triage
                        unmatchedMessageSenders.append((
                            profileURL: msg.senderProfileURL,
                            name: msg.senderName,
                            date: msg.occurredAt
                        ))
                    }

                    let linkedPeople: [SamPerson] = person.map { [$0] } ?? []
                    let peopleIDs = linkedPeople.map(\.id)

                    // Title: prefer conversation title, fall back to sender name
                    let title = msg.conversationTitle.isEmpty
                        ? "LinkedIn message from \(msg.senderName)"
                        : msg.conversationTitle

                    // Snippet: first 200 chars of plain text
                    let snippet = String(msg.plainTextContent.prefix(200))

                    try evidenceRepo.createByIDs(
                        sourceUID:        msg.sourceUID,
                        source:           .linkedIn,
                        occurredAt:       msg.occurredAt,
                        title:            title,
                        snippet:          snippet,
                        bodyText:         msg.plainTextContent,
                        linkedPeopleIDs:  peopleIDs
                    )

                    importedCount += 1
                }

                lastMessageImportAt = Date()
            }

            // 3. Queue unmatched connections and message senders for user triage
            recordUnmatchedForTriage(
                connections: unmatchedConnections,
                messageSenders: unmatchedMessageSenders
            )

            matchedConnectionCount   = matched
            unmatchedConnectionCount = unmatchedConnections.count
            lastImportCount          = importedCount
            lastImportedAt         = Date()
            importStatus           = .success

            // Clear pending state
            pendingMessages    = []
            pendingConnections = []

            logger.info("LinkedIn import complete: \(importedCount) messages, \(matched) connections matched")

        } catch {
            logger.error("LinkedIn import failed: \(error.localizedDescription)")
            importStatus = .failed
            lastError    = error.localizedDescription
        }
    }

    /// Reset the message watermark so the next import re-processes all available messages.
    func resetWatermark() {
        lastMessageImportAt = nil
        logger.info("LinkedIn message watermark reset")
    }

    /// Re-read messages.csv from the last-imported folder and import any messages
    /// whose sender profile URL matches the given URL.
    /// Called after a user promotes an unknown LinkedIn contact from the triage screen.
    /// No-op if no folder bookmark exists.
    func reprocessForSender(profileURL: String) async {
        let bookmarkManager = BookmarkManager.shared
        guard let folderURL = bookmarkManager.resolveLinkedInFolderURL() else {
            logger.info("reprocessForSender: no LinkedIn folder bookmark — skipping")
            return
        }

        let normalizedTarget = profileURL.lowercased()
        guard !normalizedTarget.isEmpty else { return }

        guard folderURL.startAccessingSecurityScopedResource() else {
            logger.warning("reprocessForSender: could not access LinkedIn folder")
            return
        }
        defer { bookmarkManager.stopAccessing(folderURL) }

        let messagesURL = folderURL.appendingPathComponent("messages.csv")
        guard FileManager.default.fileExists(atPath: messagesURL.path) else {
            logger.info("reprocessForSender: messages.csv not found in bookmarked folder")
            return
        }

        // Parse ALL messages (no watermark filter — we want full history for this sender)
        let allMessages = await linkedInService.parseMessages(at: messagesURL, since: nil)
        let matching = allMessages.filter { $0.senderProfileURL.lowercased() == normalizedTarget }

        guard !matching.isEmpty else {
            logger.info("reprocessForSender: no messages found for \(normalizedTarget, privacy: .public)")
            return
        }

        // Find the newly-created SamPerson so we can link evidence to them
        let allPeople: [SamPerson]
        do {
            allPeople = try peopleRepo.fetchAll()
        } catch {
            logger.error("reprocessForSender: fetchAll failed: \(error)")
            return
        }

        let person = allPeople.first { ($0.linkedInProfileURL ?? "").lowercased() == normalizedTarget }

        var imported = 0
        var skipped = 0
        for msg in matching {
            // Skip if already imported
            if (try? evidenceRepo.fetch(sourceUID: msg.sourceUID)) != nil {
                skipped += 1
                continue
            }

            let linkedPeople: [SamPerson] = person.map { [$0] } ?? []
            let peopleIDs = linkedPeople.map(\.id)
            let title = msg.conversationTitle.isEmpty
                ? "LinkedIn message from \(msg.senderName)"
                : msg.conversationTitle
            let snippet = String(msg.plainTextContent.prefix(200))

            do {
                try evidenceRepo.createByIDs(
                    sourceUID:       msg.sourceUID,
                    source:          .linkedIn,
                    occurredAt:      msg.occurredAt,
                    title:           title,
                    snippet:         snippet,
                    bodyText:        msg.plainTextContent,
                    linkedPeopleIDs: peopleIDs
                )
                imported += 1
            } catch {
                logger.error("reprocessForSender: failed to create evidence: \(error)")
            }
        }

        logger.info("reprocessForSender: \(imported) message(s) imported, \(skipped) already present for \(normalizedTarget, privacy: .public)")
    }

    /// Cancel a pending import (when user dismisses before confirming).
    func cancelImport() {
        pendingMessages    = []
        pendingConnections = []
        importStatus       = .idle
        parsedMessageCount = 0
        newMessageCount    = 0
        duplicateMessageCount = 0
    }

    // MARK: - Private: Connection Enrichment

    /// Write LinkedIn profile URLs and connection dates onto matching SamPerson records.
    /// Returns a tuple: (matchedCount, unmatchedConnections).
    private func enrichPeopleFromConnections(
        _ connections: [LinkedInConnectionDTO]
    ) throws -> (matched: Int, unmatched: [LinkedInConnectionDTO]) {
        var enrichedCount = 0
        var unmatched: [LinkedInConnectionDTO] = []
        for conn in connections {
            let updated = try peopleRepo.updateLinkedInData(
                profileURL: conn.profileURL,
                connectedOn: conn.connectedOn,
                email: conn.email,
                fullName: "\(conn.firstName) \(conn.lastName)"
            )
            if updated {
                enrichedCount += 1
            } else {
                unmatched.append(conn)
            }
        }
        return (enrichedCount, unmatched)
    }

    // MARK: - Private: Triage Queue

    /// Record unmatched LinkedIn connections and message senders in the UnknownSender triage system.
    /// Uses "linkedin:<profileURL>" as the unique key so they surface in the Awareness triage section.
    /// Connections with an email address use the email as key (consistent with mail-sourced unknowns).
    private func recordUnmatchedForTriage(
        connections: [LinkedInConnectionDTO],
        messageSenders: [(profileURL: String, name: String, date: Date)]
    ) {
        // Build deduped input — prefer email key when available, otherwise linkedin: URL prefix
        var senders: [(email: String, displayName: String?, subject: String, date: Date, source: EvidenceSource, isLikelyMarketing: Bool)] = []

        // Deduplicate message senders by profileURL first, keeping the most recent message date
        var sendersByURL: [String: (profileURL: String, name: String, date: Date)] = [:]
        for s in messageSenders {
            let key = s.profileURL.lowercased()
            if let existing = sendersByURL[key] {
                if s.date > existing.date { sendersByURL[key] = s }
            } else {
                sendersByURL[key] = s
            }
        }

        for s in sendersByURL.values {
            let uniqueKey = s.profileURL.isEmpty
                ? "linkedin-unknown-\(s.name.lowercased().replacingOccurrences(of: " ", with: "-"))"
                : "linkedin:\(s.profileURL.lowercased())"
            senders.append((
                email: uniqueKey,
                displayName: s.name,
                subject: s.profileURL.isEmpty ? "LinkedIn message" : s.profileURL,
                date: s.date,
                source: .linkedIn,
                isLikelyMarketing: false
            ))
        }

        // Deduplicate connections by profileURL, then add if not already captured from messages
        let messageURLs = Set(sendersByURL.keys)
        for conn in connections {
            let urlKey = conn.profileURL.lowercased()
            if messageURLs.contains(urlKey) { continue }  // already added via messages

            let uniqueKey: String
            if let email = conn.email, !email.isEmpty {
                uniqueKey = email.lowercased()
            } else {
                uniqueKey = conn.profileURL.isEmpty
                    ? "linkedin-unknown-\(conn.firstName.lowercased())-\(conn.lastName.lowercased())"
                    : "linkedin:\(conn.profileURL.lowercased())"
            }

            let displayName = "\(conn.firstName) \(conn.lastName)".trimmingCharacters(in: .whitespaces)
            let subject = conn.profileURL.isEmpty ? "LinkedIn connection" : conn.profileURL
            senders.append((
                email: uniqueKey,
                displayName: displayName.isEmpty ? nil : displayName,
                subject: subject,
                date: conn.connectedOn ?? Date(),
                source: .linkedIn,
                isLikelyMarketing: false
            ))
        }

        guard !senders.isEmpty else { return }

        do {
            try unknownSenderRepo.bulkRecordUnknownSenders(senders)
            logger.info("Queued \(senders.count) unmatched LinkedIn contact(s) for triage")
        } catch {
            logger.error("Failed to record unmatched LinkedIn senders: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Contact Matching (for messages)

    /// Match a LinkedIn message sender to an existing SamPerson.
    /// Priority: 1) exact LinkedIn profile URL, 2) full name.
    private func matchPerson(
        profileURL: String,
        name: String,
        byLinkedInURL: [String: SamPerson],
        byEmail: [String: SamPerson],
        byFullName: [String: SamPerson]
    ) -> SamPerson? {
        // 1. Exact LinkedIn profile URL match
        if !profileURL.isEmpty, let match = byLinkedInURL[profileURL.lowercased()] {
            return match
        }
        // 2. Full name match
        let nameLower = name.lowercased().trimmingCharacters(in: .whitespaces)
        if !nameLower.isEmpty, let match = byFullName[nameLower] {
            return match
        }
        return nil
    }
}
