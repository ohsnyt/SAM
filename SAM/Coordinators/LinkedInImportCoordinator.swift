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

    private let linkedInService = LinkedInService.shared
    private let evidenceRepo    = EvidenceRepository.shared
    private let peopleRepo      = PeopleRepository.shared

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
            if !pendingConnections.isEmpty {
                matched = try enrichPeopleFromConnections(pendingConnections)
                lastConnectionImportAt = Date()
            }

            // 2. Import messages as SamEvidenceItem records
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

            matchedConnectionCount = matched
            lastImportCount        = importedCount
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
    /// Returns the number of people that were updated.
    @discardableResult
    private func enrichPeopleFromConnections(_ connections: [LinkedInConnectionDTO]) throws -> Int {
        var enrichedCount = 0
        for conn in connections {
            let updated = try peopleRepo.updateLinkedInData(
                profileURL: conn.profileURL,
                connectedOn: conn.connectedOn,
                email: conn.email,
                fullName: "\(conn.firstName) \(conn.lastName)"
            )
            if updated { enrichedCount += 1 }
        }
        return enrichedCount
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
