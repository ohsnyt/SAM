//
//  MailImportCoordinator.swift
//  SAM_crm
//
//  Email Integration - Import Coordinator
//
//  Orchestrates email fetch → analyze → upsert pipeline via Mail.app.
//

import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailImportCoordinator")

@MainActor
@Observable
final class MailImportCoordinator {
    static let shared = MailImportCoordinator()

    // Dependencies
    private let mailService = MailService.shared
    private let mailDBService = MailDatabaseService.shared
    private let analysisService = EmailAnalysisService.shared
    private let evidenceRepository = EvidenceRepository.shared
    private let peopleRepository = PeopleRepository.shared

    /// Whether direct database access is available (bookmark granted for ~/Library/Mail).
    /// When true, imports bypass AppleScript entirely for metadata + body fetches.
    var hasDirectAccess: Bool { BookmarkManager.shared.hasMailDirAccess }

    // Observable state
    var importStatus: ImportStatus = .idle
    var lastImportedAt: Date?
    var lastImportCount: Int = 0
    var lastError: String?
    var unknownSenderCount: Int = 0
    var knownSenderCount: Int = 0
    /// Number of LinkedIn notification emails processed during the last import run.
    private(set) var linkedInNotificationCount: Int = 0
    /// Number of Facebook notification emails processed during the last import run.
    private(set) var facebookNotificationCount: Int = 0

    /// Available Mail.app accounts (loaded from service, not persisted)
    var availableAccounts: [MailAccountDTO] = []

    // Settings (observable vars synced to UserDefaults)
    private(set) var mailEnabled: Bool = false
    private(set) var selectedAccountIDs: [String] = []
    private(set) var importIntervalSeconds: TimeInterval = 600
    /// Lookback days for initial import. 0 means "All" (no limit).
    private(set) var lookbackDays: Int = 30
    private(set) var filterRules: [MailFilterRule] = []

    private(set) var lastMailWatermark: Date?
    private(set) var lastSentMailWatermark: Date?

    private var lastImportTime: Date?
    private var importTask: Task<Void, Never>?

    private init() {
        mailEnabled = UserDefaults.standard.bool(forKey: "mailImportEnabled")
        selectedAccountIDs = UserDefaults.standard.stringArray(forKey: "mailSelectedAccountIDs") ?? []
        let interval = UserDefaults.standard.double(forKey: "mailImportInterval")
        importIntervalSeconds = interval > 0 ? interval : 600
        let days = UserDefaults.standard.integer(forKey: "mailLookbackDays")
        // 0 means "All" (no limit); unset → fall back to globalLookbackDays (default 30)
        let globalDays = UserDefaults.standard.object(forKey: "globalLookbackDays") != nil
            ? UserDefaults.standard.integer(forKey: "globalLookbackDays")
            : 30
        lookbackDays = days >= 0 && UserDefaults.standard.object(forKey: "mailLookbackDays") != nil ? days : globalDays
        if let data = UserDefaults.standard.data(forKey: "mailFilterRules"),
           let rules = try? JSONDecoder().decode([MailFilterRule].self, from: data) {
            filterRules = rules
        }
        if let ts = UserDefaults.standard.object(forKey: "mailLastWatermark") as? Double {
            lastMailWatermark = Date(timeIntervalSinceReferenceDate: ts)
        }
        if let ts = UserDefaults.standard.object(forKey: "mailLastSentWatermark") as? Double {
            lastSentMailWatermark = Date(timeIntervalSinceReferenceDate: ts)
        }
    }

    // MARK: - Settings Setters

