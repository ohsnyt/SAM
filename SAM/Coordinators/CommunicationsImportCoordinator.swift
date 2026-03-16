//
//  CommunicationsImportCoordinator.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Orchestrates iMessage + Call History + WhatsApp import pipeline.
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
    private let whatsAppService = WhatsAppService.shared
    private let messageAnalysisService = MessageAnalysisService.shared
    private let evidenceRepository = EvidenceRepository.shared
    private let peopleRepository = PeopleRepository.shared
    private let bookmarkManager = BookmarkManager.shared

    // MARK: - Observable State

    var importStatus: ImportStatus = .idle
    var lastImportedAt: Date?
    var lastMessageCount: Int = 0
    var lastCallCount: Int = 0
    var lastWhatsAppMessageCount: Int = 0
    var lastWhatsAppCallCount: Int = 0
    var lastError: String?

    // MARK: - Settings (stored properties synced to UserDefaults)

    private(set) var messagesEnabled: Bool = false
    private(set) var callsEnabled: Bool = false
    private(set) var whatsAppMessagesEnabled: Bool = false
    private(set) var whatsAppCallsEnabled: Bool = false
    private(set) var analyzeWhatsAppMessages: Bool = true
    /// Lookback days for initial import. 0 means "All" (no limit).
    private(set) var lookbackDays: Int = 90
    private(set) var analyzeMessages: Bool = true
    private(set) var lastMessageWatermark: Date?
    private(set) var lastCallWatermark: Date?
    private(set) var lastWhatsAppMessageWatermark: Date?
    private(set) var lastWhatsAppCallWatermark: Date?

    private var importTask: Task<Void, Never>?
    private var periodicImportTask: Task<Void, Never>?

    /// Import interval in seconds (default: 1 minute). 0 disables periodic import.
    private(set) var importIntervalSeconds: TimeInterval = 60

    // MARK: - File System Watchers

    /// File descriptor + DispatchSource pairs for database file monitoring.
    private var fileWatcherSources: [DispatchSourceFileSystemObject] = []
    private var fileWatcherFDs: [Int32] = []
    /// Debounce task for coalescing rapid file system events.
    private var watcherDebounceTask: Task<Void, Never>?
    /// Fallback poll interval when file watchers are active (safety net).
    private static let fallbackPollInterval: TimeInterval = 300 // 5 minutes

    private init() {
        // Default both to true — user has already granted DB access as the gating step
        messagesEnabled = UserDefaults.standard.object(forKey: "commsMessagesEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "commsMessagesEnabled")
        callsEnabled = UserDefaults.standard.object(forKey: "commsCallsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "commsCallsEnabled")
        let days = UserDefaults.standard.integer(forKey: "commsLookbackDays")
        // 0 means "All" (no limit), negative means unset → default to globalLookbackDays (30)
        let globalDays = UserDefaults.standard.object(forKey: "globalLookbackDays") != nil
            ? UserDefaults.standard.integer(forKey: "globalLookbackDays")
            : 30
        lookbackDays = days >= 0 && UserDefaults.standard.object(forKey: "commsLookbackDays") != nil ? days : globalDays
        if UserDefaults.standard.object(forKey: "commsAnalyzeMessages") != nil {
            analyzeMessages = UserDefaults.standard.bool(forKey: "commsAnalyzeMessages")
        }
        if let ts = UserDefaults.standard.object(forKey: "commsLastMessageWatermark") as? Double {
            lastMessageWatermark = Date(timeIntervalSinceReferenceDate: ts)
        }
        if let ts = UserDefaults.standard.object(forKey: "commsLastCallWatermark") as? Double {
            lastCallWatermark = Date(timeIntervalSinceReferenceDate: ts)
        }
        // WhatsApp settings
        whatsAppMessagesEnabled = UserDefaults.standard.object(forKey: "commsWhatsAppMessagesEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "commsWhatsAppMessagesEnabled")
        whatsAppCallsEnabled = UserDefaults.standard.object(forKey: "commsWhatsAppCallsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "commsWhatsAppCallsEnabled")
        if UserDefaults.standard.object(forKey: "commsAnalyzeWhatsAppMessages") != nil {
            analyzeWhatsAppMessages = UserDefaults.standard.bool(forKey: "commsAnalyzeWhatsAppMessages")
        }
        if let ts = UserDefaults.standard.object(forKey: "commsLastWhatsAppMessageWatermark") as? Double {
            lastWhatsAppMessageWatermark = Date(timeIntervalSinceReferenceDate: ts)
        }
        if let ts = UserDefaults.standard.object(forKey: "commsLastWhatsAppCallWatermark") as? Double {
            lastWhatsAppCallWatermark = Date(timeIntervalSinceReferenceDate: ts)
        }
        let interval = UserDefaults.standard.double(forKey: "commsImportIntervalSeconds")
        importIntervalSeconds = interval > 0 ? interval : 60
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
        lastWhatsAppMessageWatermark = nil
        lastWhatsAppCallWatermark = nil
        UserDefaults.standard.removeObject(forKey: "commsLastMessageWatermark")
        UserDefaults.standard.removeObject(forKey: "commsLastCallWatermark")
        UserDefaults.standard.removeObject(forKey: "commsLastWhatsAppMessageWatermark")
        UserDefaults.standard.removeObject(forKey: "commsLastWhatsAppCallWatermark")
        logger.debug("Watermarks reset — next import will scan full lookback window")
    }

    func setAnalyzeMessages(_ value: Bool) {
        analyzeMessages = value
        UserDefaults.standard.set(value, forKey: "commsAnalyzeMessages")
    }

    func setWhatsAppMessagesEnabled(_ value: Bool) {
        whatsAppMessagesEnabled = value
        UserDefaults.standard.set(value, forKey: "commsWhatsAppMessagesEnabled")
    }

    func setWhatsAppCallsEnabled(_ value: Bool) {
        whatsAppCallsEnabled = value
        UserDefaults.standard.set(value, forKey: "commsWhatsAppCallsEnabled")
    }

    func setAnalyzeWhatsAppMessages(_ value: Bool) {
        analyzeWhatsAppMessages = value
        UserDefaults.standard.set(value, forKey: "commsAnalyzeWhatsAppMessages")
    }

    func setImportInterval(_ value: TimeInterval) {
        importIntervalSeconds = value
        UserDefaults.standard.set(value, forKey: "commsImportIntervalSeconds")
        // Restart periodic import with new interval
        if periodicImportTask != nil {
            stopPeriodicImport()
            startPeriodicImport()
        }
    }

    // MARK: - File System Watchers

    /// Start file system watchers on the database files for instant change detection.
    /// Falls back to a 5-minute poll as a safety net in case FS events are missed.
    func startFileWatchers() {
        guard messagesEnabled || callsEnabled || whatsAppMessagesEnabled || whatsAppCallsEnabled else { return }
        guard fileWatcherSources.isEmpty else { return } // Already watching

        var watchPaths: [(url: URL, label: String)] = []

        // iMessage chat.db
        if messagesEnabled, let resolved = bookmarkManager.resolveMessagesURL() {
            watchPaths.append((url: resolved.database, label: "iMessage"))
        }

        // Call history
        if callsEnabled, let resolved = bookmarkManager.resolveCallHistoryURL() {
            watchPaths.append((url: resolved.database, label: "CallHistory"))
        }

        // WhatsApp ChatStorage.sqlite
        if whatsAppMessagesEnabled || whatsAppCallsEnabled, let resolved = bookmarkManager.resolveWhatsAppURL() {
            watchPaths.append((url: resolved.messagesDB, label: "WhatsApp"))
        }

        for (url, label) in watchPaths {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else {
                logger.warning("Could not open \(label) database for watching: \(url.path)")
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename],
                queue: .global(qos: .utility)
            )

            source.setEventHandler { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.handleFileChange(label: label)
                }
            }

            source.setCancelHandler {
                close(fd)
            }

            source.resume()
            fileWatcherSources.append(source)
            fileWatcherFDs.append(fd)
            logger.debug("File watcher started for \(label): \(url.lastPathComponent)")
        }

        // Start fallback poll as safety net (FS events can be missed on network volumes, etc.)
        startFallbackPoll()
    }

    /// Stop all file system watchers and the fallback poll.
    func stopFileWatchers() {
        for source in fileWatcherSources {
            source.cancel()
        }
        fileWatcherSources.removeAll()
        fileWatcherFDs.removeAll()
        watcherDebounceTask?.cancel()
        watcherDebounceTask = nil
        stopFallbackPoll()
        logger.debug("File watchers stopped")
    }

    /// Called when a watched database file changes. Debounces rapid writes (SQLite writes
    /// in bursts) into a single import after 1.5 seconds of quiet.
    private func handleFileChange(label: String) {
        watcherDebounceTask?.cancel()
        watcherDebounceTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            logger.debug("File change detected (\(label)) — triggering import")
            await performImport()
        }
    }

    /// Fallback poll every 5 minutes in case file system events are missed.
    private func startFallbackPoll() {
        guard periodicImportTask == nil else { return }
        periodicImportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.fallbackPollInterval))
                guard !Task.isCancelled else { break }
                logger.debug("Fallback poll — checking communications")
                await performImport()
            }
        }
    }

    private func stopFallbackPoll() {
        periodicImportTask?.cancel()
        periodicImportTask = nil
    }

    // MARK: - Legacy Periodic Import (retained for settings compatibility)

    /// Start periodic background import on a repeating interval.
    /// Prefer `startFileWatchers()` for instant detection; this is the fallback path
    /// used when file watchers cannot be established.
    func startPeriodicImport() {
        guard importIntervalSeconds > 0 else { return }
        guard messagesEnabled || callsEnabled || whatsAppMessagesEnabled || whatsAppCallsEnabled else { return }
        guard periodicImportTask == nil else { return }

        periodicImportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(importIntervalSeconds))
                guard !Task.isCancelled else { break }
                logger.debug("Periodic communications import triggered")
                await performImport()
            }
        }
        logger.debug("Periodic communications import started (interval: \(Int(self.importIntervalSeconds))s)")
    }

    /// Stop periodic background import.
    func stopPeriodicImport() {
        periodicImportTask?.cancel()
        periodicImportTask = nil
        logger.debug("Periodic communications import stopped")
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
        stopFileWatchers()
        stopPeriodicImport()
        if importStatus == .importing {
            importStatus = .idle
        }
        logger.debug("All tasks cancelled")
    }

    // MARK: - Public API

    /// Fire-and-forget import — does not block the caller.
    /// Starts file system watchers for instant change detection after the initial import.
    func startImport() {
        #if DEBUG
        if UserDefaults.standard.isTestDataLoaded || UserDefaults.standard.isTestDataActive { return }
        #endif
        guard importStatus != .importing else { return }
        importTask?.cancel()
        importTask = Task {
            await performImport()
            startFileWatchers()
        }
    }

    func importNow() async {
        #if DEBUG
        if UserDefaults.standard.isTestDataLoaded || UserDefaults.standard.isTestDataActive { return }
        #endif
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

        // Invalidate resolution caches so they rebuild with fresh contact data
        EvidenceRepository.shared.invalidateResolutionCache()

        let lookbackDate: Date = lookbackDays == 0
            ? .distantPast
            : (Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date())
        let messageSince = lastMessageWatermark ?? lookbackDate
        let callSince = lastCallWatermark ?? lookbackDate
        let waMessageSince = lastWhatsAppMessageWatermark ?? lookbackDate
        let waCallSince = lastWhatsAppCallWatermark ?? lookbackDate
        var totalMessages = 0
        var totalCalls = 0
        var totalWAMessages = 0
        var totalWACalls = 0
        var deferredIMThreads: [DeferredThreadAnalysis] = []
        var deferredWAThreads: [DeferredWAThreadAnalysis] = []

        do {
            // Build known identifier sets
            logger.debug("[comms-import] Building known identifier sets…")
            let knownEmails = try peopleRepository.allKnownEmails()
            let knownPhones = try peopleRepository.allKnownPhones()
            let knownIdentifiers = knownEmails.union(knownPhones)
            logger.debug("[comms-import] Known: \(knownEmails.count) emails, \(knownPhones.count) phones")

            // --- iMessage ---
            if messagesEnabled, bookmarkManager.hasMessagesAccess {
                logger.debug("[comms-import] Starting iMessage import (since \(messageSince))…")
                let result = try await importMessages(since: messageSince, knownIdentifiers: knownIdentifiers)
                totalMessages = result.count
                deferredIMThreads = result.deferred
                logger.debug("[comms-import] iMessage import done: \(result.count) messages, \(result.deferred.count) threads for analysis")
            }

            // --- Call History ---
            if callsEnabled, bookmarkManager.hasCallHistoryAccess {
                logger.debug("[comms-import] Starting call history import…")
                totalCalls = try await importCallHistory(since: callSince, knownPhones: knownPhones)
                logger.debug("[comms-import] Call history done: \(totalCalls) calls")
            }

            // --- WhatsApp Messages ---
            if whatsAppMessagesEnabled, bookmarkManager.hasWhatsAppAccess {
                logger.debug("[comms-import] Starting WhatsApp messages import…")
                let result = try await importWhatsAppMessages(since: waMessageSince, knownPhones: knownPhones)
                totalWAMessages = result.count
                deferredWAThreads = result.deferred
                logger.debug("[comms-import] WhatsApp messages done: \(result.count)")
            }

            // --- WhatsApp Calls ---
            if whatsAppCallsEnabled, bookmarkManager.hasWhatsAppAccess {
                logger.debug("[comms-import] Starting WhatsApp calls import…")
                totalWACalls = try await importWhatsAppCalls(since: waCallSince, knownPhones: knownPhones)
                logger.debug("[comms-import] WhatsApp calls done: \(totalWACalls)")
            }

            // --- WhatsApp Unknown Sender Discovery ---
            if (whatsAppMessagesEnabled || whatsAppCallsEnabled), bookmarkManager.hasWhatsAppAccess {
                logger.debug("[comms-import] Starting WhatsApp unknown sender discovery…")
                await discoverWhatsAppUnknownSenders(knownPhones: knownPhones)
                await generateWhatsAppEnrichments(knownPhones: knownPhones)
                logger.debug("[comms-import] WhatsApp discovery done")
            }

            lastImportedAt = Date()
            lastMessageCount = totalMessages
            lastCallCount = totalCalls
            lastWhatsAppMessageCount = totalWAMessages
            lastWhatsAppCallCount = totalWACalls
            importStatus = .success

            let total = totalMessages + totalCalls + totalWAMessages + totalWACalls
            logger.info("Communications import complete: \(totalMessages) iMessages, \(totalCalls) calls, \(totalWAMessages) WhatsApp messages, \(totalWACalls) WhatsApp calls")

            // Background: analyze deferred threads, then trigger insights + summaries + role deduction
            Task(priority: .utility) { [weak self] in
                guard let self else { return }

                // Analyze iMessage threads
                for thread in deferredIMThreads {
                    guard !Task.isCancelled else { break }
                    do {
                        let analysis = try await self.messageAnalysisService.analyzeConversation(
                            messages: thread.messages,
                            contactName: thread.contactName,
                            contactRole: thread.contactRole
                        )
                        let sourceUID = "imessage:\(thread.lastMessageGUID)"
                        try self.evidenceRepository.updateMessageAnalysis(sourceUID: sourceUID, analysis: analysis)
                    } catch {
                        logger.warning("Background iMessage analysis failed: \(error)")
                    }
                }

                // Analyze WhatsApp threads
                for thread in deferredWAThreads {
                    guard !Task.isCancelled else { break }
                    do {
                        let analysis = try await self.messageAnalysisService.analyzeConversation(
                            messages: thread.messages,
                            contactName: thread.contactName,
                            contactRole: thread.contactRole
                        )
                        let sourceUID = "whatsapp:\(thread.lastMessageStanzaID)"
                        try self.evidenceRepository.updateMessageAnalysis(sourceUID: sourceUID, analysis: analysis)
                    } catch {
                        logger.warning("Background WhatsApp analysis failed: \(error)")
                    }
                }

                if total > 0 {
                    await self.refreshAffectedSummaries()
                }

                PostImportOrchestrator.shared.importDidComplete(source: "communications")
            }

        } catch {
            lastError = error.localizedDescription
            importStatus = .failed
            logger.error("Communications import failed: \(error)")
        }
    }

    // MARK: - iMessage Import

    /// Thread data for deferred background analysis.
    private struct DeferredThreadAnalysis: Sendable {
        let lastMessageGUID: String
        let messages: [(text: String, date: Date, isFromMe: Bool)]
        let handle: String
        let contactName: String?
        let contactRole: String?
    }

    private func importMessages(since: Date, knownIdentifiers: Set<String>) async throws -> (count: Int, deferred: [DeferredThreadAnalysis]) {
        guard let resolved = bookmarkManager.resolveMessagesURL() else {
            logger.warning("Could not resolve messages bookmark")
            return (0, [])
        }
        guard resolved.directory.startAccessingSecurityScopedResource() else {
            logger.warning("Could not access security-scoped messages directory")
            return (0, [])
        }
        defer { bookmarkManager.stopAccessing(resolved.directory) }

        // Fetch messages from known contacts (and capture unknown senders)
        logger.debug("[comms-import] Querying iMessage database…")
        let (messages, unknownMessages) = try await messageService.fetchMessages(
            since: since,
            dbURL: resolved.database,
            knownIdentifiers: knownIdentifiers
        )
        logger.debug("[comms-import] Fetched \(messages.count) known + \(unknownMessages.count) unknown messages")

        // Record unknown senders for triage + event RSVP detection
        if !unknownMessages.isEmpty {
            let unknownSenderData: [(email: String, displayName: String?, subject: String, date: Date, source: EvidenceSource, isLikelyMarketing: Bool)]
                = unknownMessages.map { msg in
                    let handle = msg.handleID
                    let text = msg.text ?? ""
                    let preview = String(text.prefix(200))
                    return (email: handle, displayName: nil, subject: preview, date: msg.date, source: .iMessage, isLikelyMarketing: false)
                }
            try? UnknownSenderRepository.shared.bulkRecordUnknownSenders(unknownSenderData)
            logger.debug("Recorded \(unknownMessages.count) messages from unknown iMessage senders")

            // Check for event-matching RSVPs from unknown senders
            let autoReplyData = unknownMessages.map { msg in
                (handleID: msg.handleID, text: msg.text, date: msg.date)
            }
            EventCoordinator.shared.autoReplyToUnknownEventRSVPs(messages: autoReplyData)
        }

        // Auto-tag junk/spam senders as never-include (reuses the already-open DB)
        let junkHandles = try? await messageService.fetchJunkSenderHandles(dbURL: resolved.database)
        if let junkHandles, !junkHandles.isEmpty {
            for handle in junkHandles {
                try? UnknownSenderRepository.shared.markNeverInclude(identifier: handle, source: .iMessage)
            }
            logger.debug("Auto-tagged \(junkHandles.count) junk/spam iMessage senders as never-include")
        }

        guard !messages.isEmpty else {
            logger.debug("[comms-import] No new messages from known contacts")
            return (0, [])
        }

        // Group messages by (handle, day) for analysis
        logger.debug("[comms-import] Grouping \(messages.count) messages by handle+day…")
        let grouped = groupMessagesByHandleAndDay(messages)

        // Upsert all messages WITHOUT analysis (fast persist)
        logger.debug("[comms-import] Upserting \(messages.count) messages into SwiftData…")
        let upsertData: [(MessageDTO, MessageAnalysisDTO?)] = messages.map { ($0, nil) }
        try evidenceRepository.bulkUpsertMessages(upsertData)
        logger.debug("[comms-import] Upsert complete")

        // Update watermark to newest message date
        if let newest = messages.max(by: { $0.date < $1.date })?.date {
            lastMessageWatermark = newest
            UserDefaults.standard.set(newest.timeIntervalSinceReferenceDate, forKey: "commsLastMessageWatermark")
        }

        // Collect thread data for deferred background analysis
        var deferred: [DeferredThreadAnalysis] = []
        if analyzeMessages {
            for (_, threadMessages) in grouped {
                let handle = threadMessages.first?.handleID ?? ""
                let contactName = resolveContactName(for: handle)
                let contactRole = resolveContactRole(for: handle)

                let analysisInput: [(text: String, date: Date, isFromMe: Bool)] = threadMessages.compactMap { msg in
                    guard let text = msg.text, !text.isEmpty else { return nil }
                    return (text: text, date: msg.date, isFromMe: msg.isFromMe)
                }

                if !analysisInput.isEmpty, let lastMsg = threadMessages.last {
                    // Use the last INCOMING message as the reference for RSVP matching.
                    // Thread analysis covers both directions, but RSVPs should only be
                    // attributed to contacts from their incoming messages (isFromMe=false).
                    let referenceGUID: String
                    if let lastIncoming = threadMessages.last(where: { !$0.isFromMe }) {
                        referenceGUID = lastIncoming.guid
                    } else {
                        // All outgoing — use last message; isFromMe on evidence will
                        // cause RSVPMatchingService to skip RSVP attribution (correct).
                        referenceGUID = lastMsg.guid
                    }

                    deferred.append(DeferredThreadAnalysis(
                        lastMessageGUID: referenceGUID,
                        messages: analysisInput,
                        handle: handle,
                        contactName: contactName,
                        contactRole: contactRole
                    ))
                }
            }
        }

        return (messages.count, deferred)
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
            logger.debug("No new call records from known contacts")
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
        let commsSources: Set<EvidenceSource> = [.iMessage, .phoneCall, .faceTime, .whatsApp, .whatsAppCall]

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

        logger.debug("Refreshing relationship summaries for \(toRefresh.count) people with communications")

        for person in toRefresh.prefix(10) {
            guard !Task.isCancelled else {
                logger.debug("Summary refresh cancelled")
                break
            }
            await NoteAnalysisCoordinator.shared.refreshRelationshipSummary(for: person)
        }
    }

    // MARK: - WhatsApp Messages Import

    /// Thread data for deferred WhatsApp background analysis.
    private struct DeferredWAThreadAnalysis: Sendable {
        let lastMessageStanzaID: String
        let messages: [(text: String, date: Date, isFromMe: Bool)]
        let jid: String
        let contactName: String?
        let contactRole: String?
    }

    private func importWhatsAppMessages(since: Date, knownPhones: Set<String>) async throws -> (count: Int, deferred: [DeferredWAThreadAnalysis]) {
        guard let resolved = bookmarkManager.resolveWhatsAppURL() else {
            logger.warning("Could not resolve WhatsApp bookmark")
            return (0, [])
        }
        guard resolved.directory.startAccessingSecurityScopedResource() else {
            logger.warning("Could not access security-scoped WhatsApp directory")
            return (0, [])
        }
        defer { bookmarkManager.stopAccessing(resolved.directory) }

        let messages = try await whatsAppService.fetchMessages(
            since: since,
            dbURL: resolved.messagesDB,
            knownPhones: knownPhones
        )

        guard !messages.isEmpty else { return (0, []) }

        // Group messages by (JID, day) for analysis
        let grouped = groupWhatsAppMessagesByJIDAndDay(messages)

        // Upsert all messages WITHOUT analysis (fast persist)
        let upsertData: [(WhatsAppMessageDTO, MessageAnalysisDTO?)] = messages.map { ($0, nil) }
        try evidenceRepository.bulkUpsertWhatsAppMessages(upsertData)

        if let newest = messages.max(by: { $0.date < $1.date })?.date {
            lastWhatsAppMessageWatermark = newest
            UserDefaults.standard.set(newest.timeIntervalSinceReferenceDate, forKey: "commsLastWhatsAppMessageWatermark")
        }

        // Collect thread data for deferred background analysis
        var deferred: [DeferredWAThreadAnalysis] = []
        if analyzeWhatsAppMessages {
            for (_, threadMessages) in grouped {
                let jid = threadMessages.first?.contactJID ?? ""
                let contactName = resolveContactNameByPhone(jid: jid)
                let contactRole = resolveContactRoleByPhone(jid: jid)

                let analysisInput: [(text: String, date: Date, isFromMe: Bool)] = threadMessages.compactMap { msg in
                    guard let text = msg.text, !text.isEmpty else { return nil }
                    return (text: text, date: msg.date, isFromMe: msg.isFromMe)
                }

                if !analysisInput.isEmpty, let lastMsg = threadMessages.last {
                    // Use the last INCOMING message as the reference for RSVP matching.
                    let referenceStanzaID: String
                    if let lastIncoming = threadMessages.last(where: { !$0.isFromMe }) {
                        referenceStanzaID = lastIncoming.stanzaID
                    } else {
                        referenceStanzaID = lastMsg.stanzaID
                    }

                    deferred.append(DeferredWAThreadAnalysis(
                        lastMessageStanzaID: referenceStanzaID,
                        messages: analysisInput,
                        jid: jid,
                        contactName: contactName,
                        contactRole: contactRole
                    ))
                }
            }
        }

        return (messages.count, deferred)
    }

    // MARK: - WhatsApp Calls Import

    private func importWhatsAppCalls(since: Date, knownPhones: Set<String>) async throws -> Int {
        guard let resolved = bookmarkManager.resolveWhatsAppURL() else {
            logger.warning("Could not resolve WhatsApp bookmark for calls")
            return 0
        }
        guard resolved.directory.startAccessingSecurityScopedResource() else {
            logger.warning("Could not access security-scoped WhatsApp directory for calls")
            return 0
        }
        defer { bookmarkManager.stopAccessing(resolved.directory) }

        let calls = try await whatsAppService.fetchCalls(
            since: since,
            dbURL: resolved.callsDB,
            knownPhones: knownPhones
        )

        guard !calls.isEmpty else { return 0 }

        try evidenceRepository.bulkUpsertWhatsAppCalls(calls)

        if let newest = calls.max(by: { $0.date < $1.date })?.date {
            lastWhatsAppCallWatermark = newest
            UserDefaults.standard.set(newest.timeIntervalSinceReferenceDate, forKey: "commsLastWhatsAppCallWatermark")
        }

        return calls.count
    }

    // MARK: - WhatsApp Unknown Sender Discovery

    private func discoverWhatsAppUnknownSenders(knownPhones: Set<String>) async {
        guard let resolved = bookmarkManager.resolveWhatsAppURL() else { return }
        guard resolved.directory.startAccessingSecurityScopedResource() else { return }
        defer { bookmarkManager.stopAccessing(resolved.directory) }

        do {
            let allJIDs = try await whatsAppService.fetchAllJIDs(dbURL: resolved.messagesDB)

            var unknownSenders: [(email: String, displayName: String?, subject: String, date: Date, source: EvidenceSource, isLikelyMarketing: Bool)] = []

            for jid in allJIDs {
                let phone = whatsAppJIDToPhone(jid.jid)
                guard !knownPhones.contains(phone) else { continue }
                let displayName = jid.partnerName ?? phone
                unknownSenders.append((
                    email: phone,
                    displayName: displayName,
                    subject: "WhatsApp (\(jid.messageCount) messages)",
                    date: Date(),
                    source: .whatsApp,
                    isLikelyMarketing: false
                ))
            }

            if !unknownSenders.isEmpty {
                try UnknownSenderRepository.shared.bulkRecordUnknownSenders(unknownSenders)
                logger.debug("Recorded \(unknownSenders.count) unknown WhatsApp senders for triage")
            }
        } catch {
            logger.warning("WhatsApp unknown sender discovery failed: \(error)")
        }
    }

    // MARK: - WhatsApp Enrichment

    /// Generate enrichment candidates for Apple Contacts from WhatsApp JID phone numbers.
    /// When a WhatsApp JID matches a SamPerson by canonicalized phone, but the full
    /// international number isn't in their phoneAliases, suggest adding it.
    private func generateWhatsAppEnrichments(knownPhones: Set<String>) async {
        guard let resolved = bookmarkManager.resolveWhatsAppURL() else { return }
        guard resolved.directory.startAccessingSecurityScopedResource() else { return }
        defer { bookmarkManager.stopAccessing(resolved.directory) }

        do {
            let allJIDs = try await whatsAppService.fetchAllJIDs(dbURL: resolved.messagesDB)
            guard let people = try? peopleRepository.fetchAll() else { return }

            var candidates: [EnrichmentCandidate] = []

            for jid in allJIDs {
                let canonPhone = whatsAppJIDToPhone(jid.jid)
                guard knownPhones.contains(canonPhone) else { continue }

                // Find the matching person
                guard let person = people.first(where: { p in
                    p.phoneAliases.contains(where: { canonicalizePhone($0) == canonPhone })
                }) else { continue }

                // Extract the full international number from the JID (before @)
                let fullNumber = jid.jid.split(separator: "@").first.map(String.init) ?? ""
                guard !fullNumber.isEmpty else { continue }

                // Format as +{number} for display
                let formattedNumber = fullNumber.hasPrefix("+") ? fullNumber : "+\(fullNumber)"

                // Check if this full number is already in the person's phoneAliases
                let alreadyHas = person.phoneAliases.contains(where: { alias in
                    alias.filter(\.isNumber) == fullNumber.filter(\.isNumber)
                })
                guard !alreadyHas else { continue }

                candidates.append(EnrichmentCandidate(
                    personID: person.id,
                    field: .whatsApp,
                    proposedValue: formattedNumber,
                    currentValue: person.phoneAliases.first,
                    source: .whatsAppMessages,
                    sourceDetail: "WhatsApp contact: \(jid.partnerName ?? canonPhone)"
                ))
            }

            if !candidates.isEmpty {
                let inserted = try EnrichmentRepository.shared.bulkRecord(candidates)
                logger.debug("Generated \(inserted) WhatsApp phone enrichment candidates")
            }
        } catch {
            logger.warning("WhatsApp enrichment generation failed: \(error)")
        }
    }

    // MARK: - WhatsApp Helpers

    /// Group WhatsApp messages by (JID, day) for conversation-level analysis.
    private func groupWhatsAppMessagesByJIDAndDay(_ messages: [WhatsAppMessageDTO]) -> [String: [WhatsAppMessageDTO]] {
        let calendar = Calendar.current
        var groups: [String: [WhatsAppMessageDTO]] = [:]

        for message in messages {
            let dayString = calendar.startOfDay(for: message.date).timeIntervalSinceReferenceDate
            let key = "\(message.contactJID)_\(Int(dayString))"
            groups[key, default: []].append(message)
        }

        return groups
    }

    /// Resolve contact name for a WhatsApp JID (phone-based).
    private func resolveContactNameByPhone(jid: String) -> String? {
        guard let people = try? peopleRepository.fetchAll() else { return nil }
        let phone = whatsAppJIDToPhone(jid)

        for person in people {
            if person.phoneAliases.contains(where: { canonicalizePhone($0) == phone }) {
                return person.displayNameCache ?? person.displayName
            }
        }
        return nil
    }

    /// Resolve contact role for a WhatsApp JID (phone-based).
    private func resolveContactRoleByPhone(jid: String) -> String? {
        guard let people = try? peopleRepository.fetchAll() else { return nil }
        let phone = whatsAppJIDToPhone(jid)

        for person in people {
            if person.phoneAliases.contains(where: { canonicalizePhone($0) == phone }) {
                return person.roleBadges.first
            }
        }
        return nil
    }

    /// Convert a WhatsApp JID to canonicalized phone (last 10 digits).
    private func whatsAppJIDToPhone(_ jid: String) -> String {
        let local = jid.split(separator: "@").first.map(String.init) ?? jid
        let digits = local.filter(\.isNumber)
        guard digits.count >= 7 else { return jid.lowercased() }
        return String(digits.suffix(10))
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
