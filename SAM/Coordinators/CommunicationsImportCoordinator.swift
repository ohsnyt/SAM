//
//  CommunicationsImportCoordinator.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Orchestrates iMessage + Call History import pipeline.
//  Reads from security-scoped bookmarks, filters to known contacts,
//  optionally analyzes message threads via on-device LLM, and upserts evidence.
//

import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CommunicationsImportCoordinator")

@MainActor @Observable
final class CommunicationsImportCoordinator {

    static let shared = CommunicationsImportCoordinator()

    // MARK: - Dependencies

    private let messageService = iMessageService.shared
    private let callHistoryService = CallHistoryService.shared
    private let messageAnalysisService = MessageAnalysisService.shared
    private let evidenceRepository = EvidenceRepository.shared
    private let peopleRepository = PeopleRepository.shared
    private let bookmarkManager = BookmarkManager.shared

    // MARK: - Observable State

    var importStatus: ImportStatus = .idle
    var lastImportedAt: Date?
    var lastMessageCount: Int = 0
    var lastCallCount: Int = 0
    var lastError: String?

    // MARK: - Settings (stored properties synced to UserDefaults)

    private(set) var messagesEnabled: Bool = false
    private(set) var callsEnabled: Bool = false
    private(set) var lookbackDays: Int = 90
    private(set) var analyzeMessages: Bool = true
    private(set) var lastMessageWatermark: Date?
    private(set) var lastCallWatermark: Date?

    private var importTask: Task<Void, Never>?

    private init() {
        messagesEnabled = UserDefaults.standard.bool(forKey: "commsMessagesEnabled")
        callsEnabled = UserDefaults.standard.bool(forKey: "commsCallsEnabled")
        let days = UserDefaults.standard.integer(forKey: "commsLookbackDays")
        lookbackDays = days > 0 ? days : 90
        if UserDefaults.standard.object(forKey: "commsAnalyzeMessages") != nil {
            analyzeMessages = UserDefaults.standard.bool(forKey: "commsAnalyzeMessages")
        }
        if let ts = UserDefaults.standard.object(forKey: "commsLastMessageWatermark") as? Double {
            lastMessageWatermark = Date(timeIntervalSinceReferenceDate: ts)
        }
        if let ts = UserDefaults.standard.object(forKey: "commsLastCallWatermark") as? Double {
            lastCallWatermark = Date(timeIntervalSinceReferenceDate: ts)
        }
    }

    func setMessagesEnabled(_ value: Bool) {
        messagesEnabled = value
        UserDefaults.standard.set(value, forKey: "commsMessagesEnabled")
    }

    func setCallsEnabled(_ value: Bool) {
        callsEnabled = value
        UserDefaults.standard.set(value, forKey: "commsCallsEnabled")
    }

    func setLookbackDays(_ value: Int) {
        let changed = value != lookbackDays
        lookbackDays = value
        UserDefaults.standard.set(value, forKey: "commsLookbackDays")
        if changed { resetWatermarks() }
    }

    func resetWatermarks() {
        lastMessageWatermark = nil
        lastCallWatermark = nil
        UserDefaults.standard.removeObject(forKey: "commsLastMessageWatermark")
        UserDefaults.standard.removeObject(forKey: "commsLastCallWatermark")
        logger.info("Watermarks reset — next import will scan full lookback window")
    }

    func setAnalyzeMessages(_ value: Bool) {
        analyzeMessages = value
        UserDefaults.standard.set(value, forKey: "commsAnalyzeMessages")
    }

    // MARK: - Import Status

    enum ImportStatus: Equatable {
        case idle, importing, success, failed
    }

    // MARK: - Cancellation

    /// Cancel all background tasks. Called by AppDelegate on app termination.
    func cancelAll() {
        importTask?.cancel()
        importTask = nil
        if importStatus == .importing {
            importStatus = .idle
        }
        logger.info("All tasks cancelled")
    }

    // MARK: - Public API

    /// Fire-and-forget import — does not block the caller.
    func startImport() {
        guard importStatus != .importing else { return }
        importTask?.cancel()
        importTask = Task { await performImport() }
    }

    func importNow() async {
        guard importStatus != .importing else {
            logger.debug("Import already in progress, skipping")
            return
        }
        importTask?.cancel()
        importTask = Task { await performImport() }
        await importTask?.value
    }

    // MARK: - Import Pipeline

