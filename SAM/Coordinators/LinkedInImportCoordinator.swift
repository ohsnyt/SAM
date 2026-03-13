//
//  LinkedInImportCoordinator.swift
//  SAM
//
//  Phase S+: LinkedIn Archive Import (rebuilt with intentional touch scoring)
//
//  Flow:
//   1. loadFolder  — parse all CSVs, compute touch scores, build importCandidates list
//   2. (UI)        — user sees LinkedInImportReviewSheet; toggles Add/Later per contact
//   3. confirmImport(classifications:) — persist records, store IntentionalTouch events
//

import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LinkedInImportCoordinator")

// MARK: - Sheet State Machine

enum LinkedInSheetPhase: Equatable {
    case setup                              // First-time: instructions + manual ZIP picker
    case scanning                           // Checking ~/Downloads for ZIP (brief)
    case zipFound(LinkedInZipInfo)          // Preview: filename, date, size → Confirm / Decline
    case processing                         // Unzipping + parsing 10 CSVs (progress messages)
    case awaitingReview                     // Candidate review (embedded inline — 3 sections)
    case importing                          // 11-step confirmImport pipeline (progress)
    case noZipFound                         // Instructions + "Request LinkedIn Data..." + watchers
    case watchingEmail                      // Polling Mail.app (spinner + elapsed)
    case emailFound(URL)                    // Export email detected → "Open Download Page"
    case watchingFile                       // Polling ~/Downloads (spinner + status)
    case complete(LinkedInImportStats)      // Summary + Apple Contacts sync prompt + "Delete ZIP?"
    case failed(String)                     // Error with retry
}

struct LinkedInZipInfo: Equatable {
    let url: URL
    let fileName: String
    let fileDate: Date
    let fileSize: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct LinkedInImportStats: Equatable {
    let connectionCount: Int
    let messageCount: Int
    let matchedCount: Int
    let newContacts: Int
    let enrichments: Int
}

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
    private let enrichmentRepo     = EnrichmentRepository.shared
    private let contactsService    = ContactsService.shared
    private let touchRepo          = IntentionalTouchRepository.shared

    // MARK: - Settings (UserDefaults)

