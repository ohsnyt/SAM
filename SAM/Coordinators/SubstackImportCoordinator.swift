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
import AppKit
import UserNotifications
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

    /// Current phase of the import sheet state machine.
    var sheetPhase: SubstackSheetPhase = .setup

    /// Remembers the ZIP URL for post-import deletion.
    var importedZipURL: URL?

    // MARK: - Watcher Timers

    private var emailPollingTimer: Timer?
    private var filePollingTimer: Timer?

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
        resumeWatchersIfNeeded()
    }

    // MARK: - Watcher Persistence (UserDefaults)

    private var emailWatcherActive: Bool {
        get { UserDefaults.standard.bool(forKey: "sam.substack.emailWatcherActive") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.substack.emailWatcherActive") }
    }

    private var emailWatcherStartDate: Date? {
        get { UserDefaults.standard.object(forKey: "sam.substack.emailWatcherStartDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "sam.substack.emailWatcherStartDate") }
    }

    private var fileWatcherActive: Bool {
        get { UserDefaults.standard.bool(forKey: "sam.substack.fileWatcherActive") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.substack.fileWatcherActive") }
    }

    private var fileWatcherStartDate: Date? {
        get { UserDefaults.standard.object(forKey: "sam.substack.fileWatcherStartDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "sam.substack.fileWatcherStartDate") }
    }

    private var extractedDownloadURL: String? {
        get { UserDefaults.standard.string(forKey: "sam.substack.extractedDownloadURL") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.substack.extractedDownloadURL") }
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
        logger.debug("Starting Substack feed fetch: \(urlString)")

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
        logger.debug("Starting Substack subscriber import")

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
            logger.debug("Subscriber parse complete: \(subscribers.count) total, \(matched) matched")

        } catch {
            importStatus = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
            logger.error("Subscriber import failed: \(error.localizedDescription)")
            await DiagnosticsMailService.shared.sendErrorReport(
                area: "Substack subscriber import",
                context: [
                    "selectedFile": url.lastPathComponent,
                    "selectedPath": url.path
                ],
                error: error
            )
        }
    }

    /// Confirm the subscriber import — create touch records for matched, route unmatched to UnknownSender.
    func confirmSubscriberImport() async {
        guard importStatus == .awaitingReview else { return }

        importStatus = .importing
        statusMessage = "Processing subscribers..."
        logger.debug("Confirming Substack subscriber import")

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

    // MARK: - Import Flow (Sheet Entry Point)

    /// Entry point when the sheet opens. Checks state and routes to the right phase.
    func beginImportFlow() {
        let hasFeed = !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImported = lastSubscriberImportDate != nil

        if !hasFeed {
            sheetPhase = .setup
            return
        }

        if !hasImported {
            // Feed configured but never imported subscribers — go to instructions
            sheetPhase = .noZipFound
            return
        }

        // Returning user — scan Downloads
        sheetPhase = .scanning
        Task { await scanDownloadsFolder() }
    }

    // MARK: - Step 3: Scan ~/Downloads

    /// Scan ~/Downloads for Substack export ZIP files.
    func scanDownloadsFolder() async {
        sheetPhase = .scanning

        let fm = FileManager.default
        guard let downloadsURL = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            sheetPhase = .noZipFound
            return
        }

        do {
            let contents = try fm.contentsOfDirectory(
                at: downloadsURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            // Filter for ZIP files matching Substack export patterns
            let zipFiles = contents.filter { url in
                let name = url.lastPathComponent.lowercased()
                guard name.hasSuffix(".zip") else { return false }
                return name.hasPrefix("export-") || name.hasPrefix("substack-export-")
            }

            // Find the newest ZIP
            guard let newest = zipFiles.max(by: { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return dateA < dateB
            }) else {
                sheetPhase = .noZipFound
                return
            }

            let resourceValues = try newest.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let fileDate = resourceValues.contentModificationDate ?? Date()
            let fileSize = resourceValues.fileSize ?? 0

            // For auto-detect: only show if newer than last import
            if let lastImport = lastSubscriberImportDate, fileDate <= lastImport {
                sheetPhase = .noZipFound
                return
            }

            let info = ZipInfo(
                url: newest,
                fileName: newest.lastPathComponent,
                fileDate: fileDate,
                fileSize: Int64(fileSize)
            )
            sheetPhase = .zipFound(info)

        } catch {
            logger.error("Failed to scan ~/Downloads: \(error.localizedDescription)")
            sheetPhase = .noZipFound
        }
    }

    // MARK: - Step 5: Process ZIP

    /// Unzip a Substack export, find subscriber CSV, parse and match.
    func processZip(url: URL) async {
        sheetPhase = .processing
        importedZipURL = url
        statusMessage = "Unzipping export..."

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("SAM-Substack-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Unzip via /usr/bin/unzip
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", url.path, "-d", tempDir.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                sheetPhase = .failed("Failed to unzip the export file")
                return
            }

            statusMessage = "Finding subscriber data..."

            // Find subscriber CSV using existing helper
            let csvURL = try findSubscriberCSV(at: tempDir)

            // Load and match
            await loadSubscriberCSV(url: csvURL)

            // If we got candidates, transition to awaitingReview
            if importStatus == .awaitingReview {
                sheetPhase = .awaitingReview
            } else if case .failed(let msg) = importStatus {
                sheetPhase = .failed(msg)
            }

            // Clean up temp directory
            try? fm.removeItem(at: tempDir)

        } catch {
            sheetPhase = .failed(error.localizedDescription)
            try? fm.removeItem(at: tempDir)
        }
    }

    /// Complete the import and transition to the complete phase.
    func completeImportFromSheet() async {
        await confirmSubscriberImport()
        if importStatus == .complete {
            let matched = subscriberCandidates.filter {
                if case .exactMatchEmail = $0.matchStatus { return true }; return false
            }.count
            let total = subscriberCandidates.count
            let stats = ImportStats(
                subscriberCount: total,
                matchedCount: matched,
                newLeads: total - matched,
                touchesCreated: matched
            )
            sheetPhase = .complete(stats)
        }
    }

    // MARK: - Step 6: Open Substack Export Page

    /// Open the Substack settings/export page in the browser.
    func openSubstackExportPage() {
        let rawURL = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = rawURL
        if !base.hasPrefix("http") { base = "https://\(base)" }
        // Remove trailing /feed if present
        if base.hasSuffix("/feed") { base = String(base.dropLast(5)) }
        if base.hasSuffix("/") { base = String(base.dropLast()) }

        let exportURL = URL(string: "\(base)/publish/settings")
            ?? URL(string: "https://substack.com/settings")!
        NSWorkspace.shared.open(exportURL)
    }

    // MARK: - Step 7: Email Watcher

    /// Start polling Mail.app for the Substack export-ready email.
    func startEmailWatcher() {
        guard !MailImportCoordinator.shared.selectedAccountIDs.isEmpty,
              MailImportCoordinator.shared.mailEnabled else {
            logger.warning("Mail not configured — cannot watch for export email")
            return
        }

        emailWatcherActive = true
        emailWatcherStartDate = .now
        sheetPhase = .watchingEmail
        scheduleEmailPolling()
        logger.debug("Substack email watcher started")
    }

    /// Stop the email watcher.
    func stopEmailWatcher() {
        emailPollingTimer?.invalidate()
        emailPollingTimer = nil
        emailWatcherActive = false
        emailWatcherStartDate = nil
        logger.debug("Substack email watcher stopped")
    }

    private func scheduleEmailPolling() {
        emailPollingTimer?.invalidate()
        emailPollingTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.pollForExportEmail()
            }
        }
        // Also poll immediately
        Task { await pollForExportEmail() }
    }

    private func pollForExportEmail() async {
        // Check timeout (2 days)
        if let startDate = emailWatcherStartDate,
           Date.now.timeIntervalSince(startDate) > 2 * 24 * 3600 {
            stopEmailWatcher()
            sheetPhase = .failed("Email watcher timed out after 2 days. Try downloading manually from Substack.")
            return
        }

        do {
            let accountIDs = MailImportCoordinator.shared.selectedAccountIDs
            let since = emailWatcherStartDate ?? Date.now.addingTimeInterval(-3600)

            let (metas, _) = try await MailService.shared.fetchMetadata(
                accountIDs: accountIDs,
                since: since
            )

            // Filter for Substack export emails
            let exportEmail = metas.first { meta in
                let sender = meta.sender.lowercased()
                let subject = meta.subject.lowercased()
                return sender.contains("substack.com")
                    && subject.contains("export")
                    && subject.contains("ready")
            }

            guard let email = exportEmail else { return }

            // Found the email — try to extract download URL from MIME source
            var downloadURL: URL?
            if let mimeSource = await MailService.shared.fetchMIMESource(for: email) {
                downloadURL = extractDownloadURL(from: mimeSource)
            }

            stopEmailWatcher()

            if let url = downloadURL {
                extractedDownloadURL = url.absoluteString
                sheetPhase = .emailFound(url)

                // Post macOS notification
                await SystemNotificationService.shared.postSubstackExportReady(downloadURL: url)
            } else {
                // Email found but couldn't extract URL — still useful
                sheetPhase = .emailFound(URL(string: "https://substack.com/settings")!)
                await SystemNotificationService.shared.postSubstackExportReady(
                    downloadURL: URL(string: "https://substack.com/settings")!
                )
            }

            logger.debug("Substack export email detected")

        } catch {
            logger.error("Email poll failed: \(error.localizedDescription)")
        }
    }

    /// Extract download URL from email MIME source HTML.
    private func extractDownloadURL(from mimeSource: String) -> URL? {
        // Look for Substack download/export links in the HTML
        let pattern = #"href="(https://[^"]*substack[^"]*(?:export|download)[^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(mimeSource.startIndex..<mimeSource.endIndex, in: mimeSource)
        guard let match = regex.firstMatch(in: mimeSource, range: range),
              let urlRange = Range(match.range(at: 1), in: mimeSource) else { return nil }
        return URL(string: String(mimeSource[urlRange]))
    }

    // MARK: - Step 9: File Watcher

    /// Start polling ~/Downloads for new Substack export ZIP files.
    func startFileWatcher() {
        fileWatcherActive = true
        fileWatcherStartDate = .now
        sheetPhase = .watchingFile
        scheduleFilePolling()
        logger.debug("Substack file watcher started")
    }

    /// Stop the file watcher.
    func stopFileWatcher() {
        filePollingTimer?.invalidate()
        filePollingTimer = nil
        fileWatcherActive = false
        fileWatcherStartDate = nil
        logger.debug("Substack file watcher stopped")
    }

    private func scheduleFilePolling() {
        filePollingTimer?.invalidate()
        filePollingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.pollForZipFile()
            }
        }
    }

    private func pollForZipFile() async {
        // Check timeout (2 days)
        if let startDate = fileWatcherStartDate,
           Date.now.timeIntervalSince(startDate) > 2 * 24 * 3600 {
            stopFileWatcher()
            sheetPhase = .failed("File watcher timed out after 2 days.")
            return
        }

        let fm = FileManager.default
        guard let downloadsURL = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }

        do {
            let contents = try fm.contentsOfDirectory(
                at: downloadsURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            let watchStart = fileWatcherStartDate ?? .distantPast

            let newZip = contents.first { url in
                let name = url.lastPathComponent.lowercased()
                guard name.hasSuffix(".zip"),
                      name.hasPrefix("export-") || name.hasPrefix("substack-export-") else { return false }
                let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return fileDate > watchStart
            }

            if newZip != nil {
                stopFileWatcher()
                NotificationCenter.default.post(name: .samSubstackZipDetected, object: nil)
                // Re-scan will pick up the new file
                await scanDownloadsFolder()
            }
        } catch {
            logger.error("File poll failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Step 10: Reminder Scheduling

    /// Schedule a reminder notification during the next free calendar gap.
    func scheduleReminder() async {
        let calendar = Calendar.current
        let now = Date.now
        let endWindow = calendar.date(byAdding: .hour, value: 8, to: now)!

        // Try to find a free 15-min gap in the next 8 hours
        var reminderDate = calendar.date(byAdding: .hour, value: 2, to: now)! // Fallback: 2 hours

        if let calendarIDs = UserDefaults.standard.stringArray(forKey: "selectedCalendarIdentifiers"),
           !calendarIDs.isEmpty {
            if let events = await CalendarService.shared.fetchEvents(
                from: calendarIDs,
                startDate: now,
                endDate: endWindow
            ) {
                // Find first 15-min gap between events
                var cursor = now
                let sorted = events.sorted { $0.startDate < $1.startDate }
                for event in sorted {
                    if event.startDate.timeIntervalSince(cursor) >= 900 { // 15 minutes
                        reminderDate = cursor.addingTimeInterval(60) // 1 min into the gap
                        break
                    }
                    cursor = max(cursor, event.endDate)
                }
                // Check gap after last event
                if endWindow.timeIntervalSince(cursor) >= 900 {
                    reminderDate = cursor.addingTimeInterval(60)
                }
            }
        }

        // Schedule the notification
        let downloadURL = extractedDownloadURL.flatMap { URL(string: $0) }
            ?? URL(string: "https://substack.com/settings")!
        await SystemNotificationService.shared.postSubstackExportReady(
            downloadURL: downloadURL,
            triggerDate: reminderDate
        )
        logger.debug("Substack reminder scheduled for \(reminderDate.formatted())")
    }

    // MARK: - Watcher Persistence

    /// Resume watchers that were active before app restart.
    private func resumeWatchersIfNeeded() {
        if emailWatcherActive {
            // Check if within timeout
            if let startDate = emailWatcherStartDate,
               Date.now.timeIntervalSince(startDate) < 2 * 24 * 3600 {
                sheetPhase = .watchingEmail
                scheduleEmailPolling()
                logger.debug("Resumed Substack email watcher from previous session")
            } else {
                emailWatcherActive = false
                emailWatcherStartDate = nil
            }
        }

        if fileWatcherActive {
            if let startDate = fileWatcherStartDate,
               Date.now.timeIntervalSince(startDate) < 2 * 24 * 3600 {
                sheetPhase = .watchingFile
                scheduleFilePolling()
                logger.debug("Resumed Substack file watcher from previous session")
            } else {
                fileWatcherActive = false
                fileWatcherStartDate = nil
            }
        }
    }

    // MARK: - Post-Import Cleanup

    /// Delete the source ZIP file after successful import.
    func deleteSourceZip() throws {
        guard let url = importedZipURL else { return }
        try FileManager.default.removeItem(at: url)
        importedZipURL = nil
        logger.debug("Deleted Substack export ZIP: \(url.lastPathComponent)")
    }

    // MARK: - Cancellation

    /// Cancel all watchers and timers.
    func cancelWatchers() {
        stopEmailWatcher()
        stopFileWatcher()
    }

    /// Cancel everything (watchers + any in-progress import).
    func cancelAll() {
        cancelWatchers()
        if case .importing = importStatus {
            importStatus = .idle
        }
    }

    /// Whether the mail system is available for email watching.
    var isMailAvailableForWatching: Bool {
        MailImportCoordinator.shared.mailEnabled && !MailImportCoordinator.shared.selectedAccountIDs.isEmpty
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
            logger.debug("Substack profile analysis complete: score \(result.overallScore)")
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

// MARK: - Sheet Phase State Machine

enum SubstackSheetPhase: Equatable {
    /// First-time: feed URL entry + manual CSV picker
    case setup
    /// Checking ~/Downloads for ZIP files (brief spinner)
    case scanning
    /// Preview: filename, date, size — Confirm / Decline
    case zipFound(ZipInfo)
    /// Unzipping + CSV parsing + matching (linear progress)
    case processing
    /// Subscriber candidates displayed for confirmation
    case awaitingReview
    /// Instructions + "Download Substack Data..." button
    case noZipFound
    /// Polling Mail.app (spinner + elapsed time)
    case watchingEmail
    /// Export email detected — "Open Download Page" button
    case emailFound(URL)
    /// Polling ~/Downloads (spinner + status)
    case watchingFile
    /// Summary + "Delete ZIP?" prompt
    case complete(ImportStats)
    /// Error with retry
    case failed(String)
}

// MARK: - Supporting Types

struct ZipInfo: Equatable {
    let url: URL
    let fileName: String
    let fileDate: Date
    let fileSize: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct ImportStats: Equatable {
    let subscriberCount: Int
    let matchedCount: Int
    let newLeads: Int
    let touchesCreated: Int
}