    private func performImport() async {
        importStatus = .importing
        lastError = nil

        let lookbackDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()
        let messageSince = lastMessageWatermark ?? lookbackDate
        let callSince = lastCallWatermark ?? lookbackDate
        var totalMessages = 0
        var totalCalls = 0

        do {
            // Build known identifier sets
            let knownEmails = try peopleRepository.allKnownEmails()
            let knownPhones = try peopleRepository.allKnownPhones()
            let knownIdentifiers = knownEmails.union(knownPhones)

            // --- iMessage ---
            if messagesEnabled, bookmarkManager.hasMessagesAccess {
                totalMessages = try await importMessages(since: messageSince, knownIdentifiers: knownIdentifiers)
            }

            // --- Call History ---
            if callsEnabled, bookmarkManager.hasCallHistoryAccess {
                totalCalls = try await importCallHistory(since: callSince, knownPhones: knownPhones)
            }

            // Trigger insight generation
            InsightGenerator.shared.startAutoGeneration()

            lastImportedAt = Date()
            lastMessageCount = totalMessages
            lastCallCount = totalCalls
            importStatus = .success

            logger.info("Communications import complete: \(totalMessages) messages, \(totalCalls) calls")

            // Refresh relationship summaries for people with new evidence
            if totalMessages + totalCalls > 0 {
                await refreshAffectedSummaries()
            }

        } catch {
            lastError = error.localizedDescription
            importStatus = .failed
            logger.error("Communications import failed: \(error)")
        }
    }

    // MARK: - iMessage Import

    private func importMessages(since: Date, knownIdentifiers: Set<String>) async throws -> Int {
        guard let resolved = bookmarkManager.resolveMessagesURL() else {
            logger.warning("Could not resolve messages bookmark")
            return 0
        }
        guard resolved.directory.startAccessingSecurityScopedResource() else {
            logger.warning("Could not access security-scoped messages directory")
            return 0
        }
        defer { bookmarkManager.stopAccessing(resolved.directory) }

        // Fetch messages from known contacts
        let messages = try await messageService.fetchMessages(
            since: since,
            dbURL: resolved.database,
            knownIdentifiers: knownIdentifiers
        )

        guard !messages.isEmpty else {
            logger.info("No new messages from known contacts")
            return 0
        }

        // Group messages by (handle, day) for analysis
        let grouped = groupMessagesByHandleAndDay(messages)

        // Analyze and upsert
        var analyzedMessages: [(MessageDTO, MessageAnalysisDTO?)] = []

        for (_, threadMessages) in grouped {
            guard !Task.isCancelled else {
                logger.info("Message import cancelled during analysis")
                break
            }
            if analyzeMessages {
                // Get contact info for role context
                let handle = threadMessages.first?.handleID ?? ""
                let contactName = resolveContactName(for: handle)
                let contactRole = resolveContactRole(for: handle)

                // Build analysis input
                let analysisInput: [(text: String, date: Date, isFromMe: Bool)] = threadMessages.compactMap { msg in
                    guard let text = msg.text, !text.isEmpty else { return nil }
                    return (text: text, date: msg.date, isFromMe: msg.isFromMe)
                }

                if analysisInput.count >= 2 {
                    // Only analyze threads with at least 2 messages with text
                    do {
                        let analysis = try await messageAnalysisService.analyzeConversation(
                            messages: analysisInput,
                            contactName: contactName,
                            contactRole: contactRole
                        )
                        // Apply analysis to the last message in the thread (represents the conversation)
                        if let lastMsg = threadMessages.last {
                            analyzedMessages.append((lastMsg, analysis))
                        }
                        // Also add remaining messages without analysis
                        for msg in threadMessages.dropLast() {
                            analyzedMessages.append((msg, nil))
                        }
                    } catch {
                        logger.warning("Message analysis failed for thread: \(error)")
                        for msg in threadMessages {
                            analyzedMessages.append((msg, nil))
                        }
                    }
                } else {
                    for msg in threadMessages {
                        analyzedMessages.append((msg, nil))
                    }
                }
            } else {
                for msg in threadMessages {
                    analyzedMessages.append((msg, nil))
                }
            }
        }

        // Bulk upsert
        try evidenceRepository.bulkUpsertMessages(analyzedMessages)

        // Update watermark to newest message date
        if let newest = messages.max(by: { $0.date < $1.date })?.date {
            lastMessageWatermark = newest
            UserDefaults.standard.set(newest.timeIntervalSinceReferenceDate, forKey: "commsLastMessageWatermark")
        }

        return messages.count
    }