    @ObservationIgnored
    var importEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "sam.linkedin.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.linkedin.enabled") }
    }

    /// Watermark: only messages newer than this date are imported on subsequent runs.
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
        case idle, parsing, awaitingReview, importing, success, failed
        var displayText: String {
            switch self {
            case .idle:           "Ready"
            case .parsing:        "Reading files..."
            case .awaitingReview: "Ready to review"
            case .importing:      "Importing..."
            case .success:        "Done"
            case .failed:         "Failed"
            }
        }
        var isActive: Bool { self == .parsing || self == .importing }
    }

    enum ProfileAnalysisStatus: String {
        case idle, analyzing, complete, failed
    }

    private(set) var importStatus: ImportStatus = .idle
    /// Short phrase describing the current import phase — shown next to the progress spinner.
    private(set) var progressMessage: String? = nil
    private(set) var lastError: String?
    private(set) var lastImportedAt: Date?
    private(set) var lastImportCount: Int = 0
    private(set) var parsedMessageCount: Int = 0
    private(set) var newMessageCount: Int = 0
    private(set) var duplicateMessageCount: Int = 0
    private(set) var matchedConnectionCount: Int = 0
    private(set) var unmatchedConnectionCount: Int = 0
    private(set) var enrichmentCandidateCount: Int = 0
    /// True if a user LinkedIn profile was found and parsed in the current import session.
    private(set) var userProfileParsed: Bool = false

    // Phase 4: Enhanced de-duplication state
    /// Number of connections that exactly matched an existing SamPerson (auto-enriched).
    private(set) var exactMatchCount: Int = 0
    /// Number of connections that probably matched (requiring user confirmation).
    private(set) var probableMatchCount: Int = 0
    /// Number of connections with no match (shown as Add/Later in review sheet).
    private(set) var noMatchCount: Int = 0
    /// Non-nil when last import was more than 90 days ago.
    private(set) var staleImportWarning: String? = nil

    // MARK: - §13 Apple Contacts LinkedIn URL Sync state

    /// Candidates for which SAM can write LinkedIn URLs to Apple Contacts.
    /// Populated after confirmImport() completes. Only "Add" candidates whose
    /// Apple Contact did NOT already have the LinkedIn URL are included.
    /// Cleared after the user responds to the batch sync confirmation.
    private(set) var appleContactsSyncCandidates: [AppleContactsSyncCandidate] = []

    /// Auto-sync preference: when true, SAM writes LinkedIn URLs to Apple Contacts
    /// automatically for new "Add" contacts without asking each time.
    @ObservationIgnored
    var autoSyncLinkedInURLs: Bool {
        get { UserDefaults.standard.bool(forKey: "sam.linkedin.autoSyncAppleContactURLs") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.linkedin.autoSyncAppleContactURLs") }
    }

    // MARK: - Profile Analysis State (Phase 7)

    private(set) var profileAnalysisStatus: ProfileAnalysisStatus = .idle
    private(set) var latestProfileAnalysis: ProfileAnalysisDTO? = nil

    // MARK: - Sheet Phase State (Auto-Detection Flow)

    /// Current phase of the LinkedIn import sheet state machine.
    var sheetPhase: LinkedInSheetPhase = .setup

    /// Remembers the ZIP URL for post-import deletion.
    var importedZipURL: URL?

    // MARK: - Watcher Timers

    private var emailPollingTimer: Timer?
    private var filePollingTimer: Timer?

    // MARK: - Watcher Persistence (UserDefaults)

    private var emailWatcherActive: Bool {
        get { UserDefaults.standard.bool(forKey: "sam.linkedin.emailWatcherActive") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.linkedin.emailWatcherActive") }
    }

    private var emailWatcherStartDate: Date? {
        get { UserDefaults.standard.object(forKey: "sam.linkedin.emailWatcherStartDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "sam.linkedin.emailWatcherStartDate") }
    }

    private var fileWatcherActive: Bool {
        get { UserDefaults.standard.bool(forKey: "sam.linkedin.fileWatcherActive") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.linkedin.fileWatcherActive") }
    }

    private var fileWatcherStartDate: Date? {
        get { UserDefaults.standard.object(forKey: "sam.linkedin.fileWatcherStartDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "sam.linkedin.fileWatcherStartDate") }
    }

    private var extractedDownloadURL: String? {
        get { UserDefaults.standard.string(forKey: "sam.linkedin.extractedDownloadURL") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.linkedin.extractedDownloadURL") }
    }

    // MARK: - Container

    private var container: ModelContainer?

    /// Temp directory created when importing from a ZIP file. Cleaned up after import completes or cancels.
    private var tempExtractDir: URL? = nil

    // MARK: - Parsed state (held between loadFolder and confirmImport)

    private var pendingMessages: [LinkedInMessageDTO] = []
    private var pendingConnections: [LinkedInConnectionDTO] = []
    private var pendingEndorsementsReceived: [LinkedInEndorsementReceivedDTO] = []
    private var pendingEndorsementsGiven: [LinkedInEndorsementGivenDTO] = []
    private var pendingRecommendationsGiven: [LinkedInRecommendationGivenDTO] = []
    private var pendingRecommendationsReceived: [LinkedInRecommendationReceivedDTO] = []
    private var pendingReactionsGiven: [LinkedInReactionDTO] = []
    private var pendingCommentsGiven: [LinkedInCommentDTO] = []
    private var pendingInvitations: [LinkedInInvitationDTO] = []
    private var pendingShares: [LinkedInShareDTO] = []
    private var pendingUserProfile: UserLinkedInProfileDTO? = nil

    /// Computed touch scores keyed by normalized profile URL.
    private var touchScores: [String: IntentionalTouchScore] = [:]

    /// Import candidates built from unmatched connections, ready for the review sheet.
    /// Only populated after loadFolder completes successfully.
    private(set) var importCandidates: [LinkedInImportCandidate] = []

    // MARK: - Convenience counts (exposed for preview / settings UI)

    var pendingConnectionCount: Int { pendingConnections.count }
    var pendingEndorsementsReceivedCount: Int { pendingEndorsementsReceived.count }
    var pendingEndorsementsGivenCount: Int { pendingEndorsementsGiven.count }
    var pendingRecommendationsGivenCount: Int { pendingRecommendationsGiven.count }
    var pendingInvitationsCount: Int { pendingInvitations.count }
    var recommendedToAddCount: Int { importCandidates.filter { $0.defaultClassification == .add }.count }
    var noInteractionCount: Int { importCandidates.filter { $0.defaultClassification == .later }.count }

    // MARK: - Initialization

    private init() {
        // Load cached profile analysis from prior import session
        Task { @MainActor in
            self.latestProfileAnalysis = await BusinessProfileService.shared.profileAnalysis(for: "linkedIn")
        }
    }

    /// Wire to SwiftData container and resume any active watchers from a prior session.
    func configure(container: ModelContainer) {
        self.container = container
        resumeWatchersIfNeeded()
    }

    // MARK: - Public API

    /// Parse a LinkedIn data export folder. Call from Settings UI after user selects folder.
    /// Populates importCandidates for the review sheet.
    func loadFolder(url: URL) async {
        guard importStatus != .parsing && importStatus != .importing else { return }

        importStatus = .parsing
        progressMessage = "Reading CSV files…"
        lastError = nil
        parsedMessageCount = 0
        newMessageCount = 0
        duplicateMessageCount = 0
        pendingMessages = []
        pendingConnections = []
        pendingEndorsementsReceived = []
        pendingEndorsementsGiven = []
        pendingRecommendationsGiven = []
        pendingRecommendationsReceived = []
        pendingReactionsGiven = []
        pendingCommentsGiven = []
        pendingInvitations = []
        pendingUserProfile = nil
        touchScores = [:]
        importCandidates = []
        enrichmentCandidateCount = 0
        userProfileParsed = false
        exactMatchCount = 0
        probableMatchCount = 0
        noMatchCount = 0
        staleImportWarning = nil

        let messagesURL                = url.appendingPathComponent("messages.csv")
        let connectionsURL             = url.appendingPathComponent("Connections.csv")
        let endorsementsReceivedURL    = url.appendingPathComponent("Endorsement_Received_Info.csv")
        let endorsementsGivenURL       = url.appendingPathComponent("Endorsement_Given_Info.csv")
        let recommendationsGivenURL    = url.appendingPathComponent("Recommendations_Given.csv")
        let recommendationsReceivedURL = url.appendingPathComponent("Recommendations_Received.csv")
        let reactionsGivenURL          = url.appendingPathComponent("Reactions.csv")
        let commentsGivenURL           = url.appendingPathComponent("Comments.csv")
        let invitationsURL             = url.appendingPathComponent("Invitations.csv")
        let sharesURL                  = url.appendingPathComponent("Shares.csv")

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

        // Parse connections (always full re-parse)
        if FileManager.default.fileExists(atPath: connectionsURL.path) {
            pendingConnections = await linkedInService.parseConnections(at: connectionsURL)
        } else {
            logger.info("No Connections.csv found in folder")
        }

        // Parse touch-related CSVs (silently skip if not present)
        if FileManager.default.fileExists(atPath: endorsementsReceivedURL.path) {
            pendingEndorsementsReceived = await linkedInService.parseEndorsementsReceived(at: endorsementsReceivedURL)
        }
        if FileManager.default.fileExists(atPath: endorsementsGivenURL.path) {
            pendingEndorsementsGiven = await linkedInService.parseEndorsementsGiven(at: endorsementsGivenURL)
        }
        if FileManager.default.fileExists(atPath: recommendationsGivenURL.path) {
            pendingRecommendationsGiven = await linkedInService.parseRecommendationsGiven(at: recommendationsGivenURL)
        }
        if FileManager.default.fileExists(atPath: recommendationsReceivedURL.path) {
            pendingRecommendationsReceived = await linkedInService.parseRecommendationsReceived(at: recommendationsReceivedURL)
        }
        if FileManager.default.fileExists(atPath: reactionsGivenURL.path) {
            pendingReactionsGiven = await linkedInService.parseReactionsGiven(at: reactionsGivenURL)
        }
        if FileManager.default.fileExists(atPath: commentsGivenURL.path) {
            pendingCommentsGiven = await linkedInService.parseCommentsGiven(at: commentsGivenURL)
        }
        if FileManager.default.fileExists(atPath: invitationsURL.path) {
            pendingInvitations = await linkedInService.parseInvitations(at: invitationsURL)
        }
        if FileManager.default.fileExists(atPath: sharesURL.path) {
            pendingShares = await linkedInService.parseShares(at: sharesURL)
        }

        // Parse user profile
        pendingUserProfile = await linkedInService.parseUserProfile(folder: url)
        userProfileParsed = pendingUserProfile != nil

        parsedMessageCount    = allMessages.count
        newMessageCount       = newMessages.count
        duplicateMessageCount = duplicateCount
        pendingMessages       = newMessages

        // Compute touch scores from all parsed data
        progressMessage = "Scoring contacts…"
        await Task.yield()
        touchScores = computeTouchScores()

        // Build import candidates from unmatched connections (async — checks Apple Contacts for Priority 2)
        progressMessage = "Building review list…"
        await Task.yield()
        importCandidates = await buildImportCandidates()

        // Check for stale import warning (>90 days since last connection import)
        if let lastImport = lastConnectionImportAt {
            let daysSince = Calendar.current.dateComponents([.day], from: lastImport, to: Date()).day ?? 0
            if daysSince > 90 {
                staleImportWarning = "Your LinkedIn data was last imported \(daysSince) days ago. Consider downloading a fresh export for the most accurate contact information."
            }
        }

        importStatus = .awaitingReview
        sheetPhase = .awaitingReview
        progressMessage = nil

        let erCount   = pendingEndorsementsReceived.count
        let egCount   = pendingEndorsementsGiven.count
        let recCount  = pendingRecommendationsGiven.count
        let rrCount   = pendingRecommendationsReceived.count
        let rxCount   = pendingReactionsGiven.count
        let cmCount   = pendingCommentsGiven.count
        let invCount  = pendingInvitations.count
        let shrCount  = pendingShares.count
        let connCount = pendingConnections.count
        logger.info("Folder parsed: \(allMessages.count) msgs (\(newMessages.count) new), \(connCount) connections, \(erCount) endorse rcvd, \(egCount) endorse given, \(recCount) rec given, \(rrCount) rec rcvd, \(rxCount) reactions, \(cmCount) comments, \(invCount) invitations, \(shrCount) shares")
        logger.info("Import candidates: \(self.importCandidates.count) (\(self.recommendedToAddCount) to add, \(self.noInteractionCount) later)")

        // Notify observers (SAMApp listens to present the review sheet from the File menu flow)
        NotificationCenter.default.post(name: .samLinkedInAwaitingReview, object: nil)
    }

    /// Present an NSOpenPanel starting in ~/Downloads, filtered to ZIP files,
    /// so the user can select their LinkedIn export with one click.
    /// Returns the selected URL, or nil if the user cancelled.
    func pickLinkedInExportZip() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .archive]
        panel.allowsOtherFileTypes = true
        panel.message = "Select your LinkedIn data export ZIP file"
        panel.prompt = "Import"

        // Start in ~/Downloads so the user can see their export immediately
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = downloads
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Import a LinkedIn data export from a ZIP file.
    /// Accepts both Complete and Basic LinkedIn exports.
    /// Unzips to a temp directory, then calls loadFolder().
    func importFromZip(url: URL) async {
        let filename = url.lastPathComponent

        // Accept both Complete and Basic LinkedIn exports
        guard filename.hasPrefix("Complete_LinkedInDataExport_")
           || filename.hasPrefix("Basic_LinkedInDataExport_") else {
            let msg = "Expected a LinkedIn data export ZIP (Complete_LinkedInDataExport_*.zip or Basic_LinkedInDataExport_*.zip). Request your archive from LinkedIn — it takes up to 24 hours."
            lastError = msg
            importStatus = .failed
            sheetPhase = .failed(msg)
            return
        }

        // Create temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SAM-LinkedIn-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            let msg = "Failed to create temporary directory: \(error.localizedDescription)"
            lastError = msg
            importStatus = .failed
            sheetPhase = .failed(msg)
            return
        }

        importStatus = .parsing
        sheetPhase = .processing
        progressMessage = "Unzipping archive…"
        lastError = nil

        // Unzip using /usr/bin/unzip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let msg = "Failed to unzip the LinkedIn export. The file may be corrupted — try downloading it again."
                lastError = msg
                importStatus = .failed
                sheetPhase = .failed(msg)
                cleanupTempDir()
                return
            }
        } catch {
            let msg = "Failed to run unzip: \(error.localizedDescription)"
            lastError = msg
            importStatus = .failed
            sheetPhase = .failed(msg)
            cleanupTempDir()
            return
        }

        // Find the extracted content directory.
        // The ZIP may contain files directly or inside a top-level folder.
        let extractedDir: URL
        let fm = FileManager.default
        let topLevelItems = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        if topLevelItems.count == 1,
           let only = topLevelItems.first,
           (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            // Single top-level folder — use it
            extractedDir = only
        } else {
            // Files directly in temp dir
            extractedDir = tempDir
        }

        tempExtractDir = tempDir

        // Save bookmark so reprocessForSender can re-access later
        BookmarkManager.shared.saveLinkedInFolderBookmark(extractedDir)

        // Reset status so loadFolder starts fresh
        importStatus = .idle

        await loadFolder(url: extractedDir)
    }

    /// Confirm and execute the import with user-selected classifications.
    /// - Parameter classifications: maps candidate.id → .add or .later
    func confirmImport(classifications: [UUID: LinkedInClassification]) async {
        guard importStatus == .awaitingReview || !pendingConnections.isEmpty || !pendingMessages.isEmpty else {
            importStatus = .idle
            return
        }

        importStatus = .importing
        progressMessage = "Preparing…"
        lastError = nil

        let connectionsToImport = pendingConnections
        let messagesToImport = pendingMessages
        var importedCount = 0
        var matched = 0

        do {
            // 1. Enrich matched SamPerson records from connections
            var unmatchedConnections: [LinkedInConnectionDTO] = []
            if !connectionsToImport.isEmpty {
                progressMessage = "Matching \(connectionsToImport.count) connection\(connectionsToImport.count == 1 ? "" : "s")…"
                await Task.yield()
                let result = try enrichPeopleFromConnections(connectionsToImport)
                matched = result.matched
                unmatchedConnections = result.unmatched
                lastConnectionImportAt = Date()
                if !unmatchedConnections.isEmpty {
                    logger.info("\(unmatchedConnections.count) LinkedIn connection(s) unmatched — building candidates")
                }
            }

            // 2. Import messages as SamEvidenceItem records
            var unmatchedMessageSenders: [(profileURL: String, name: String, date: Date)] = []
            if !messagesToImport.isEmpty {
                progressMessage = "Importing \(messagesToImport.count) message\(messagesToImport.count == 1 ? "" : "s")…"
                await Task.yield()
                let allPeople = try peopleRepo.fetchAll()
                var byLinkedInURL: [String: SamPerson] = allPeople.reduce(into: [:]) { dict, p in
                    if let url = p.linkedInProfileURL { dict[url.lowercased()] = p }
                }
                let byFullName: [String: SamPerson] = allPeople.reduce(into: [:]) { dict, p in
                    let name = (p.displayNameCache ?? p.displayName).lowercased()
                    dict[name] = p
                }
                let byEmail: [String: SamPerson] = allPeople.reduce(into: [:]) { dict, p in
                    if let email = p.emailCache?.lowercased(), !email.isEmpty { dict[email] = p }
                    for alias in p.emailAliases { dict[alias.lowercased()] = p }
                }

                for msg in messagesToImport {
                    let person = matchPerson(
                        profileURL: msg.senderProfileURL,
                        name: msg.senderName,
                        byLinkedInURL: byLinkedInURL,
                        byEmail: byEmail,
                        byFullName: byFullName
                    )

                    if let matched = person,
                       !msg.senderProfileURL.isEmpty,
                       (matched.linkedInProfileURL ?? "").lowercased() != msg.senderProfileURL.lowercased() {
                        matched.linkedInProfileURL = msg.senderProfileURL
                        byLinkedInURL[msg.senderProfileURL.lowercased()] = matched
                    }

                    if person == nil && !msg.senderName.isEmpty {
                        unmatchedMessageSenders.append((
                            profileURL: msg.senderProfileURL,
                            name: msg.senderName,
                            date: msg.occurredAt
                        ))
                    }

                    let linkedPeople: [SamPerson] = person.map { [$0] } ?? []
                    let peopleIDs = linkedPeople.map(\.id)

                    let title = msg.conversationTitle.isEmpty
                        ? "LinkedIn message from \(msg.senderName)"
                        : msg.conversationTitle
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

                try peopleRepo.save()
                lastMessageImportAt = Date()
            }

            // 3. Persist IntentionalTouch records for ALL contacts (both add and later)
            progressMessage = "Recording touch history…"
            await Task.yield()
            let touchCandidates = buildTouchCandidates()
            if !touchCandidates.isEmpty {
                let inserted = try touchRepo.bulkInsert(touchCandidates)
                logger.info("Persisted \(inserted) IntentionalTouch records")
            }

            // 4. Generate enrichment candidates for matched connections
            progressMessage = "Scanning for contact updates…"
            await Task.yield()
            let enrichmentCount = await generateEnrichmentCandidates(
                connections: connectionsToImport,
                endorsementsReceived: pendingEndorsementsReceived,
                endorsementsGiven: pendingEndorsementsGiven,
                recommendationsGiven: pendingRecommendationsGiven
            )
            enrichmentCandidateCount = enrichmentCount

            // 5a. Create contacts for "Add" candidates
            // Also treat "skip" as "add" — user rejected the probable match, so we create a new contact.
            let addCandidates = importCandidates.filter {
                let classification = classifications[$0.id] ?? $0.defaultClassification
                return classification == .add || classification == .skip
            }
            if !addCandidates.isEmpty {
                progressMessage = "Creating \(addCandidates.count) contact\(addCandidates.count == 1 ? "" : "s")…"
                await Task.yield()
                await createContactsForAddCandidates(addCandidates)
            }

            // 5a'. Merge confirmed probable matches into existing SamPerson records
            let mergeCandidates = importCandidates.filter {
                (classifications[$0.id] ?? $0.defaultClassification) == .merge
            }
            if !mergeCandidates.isEmpty {
                progressMessage = "Merging \(mergeCandidates.count) matched contact\(mergeCandidates.count == 1 ? "" : "s")…"
                await Task.yield()
                await mergeConfirmedCandidates(mergeCandidates)
            }

            // 5b. Route "Later" candidates to the triage queue
            progressMessage = "Finalizing…"
            await Task.yield()
            routeUnmatchedContacts(
                candidates: importCandidates,
                classifications: classifications,
                unmatchedConnections: unmatchedConnections,
                messageSenders: unmatchedMessageSenders
            )

            // 6. Create a LinkedInImport audit record
            let addCount = importCandidates.filter {
                let c = classifications[$0.id] ?? $0.defaultClassification
                return c == .add || c == .skip
            }.count
            let mergeCount = mergeCandidates.count
            let importRecord = LinkedInImport(
                importDate: Date(),
                archiveFileName: "",
                connectionCount: pendingConnections.count,
                matchedContactCount: matched + exactMatchCount + mergeCount,
                newContactsFound: addCount,
                touchEventsFound: touchCandidates.count,
                messagesImported: importedCount,
                status: .complete
            )
            try touchRepo.insertLinkedInImport(importRecord)

            matchedConnectionCount   = matched
            unmatchedConnectionCount = unmatchedConnections.count
            lastImportCount          = importedCount
            lastImportedAt           = Date()
            importStatus             = .success
            progressMessage          = nil

            // 7. Save user profile if parsed (with voice analysis from shares)
            if var profile = pendingUserProfile {
                let voiceSnippets = pendingShares
                    .sorted { $0.shareDate > $1.shareDate }
                    .prefix(5)
                    .compactMap { $0.shareComment.map { $0.count > 500 ? String($0.prefix(500)) + "…" : $0 } }
                if !voiceSnippets.isEmpty {
                    profile.recentShareSnippets = Array(voiceSnippets)
                    let voiceSummary = await analyzeWritingVoice(shares: voiceSnippets)
                    profile.writingVoiceSummary = voiceSummary
                }
                await BusinessProfileService.shared.saveLinkedInProfile(profile)
                logger.info("LinkedIn user profile saved: \(profile.firstName) \(profile.lastName), \(profile.positions.count) positions, voice: \(!profile.writingVoiceSummary.isEmpty)")
            }

            // 8. Build and cache profile analysis snapshot (before clearing pending state)
            let snapshot = buildAnalysisSnapshot()
            await BusinessProfileService.shared.saveAnalysisSnapshot(snapshot)
            logger.info("Profile analysis snapshot cached: \(snapshot.endorsementsReceivedCount) endorsements, \(snapshot.shareCount) shares, \(snapshot.connectionCount) connections")

            clearPendingState()
            logger.info("LinkedIn import complete: \(importedCount) messages, \(matched) connections matched")

            // 9. Run profile analysis in background (non-blocking)
            Task(priority: .utility) { [weak self] in
                await self?.runProfileAnalysis()
            }

            // 10. §13 Apple Contacts sync — if auto-sync is enabled, write immediately.
            // If not, prepareSyncCandidates will be triggered by the sheet after it
            // observes importStatus == .success.
            if autoSyncLinkedInURLs {
                await prepareSyncCandidates(classifications: classifications)
            }

            // 11. Re-run role deduction for newly imported people
            Task(priority: .utility) {
                await RoleDeductionEngine.shared.deduceRoles()
            }

        } catch {
            logger.error("LinkedIn import failed: \(error.localizedDescription)")
            importStatus    = .failed
            progressMessage = nil
            lastError       = error.localizedDescription
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

        let allMessages = await linkedInService.parseMessages(at: messagesURL, since: nil)
        let matching = allMessages.filter { $0.senderProfileURL.lowercased() == normalizedTarget }

        guard !matching.isEmpty else {
            logger.info("reprocessForSender: no messages found for \(normalizedTarget, privacy: .private)")
            return
        }

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

        // Back-fill IntentionalTouch attribution if we now have a SamPerson
        if let personID = person?.id {
            try? touchRepo.attributeTouches(forProfileURL: normalizedTarget, to: personID)
        }

        logger.info("reprocessForSender: \(imported) message(s) imported, \(skipped) already present for \(normalizedTarget, privacy: .private)")
    }

    /// Cancel a pending import (when user dismisses before confirming).
    func cancelImport() {
        clearPendingState()
        cleanupTempDir()
        importStatus          = .idle
        parsedMessageCount    = 0
        newMessageCount       = 0
        duplicateMessageCount = 0
        userProfileParsed     = false
    }

    // MARK: - Sheet Import Flow (Auto-Detection)

    /// Entry point when the import sheet opens. Routes to the appropriate phase.
    func beginImportFlow() {
        let hasImported = lastConnectionImportAt != nil

        if !hasImported {
            // First-time user — show instructions + manual ZIP picker
            sheetPhase = .setup
            return
        }

        // Returning user — scan ~/Downloads for a newer ZIP
        sheetPhase = .scanning
        Task { await scanDownloadsFolder() }
    }

    /// Scan ~/Downloads for LinkedIn export ZIP files.
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

            // Filter for ZIP files matching LinkedIn export patterns (case-insensitive)
            let zipFiles = contents.filter { url in
                let name = url.lastPathComponent.lowercased()
                guard name.hasSuffix(".zip") else { return false }
                return name.hasPrefix("complete_linkedindataexport_")
                    || name.hasPrefix("basic_linkedindataexport_")
            }

            // Find the newest ZIP by modification date
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

            // Only show if newer than last import
            if let lastImport = lastConnectionImportAt, fileDate <= lastImport {
                sheetPhase = .noZipFound
                return
            }

            let info = LinkedInZipInfo(
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

    /// Process a ZIP file through the existing import pipeline and transition to review.
    func processZip(url: URL) async {
        sheetPhase = .processing
        importedZipURL = url
        await importFromZip(url: url)

        // importFromZip → loadFolder → sets importStatus and sheetPhase
        // If it failed, sheetPhase was already set by importFromZip
    }

    /// Open the LinkedIn data export settings page in the browser.
    func openLinkedInExportPage() {
        if let url = URL(string: "https://www.linkedin.com/mypreferences/d/download-my-data") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Email Watcher

    /// Start polling Mail.app for the LinkedIn export-ready email.
    func startEmailWatcher() {
        guard MailImportCoordinator.shared.mailEnabled,
              !MailImportCoordinator.shared.selectedAccountIDs.isEmpty else {
            logger.warning("Mail not configured — cannot watch for LinkedIn export email")
            return
        }

        emailWatcherActive = true
        emailWatcherStartDate = .now
        sheetPhase = .watchingEmail
        scheduleEmailPolling()
        logger.info("LinkedIn email watcher started")
    }

    /// Stop the email watcher.
    func stopEmailWatcher() {
        emailPollingTimer?.invalidate()
        emailPollingTimer = nil
        emailWatcherActive = false
        emailWatcherStartDate = nil
        logger.info("LinkedIn email watcher stopped")
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
            sheetPhase = .failed("Email watcher timed out after 2 days. Try downloading manually from LinkedIn.")
            return
        }

        do {
            let accountIDs = MailImportCoordinator.shared.selectedAccountIDs
            let since = emailWatcherStartDate ?? Date.now.addingTimeInterval(-3600)

            let (metas, _) = try await MailService.shared.fetchMetadata(
                accountIDs: accountIDs,
                since: since
            )

            // Filter for LinkedIn export emails
            let exportEmail = metas.first { meta in
                let sender = meta.sender.lowercased()
                let subject = meta.subject.lowercased()
                return sender.contains("linkedin.com")
                    && subject.contains("data")
                    && (subject.contains("ready") || subject.contains("download"))
            }

            guard let email = exportEmail else { return }

            // Found the email — try to extract download URL from MIME source
            var downloadURL: URL?
            if let mimeSource = await MailService.shared.fetchMIMESource(for: email) {
                downloadURL = extractLinkedInDownloadURL(from: mimeSource)
            }

            stopEmailWatcher()

            if let url = downloadURL {
                extractedDownloadURL = url.absoluteString
                sheetPhase = .emailFound(url)
                await SystemNotificationService.shared.postLinkedInExportReady(downloadURL: url)
            } else {
                let fallbackURL = URL(string: "https://www.linkedin.com/mypreferences/d/download-my-data")!
                sheetPhase = .emailFound(fallbackURL)
                await SystemNotificationService.shared.postLinkedInExportReady(downloadURL: fallbackURL)
            }

            logger.info("LinkedIn export email detected")

        } catch {
            logger.error("LinkedIn email poll failed: \(error.localizedDescription)")
        }
    }

    /// Extract download URL from email MIME source HTML.
    private func extractLinkedInDownloadURL(from mimeSource: String) -> URL? {
        let pattern = #"href="(https://[^"]*linkedin[^"]*(?:download|export)[^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(mimeSource.startIndex..<mimeSource.endIndex, in: mimeSource)
        guard let match = regex.firstMatch(in: mimeSource, range: range),
              let urlRange = Range(match.range(at: 1), in: mimeSource) else { return nil }
        return URL(string: String(mimeSource[urlRange]))
    }

    // MARK: - File Watcher

    /// Start polling ~/Downloads for new LinkedIn export ZIP files.
    func startFileWatcher() {
        fileWatcherActive = true
        fileWatcherStartDate = .now
        sheetPhase = .watchingFile
        scheduleFilePolling()
        logger.info("LinkedIn file watcher started")
    }

    /// Stop the file watcher.
    func stopFileWatcher() {
        filePollingTimer?.invalidate()
        filePollingTimer = nil
        fileWatcherActive = false
        fileWatcherStartDate = nil
        logger.info("LinkedIn file watcher stopped")
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
                      name.hasPrefix("complete_linkedindataexport_")
                   || name.hasPrefix("basic_linkedindataexport_") else { return false }
                let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return fileDate > watchStart
            }

            if newZip != nil {
                stopFileWatcher()
                NotificationCenter.default.post(name: .samLinkedInZipDetected, object: nil)
                // Re-scan will pick up the new file
                await scanDownloadsFolder()
            }
        } catch {
            logger.error("LinkedIn file poll failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Reminder Scheduling

    /// Schedule a reminder notification during the next free calendar gap.
    func scheduleReminder() async {
        let calendar = Calendar.current
        let now = Date.now
        let endWindow = calendar.date(byAdding: .hour, value: 8, to: now)!

        // Fallback: 2 hours from now
        var reminderDate = calendar.date(byAdding: .hour, value: 2, to: now)!

        if let calendarIDs = UserDefaults.standard.stringArray(forKey: "selectedCalendarIdentifiers"),
           !calendarIDs.isEmpty {
            if let events = await CalendarService.shared.fetchEvents(
                from: calendarIDs,
                startDate: now,
                endDate: endWindow
            ) {
                var cursor = now
                let sorted = events.sorted { $0.startDate < $1.startDate }
                for event in sorted {
                    if event.startDate.timeIntervalSince(cursor) >= 900 { // 15 min gap
                        reminderDate = cursor.addingTimeInterval(60)
                        break
                    }
                    cursor = max(cursor, event.endDate)
                }
                if endWindow.timeIntervalSince(cursor) >= 900 {
                    reminderDate = cursor.addingTimeInterval(60)
                }
            }
        }

        let downloadURL = extractedDownloadURL.flatMap { URL(string: $0) }
            ?? URL(string: "https://www.linkedin.com/mypreferences/d/download-my-data")!
        await SystemNotificationService.shared.postLinkedInExportReady(
            downloadURL: downloadURL,
            triggerDate: reminderDate
        )
        logger.info("LinkedIn reminder scheduled for \(reminderDate.formatted())")
    }

    // MARK: - Watcher Persistence

    /// Resume watchers that were active before app restart.
    private func resumeWatchersIfNeeded() {
        if emailWatcherActive {
            if let startDate = emailWatcherStartDate,
               Date.now.timeIntervalSince(startDate) < 2 * 24 * 3600 {
                sheetPhase = .watchingEmail
                scheduleEmailPolling()
                logger.info("Resumed LinkedIn email watcher from previous session")
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
                logger.info("Resumed LinkedIn file watcher from previous session")
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
        logger.info("Deleted LinkedIn export ZIP: \(url.lastPathComponent)")
    }

    // MARK: - Cancellation (Sheet Flow)

    /// Cancel all watchers and timers.
    func cancelWatchers() {
        stopEmailWatcher()
        stopFileWatcher()
    }

    /// Cancel everything (watchers + any in-progress import).
    func cancelAll() {
        cancelWatchers()
        cancelImport()
    }

    /// Whether the mail system is available for email watching.
    var isMailAvailableForWatching: Bool {
        MailImportCoordinator.shared.mailEnabled && !MailImportCoordinator.shared.selectedAccountIDs.isEmpty
    }

    /// Complete the import from the sheet and transition to the complete phase.
    func completeImportFromSheet(classifications: [UUID: LinkedInClassification]) async {
        sheetPhase = .importing
        await confirmImport(classifications: classifications)

        if importStatus == .success {
            let stats = LinkedInImportStats(
                connectionCount: pendingConnectionCount,
                messageCount: lastImportCount,
                matchedCount: matchedConnectionCount + exactMatchCount,
                newContacts: importCandidates.filter {
                    let c = classifications[$0.id] ?? $0.defaultClassification
                    return c == .add || c == .skip
                }.count,
                enrichments: enrichmentCandidateCount
            )
            sheetPhase = .complete(stats)
        } else if importStatus == .failed {
            sheetPhase = .failed(lastError ?? "Import failed")
        }
    }

    // MARK: - §13 Apple Contacts LinkedIn URL Sync

    /// Called by `LinkedInImportReviewSheet` after `confirmImport` completes
    /// (or from `confirmImport` directly when `autoSyncLinkedInURLs` is true).
    ///
    /// Scans every "Add" candidate (including merged) and, for those whose Apple
    /// Contact does NOT yet have the LinkedIn URL, assembles `AppleContactsSyncCandidate`
    /// records. When `autoSync` is true the write-back is performed immediately and
    /// silently; when false the result is stored in `appleContactsSyncCandidates` so
    /// the UI can show a single confirmation dialog.
    func prepareSyncCandidates(classifications: [UUID: LinkedInClassification]) async {
        // Candidates the user wants to "add" (or merge)
        let addCandidates = importCandidates.filter {
            let c = classifications[$0.id] ?? $0.defaultClassification
            return c == .add || c == .skip || c == .merge
        }

        guard !addCandidates.isEmpty else { return }

        // For each add candidate with a profile URL, check whether its Apple
        // Contact already has the LinkedIn social profile URL.
        var syncCandidates: [AppleContactsSyncCandidate] = []

        for candidate in addCandidates {
            let profileURL = candidate.profileURL
            guard !profileURL.isEmpty else { continue }

            // Search Apple Contacts for this person
            let displayName = candidate.fullName.isEmpty ? "LinkedIn Contact" : candidate.fullName
            let results = await contactsService.searchContacts(query: displayName, keys: .detail)

            // Find the best match: by LinkedIn URL first, then email, then name
            let match = results.first { contact in
                let urlMatch = contact.socialProfiles.contains {
                    ($0.urlString ?? "").lowercased().contains(profileURL.lowercased())
                }
                let emailMatch = candidate.email.map { email in
                    contact.emailAddresses.contains { $0.lowercased() == email.lowercased() }
                } ?? false
                let nameMatch = contact.displayName.lowercased() == displayName.lowercased()
                return urlMatch || emailMatch || nameMatch
            }

            guard let contactDTO = match else { continue }

            // Check if the LinkedIn URL is already present
            let alreadyHasURL = contactDTO.socialProfiles.contains {
                ($0.urlString ?? "").lowercased().contains(profileURL.lowercased())
            }

            guard !alreadyHasURL else { continue }

            syncCandidates.append(AppleContactsSyncCandidate(
                displayName: displayName,
                appleContactIdentifier: contactDTO.id,
                linkedInProfileURL: profileURL
            ))
        }

        guard !syncCandidates.isEmpty else { return }

        if autoSyncLinkedInURLs {
            // Silent batch write — user has already opted in
            await performAppleContactsSync(candidates: syncCandidates)
        } else {
            // Store for UI confirmation
            appleContactsSyncCandidates = syncCandidates
        }
    }

    /// Performs the batch LinkedIn URL write to Apple Contacts for the given candidates.
    /// Should be called either from the UI confirmation handler or directly when
    /// `autoSyncLinkedInURLs` is true.
    func performAppleContactsSync(candidates: [AppleContactsSyncCandidate]) async {
        for candidate in candidates {
            _ = await contactsService.updateContact(
                identifier: candidate.appleContactIdentifier,
                updates: [.linkedInURL: candidate.linkedInProfileURL],
                samNoteBlock: nil
            )
        }
        appleContactsSyncCandidates = []
        logger.info("§13 Apple Contacts sync: wrote LinkedIn URLs to \(candidates.count) contact(s)")
    }

    /// Clears the pending sync candidates without writing (user chose "Not Now").
    func dismissAppleContactsSync() {
        appleContactsSyncCandidates = []
    }

    // MARK: - Private: Touch Score Computation

    /// Compute IntentionalTouchScore for every profile URL found across all parsed CSVs.
    private func computeTouchScores() -> [String: IntentionalTouchScore] {
        // Messages → (profileURL, direction, date, snippet)
        var messageTouches: [(profileURL: String, direction: TouchDirection, date: Date, snippet: String?)] = []
        for msg in pendingMessages {
            let url = msg.senderProfileURL.lowercased()
            guard !url.isEmpty else { continue }
            messageTouches.append((url, .inbound, msg.occurredAt, String(msg.plainTextContent.prefix(200))))
        }

        // Invitations → (profileURL, isPersonalized, date)
        var invitationTouches: [(profileURL: String, isPersonalized: Bool, date: Date)] = []
        for inv in pendingInvitations {
            let url = inv.contactProfileURL.lowercased()
            guard !url.isEmpty else { continue }
            let isPersonalized = !(inv.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let date = inv.sentAt ?? Date()
            invitationTouches.append((url, isPersonalized, date))
        }

        // Endorsements received → (profileURL, date, skillName)
        let endorsementsRcvd: [(profileURL: String, date: Date?, skillName: String?)] =
            pendingEndorsementsReceived.compactMap { e in
                let url = e.profileURL.lowercased()
                guard !url.isEmpty else { return nil }
                return (url, e.endorsementDate, e.skillName)
            }

        // Endorsements given → (profileURL, date, skillName)
        let endorsementsGiven: [(profileURL: String, date: Date?, skillName: String?)] =
            pendingEndorsementsGiven.compactMap { e in
                let url = e.profileURL.lowercased()
                guard !url.isEmpty else { return nil }
                return (url, e.endorsementDate, e.skillName)
            }

        // Recommendations received → (profileURL, date)
        let recommendationsRcvd: [(profileURL: String, date: Date?)] =
            pendingRecommendationsReceived.compactMap { r in
                guard let url = r.recommenderProfileURL?.lowercased(), !url.isEmpty else { return nil }
                return (url, r.sentAt)
            }

        // Recommendations given — we don't have a profile URL; skip for scoring
        // (they contribute to evidence but not profile-keyed touch scoring)
        let recommendationsGiven: [(profileURL: String, date: Date?)] = []

        // Reactions → (profileURL?, date) — LinkedIn reactions don't include the target's profileURL
        let reactions: [(profileURL: String?, date: Date)] = pendingReactionsGiven.map { (nil, $0.date) }

        // Comments → (profileURL?, date) — same limitation
        let comments: [(profileURL: String?, date: Date)] = pendingCommentsGiven.map { (nil, $0.date) }

        return TouchScoringEngine.computeScores(
            messages: messageTouches,
            invitations: invitationTouches,
            endorsementsReceived: endorsementsRcvd,
            endorsementsGiven: endorsementsGiven,
            recommendationsReceived: recommendationsRcvd,
            recommendationsGiven: recommendationsGiven,
            reactions: reactions,
            comments: comments
        )
    }

    /// Build a flat list of IntentionalTouchCandidate structs from all parsed touch events.
    private func buildTouchCandidates() -> [IntentionalTouchCandidate] {
        var candidates: [IntentionalTouchCandidate] = []

        // Messages
        for msg in pendingMessages {
            let url = msg.senderProfileURL.lowercased()
            guard !url.isEmpty else { continue }
            candidates.append(IntentionalTouchCandidate(
                platform: .linkedIn,
                touchType: .message,
                direction: .inbound,
                contactProfileUrl: url,
                date: msg.occurredAt,
                snippet: String(msg.plainTextContent.prefix(200)),
                source: .bulkImport
            ))
        }

        // Invitations
        for inv in pendingInvitations {
            let url = inv.contactProfileURL.lowercased()
            guard !url.isEmpty else { continue }
            let isPersonalized = !(inv.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let touchType: TouchType = isPersonalized ? .invitationPersonalized : .invitationGeneric
            let date = inv.sentAt ?? Date()
            candidates.append(IntentionalTouchCandidate(
                platform: .linkedIn,
                touchType: touchType,
                direction: .outbound,
                contactProfileUrl: url,
                date: date,
                snippet: inv.message.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) },
                source: .bulkImport
            ))
        }

        // Endorsements received
        for e in pendingEndorsementsReceived {
            let url = e.profileURL.lowercased()
            guard !url.isEmpty else { continue }
            candidates.append(IntentionalTouchCandidate(
                platform: .linkedIn,
                touchType: .endorsementReceived,
                direction: .inbound,
                contactProfileUrl: url,
                date: e.endorsementDate ?? Date(),
                snippet: e.skillName.map { "Endorsed for: \($0)" },
                source: .bulkImport
            ))
        }

        // Endorsements given
        for e in pendingEndorsementsGiven {
            let url = e.profileURL.lowercased()
            guard !url.isEmpty else { continue }
            candidates.append(IntentionalTouchCandidate(
                platform: .linkedIn,
                touchType: .endorsementGiven,
                direction: .outbound,
                contactProfileUrl: url,
                date: e.endorsementDate ?? Date(),
                snippet: e.skillName.map { "Endorsed: \($0)" },
                source: .bulkImport
            ))
        }

        // Recommendations received
        for r in pendingRecommendationsReceived {
            guard let url = r.recommenderProfileURL?.lowercased(), !url.isEmpty else { continue }
            candidates.append(IntentionalTouchCandidate(
                platform: .linkedIn,
                touchType: .recommendationReceived,
                direction: .inbound,
                contactProfileUrl: url,
                date: r.sentAt ?? Date(),
                snippet: r.recommendationText.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) },
                source: .bulkImport
            ))
        }

        return candidates
    }

    // MARK: - Private: Import Candidate Building

    /// Build LinkedInImportCandidate list using a 4-priority matching cascade.
    ///
    /// Priority 1: SAM has a SamPerson with matching LinkedIn URL → exactMatchURL (silently enriched)
    /// Priority 2: Apple Contacts has a contact with matching LinkedIn social profile URL → exactMatchAppleContact (enriched)
    /// Priority 3: Email address match against SamPerson records → probableMatchEmail (shown to user)
    /// Priority 4: Accent-normalized name + fuzzy company match → probableMatchNameCompany (shown to user)
    /// No match → shown in review sheet as Add/Later based on touch score
    private func buildImportCandidates() async -> [LinkedInImportCandidate] {
        var candidates: [LinkedInImportCandidate] = []
        var localExactCount = 0
        var localProbableCount = 0
        var localNoMatchCount = 0

        // Fetch all SamPerson records
        let allPeople: [SamPerson]
        do { allPeople = try peopleRepo.fetchAll() } catch { return [] }

        // --- Priority 1: LinkedIn URL → SamPerson ---
        let byLinkedInURL: [String: SamPerson] = allPeople.reduce(into: [:]) { dict, p in
            if let url = p.linkedInProfileURL, !url.isEmpty {
                dict[normalizeLinkedInURL(url)] = p
            }
        }

        // --- Priority 2: Apple Contacts LinkedIn URL index ---
        // Single batch fetch from the SAM contact group so we can check social profiles / URL addresses.
        let groupID = UserDefaults.standard.string(forKey: "selectedContactGroupIdentifier") ?? ""
        var appleContactLinkedInIndex: [String: String] = [:]  // normalizedURL → contactIdentifier
        var companyCache: [String: String] = [:]               // contactIdentifier → organizationName

        if !groupID.isEmpty {
            let groupContacts = await contactsService.fetchContacts(inGroupWithIdentifier: groupID, keys: .detail)
            for contact in groupContacts {
                // Cache company name for Priority 4 comparison
                if !contact.organizationName.isEmpty {
                    companyCache[contact.id] = contact.organizationName
                }
                // Index LinkedIn URLs from social profiles
                for profile in contact.socialProfiles {
                    let isLinkedIn = profile.service.lowercased().contains("linkedin") ||
                        (profile.urlString ?? "").lowercased().contains("linkedin.com/in/")
                    if isLinkedIn, let urlStr = profile.urlString, !urlStr.isEmpty {
                        appleContactLinkedInIndex[normalizeLinkedInURL(urlStr)] = contact.id
                    }
                }
                // Also check URL addresses for linkedin.com/in/ patterns
                for urlStr in contact.urlAddresses {
                    if urlStr.lowercased().contains("linkedin.com/in/") {
                        appleContactLinkedInIndex[normalizeLinkedInURL(urlStr)] = contact.id
                    }
                }
            }
        }

        // --- Priority 3: Email → SamPerson ---
        let byEmail: [String: SamPerson] = allPeople.reduce(into: [:]) { dict, p in
            if let email = p.emailCache?.lowercased(), !email.isEmpty { dict[email] = p }
            for alias in p.emailAliases { dict[alias.lowercased()] = p }
        }

        // --- Priority 4: Accent-normalized name → [SamPerson] ---
        // Array because names can collide; company comparison is used as tie-breaker.
        var byNormalizedName: [String: [SamPerson]] = [:]
        for p in allPeople {
            let name = normalizeForComparison(p.displayNameCache ?? p.displayName)
            if !name.isEmpty {
                byNormalizedName[name, default: []].append(p)
            }
        }

        // Helper: get company for a SamPerson (from companyCache via contactIdentifier)
        func companyForPerson(_ person: SamPerson) -> String? {
            guard let cid = person.contactIdentifier else { return nil }
            return companyCache[cid]
        }

        // Helper: build a MatchedPersonInfo snapshot from a SamPerson
        func matchedInfo(from person: SamPerson, matchedByEmail: String? = nil) -> MatchedPersonInfo {
            MatchedPersonInfo(
                personID: person.id,
                displayName: person.displayNameCache ?? person.displayName,
                email: matchedByEmail ?? person.emailCache,
                company: companyForPerson(person),
                position: nil,
                linkedInURL: person.linkedInProfileURL
            )
        }

        // --- Cascade loop ---
        for conn in pendingConnections {
            let normalizedURL = normalizeLinkedInURL(conn.profileURL)
            let fullName = "\(conn.firstName) \(conn.lastName)".trimmingCharacters(in: .whitespaces)
            let normalizedName = normalizeForComparison(fullName)

            // Priority 1: SAM LinkedIn URL match
            if !normalizedURL.isEmpty, byLinkedInURL[normalizedURL] != nil {
                // Enrich existing SamPerson with any new LinkedIn data silently
                if let connectedOn = conn.connectedOn {
                    _ = try? peopleRepo.updateLinkedInData(
                        profileURL: conn.profileURL,
                        connectedOn: connectedOn,
                        email: conn.email,
                        fullName: fullName
                    )
                }
                localExactCount += 1
                continue
            }

            // Priority 2: Apple Contacts LinkedIn URL match
            if !normalizedURL.isEmpty, let contactID = appleContactLinkedInIndex[normalizedURL] {
                // Enrich via upsert — contact already exists in Apple Contacts
                if let existing = allPeople.first(where: { $0.contactIdentifier == contactID }) {
                    if let connectedOn = conn.connectedOn {
                        _ = try? peopleRepo.updateLinkedInData(
                            profileURL: conn.profileURL,
                            connectedOn: connectedOn,
                            email: conn.email,
                            fullName: fullName
                        )
                    }
                    if existing.linkedInProfileURL == nil {
                        try? peopleRepo.setLinkedInProfileURL(contactIdentifier: contactID, profileURL: conn.profileURL)
                    }
                }
                localExactCount += 1
                continue
            }

            // Priority 3: Email match
            if let email = conn.email?.lowercased(), !email.isEmpty, let person = byEmail[email] {
                let info = matchedInfo(from: person, matchedByEmail: conn.email)
                candidates.append(LinkedInImportCandidate(
                    firstName: conn.firstName,
                    lastName: conn.lastName,
                    profileURL: conn.profileURL,
                    email: conn.email,
                    company: conn.company,
                    position: conn.position,
                    connectedOn: conn.connectedOn,
                    touchScore: touchScores[normalizedURL],
                    matchStatus: .probableMatchEmail,
                    defaultClassification: .merge,
                    matchedPersonInfo: info
                ))
                localProbableCount += 1
                continue
            }

            // Priority 4: Accent-normalized name + fuzzy company
            if !normalizedName.isEmpty, let nameCandidates = byNormalizedName[normalizedName] {
                // If exactly one person with that name, or if company also matches → probable match
                let companyMatch = nameCandidates.first { person in
                    guard let personCompany = companyForPerson(person), !personCompany.isEmpty,
                          let connCompany = conn.company, !connCompany.isEmpty else { return false }
                    return fuzzyCompanyMatch(personCompany, connCompany)
                }
                let matchedPerson = companyMatch ?? (nameCandidates.count == 1 ? nameCandidates[0] : nil)

                if let person = matchedPerson {
                    let info = matchedInfo(from: person)
                    candidates.append(LinkedInImportCandidate(
                        firstName: conn.firstName,
                        lastName: conn.lastName,
                        profileURL: conn.profileURL,
                        email: conn.email,
                        company: conn.company,
                        position: conn.position,
                        connectedOn: conn.connectedOn,
                        touchScore: touchScores[normalizedURL],
                        matchStatus: .probableMatchNameCompany,
                        defaultClassification: .merge,
                        matchedPersonInfo: info
                    ))
                    localProbableCount += 1
                    continue
                }
            }

            // No match — show in Add/Later review
            let score = touchScores[normalizedURL]
            let defaultClassification: LinkedInClassification = (score?.totalScore ?? 0) > 0 ? .add : .later
            candidates.append(LinkedInImportCandidate(
                firstName: conn.firstName,
                lastName: conn.lastName,
                profileURL: conn.profileURL,
                email: conn.email,
                company: conn.company,
                position: conn.position,
                connectedOn: conn.connectedOn,
                touchScore: score,
                matchStatus: .noMatch,
                defaultClassification: defaultClassification,
                matchedPersonInfo: nil
            ))
            localNoMatchCount += 1
        }

        exactMatchCount = localExactCount
        probableMatchCount = localProbableCount
        noMatchCount = localNoMatchCount

        // Sort: probable matches first (user must decide), then "add" by score desc, then "later" by date desc
        return candidates.sorted { lhs, rhs in
            let lIsProbable = lhs.matchStatus.isProbable
            let rIsProbable = rhs.matchStatus.isProbable
            if lIsProbable != rIsProbable { return lIsProbable }
            if lhs.defaultClassification != rhs.defaultClassification {
                return lhs.defaultClassification == .add || lhs.defaultClassification == .merge
            }
            let lScore = lhs.touchScore?.totalScore ?? 0
            let rScore = rhs.touchScore?.totalScore ?? 0
            if lScore != rScore { return lScore > rScore }
            let lDate = lhs.connectedOn ?? .distantPast
            let rDate = rhs.connectedOn ?? .distantPast
            return lDate > rDate
        }
    }

    // MARK: - Private: Matching Helpers

    /// Normalize a string for accent-insensitive, case-insensitive comparison.
    private func normalizeForComparison(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
              .trimmingCharacters(in: .whitespaces)
    }

    /// Normalize a LinkedIn profile URL for comparison:
    /// lowercase, strip query params, strip trailing slash, normalize http→https.
    private func normalizeLinkedInURL(_ urlString: String) -> String {
        var s = urlString.lowercased().trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "http://", with: "https://")
        // Strip query string
        if let qIdx = s.range(of: "?") { s = String(s[..<qIdx.lowerBound]) }
        // Strip trailing slash
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    /// Normalize a company name for fuzzy comparison:
    /// strip common legal suffixes, accent-fold, lowercase.
    private func normalizeCompanyName(_ name: String) -> String {
        var s = normalizeForComparison(name)
        // Strip trailing punctuation and common legal suffixes
        let suffixes = [", inc", ", llc", ", ltd", ", corp", ", co", ", gmbh",
                        " inc.", " llc.", " ltd.", " corp.", " co.", " gmbh",
                        " inc", " llc", " ltd", " corp", " co", " gmbh",
                        " incorporated", " limited", " corporation", " company"]
        for suffix in suffixes {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    /// Returns true if two company name strings are close enough to be considered the same company.
    private func fuzzyCompanyMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizeCompanyName(a)
        let nb = normalizeCompanyName(b)
        return !na.isEmpty && na == nb
    }

    // MARK: - Private: Create Contacts for "Add" Candidates

    /// Create Apple Contacts and SamPerson records for candidates the user chose to Add.
    /// Checks for existing contacts before creating to avoid duplicates.
    private func createContactsForAddCandidates(_ candidates: [LinkedInImportCandidate]) async {
        for candidate in candidates {
            let displayName = candidate.fullName.isEmpty ? "LinkedIn Contact" : candidate.fullName
            let profileURL = candidate.profileURL.isEmpty ? nil : candidate.profileURL

            do {
                // Create standalone SamPerson — no Apple Contact written
                let personID = try peopleRepo.upsertFromSocialImport(
                    displayName: displayName,
                    linkedInProfileURL: profileURL,
                    linkedInConnectedOn: candidate.connectedOn,
                    linkedInEmail: candidate.email
                )

                // Attribute any existing IntentionalTouch records to this new SamPerson
                if let url = profileURL, !url.isEmpty {
                    try? touchRepo.attributeTouches(forProfileURL: url, to: personID)
                }

                logger.info("Add candidate '\(displayName, privacy: .private)': created standalone SamPerson")
            } catch {
                logger.error("Failed to create SamPerson for '\(displayName, privacy: .private)': \(error)")
            }
        }

        // Refresh participant resolution so any new LinkedIn messages link to new people
        try? EvidenceRepository.shared.refreshParticipantResolution()
        // Also trigger reprocessing for each added sender's LinkedIn messages
        for candidate in candidates {
            if let url = candidate.profileURL.isEmpty ? nil : candidate.profileURL {
                await reprocessForSender(profileURL: url)
            }
        }
    }

    // MARK: - Private: Merge Confirmed Probable Matches

    /// Merge probable-match candidates into their existing SamPerson records.
    /// Called for candidates where the user confirmed the match (classification == .merge).
    private func mergeConfirmedCandidates(_ candidates: [LinkedInImportCandidate]) async {
        for candidate in candidates {
            guard let info = candidate.matchedPersonInfo else { continue }
            let profileURL = candidate.profileURL.isEmpty ? nil : candidate.profileURL

            do {
                // Stamp LinkedIn URL and connectedOn onto existing SamPerson
                if let url = profileURL, !url.isEmpty {
                    _ = try peopleRepo.updateLinkedInData(
                        profileURL: url,
                        connectedOn: candidate.connectedOn,
                        email: candidate.email,
                        fullName: candidate.fullName
                    )

                    // Attribute any IntentionalTouch records to the existing SamPerson
                    try? touchRepo.attributeTouches(forProfileURL: url, to: info.personID)

                    // Reprocess LinkedIn messages so they link to this person
                    await reprocessForSender(profileURL: url)
                }
                logger.info("Merged LinkedIn candidate '\(candidate.fullName, privacy: .private)' into existing person '\(info.displayName, privacy: .private)'")
            } catch {
                logger.error("Failed to merge candidate '\(candidate.fullName, privacy: .private)': \(error)")
            }
        }
    }

    // MARK: - Private: Route Unmatched Contacts

    /// Route unmatched contacts to triage based on user classifications.
    /// "Later" contacts go to UnknownSender with LinkedIn metadata.
    private func routeUnmatchedContacts(
        candidates: [LinkedInImportCandidate],
        classifications: [UUID: LinkedInClassification],
        unmatchedConnections: [LinkedInConnectionDTO],
        messageSenders: [(profileURL: String, name: String, date: Date)]
    ) {
        // Collect all candidate profile URLs for de-dup below
        let candidateURLs = Set(candidates.map { $0.profileURL.lowercased() })

        // Process review sheet candidates
        for candidate in candidates {
            let classification = classifications[candidate.id] ?? candidate.defaultClassification
            guard classification == .later else { continue }

            let uniqueKey = candidate.profileURL.isEmpty
                ? "linkedin-unknown-\(candidate.fullName.lowercased().replacingOccurrences(of: " ", with: "-"))"
                : "linkedin:\(candidate.profileURL.lowercased())"

            do {
                try unknownSenderRepo.upsertLinkedInLater(
                    uniqueKey: uniqueKey,
                    displayName: candidate.fullName.isEmpty ? nil : candidate.fullName,
                    touchScore: candidate.touchScore?.totalScore ?? 0,
                    company: candidate.company,
                    position: candidate.position,
                    connectedOn: candidate.connectedOn
                )
            } catch {
                logger.error("Failed to upsert Later contact \(candidate.fullName): \(error)")
            }
        }

        // Also record any unmatched message senders not already in the candidate list
        // (these have no connection record — just messages from unknown senders)
        var sendersByURL: [String: (profileURL: String, name: String, date: Date)] = [:]
        for s in messageSenders {
            let key = s.profileURL.lowercased()
            if let existing = sendersByURL[key] {
                if s.date > existing.date { sendersByURL[key] = s }
            } else {
                sendersByURL[key] = s
            }
        }

        var legacySenders: [(email: String, displayName: String?, subject: String, date: Date, source: EvidenceSource, isLikelyMarketing: Bool)] = []
        for s in sendersByURL.values {
            let urlKey = s.profileURL.lowercased()
            guard !candidateURLs.contains(urlKey) else { continue }
            let uniqueKey = s.profileURL.isEmpty
                ? "linkedin-unknown-\(s.name.lowercased().replacingOccurrences(of: " ", with: "-"))"
                : "linkedin:\(s.profileURL.lowercased())"
            legacySenders.append((
                email: uniqueKey,
                displayName: s.name,
                subject: s.profileURL.isEmpty ? "LinkedIn message" : s.profileURL,
                date: s.date,
                source: .linkedIn,
                isLikelyMarketing: false
            ))
        }

        if !legacySenders.isEmpty {
            do {
                try unknownSenderRepo.bulkRecordUnknownSenders(legacySenders)
            } catch {
                logger.error("Failed to record unmatched message senders: \(error)")
            }
        }
    }

    // MARK: - Private: Connection Enrichment

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

    // MARK: - Private: Enrichment Candidate Generation

    private func generateEnrichmentCandidates(
        connections: [LinkedInConnectionDTO],
        endorsementsReceived: [LinkedInEndorsementReceivedDTO],
        endorsementsGiven: [LinkedInEndorsementGivenDTO],
        recommendationsGiven: [LinkedInRecommendationGivenDTO]
    ) async -> Int {
        var candidates: [EnrichmentCandidate] = []

        let allPeople: [SamPerson]
        do { allPeople = try peopleRepo.fetchAll() } catch { return 0 }

        let byLinkedInURL: [String: SamPerson] = allPeople.reduce(into: [:]) { dict, p in
            if let url = p.linkedInProfileURL { dict[url.lowercased()] = p }
        }
        let byFullName: [String: SamPerson] = allPeople.reduce(into: [:]) { dict, p in
            let name = (p.displayNameCache ?? p.displayName).lowercased()
            dict[name] = p
        }

        func findPerson(profileURL: String?, name: String?) -> SamPerson? {
            if let url = profileURL, !url.isEmpty,
               let match = byLinkedInURL[url.lowercased()] { return match }
            if let n = name, !n.isEmpty,
               let match = byFullName[n.lowercased()] { return match }
            return nil
        }

        // Connections: company + job title
        for conn in connections {
            guard let person = findPerson(
                profileURL: conn.profileURL.isEmpty ? nil : conn.profileURL,
                name: { let n = "\(conn.firstName) \(conn.lastName)".trimmingCharacters(in: .whitespaces); return n.isEmpty ? nil : n }()
            ) else { continue }
            guard let contactID = person.contactIdentifier else { continue }
            let contact = await contactsService.fetchContact(identifier: contactID, keys: .detail)

            if let company = conn.company, !company.isEmpty {
                let current = contact?.organizationName ?? ""
                if current.lowercased() != company.lowercased() {
                    candidates.append(EnrichmentCandidate(
                        personID: person.id, field: .company,
                        proposedValue: company, currentValue: current.isEmpty ? nil : current,
                        source: .linkedInConnections, sourceDetail: nil
                    ))
                }
            }
            if let position = conn.position, !position.isEmpty {
                let current = contact?.jobTitle ?? ""
                if current.lowercased() != position.lowercased() {
                    candidates.append(EnrichmentCandidate(
                        personID: person.id, field: .jobTitle,
                        proposedValue: position, currentValue: current.isEmpty ? nil : current,
                        source: .linkedInConnections, sourceDetail: nil
                    ))
                }
            }
            if !conn.profileURL.isEmpty {
                let alreadyInContacts = contact?.socialProfiles.contains(where: {
                    $0.service.lowercased() == "linkedin" ||
                    ($0.urlString ?? "").lowercased().contains("linkedin.com/in/")
                }) ?? false
                if !alreadyInContacts {
                    candidates.append(EnrichmentCandidate(
                        personID: person.id, field: .linkedInURL,
                        proposedValue: conn.profileURL, currentValue: nil,
                        source: .linkedInConnections, sourceDetail: nil
                    ))
                }
            }
        }

        // Endorsements received: LinkedIn URL discovery
        for endorsement in endorsementsReceived {
            guard let person = findPerson(profileURL: endorsement.profileURL, name: endorsement.fullName)
            else { continue }
            if person.linkedInProfileURL == nil || person.linkedInProfileURL?.isEmpty == true {
                candidates.append(EnrichmentCandidate(
                    personID: person.id, field: .linkedInURL,
                    proposedValue: endorsement.profileURL, currentValue: nil,
                    source: .linkedInEndorsementsReceived,
                    sourceDetail: endorsement.skillName.map { "Endorsed you for: \($0)" }
                ))
            }
        }

        // Endorsements given: LinkedIn URL discovery
        for endorsement in endorsementsGiven {
            guard let person = findPerson(profileURL: endorsement.profileURL, name: endorsement.fullName)
            else { continue }
            if person.linkedInProfileURL == nil || person.linkedInProfileURL?.isEmpty == true {
                candidates.append(EnrichmentCandidate(
                    personID: person.id, field: .linkedInURL,
                    proposedValue: endorsement.profileURL, currentValue: nil,
                    source: .linkedInEndorsementsGiven,
                    sourceDetail: endorsement.skillName.map { "You endorsed: \($0)" }
                ))
            }
        }

        // Recommendations given: company + job title
        for rec in recommendationsGiven {
            guard let person = findPerson(profileURL: nil, name: rec.fullName.isEmpty ? nil : rec.fullName)
            else { continue }
            guard let contactID = person.contactIdentifier else { continue }
            let contact = await contactsService.fetchContact(identifier: contactID, keys: .detail)
            if let company = rec.company, !company.isEmpty {
                let current = contact?.organizationName ?? ""
                if current.lowercased() != company.lowercased() {
                    candidates.append(EnrichmentCandidate(
                        personID: person.id, field: .company,
                        proposedValue: company, currentValue: current.isEmpty ? nil : current,
                        source: .linkedInRecommendationsGiven, sourceDetail: "At time of recommendation"
                    ))
                }
            }
            if let title = rec.jobTitle, !title.isEmpty {
                let current = contact?.jobTitle ?? ""
                if current.lowercased() != title.lowercased() {
                    candidates.append(EnrichmentCandidate(
                        personID: person.id, field: .jobTitle,
                        proposedValue: title, currentValue: current.isEmpty ? nil : current,
                        source: .linkedInRecommendationsGiven, sourceDetail: "At time of recommendation"
                    ))
                }
            }
        }

        // Sweep: any SamPerson with a linkedInProfileURL not yet in Apple Contacts
        let alreadyProposedForURL = Set(candidates.filter { $0.field == .linkedInURL }.map { $0.personID })
        for person in allPeople {
            guard let linkedInURL = person.linkedInProfileURL, !linkedInURL.isEmpty else { continue }
            guard let contactID = person.contactIdentifier else { continue }
            guard !alreadyProposedForURL.contains(person.id) else { continue }
            let contact = await contactsService.fetchContact(identifier: contactID, keys: .detail)
            let alreadyInContacts = contact?.socialProfiles.contains(where: {
                $0.service.lowercased() == "linkedin" ||
                ($0.urlString ?? "").lowercased().contains("linkedin.com/in/")
            }) ?? false
            if !alreadyInContacts {
                candidates.append(EnrichmentCandidate(
                    personID: person.id, field: .linkedInURL,
                    proposedValue: linkedInURL, currentValue: nil,
                    source: .linkedInConnections, sourceDetail: "From LinkedIn messages"
                ))
            }
        }

        guard !candidates.isEmpty else { return 0 }

        do {
            let inserted = try enrichmentRepo.bulkRecord(candidates)
            if inserted > 0 {
                await ContactEnrichmentCoordinator.shared.refresh()
            }
            return inserted
        } catch {
            logger.error("Failed to record enrichment candidates: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Private: Contact Matching

    private func matchPerson(
        profileURL: String,
        name: String,
        byLinkedInURL: [String: SamPerson],
        byEmail: [String: SamPerson],
        byFullName: [String: SamPerson]
    ) -> SamPerson? {
        // Priority 1: LinkedIn profile URL
        if !profileURL.isEmpty, let match = byLinkedInURL[profileURL.lowercased()] {
            return match
        }
        // Priority 2: Email address
        // (LinkedIn messages don't carry email, but future callers may pass one)
        // Priority 3: Full name exact match
        let nameLower = name.lowercased().trimmingCharacters(in: .whitespaces)
        if !nameLower.isEmpty, let match = byFullName[nameLower] {
            return match
        }
        return nil
    }

    // MARK: - LinkedIn Email Notification Handling (Phase 5)

    /// Recent notification events processed during the current mail import session.
    /// Reset at the start of each mail import run.
    private(set) var recentNotificationEvents: [LinkedInNotificationEvent] = []

    /// When the most recent notification batch was processed.
    private(set) var lastNotificationCheckAt: Date? = nil

    /// Process a single LinkedIn notification event extracted from a Mail.app notification email.
    ///
    /// Routing:
    /// 1. Match contact by LinkedIn profile URL, then by name.
    /// 2. Insert an IntentionalTouch record if the event type has a touch type.
    /// 3. For `.directMessage` events from matched contacts, create a SamEvidenceItem.
    /// 4. For `.jobChange` events, create EnrichmentCandidate records for review.
    /// 5. For unmatched events, record to UnknownSenderRepository with the profile URL.
    func handleNotificationEvent(_ event: LinkedInNotificationEvent) async {
        recentNotificationEvents.append(event)
        lastNotificationCheckAt = Date()

        // Build lookup tables for contact matching
        let allPeople = (try? peopleRepo.fetchAll()) ?? []
        let byLinkedInURL = Dictionary(
            allPeople
                .compactMap { person -> (String, SamPerson)? in
                    guard let url = person.linkedInProfileURL, !url.isEmpty else { return nil }
                    return (url.lowercased(), person)
                },
            uniquingKeysWith: { first, _ in first }
        )
        let byFullName = Dictionary(
            allPeople
                .compactMap { person -> (String, SamPerson)? in
                    let name = person.displayName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return nil }
                    return (name, person)
                },
            uniquingKeysWith: { first, _ in first }
        )

        // Attempt to match the contact
        let matchedPerson = matchPerson(
            profileURL: event.contactProfileUrl ?? "",
            name: event.contactName,
            byLinkedInURL: byLinkedInURL,
            byEmail: [:],
            byFullName: byFullName
        )

        // Insert IntentionalTouch if this event type generates one
        if let touchType = event.eventType.touchType {
            let candidate = IntentionalTouchCandidate(
                platform: .linkedIn,
                touchType: touchType,
                direction: event.eventType.touchDirection,
                contactProfileUrl: event.contactProfileUrl,
                samPersonID: matchedPerson?.id,
                date: event.date,
                snippet: event.snippet,
                source: .emailNotification,
                sourceEmailID: event.sourceEmailId
            )
            do {
                try touchRepo.bulkInsert([candidate])
            } catch {
                logger.error("Failed to insert touch from notification \(event.sourceEmailId): \(error.localizedDescription)")
            }
        }

        // Special routing: direct messages → create SamEvidenceItem for Today view visibility
        if event.eventType == .directMessage, let person = matchedPerson {
            do {
                try evidenceRepo.createByIDs(
                    sourceUID: "linkedin-dm-\(event.sourceEmailId)",
                    source: .linkedIn,
                    occurredAt: event.date,
                    title: "LinkedIn message from \(event.contactName)",
                    snippet: event.snippet ?? "LinkedIn message",
                    linkedPeopleIDs: [person.id]
                )
            } catch {
                logger.warning("Failed to create evidence for LinkedIn DM \(event.sourceEmailId): \(error.localizedDescription)")
            }
        }

        // Special routing: job changes → create enrichment candidates for user review
        if event.eventType == .jobChange, let person = matchedPerson {
            generateJobChangeEnrichment(for: person, snippet: event.snippet, subject: event.rawSubject)
        }

        // Unmatched events: record to Unknown Senders with the LinkedIn profile URL
        // so future bulk imports can retroactively match and attribute the touch
        if matchedPerson == nil, let profileUrl = event.contactProfileUrl {
            let key = "linkedin:\(profileUrl)"
            do {
                try unknownSenderRepo.upsertLinkedInLater(
                    uniqueKey: key,
                    displayName: event.contactName.isEmpty ? nil : event.contactName,
                    touchScore: event.eventType.touchType?.baseWeight ?? 0,
                    company: nil,
                    position: nil,
                    connectedOn: event.date
                )
            } catch {
                logger.warning("Failed to record unmatched notification sender \(key): \(error.localizedDescription)")
            }
        }
    }

    /// Parse a job title and company from a notification snippet like "VP Engineering at Acme Corp".
    /// Splits on " at " (case-insensitive), taking the last occurrence to handle "Director at X at Y".
    private func parseJobChangeSnippet(_ snippet: String) -> (title: String?, company: String?) {
        let lower = snippet.lowercased()
        guard let atRange = lower.range(of: " at ", options: .backwards) else {
            return (nil, snippet.isEmpty ? nil : snippet)
        }
        let titlePart = String(snippet[snippet.startIndex..<atRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let companyPart = String(snippet[atRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            titlePart.isEmpty ? nil : titlePart,
            companyPart.isEmpty ? nil : companyPart
        )
    }

    /// Generate enrichment candidates for a detected job change.
    /// Extracts title and company from the notification snippet or subject,
    /// then queues them for user review via the EnrichmentRepository.
    @discardableResult
    private func generateJobChangeEnrichment(for person: SamPerson, snippet: String?, subject: String) -> Int {
        // Try to parse "Title at Company" from snippet, falling back to subject
        let sourceText = snippet ?? subject
        let (title, company) = parseJobChangeSnippet(sourceText)

        var candidates: [EnrichmentCandidate] = []

        if let company, !company.isEmpty {
            candidates.append(EnrichmentCandidate(
                personID: person.id,
                field: .company,
                proposedValue: company,
                currentValue: nil,
                source: .linkedInNotification,
                sourceDetail: "LinkedIn job change notification"
            ))
        }

        if let title, !title.isEmpty {
            candidates.append(EnrichmentCandidate(
                personID: person.id,
                field: .jobTitle,
                proposedValue: title,
                currentValue: nil,
                source: .linkedInNotification,
                sourceDetail: "LinkedIn job change notification"
            ))
        }

        guard !candidates.isEmpty else { return 0 }

        do {
            let inserted = try enrichmentRepo.bulkRecord(candidates)
            if inserted > 0 {
                enrichmentCandidateCount += inserted
                ContactEnrichmentCoordinator.shared.refresh()
            }
            return inserted
        } catch {
            logger.error("Failed to record job change enrichment for \(person.id): \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Phase 7: Profile Analysis

    /// Builds a snapshot of import-time data for caching.
    /// Must be called before `clearPendingState()` while pending arrays are still populated.
    private func buildAnalysisSnapshot() -> ProfileAnalysisSnapshot {
        // Aggregate endorsement skill counts
        var skillCounts: [String: Int] = [:]
        for e in pendingEndorsementsReceived {
            if let skill = e.skillName { skillCounts[skill, default: 0] += 1 }
        }
        let topSkills = skillCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        let uniqueEndorsers = Set(pendingEndorsementsReceived.map(\.profileURL).filter { !$0.isEmpty }).count

        // Connection growth by year
        var byYear: [String: Int] = [:]
        for c in pendingConnections {
            if let date = c.connectedOn {
                let year = String(Calendar.current.component(.year, from: date))
                byYear[year, default: 0] += 1
            }
        }

        // Recommendation samples (first ~200 chars of up to 3 received)
        let recSamples = pendingRecommendationsReceived.prefix(3).compactMap {
            $0.recommendationText.map { String($0.prefix(200)) }
        }

        // Share snippets (most recent 10, truncated to 100 chars)
        let shareSnippets = pendingShares
            .sorted { $0.shareDate > $1.shareDate }
            .prefix(10)
            .compactMap { $0.shareComment.map { String($0.prefix(100)) } }

        // Voice share snippets (top 5, up to 500 chars each) for voice re-analysis
        let voiceSnippets = pendingShares
            .sorted { $0.shareDate > $1.shareDate }
            .prefix(5)
            .compactMap { $0.shareComment.map { $0.count > 500 ? String($0.prefix(500)) + "…" : $0 } }

        return ProfileAnalysisSnapshot(
            endorsementsReceivedCount: pendingEndorsementsReceived.count,
            topEndorsedSkills: Array(topSkills),
            uniqueEndorsers: uniqueEndorsers,
            recommendationsReceivedCount: pendingRecommendationsReceived.count,
            recommendationsGivenCount: pendingRecommendationsGiven.count,
            recommendationSamples: Array(recSamples),
            shareCount: pendingShares.count,
            recentShareSnippets: Array(shareSnippets),
            voiceShareSnippets: Array(voiceSnippets),
            reactionsGivenCount: pendingReactionsGiven.count,
            commentsGivenCount: pendingCommentsGiven.count,
            connectionCount: pendingConnections.count,
            connectionsByYear: byYear,
            snapshotDate: Date()
        )
    }

    /// Runs the profile analysis AI agent. Safe to call multiple times; guards against concurrent runs.
    func runProfileAnalysis() async {
        guard profileAnalysisStatus != .analyzing else { return }
        guard var profile = await BusinessProfileService.shared.linkedInProfile() else {
            logger.info("Profile analysis skipped: no LinkedIn profile available")
            return
        }
        guard let snapshot = await BusinessProfileService.shared.analysisSnapshot() else {
            logger.info("Profile analysis skipped: no analysis snapshot available")
            return
        }

        profileAnalysisStatus = .analyzing

        // Re-analyze voice from snapshot if profile has no voice data but snapshot has snippets
        if profile.writingVoiceSummary.isEmpty {
            var snippets: [String] = {
                if let voice = snapshot.voiceShareSnippets, !voice.isEmpty { return voice }
                if !snapshot.recentShareSnippets.isEmpty { return snapshot.recentShareSnippets }
                return []
            }()

            // If snapshot has no shares, try re-reading Shares.csv from the bookmarked folder
            if snippets.isEmpty {
                if let folderURL = BookmarkManager.shared.resolveLinkedInFolderURL() {
                    snippets = await findAndParseShares(startingAt: folderURL)
                    BookmarkManager.shared.stopAccessing(folderURL)
                }
            }

            if !snippets.isEmpty {
                let voiceSummary = await analyzeWritingVoice(shares: snippets)
                profile.writingVoiceSummary = voiceSummary
                profile.recentShareSnippets = snippets
                await BusinessProfileService.shared.saveLinkedInProfile(profile)
                logger.info("LinkedIn voice analysis completed during re-analysis (\(snippets.count) snippets)")
            }
        }

        do {
            let data = buildProfileAnalysisInput(profile: profile, snapshot: snapshot)
            let previousAnalysis = await BusinessProfileService.shared.profileAnalysis(for: "linkedIn")
            let previousJSON: String? = {
                guard let prev = previousAnalysis,
                      let encoded = try? JSONEncoder().encode(prev) else { return nil }
                return String(data: encoded, encoding: .utf8)
            }()

            let result = try await ProfileAnalystService.shared.analyze(
                data: data,
                previousAnalysisJSON: previousJSON
            )
            await BusinessProfileService.shared.saveProfileAnalysis(result)
            latestProfileAnalysis = result
            profileAnalysisStatus = .complete
            logger.info("Profile analysis complete: score \(result.overallScore), \(result.praise.count) praise, \(result.improvements.count) improvements")
        } catch {
            logger.error("Profile analysis failed: \(error.localizedDescription)")
            profileAnalysisStatus = .failed
        }
    }

    /// Assembles the text block sent to the AI for profile analysis.
    private func buildProfileAnalysisInput(
        profile: UserLinkedInProfileDTO,
        snapshot: ProfileAnalysisSnapshot
    ) -> String {
        var lines: [String] = []

        // Identity
        lines.append("LinkedIn Profile for \(profile.firstName) \(profile.lastName)")
        if !profile.headline.isEmpty { lines.append("Headline: \(profile.headline)") }
        if !profile.summary.isEmpty { lines.append("Summary: \(String(profile.summary.prefix(500)))") }
        if !profile.industry.isEmpty { lines.append("Industry: \(profile.industry)") }
        if !profile.geoLocation.isEmpty { lines.append("Location: \(profile.geoLocation)") }

        // Positions
        if !profile.positions.isEmpty {
            lines.append("\nPositions:")
            for p in profile.positions {
                let end = p.isCurrent ? "Present" : (p.finishedOn ?? "")
                lines.append("- \(p.title) at \(p.companyName) (\(p.startedOn ?? "") – \(end))")
            }
        }

        // Education
        if !profile.education.isEmpty {
            lines.append("\nEducation:")
            for e in profile.education {
                lines.append("- \(e.degreeName) at \(e.schoolName)")
            }
        }

        // Skills & certifications
        if !profile.skills.isEmpty {
            lines.append("\nSkills: \(profile.skills.joined(separator: ", "))")
        }
        if !profile.certifications.isEmpty {
            lines.append("Certifications: \(profile.certifications.map(\.name).joined(separator: ", "))")
        }

        // Endorsements & recommendations (from snapshot)
        lines.append("\nEndorsements: \(snapshot.endorsementsReceivedCount) received from \(snapshot.uniqueEndorsers) people")
        if !snapshot.topEndorsedSkills.isEmpty {
            lines.append("Top endorsed skills: \(snapshot.topEndorsedSkills.joined(separator: ", "))")
        }
        lines.append("Recommendations: \(snapshot.recommendationsReceivedCount) received, \(snapshot.recommendationsGivenCount) given")
        for (i, sample) in snapshot.recommendationSamples.enumerated() {
            lines.append("  Sample \(i + 1): \"\(sample)\"")
        }

        // Content activity
        lines.append("\nContent Activity: \(snapshot.shareCount) posts published")
        if !snapshot.recentShareSnippets.isEmpty {
            lines.append("Recent posts:")
            for s in snapshot.recentShareSnippets { lines.append("  - \(s)") }
        }
        lines.append("Reactions given: \(snapshot.reactionsGivenCount) | Comments written: \(snapshot.commentsGivenCount)")

        // Email notification engagement (last 90 days)
        let since90 = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .now
        let seenTypes = (try? IntentionalTouchRepository.shared.emailNotificationTypesSeenSince(since90)) ?? []
        let hasCommentNotifs = seenTypes.contains(TouchType.comment.rawValue)
        let hasReactionNotifs = seenTypes.contains(TouchType.reaction.rawValue)
        lines.append("\nEmail Notification Engagement (last 90 days):")
        lines.append("Comments on your posts: \(hasCommentNotifs ? "detected" : "none")")
        lines.append("Reactions to your posts: \(hasReactionNotifs ? "detected" : "none")")

        // Network
        lines.append("\nNetwork: \(snapshot.connectionCount) connections")
        let sortedYears = snapshot.connectionsByYear.sorted { $0.key < $1.key }
        if !sortedYears.isEmpty {
            lines.append("Growth by year: \(sortedYears.map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Voice Analysis

    /// Search for Shares.csv starting at the bookmarked folder, then sibling folders,
    /// then ~/Downloads. Skips .zip paths (macOS zip transparency fakes fileExists but
    /// String(contentsOf:) fails). Returns parsed share snippets for voice analysis.
    private func findAndParseShares(startingAt folderURL: URL) async -> [String] {
        let fm = FileManager.default

        // Helper: try to parse shares from a real (non-zip) directory
        func tryParse(in dir: URL) async -> [String]? {
            guard !dir.path.contains(".zip") else { return nil }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let csv = dir.appendingPathComponent("Shares.csv")
            guard fm.fileExists(atPath: csv.path) else { return nil }
            let snippets = await parseShareSnippets(at: csv)
            return snippets.isEmpty ? nil : snippets
        }

        // 1. Bookmarked folder
        if let result = await tryParse(in: folderURL) {
            logger.info(" Found Shares.csv in bookmarked folder")
            return result
        }

        // 2. Sibling folders with "linkedin" in the name
        let parentURL = folderURL.deletingLastPathComponent()
        if let result = await searchLinkedInFolders(in: parentURL, excluding: folderURL, tryParse: tryParse) {
            return result
        }

        // 3. ~/Downloads as a last resort (bookmark may point elsewhere)
        let downloadsURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        if downloadsURL != parentURL {
            if let result = await searchLinkedInFolders(in: downloadsURL, excluding: folderURL, tryParse: tryParse) {
                return result
            }
        }

        logger.info(" No readable Shares.csv found anywhere")
        return []
    }

    /// Scan a directory for LinkedIn export folders containing a readable Shares.csv.
    private func searchLinkedInFolders(
        in parent: URL,
        excluding: URL,
        tryParse: (URL) async -> [String]?
    ) async -> [String]? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        for item in items where item != excluding {
            let name = item.lastPathComponent.lowercased()
            guard name.contains("linkedin") else { continue }
            if let result = await tryParse(item) {
                logger.info(" Found Shares.csv in: \(item.lastPathComponent)")
                return result
            }
        }
        return nil
    }

    /// Parse a Shares.csv file and return up to 5 non-empty comment snippets for voice analysis.
    private func parseShareSnippets(at url: URL) async -> [String] {
        let shares = await linkedInService.parseShares(at: url)
        let snippets = shares
            .sorted { $0.shareDate > $1.shareDate }
            .prefix(5)
            .compactMap { $0.shareComment.map { $0.count > 500 ? String($0.prefix(500)) + "…" : $0 } }
        logger.info(" Parsed \(shares.count) shares, \(snippets.count) with comments")
        return Array(snippets)
    }

    /// Analyze writing voice from share comment snippets using AI.
    private func analyzeWritingVoice(shares: [String]) async -> String {
        let combined = shares.joined(separator: "\n---\n")

        let instructions = """
            You are a writing style analyst. Respond with ONE single sentence. \
            Never number your response. Never list multiple analyses. \
            Never quote or summarize post content.
            """

        let prompt = """
            Below are several LinkedIn share comments by the same author. Read all of them together, \
            then write ONE sentence describing the author's overall writing voice and style.

            Focus on: formality level, emotional tone, use of humor or storytelling, \
            sentence structure, and intended audience. Do NOT describe individual posts.

            ---
            \(combined)
            ---
            """

        do {
            let result = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.warning("LinkedIn voice analysis failed: \(error.localizedDescription)")
            return ""
        }
    }

    // MARK: - Private: Helpers

    private func clearPendingState() {
        pendingMessages             = []
        pendingConnections          = []
        pendingEndorsementsReceived = []
        pendingEndorsementsGiven    = []
        pendingRecommendationsGiven = []
        pendingRecommendationsReceived = []
        pendingReactionsGiven       = []
        pendingCommentsGiven        = []
        pendingInvitations          = []
        pendingShares               = []
        pendingUserProfile          = nil
        touchScores                 = [:]
        importCandidates            = []
        cleanupTempDir()
    }

    /// Remove the temporary directory created during ZIP import, if any.
    private func cleanupTempDir() {
        guard let dir = tempExtractDir else { return }
        tempExtractDir = nil
        try? FileManager.default.removeItem(at: dir)
        logger.info("Cleaned up temp LinkedIn extract directory")
    }
}