    func setMailEnabled(_ value: Bool) {
        mailEnabled = value
        UserDefaults.standard.set(value, forKey: "mailImportEnabled")

        // Record the first time mail monitoring is enabled (Phase 6: notification setup guidance)
        if value && UserDefaults.standard.object(forKey: "sam.linkedin.monitoringSince") == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "sam.linkedin.monitoringSince")
        }
    }

    func setSelectedAccountIDs(_ value: [String]) {
        selectedAccountIDs = value
        UserDefaults.standard.set(value, forKey: "mailSelectedAccountIDs")
    }

    func setImportInterval(_ value: TimeInterval) {
        importIntervalSeconds = value
        UserDefaults.standard.set(value, forKey: "mailImportInterval")
    }

    func setLookbackDays(_ value: Int) {
        let changed = value != lookbackDays
        lookbackDays = value
        UserDefaults.standard.set(value, forKey: "mailLookbackDays")
        if changed { resetMailWatermark() }
    }

    func resetMailWatermark() {
        lastMailWatermark = nil
        UserDefaults.standard.removeObject(forKey: "mailLastWatermark")
        logger.debug("Mail watermark reset — next import will scan full lookback window")
    }

    func setFilterRules(_ value: [MailFilterRule]) {
        filterRules = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "mailFilterRules")
        }
    }

    // MARK: - Cancellation

    /// Cancel all background tasks. Called by AppDelegate on app termination.
    func cancelAll() {
        importTask?.cancel()
        importTask = nil
        if importStatus == .importing {
            importStatus = .idle
        }
        logger.debug("All tasks cancelled")
    }

    // MARK: - Public API

    var isConfigured: Bool {
        !selectedAccountIDs.isEmpty
    }

    /// Load available accounts from Mail.app.
    func loadAccounts() async {
        availableAccounts = await mailService.fetchAccounts()
    }

    func startAutoImport() {
        #if DEBUG
        if UserDefaults.standard.isTestDataLoaded || UserDefaults.standard.isTestDataActive { return }
        #endif
        guard mailEnabled, isConfigured else { return }
        Task { await importNow() }
    }

    /// Fire-and-forget import — does not block the caller.
    func startImport() {
        #if DEBUG
        if UserDefaults.standard.isTestDataLoaded || UserDefaults.standard.isTestDataActive { return }
        #endif
        guard importStatus != .importing, isConfigured else { return }
        importTask?.cancel()
        importTask = Task { await performImport(force: true) }
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
        importTask = Task { await performImport(force: true) }
        await importTask?.value
    }

    /// Check if Mail.app is accessible. Returns nil on success.
    func checkMailAccess() async -> String? {
        await mailService.checkAccess()
    }

    // MARK: - Private

    private func performImport(force: Bool = false) async {
        guard isConfigured else {
            lastError = "No Mail accounts selected"
            return
        }

        if !force, let last = lastImportTime, Date().timeIntervalSince(last) < importIntervalSeconds {
            logger.debug("Skipping import — last import was \(Date().timeIntervalSince(last), format: .fixed(precision: 0))s ago (interval: \(self.importIntervalSeconds)s)")
            return
        }

        importStatus = .importing
        lastError = nil
        EvidenceRepository.shared.invalidateResolutionCache()

        do {
            let lookbackDate: Date = lookbackDays == 0
                ? .distantPast
                : (Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date())
            let since = lastMailWatermark ?? lookbackDate

            // Strategy: prefer direct database access (no AppleScript, Mail stays responsive)
            let useDirectAccess = hasDirectAccess
            var mailDirURL: URL?
            var versionDirURL: URL?
            var envelopeURL: URL?

            if useDirectAccess {
                mailDirURL = BookmarkManager.shared.resolveMailDirURL()
                if let dirURL = mailDirURL {
                    _ = dirURL.startAccessingSecurityScopedResource()
                    versionDirURL = await mailDBService.findMailDataDir(rootURL: dirURL)
                    if let vDir = versionDirURL {
                        envelopeURL = await mailDBService.findEnvelopeIndex(in: vDir)
                    }
                }
            }
            // Release security-scoped resource when import completes (success or failure)
            defer {
                if let dirURL = mailDirURL {
                    BookmarkManager.shared.stopAccessing(dirURL)
                }
            }

            // When direct DB access is available, skip osascript entirely.
            // The pre-flight osascript check itself can hang if Mail is unresponsive,
            // and we don't need it — metadata comes from the DB, bodies from .emlx files.
            // Osascript fallback is only used when there's NO direct DB access.
            let osascriptAvailable = (envelopeURL == nil)
            if envelopeURL != nil {
                logger.debug("[mail-import] Direct DB access available — skipping osascript entirely")
            }

            // 1. Fast metadata sweep (all messages)
            let allMetas: [MessageMeta]
            let fetchWarnings: String?

            if let envURL = envelopeURL {
                // Direct database access — zero AppleScript, Mail never touched
                logger.debug("Using direct database access for metadata sweep")
                allMetas = try await mailDBService.fetchMetadata(
                    dbURL: envURL,
                    since: since,
                    accountEmails: selectedAccountIDs,
                    maxResults: 200
                )
                fetchWarnings = nil
            } else {
                // Fallback: AppleScript via osascript subprocess
                if useDirectAccess {
                    logger.warning("Direct access bookmark exists but database not found — falling back to AppleScript")
                }
                let (metas, warnings) = try await mailService.fetchMetadata(
                    accountIDs: selectedAccountIDs, since: since
                )
                allMetas = metas
                fetchWarnings = warnings
            }

            if allMetas.isEmpty, let warning = fetchWarnings {
                lastError = warning
            }

            logger.debug("[mail-import] Metadata sweep done: \(allMetas.count) messages")

            // 1b. Intercept LinkedIn notification emails before partitioning.
            // LinkedIn notification addresses (e.g. notifications-noreply@linkedin.com) are
            // never in contacts, so they always fall into the "unknown" bucket and would
            // pollute the Unknown Senders triage queue. We remove them from the main flow
            // here and route them to the LinkedIn notification pipeline instead.
            let linkedInMetas = allMetas.filter { $0.senderEmail.hasSuffix("@linkedin.com") }
            let regularMetas  = allMetas.filter { !$0.senderEmail.hasSuffix("@linkedin.com") }

            if !linkedInMetas.isEmpty {
                linkedInNotificationCount = 0
                await processLinkedInNotifications(linkedInMetas, versionDir: versionDirURL, osascriptAvailable: osascriptAvailable)
            }

            // 1c. Intercept Facebook notification emails before partitioning.
            // Same rationale as LinkedIn — @facebookmail.com / @facebook.com senders
            // are never in contacts and would pollute the Unknown Senders triage queue.
            let facebookMetas = regularMetas.filter {
                $0.senderEmail.hasSuffix("@facebookmail.com") || $0.senderEmail.hasSuffix("@facebook.com")
            }
            let regularMetasFiltered = regularMetas.filter {
                !$0.senderEmail.hasSuffix("@facebookmail.com") && !$0.senderEmail.hasSuffix("@facebook.com")
            }

            if !facebookMetas.isEmpty {
                facebookNotificationCount = 0
                await processFacebookNotifications(facebookMetas)
            }

            // 2. Build known emails set from PeopleRepository
            let knownEmails = try peopleRepository.allKnownEmails()

            // 3. Also exclude neverInclude senders
            let neverInclude = try UnknownSenderRepository.shared.neverIncludeEmails()

            // 4. Partition metas → known vs unknown (LinkedIn + Facebook excluded)
            let (knownMetas, unknownMetas) = partitionBySenderKnown(
                metas: regularMetasFiltered,
                knownEmails: knownEmails,
                neverIncludeEmails: neverInclude
            )

            knownSenderCount = knownMetas.count
            unknownSenderCount = unknownMetas.count

            logger.debug("\(knownMetas.count) emails from known senders, \(unknownMetas.count) unknown skipped")

            // 5. Record unknown senders for triage (excluding neverInclude)
            let unknownToRecord = unknownMetas.filter { !neverInclude.contains($0.senderEmail) }
            if !unknownToRecord.isEmpty {
                let senderData = unknownToRecord.map { meta in
                    (email: meta.senderEmail,
                     displayName: MailService.extractName(from: meta.sender),
                     subject: meta.subject,
                     date: meta.date,
                     source: EvidenceSource.mail,
                     isLikelyMarketing: meta.isLikelyMarketing)
                }
                try UnknownSenderRepository.shared.bulkRecordUnknownSenders(senderData)
            }

            logger.debug("[mail-import] Partitioned: \(knownMetas.count) known, \(unknownMetas.count) unknown, \(linkedInMetas.count) LinkedIn, \(facebookMetas.count) Facebook")

            // 6. Fetch bodies only for known senders
            // Hybrid strategy: try .emlx files first (instant, no Mail impact),
            // then fall back to osascript for messages without local files (IMAP).
            var emails: [EmailDTO] = []
            var metasNeedingFallback = knownMetas

            if let vDir = versionDirURL, let mDir = mailDirURL {
                let directEmails = await mailDBService.fetchBodies(
                    mailRootURL: mDir,
                    versionDir: vDir,
                    metas: knownMetas,
                    filterRules: filterRules
                )
                emails.append(contentsOf: directEmails)

                // Determine which metas weren't found via .emlx
                let foundIDs = Set(directEmails.map { $0.id })
                metasNeedingFallback = knownMetas.filter { !foundIDs.contains(String($0.mailID)) }

                if !metasNeedingFallback.isEmpty {
                    logger.debug("\(directEmails.count) bodies from .emlx, \(metasNeedingFallback.count) need osascript fallback")
                }
            }

            // Osascript fallback for messages without local .emlx files
            if !metasNeedingFallback.isEmpty, osascriptAvailable {
                guard !Task.isCancelled else { return }
                let fallbackEmails = await mailService.fetchBodies(
                    for: metasNeedingFallback, filterRules: filterRules
                )
                emails.append(contentsOf: fallbackEmails)
            }

            // 7. Upsert into EvidenceRepository WITHOUT analysis (fast persist)
            let upsertData: [(EmailDTO, EmailAnalysisDTO?)] = emails.map { ($0, nil) }
            try evidenceRepository.bulkUpsertEmails(upsertData, direction: .inbound)

            // Update watermark to newest email date (from all metas, not just bodies)
            // Include LinkedIn + Facebook notification dates so they advance the watermark too
            let allDates = knownMetas.map(\.date) + unknownMetas.map(\.date) + linkedInMetas.map(\.date) + facebookMetas.map(\.date)
            if let newest = allDates.max() {
                lastMailWatermark = newest
                UserDefaults.standard.set(newest.timeIntervalSinceReferenceDate, forKey: "mailLastWatermark")
            }

            // ── Sent Mail Pipeline ──────────────────────────────────────────
            // Scan the Sent mailbox for outbound emails to known contacts.
            // This fills the direction gap: SAM can now see both sides of email communication.
            let sentSince = lastSentMailWatermark ?? lookbackDate

            let sentMetas: [MessageMeta]
            let sentWarnings: String?
            if let envURL = envelopeURL {
                sentMetas = try await mailDBService.fetchMetadata(
                    dbURL: envURL,
                    since: sentSince,
                    accountEmails: selectedAccountIDs,
                    maxResults: 50,
                    mailbox: .sent
                )
                sentWarnings = nil
            } else {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                let (sm, sw) = try await mailService.fetchMetadata(
                    accountIDs: selectedAccountIDs, since: sentSince, mailbox: .sent
                )
                sentMetas = sm
                sentWarnings = sw
            }

            if let sentWarnings { logger.debug("Sent mailbox warnings: \(sentWarnings)") }

            // For sent mail, the user is the sender. Match by recipient → known contact.
            let (knownSentMetas, _) = partitionSentByRecipientKnown(
                metas: sentMetas, knownEmails: knownEmails
            )

            if !knownSentMetas.isEmpty {
                // Hybrid: try .emlx first, osascript fallback for IMAP messages
                var sentEmails: [EmailDTO] = []
                var sentNeedingFallback = knownSentMetas

                if let vDir = versionDirURL, let mDir = mailDirURL {
                    let directSent = await mailDBService.fetchBodies(
                        mailRootURL: mDir,
                        versionDir: vDir,
                        metas: knownSentMetas,
                        filterRules: [],
                        mailbox: .sent
                    )
                    sentEmails.append(contentsOf: directSent)
                    let foundIDs = Set(directSent.map { $0.id })
                    sentNeedingFallback = knownSentMetas.filter { !foundIDs.contains(String($0.mailID)) }
                }

                if !sentNeedingFallback.isEmpty, osascriptAvailable, !Task.isCancelled {
                    let fallbackSent = await mailService.fetchBodies(
                        for: sentNeedingFallback, filterRules: [], mailbox: .sent
                    )
                    sentEmails.append(contentsOf: fallbackSent)
                }

                if !sentEmails.isEmpty {
                    let sentUpsertData: [(EmailDTO, EmailAnalysisDTO?)] = sentEmails.map { ($0, nil) }
                    try evidenceRepository.bulkUpsertEmails(sentUpsertData, direction: .outbound)
                    logger.debug("Sent mail import: \(sentEmails.count) outbound emails from known recipients")
                }
            }

            // Update sent watermark
            if let newestSent = sentMetas.map(\.date).max() {
                lastSentMailWatermark = newestSent
                UserDefaults.standard.set(newestSent.timeIntervalSinceReferenceDate, forKey: "mailLastSentWatermark")
            }

            // 8. Prune orphaned mail evidence — only for known senders
            // We must NOT prune evidence for emails we intentionally skipped
            if !emails.isEmpty {
                let validUIDs = Set(emails.map { $0.sourceUID })
                try evidenceRepository.pruneMailOrphans(
                    validSourceUIDs: validUIDs,
                    scopedToSenderEmails: knownEmails
                )
            }

            lastImportedAt = Date()
            lastImportTime = Date()
            lastImportCount = emails.count
            importStatus = .success

            logger.info("Mail import complete: \(emails.count) emails from known senders")

            // 9. Background: analyze each email with LLM, then trigger insights + role deduction
            let emailsToAnalyze = emails
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                for email in emailsToAnalyze {
                    guard !Task.isCancelled else { break }
                    do {
                        let analysis = try await self.analysisService.analyzeEmail(
                            subject: email.subject,
                            body: email.bodyPlainText,
                            senderName: email.senderName
                        )
                        try self.evidenceRepository.updateEmailAnalysis(
                            sourceUID: email.sourceUID,
                            analysis: analysis
                        )
                    } catch {
                        logger.warning("Background analysis failed for email \(email.messageID): \(error)")
                    }
                }
                PostImportOrchestrator.shared.importDidComplete(source: "mail")
            }

        } catch {
            lastError = error.localizedDescription
            importStatus = .failed
            logger.error("Mail import failed: \(error)")
        }
    }

    // MARK: - Reprocess

    /// Reprocess emails for a specific sender (after user adds them as a contact).
    func reprocessForSender(email senderEmail: String) async {
        guard isConfigured else { return }

        do {
            let since: Date = lookbackDays == 0
                ? .distantPast
                : (Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date())

            // 1. Full metadata sweep
            let (allMetas, _) = try await mailService.fetchMetadata(
                accountIDs: selectedAccountIDs, since: since
            )

            // 2. Filter to just this sender's emails
            let senderMetas = allMetas.filter { $0.senderEmail == senderEmail.lowercased() }
            guard !senderMetas.isEmpty else {
                logger.debug("No emails found for sender \(senderEmail, privacy: .private) to reprocess")
                return
            }

            // 3. Fetch bodies for those metas
            let emails = await mailService.fetchBodies(for: senderMetas, filterRules: filterRules)

            // 4. Analyze with LLM
            var analyzedEmails: [(EmailDTO, EmailAnalysisDTO?)] = []
            for email in emails {
                do {
                    let analysis = try await analysisService.analyzeEmail(
                        subject: email.subject,
                        body: email.bodyPlainText,
                        senderName: email.senderName
                    )
                    analyzedEmails.append((email, analysis))
                } catch {
                    logger.warning("Analysis failed for reprocess email \(email.messageID): \(error)")
                    analyzedEmails.append((email, nil))
                }
            }

            // 5. Upsert (deduplicates by sourceUID)
            try evidenceRepository.bulkUpsertEmails(analyzedEmails)

            // 6. Debounced post-import work
            PostImportOrchestrator.shared.importDidComplete(source: "mail-reprocess")

            logger.debug("Reprocessed \(emails.count) emails for sender \(senderEmail, privacy: .private)")

        } catch {
            logger.error("Reprocess failed for \(senderEmail, privacy: .private): \(error)")
        }
    }

    // MARK: - LinkedIn Notification Processing

    /// Process a batch of LinkedIn notification emails (sender @linkedin.com).
    ///
    /// For each message:
    /// 1. Skip known non-actionable senders (jobs-noreply, news, etc.)
    /// 2. Fetch the MIME source to get the HTML body
    /// 3. Parse the HTML into a LinkedInNotificationEvent
    /// 4. Route the event through LinkedInImportCoordinator.handleNotificationEvent()
    private func processLinkedInNotifications(_ metas: [MessageMeta], versionDir: URL?, osascriptAvailable: Bool) async {
        // Non-actionable LinkedIn sender local-parts — skip without fetching
        let skipLocalParts: Set<String> = [
            "jobs-noreply", "news", "marketing", "promotions",
            "invitations", "weekly-digest",
        ]

        var processed = 0

        for (index, meta) in metas.enumerated() {
            guard !Task.isCancelled else { break }

            // Check sender local-part (before the @)
            let localPart = meta.senderEmail.components(separatedBy: "@").first ?? ""
            if skipLocalParts.contains(localPart) { continue }

            // Fetch MIME source: try .emlx first, then osascript fallback
            var mimeSource: String?
            if let vDir = versionDir {
                mimeSource = await mailDBService.fetchMIMESource(versionDir: vDir, meta: meta)
            }
            // Fallback to osascript only if permission is available
            if mimeSource == nil, osascriptAvailable {
                if index > 0 {
                    try? await Task.sleep(for: .seconds(1.0))
                }
                mimeSource = await mailService.fetchMIMESource(for: meta)
            }
            guard let mimeSource else {
                logger.debug("Skipping LinkedIn notification \(meta.mailID) — no MIME source")
                continue
            }

            let html = MailService.extractHTMLFromMIMESource(mimeSource)

            // Parse the notification event
            guard let event = LinkedInEmailParser.parse(
                htmlBody: html,
                subject: meta.subject,
                date: meta.date,
                sourceEmailId: String(meta.mailID)
            ) else {
                // Non-actionable noise (digest, jobs listing, etc.) — skip silently
                continue
            }

            // Route through the LinkedIn coordinator
            await LinkedInImportCoordinator.shared.handleNotificationEvent(event)
            processed += 1
        }

        linkedInNotificationCount += processed
        if processed > 0 {
            logger.debug("Processed \(processed) LinkedIn notification emails")
        }
    }

    // MARK: - Facebook Notification Processing

    /// Process a batch of Facebook notification emails (sender @facebookmail.com / @facebook.com).
    ///
    /// Subject-only parsing — no MIME body fetch needed (lightweight).
    private func processFacebookNotifications(_ metas: [MessageMeta]) async {
        // Non-actionable Facebook sender local-parts
        let skipLocalParts: Set<String> = [
            "noreply", "security", "ads", "support",
        ]

        var processed = 0

        for meta in metas {
            let localPart = meta.senderEmail.components(separatedBy: "@").first ?? ""
            if skipLocalParts.contains(localPart) { continue }

            // Parse from subject line only (no MIME fetch)
            guard let event = FacebookEmailParser.parse(
                subject: meta.subject,
                date: meta.date,
                sourceEmailId: String(meta.mailID)
            ) else {
                continue
            }

            // Route through Facebook coordinator for touch recording
            await FacebookImportCoordinator.shared.handleNotificationEvent(event)
            processed += 1
        }

        facebookNotificationCount += processed
        if processed > 0 {
            logger.debug("Processed \(processed) Facebook notification emails")
        }
    }

    // MARK: - Helpers

    /// Partition message metas into known-sender and unknown-sender groups.
    private func partitionBySenderKnown(
        metas: [MessageMeta],
        knownEmails: Set<String>,
        neverIncludeEmails: Set<String>
    ) -> (known: [MessageMeta], unknown: [MessageMeta]) {
        var known: [MessageMeta] = []
        var unknown: [MessageMeta] = []

        for meta in metas {
            if knownEmails.contains(meta.senderEmail) {
                known.append(meta)
            } else if neverIncludeEmails.contains(meta.senderEmail) {
                // Silently skip neverInclude — still "unknown" for counting
                unknown.append(meta)
            } else {
                unknown.append(meta)
            }
        }

        return (known, unknown)
    }

    /// Cap on sent-mail body fetches per import cycle.
    /// Sent mail metadata doesn't include recipients, so we can't pre-filter by
    /// known contacts at the metadata stage. This cap limits the AppleScript
    /// body-fetch work and avoids hammering Mail.app. Emails beyond this cap
    /// will be picked up in subsequent import cycles via the sent watermark.
    private let maxSentBodyFetches = 50

    /// Partition sent-mail metas by whether any **recipient** is a known contact.
    /// For sent mail the user is the sender, so we match on recipients instead.
    ///
    /// Because recipient data isn't available at the metadata stage, this returns
    /// all non-marketing metas as "known" (capped at `maxSentBodyFetches`).
    /// The actual recipient filtering happens post-body-fetch via `bulkUpsertEmails`.
    private func partitionSentByRecipientKnown(
        metas: [MessageMeta],
        knownEmails: Set<String>
    ) -> (known: [MessageMeta], unknown: [MessageMeta]) {
        var known: [MessageMeta] = []
        var unknown: [MessageMeta] = []

        for meta in metas {
            if !meta.isLikelyMarketing && known.count < maxSentBodyFetches {
                known.append(meta)
            } else {
                unknown.append(meta)
            }
        }

        return (known, unknown)
    }

    enum ImportStatus: Equatable {
        case idle, importing, success, failed
    }
}