    // MARK: - Call History Import

    private func importCallHistory(since: Date, knownPhones: Set<String>) async throws -> Int {
        guard let resolved = bookmarkManager.resolveCallHistoryURL() else {
            logger.warning("Could not resolve call history bookmark")
            return 0
        }
        guard resolved.directory.startAccessingSecurityScopedResource() else {
            logger.warning("Could not access security-scoped call history directory")
            return 0
        }
        defer { bookmarkManager.stopAccessing(resolved.directory) }

        let calls = try await callHistoryService.fetchCalls(
            since: since,
            dbURL: resolved.database,
            knownPhones: knownPhones
        )

        guard !calls.isEmpty else {
            logger.info("No new call records from known contacts")
            return 0
        }

        try evidenceRepository.bulkUpsertCallRecords(calls)

        // Update watermark to newest call date
        if let newest = calls.max(by: { $0.date < $1.date })?.date {
            lastCallWatermark = newest
            UserDefaults.standard.set(newest.timeIntervalSinceReferenceDate, forKey: "commsLastCallWatermark")
        }

        return calls.count
    }

    // MARK: - Relationship Summary Refresh

    /// Refresh relationship summaries for people who have communications evidence.
    private func refreshAffectedSummaries() async {
        let commsSources: Set<EvidenceSource> = [.iMessage, .phoneCall, .faceTime]

        guard let allEvidence = try? evidenceRepository.fetchAll() else { return }

        // Find people linked to communications evidence
        var affectedPeople = Set<UUID>()
        for item in allEvidence where commsSources.contains(item.source) {
            for person in item.linkedPeople {
                affectedPeople.insert(person.id)
            }
        }

        guard !affectedPeople.isEmpty else { return }

        let people = (try? peopleRepository.fetchAll()) ?? []
        let toRefresh = people.filter { affectedPeople.contains($0.id) && !$0.isMe }

        logger.info("Refreshing relationship summaries for \(toRefresh.count) people with communications")

        for person in toRefresh.prefix(10) {
            guard !Task.isCancelled else {
                logger.info("Summary refresh cancelled")
                break
            }
            await NoteAnalysisCoordinator.shared.refreshRelationshipSummary(for: person)
        }
    }

    // MARK: - Helpers

    /// Group messages by (handle, day) for conversation-level analysis.
    private func groupMessagesByHandleAndDay(_ messages: [MessageDTO]) -> [String: [MessageDTO]] {
        let calendar = Calendar.current
        var groups: [String: [MessageDTO]] = [:]

        for message in messages {
            let dayString = calendar.startOfDay(for: message.date).timeIntervalSinceReferenceDate
            let key = "\(message.handleID)_\(Int(dayString))"
            groups[key, default: []].append(message)
        }

        return groups
    }

    /// Resolve contact display name for a handle (email or phone).
    private func resolveContactName(for handle: String) -> String? {
        guard let people = try? peopleRepository.fetchAll() else { return nil }
        let canonicalHandle = canonicalizeHandle(handle)

        for person in people {
            if handle.contains("@") {
                if person.emailAliases.contains(where: { $0.lowercased() == canonicalHandle }) {
                    return person.displayNameCache ?? person.displayName
                }
            } else {
                if person.phoneAliases.contains(where: { canonicalizePhone($0) == canonicalHandle }) {
                    return person.displayNameCache ?? person.displayName
                }
            }
        }
        return nil
    }

    /// Resolve contact role for a handle.
    private func resolveContactRole(for handle: String) -> String? {
        guard let people = try? peopleRepository.fetchAll() else { return nil }
        let canonicalHandle = canonicalizeHandle(handle)

        for person in people {
            let matched: Bool
            if handle.contains("@") {
                matched = person.emailAliases.contains(where: { $0.lowercased() == canonicalHandle })
            } else {
                matched = person.phoneAliases.contains(where: { canonicalizePhone($0) == canonicalHandle })
            }
            if matched {
                return person.roleBadges.first
            }
        }
        return nil
    }

    private func canonicalizeHandle(_ handle: String) -> String {
        if handle.contains("@") {
            return handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return canonicalizePhone(handle) ?? handle.lowercased()
    }

    private func canonicalizePhone(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }
}
