//
//  FacebookImportCoordinator.swift
//  SAM
//
//  Phase FB-1: Facebook Archive Import
//
//  Flow:
//   1. loadFolder  — parse all JSONs, compute touch scores, build importCandidates list
//   2. (UI)        — user sees FacebookImportReviewSheet; toggles Add/Later per contact
//   3. confirmImport(classifications:) — persist records, store IntentionalTouch events
//

import Foundation
import SwiftUI
import SwiftData
import os.log

@MainActor
@Observable
final class FacebookImportCoordinator {

    // MARK: - Singleton

    static let shared = FacebookImportCoordinator()

    // MARK: - Dependencies

    private let facebookService    = FacebookService.shared
    private let peopleRepo         = PeopleRepository.shared
    private let unknownSenderRepo  = UnknownSenderRepository.shared
    // contactsService removed — Facebook import creates standalone SamPerson records, not Apple Contacts
    private let touchRepo          = IntentionalTouchRepository.shared

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "FacebookImportCoordinator")

    // MARK: - State

    enum ImportStatus: Equatable {
        case idle, parsing, awaitingReview, importing, success, failed
        var displayText: String {
            switch self {
            case .idle:           "Ready"
            case .parsing:        "Reading files…"
            case .awaitingReview: "Ready to review"
            case .importing:      "Importing…"
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
    private(set) var parsedFriendCount: Int = 0
    private(set) var parsedMessageThreadCount: Int = 0
    private(set) var parsedMessageCount: Int = 0
    private(set) var matchedFriendCount: Int = 0
    private(set) var unmatchedFriendCount: Int = 0
    /// True if a user Facebook profile was found and parsed in the current import session.
    private(set) var userProfileParsed: Bool = false

    // De-duplication state
    private(set) var exactMatchCount: Int = 0
    private(set) var probableMatchCount: Int = 0
    private(set) var noMatchCount: Int = 0
    /// Non-nil when last import was more than 90 days ago.
    private(set) var staleImportWarning: String? = nil

    // MARK: - Profile Analysis State (Phase FB-3)

    private(set) var profileAnalysisStatus: ProfileAnalysisStatus = .idle
    private(set) var latestProfileAnalysis: ProfileAnalysisDTO? = nil

    // MARK: - Cross-Platform Consistency State (Phase FB-4)

    private(set) var crossPlatformAnalysisStatus: ProfileAnalysisStatus = .idle
    private(set) var latestCrossPlatformAnalysis: ProfileAnalysisDTO? = nil
    private(set) var crossPlatformComparison: CrossPlatformProfileComparison? = nil
    private(set) var crossPlatformOverlapCount: Int = 0

    // MARK: - Parsed state (held between loadFolder and confirmImport)

    private var pendingFriends: [FacebookFriendDTO] = []
    private var pendingMessages: [FacebookMessageDTO] = []
    private var pendingComments: [FacebookCommentDTO] = []
    private var pendingReactions: [FacebookReactionDTO] = []
    private var pendingFriendRequests: [FacebookFriendRequestDTO] = []
    private var pendingUserProfile: UserFacebookProfileDTO? = nil
    private var pendingPosts: [FacebookPostDTO] = []
    private(set) var parsedPostCount: Int = 0

    /// Computed touch scores keyed by normalized display name.
    private var touchScores: [String: IntentionalTouchScore] = [:]

    /// Import candidates built from friends, ready for the review sheet.
    private(set) var importCandidates: [FacebookImportCandidate] = []

    // MARK: - Convenience counts

    var pendingFriendCount: Int { pendingFriends.count }

    // MARK: - UserDefaults

    @ObservationIgnored
    var lastFacebookImportAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: "sam.facebook.lastImportAt")
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0,
                                      forKey: "sam.facebook.lastImportAt")
        }
    }

    // MARK: - Initialization

    private init() {
        // Check for stale import warning
        if let lastImport = lastFacebookImportAt {
            let daysSince = Calendar.current.dateComponents([.day], from: lastImport, to: Date()).day ?? 0
            if daysSince > 90 {
                staleImportWarning = "Facebook data was last imported \(daysSince) days ago. Consider re-importing for fresh interaction data."
            }
        }
    }

    // MARK: - Public API

    /// Parse a Facebook data export folder. Call from Settings UI after user selects folder.
    /// Populates importCandidates for the review sheet.
    func loadFolder(url: URL) async {
        guard importStatus != .parsing && importStatus != .importing else { return }

        importStatus = .parsing
        progressMessage = "Reading JSON files…"
        lastError = nil
        resetParsedState()

        do {
            // Step 1: Validate folder structure — must contain friends list
            let friendsFile = url.appending(path: "connections/friends/your_friends.json")
            guard FileManager.default.fileExists(atPath: friendsFile.path) else {
                throw ImportError.invalidFolder("Could not find connections/friends/your_friends.json. Select the root of your Facebook export folder.")
            }

            // Step 2: Parse user profile
            progressMessage = "Parsing profile…"
            pendingUserProfile = await facebookService.parseUserProfile(in: url)
            userProfileParsed = pendingUserProfile != nil

            // Step 3: Parse friends list
            progressMessage = "Parsing friends list…"
            pendingFriends = await facebookService.parseFriends(in: url)
            parsedFriendCount = pendingFriends.count
            logger.info("Parsed \(self.parsedFriendCount) friends")

            // Step 4: Parse all Messenger threads
            progressMessage = "Parsing Messenger threads…"
            pendingMessages = await facebookService.parseMessengerThreads(in: url)
            parsedMessageCount = pendingMessages.count

            // Count unique threads
            let uniqueThreads = Set(pendingMessages.map(\.threadId))
            parsedMessageThreadCount = uniqueThreads.count
            logger.info("Parsed \(self.parsedMessageCount) messages across \(self.parsedMessageThreadCount) threads")

            // Step 5: Parse comments, reactions, friend requests
            progressMessage = "Parsing comments and reactions…"
            pendingComments = await facebookService.parseComments(in: url)
            pendingReactions = await facebookService.parseReactions(in: url)
            let sentRequests = await facebookService.parseSentFriendRequests(in: url)
            let receivedRequests = await facebookService.parseReceivedFriendRequests(in: url)
            pendingFriendRequests = sentRequests + receivedRequests

            // Step 5b: Parse user posts
            progressMessage = "Parsing posts…"
            pendingPosts = await facebookService.parsePosts(in: url)
            parsedPostCount = pendingPosts.count
            logger.info("Parsed \(self.parsedPostCount) text posts")

            // Step 6: Compute touch scores
            progressMessage = "Computing touch scores…"
            touchScores = computeTouchScores()

            // Step 7: Build import candidates with matching
            progressMessage = "Matching contacts…"
            importCandidates = await buildImportCandidates()

            // Compute match statistics
            exactMatchCount = importCandidates.filter { $0.matchStatus.isExact }.count
            probableMatchCount = importCandidates.filter { $0.matchStatus.isProbable }.count
            noMatchCount = importCandidates.filter { $0.matchStatus == .noMatch }.count

            importStatus = .awaitingReview
            progressMessage = nil
            logger.info("Facebook import ready for review: \(self.exactMatchCount) exact, \(self.probableMatchCount) probable, \(self.noMatchCount) no match")

        } catch let error as ImportError {
            importStatus = .failed
            lastError = error.message
            progressMessage = nil
            logger.error("Facebook import failed: \(error.message)")
        } catch {
            importStatus = .failed
            lastError = "Unexpected error: \(error.localizedDescription)"
            progressMessage = nil
            logger.error("Facebook import failed: \(error)")
        }
    }

    /// Process user's classifications from the review sheet.
    /// Creates Apple Contacts, routes to Unknown Senders, persists IntentionalTouch records.
    func confirmImport(classifications: [UUID: FacebookClassification]) async {
        guard importStatus == .awaitingReview else { return }

        importStatus = .importing
        progressMessage = "Starting import…"

        let importRecord = FacebookImport(
            importDate: Date(),
            archiveFileName: "Facebook Export",
            friendCount: parsedFriendCount,
            status: .processing
        )

        do {
            let context = SAMModelContainer.newContext()

            // Step 1: Silently enrich exact matches
            progressMessage = "Enriching matched contacts…"
            let exactMatches = importCandidates.filter { $0.matchStatus.isExact }
            matchedFriendCount = exactMatches.count

            // Step 2: Persist IntentionalTouch records
            progressMessage = "Recording touch events…"
            let touchCount = persistTouchRecords(
                importID: importRecord.id,
                context: context
            )
            importRecord.touchEventsFound = touchCount

            // Step 3: Create SamPerson records for "Add" candidates (no Apple Contact)
            progressMessage = "Creating new contacts…"
            var newContactCount = 0
            for candidate in importCandidates {
                let classification = classifications[candidate.id] ?? candidate.defaultClassification
                if classification == .add {
                    do {
                        try peopleRepo.upsertFromSocialImport(
                            displayName: candidate.displayName,
                            facebookFriendedOn: candidate.friendedOn,
                            facebookMessageCount: candidate.messageCount,
                            facebookLastMessageDate: candidate.lastMessageDate,
                            facebookTouchScore: candidate.touchScore?.totalScore ?? 0
                        )
                        newContactCount += 1
                    } catch {
                        logger.error("Failed to create SamPerson for '\(candidate.displayName, privacy: .public)': \(error)")
                    }
                }
            }
            importRecord.newContactsFound = newContactCount

            // Step 4: Merge confirmed probable matches
            progressMessage = "Merging confirmed matches…"
            for candidate in importCandidates where candidate.matchStatus.isProbable {
                let classification = classifications[candidate.id] ?? candidate.defaultClassification
                if classification == .merge, let matchInfo = candidate.matchedPersonInfo {
                    // Update the matched SamPerson with Facebook data
                    enrichMatchedPerson(personID: matchInfo.personID, candidate: candidate, context: context)
                    matchedFriendCount += 1
                }
            }
            importRecord.matchedContactCount = matchedFriendCount

            // Step 5: Route "Later" contacts to UnknownSender triage
            progressMessage = "Routing unmatched contacts…"
            routeUnmatchedContacts(candidates: importCandidates, classifications: classifications)

            // Step 6: Save import audit record
            progressMessage = "Saving import record…"
            importRecord.messageThreadsParsed = parsedMessageThreadCount
            importRecord.statusRawValue = FacebookImportStatus.complete.rawValue
            context.insert(importRecord)
            try context.save()

            // Step 7: Update state
            lastImportedAt = Date()
            lastFacebookImportAt = Date()
            lastImportCount = parsedFriendCount
            unmatchedFriendCount = noMatchCount - newContactCount
            staleImportWarning = nil

            // Step 8: Build and cache Facebook analysis snapshot
            let snapshot = buildFacebookAnalysisSnapshot()
            await BusinessProfileService.shared.saveFacebookSnapshot(snapshot)
            logger.info("Facebook analysis snapshot cached: \(snapshot.friendCount) friends, \(snapshot.messageThreadCount) threads")

            // Step 9: Run voice analysis on posts and store Facebook profile
            if var fbProfile = pendingUserProfile {
                if !pendingPosts.isEmpty {
                    let voiceSummary = await analyzeWritingVoice(posts: pendingPosts)
                    fbProfile.writingVoiceSummary = voiceSummary
                    fbProfile.recentPostSnippets = pendingPosts.prefix(5).map {
                        $0.text.count > 500 ? String($0.text.prefix(500)) + "…" : $0.text
                    }
                }
                await BusinessProfileService.shared.saveFacebookProfile(fbProfile)
            }

            importStatus = .success
            progressMessage = nil
            logger.info("Facebook import complete: \(self.matchedFriendCount) matched, \(newContactCount) new, \(touchCount) touches")

            // Step 10: Run profile analysis in background (non-blocking)
            Task(priority: .utility) { [weak self] in
                await self?.runProfileAnalysis()
            }

            // Step 11: Run cross-platform consistency analysis if LinkedIn data available
            Task(priority: .background) { [weak self] in
                await self?.runCrossPlatformAnalysis()
            }

            // Step 12: Re-run role deduction for newly imported people
            Task(priority: .utility) {
                await RoleDeductionEngine.shared.deduceRoles()
            }

        } catch {
            importStatus = .failed
            lastError = "Import failed: \(error.localizedDescription)"
            progressMessage = nil
            logger.error("Facebook confirmImport failed: \(error)")
        }
    }

    /// Cancel the current import and reset to idle.
    func cancelImport() {
        resetParsedState()
        importStatus = .idle
        progressMessage = nil
        lastError = nil
    }

    // MARK: - Private: Touch Score Computation

    /// Compute touch scores for all friends using Messenger messages, comments, reactions,
    /// and friend requests. Keyed by normalized display name (since Facebook exports
    /// have no profile URLs for friends).
    private func computeTouchScores() -> [String: IntentionalTouchScore] {
        let userName = pendingUserProfile?.fullName ?? "David Snyder"
        let normalizedUserName = facebookService.normalizeNameForMatching(userName)

        // Build message tuples for TouchScoringEngine
        // For messages, the "profileURL" slot holds the normalized friend name
        var messageTuples: [(profileURL: String, direction: TouchDirection, date: Date, snippet: String?)] = []

        for msg in pendingMessages {
            let senderNorm = facebookService.normalizeNameForMatching(msg.senderName)
            guard senderNorm != normalizedUserName else {
                // User sent this message — attribute to each non-user participant
                for participant in msg.participantNames {
                    let pNorm = facebookService.normalizeNameForMatching(participant)
                    guard pNorm != normalizedUserName else { continue }
                    let weight = msg.isGroupThread ? max(1, msg.participantCount - 1) : 1
                    // For group threads, we still add the touch but the scoring engine
                    // handles per-touch weight via the base weight system.
                    // We add one tuple per participant, which naturally distributes touches.
                    for _ in 0..<(msg.isGroupThread ? 1 : 1) {
                        messageTuples.append((
                            profileURL: pNorm,
                            direction: .outbound,
                            date: msg.date,
                            snippet: msg.content.map { String($0.prefix(200)) }
                        ))
                    }
                    _ = weight // reserved for future per-message weight adjustment
                }
                continue
            }

            // Someone else sent this message
            messageTuples.append((
                profileURL: senderNorm,
                direction: .inbound,
                date: msg.date,
                snippet: msg.content.map { String($0.prefix(200)) }
            ))
        }

        // Build invitation tuples from friend requests
        var invitationTuples: [(profileURL: String, isPersonalized: Bool, date: Date)] = []
        for req in pendingFriendRequests {
            let nameNorm = facebookService.normalizeNameForMatching(req.name)
            invitationTuples.append((
                profileURL: nameNorm,
                isPersonalized: true,  // Friend requests are always intentional
                date: req.timestamp
            ))
        }

        // Build comment tuples
        var commentTuples: [(profileURL: String?, date: Date)] = []
        for comment in pendingComments {
            let nameNorm = facebookService.normalizeNameForMatching(comment.targetName)
            commentTuples.append((profileURL: nameNorm, date: comment.timestamp))
        }

        // Build reaction tuples
        var reactionTuples: [(profileURL: String?, date: Date)] = []
        for reaction in pendingReactions {
            let nameNorm = facebookService.normalizeNameForMatching(reaction.targetName)
            reactionTuples.append((profileURL: nameNorm, date: reaction.timestamp))
        }

        // Use the shared TouchScoringEngine (same as LinkedIn)
        return TouchScoringEngine.computeScores(
            messages: messageTuples,
            invitations: invitationTuples,
            endorsementsReceived: [],   // Not applicable for Facebook
            endorsementsGiven: [],
            recommendationsReceived: [],
            recommendationsGiven: [],
            reactions: reactionTuples,
            comments: commentTuples
        )
    }

    // MARK: - Private: Build Import Candidates

    /// Build import candidates from parsed friends, enriched with touch scores and match status.
    private func buildImportCandidates() async -> [FacebookImportCandidate] {
        var candidates: [FacebookImportCandidate] = []

        // Build a lookup of message counts and last message dates per normalized name
        let userName = pendingUserProfile?.fullName ?? "David Snyder"
        let normalizedUserName = facebookService.normalizeNameForMatching(userName)
        var messageCountByName: [String: Int] = [:]
        var lastMessageByName: [String: Date] = [:]
        var threadIdByName: [String: String] = [:]

        for msg in pendingMessages {
            for participant in msg.participantNames {
                let pNorm = facebookService.normalizeNameForMatching(participant)
                guard pNorm != normalizedUserName else { continue }
                messageCountByName[pNorm, default: 0] += 1
                if let existing = lastMessageByName[pNorm] {
                    if msg.date > existing { lastMessageByName[pNorm] = msg.date }
                } else {
                    lastMessageByName[pNorm] = msg.date
                }
                if threadIdByName[pNorm] == nil {
                    threadIdByName[pNorm] = msg.threadId
                }
            }
        }

        // Build the lookup of all existing SAM people for matching
        let allPeople = await loadAllPeopleForMatching()

        for friend in pendingFriends {
            let nameNorm = facebookService.normalizeNameForMatching(friend.name)
            let score = touchScores[nameNorm]
            let msgCount = messageCountByName[nameNorm] ?? 0
            let lastMsg = lastMessageByName[nameNorm]
            let threadId = threadIdByName[nameNorm]

            // Run matching cascade
            let (matchStatus, matchedInfo) = matchPerson(
                name: friend.name,
                normalizedName: nameNorm,
                allPeople: allPeople
            )

            // Classification: exact matches are silently enriched, probable need confirmation,
            // no-match with score > 0 defaults to add, score = 0 defaults to later
            let defaultClassification: FacebookClassification
            if matchStatus.isExact {
                defaultClassification = .merge
            } else if matchStatus.isProbable {
                defaultClassification = .merge
            } else if (score?.totalScore ?? 0) > 0 {
                defaultClassification = .add
            } else {
                defaultClassification = .later
            }

            candidates.append(FacebookImportCandidate(
                displayName: friend.name,
                friendedOn: friend.friendedOn,
                messengerThreadId: threadId,
                messageCount: msgCount,
                lastMessageDate: lastMsg,
                touchScore: score,
                matchStatus: matchStatus,
                defaultClassification: defaultClassification,
                matchedPersonInfo: matchedInfo
            ))
        }

        // Sort: exact matches first, then probable, then by score descending
        candidates.sort { a, b in
            if a.matchStatus.isExact != b.matchStatus.isExact { return a.matchStatus.isExact }
            if a.matchStatus.isProbable != b.matchStatus.isProbable { return a.matchStatus.isProbable }
            return (a.touchScore?.totalScore ?? 0) > (b.touchScore?.totalScore ?? 0)
        }

        return candidates
    }

    // MARK: - Private: Contact Matching

    /// Lightweight struct to hold existing SamPerson data for matching.
    private struct PersonMatchData {
        let id: UUID
        let displayName: String
        let normalizedName: String
        let facebookURL: String?
        let linkedInURL: String?
        let email: String?
    }

    /// Load all SAM people into memory for matching.
    private func loadAllPeopleForMatching() async -> [PersonMatchData] {
        let context = SAMModelContainer.newContext()
        let descriptor = FetchDescriptor<SamPerson>()
        guard let people = try? context.fetch(descriptor) else { return [] }

        return people.map { person in
            PersonMatchData(
                id: person.id,
                displayName: person.displayNameCache ?? person.displayName,
                normalizedName: facebookService.normalizeNameForMatching(person.displayNameCache ?? person.displayName),
                facebookURL: person.facebookProfileURL,
                linkedInURL: person.linkedInProfileURL,
                email: person.emailCache
            )
        }
    }

    /// Run the 4-priority matching cascade for a Facebook friend.
    private func matchPerson(
        name: String,
        normalizedName: String,
        allPeople: [PersonMatchData]
    ) -> (FacebookMatchStatus, MatchedPersonInfo?) {

        // Priority 1: Facebook profile URL match (if SamPerson already has one)
        for person in allPeople {
            if let fbURL = person.facebookURL, !fbURL.isEmpty {
                // We don't have the friend's URL from the export, but if a SamPerson
                // has a Facebook URL and the names match, that's a high-confidence match
                if person.normalizedName == normalizedName {
                    return (.exactMatchFacebookURL, makeMatchInfo(person))
                }
            }
        }

        // Priority 2: Apple Contacts match (check if Apple Contact has a Facebook social profile)
        // This would require querying CNContactStore — for FB-1 we do name-based matching
        // TODO: FB-4 will add Apple Contacts social profile URL checking

        // Priority 3: Cross-platform match (name matches SamPerson with LinkedIn data)
        for person in allPeople {
            if person.normalizedName == normalizedName, person.linkedInURL != nil {
                return (.probableMatchCrossPlatform, makeMatchInfo(person))
            }
        }

        // Priority 4: Fuzzy name-only match
        for person in allPeople {
            if person.normalizedName == normalizedName {
                return (.probableMatchName, makeMatchInfo(person))
            }
        }

        return (.noMatch, nil)
    }

    private func makeMatchInfo(_ person: PersonMatchData) -> MatchedPersonInfo {
        MatchedPersonInfo(
            personID: person.id,
            displayName: person.displayName,
            email: person.email,
            linkedInURL: person.linkedInURL
        )
    }

    // MARK: - Private: Persist Touch Records

    /// Create IntentionalTouch records for all parsed touch data.
    /// Returns the number of touch records created.
    private func persistTouchRecords(importID: UUID, context: ModelContext) -> Int {
        var count = 0
        let userName = pendingUserProfile?.fullName ?? "David Snyder"
        let normalizedUserName = facebookService.normalizeNameForMatching(userName)

        // Messages → IntentionalTouch
        // Group by normalized sender name to avoid creating too many records
        // We'll create one touch record per unique (sender, date-rounded-to-day) pair
        var seenMessageKeys: Set<String> = []
        for msg in pendingMessages {
            let senderNorm = facebookService.normalizeNameForMatching(msg.senderName)
            let isOutbound = senderNorm == normalizedUserName

            if isOutbound {
                // User sent — attribute to each non-user participant
                for participant in msg.participantNames {
                    let pNorm = facebookService.normalizeNameForMatching(participant)
                    guard pNorm != normalizedUserName else { continue }
                    let key = "msg-\(pNorm)-\(msg.timestampMs)"
                    guard !seenMessageKeys.contains(key) else { continue }
                    seenMessageKeys.insert(key)

                    let touch = IntentionalTouch(
                        platform: .facebook,
                        touchType: .message,
                        direction: .outbound,
                        contactProfileUrl: pNorm,
                        date: msg.date,
                        snippet: msg.content.map { String($0.prefix(200)) },
                        weight: Int(Double(TouchType.message.baseWeight) * msg.category.weightMultiplier),
                        source: .bulkImport,
                        sourceImportID: importID
                    )
                    context.insert(touch)
                    count += 1
                }
            } else {
                let key = "msg-\(senderNorm)-\(msg.timestampMs)"
                guard !seenMessageKeys.contains(key) else { continue }
                seenMessageKeys.insert(key)

                let touch = IntentionalTouch(
                    platform: .facebook,
                    touchType: .message,
                    direction: .inbound,
                    contactProfileUrl: senderNorm,
                    date: msg.date,
                    snippet: msg.content.map { String($0.prefix(200)) },
                    weight: Int(Double(TouchType.message.baseWeight) * msg.category.weightMultiplier),
                    source: .bulkImport,
                    sourceImportID: importID
                )
                context.insert(touch)
                count += 1
            }
        }

        // Comments → IntentionalTouch
        for comment in pendingComments {
            let nameNorm = facebookService.normalizeNameForMatching(comment.targetName)
            let touch = IntentionalTouch(
                platform: .facebook,
                touchType: .comment,
                direction: .outbound,
                contactProfileUrl: nameNorm,
                date: comment.timestamp,
                snippet: comment.commentText.map { String($0.prefix(200)) },
                weight: TouchType.comment.baseWeight,
                source: .bulkImport,
                sourceImportID: importID
            )
            context.insert(touch)
            count += 1
        }

        // Reactions → IntentionalTouch
        for reaction in pendingReactions {
            let nameNorm = facebookService.normalizeNameForMatching(reaction.targetName)
            let touch = IntentionalTouch(
                platform: .facebook,
                touchType: .reaction,
                direction: .outbound,
                contactProfileUrl: nameNorm,
                date: reaction.timestamp,
                snippet: reaction.reactionType,
                weight: TouchType.reaction.baseWeight,
                source: .bulkImport,
                sourceImportID: importID
            )
            context.insert(touch)
            count += 1
        }

        // Friend requests → IntentionalTouch
        for req in pendingFriendRequests {
            let nameNorm = facebookService.normalizeNameForMatching(req.name)
            let direction: TouchDirection = req.direction == .sent ? .outbound : .inbound
            let touch = IntentionalTouch(
                platform: .facebook,
                touchType: .invitationPersonalized,
                direction: direction,
                contactProfileUrl: nameNorm,
                date: req.timestamp,
                snippet: "Friend request \(req.direction.rawValue)",
                weight: TouchType.invitationPersonalized.baseWeight,
                source: .bulkImport,
                sourceImportID: importID
            )
            context.insert(touch)
            count += 1
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to save IntentionalTouch records: \(error)")
        }

        return count
    }

    // MARK: - Private: Enrich Matched Person

    /// Update an existing SamPerson with Facebook data (friendship date, messaging stats, etc.).
    private func enrichMatchedPerson(personID: UUID, candidate: FacebookImportCandidate, context: ModelContext) {
        let descriptor = FetchDescriptor<SamPerson>(predicate: #Predicate { $0.id == personID })
        guard let person = try? context.fetch(descriptor).first else { return }

        // Set Facebook friendship date if we have one
        if let friendedOn = candidate.friendedOn {
            person.facebookFriendedOn = friendedOn
        }
        // Store messaging stats
        if candidate.messageCount > 0 {
            person.facebookMessageCount = candidate.messageCount
        }
        if let lastMsg = candidate.lastMessageDate {
            person.facebookLastMessageDate = lastMsg
        }
        if let score = candidate.touchScore?.totalScore, score > 0 {
            person.facebookTouchScore = score
        }
    }

    // MARK: - Private: Route Unmatched Contacts

    /// Route unmatched contacts to triage based on user classifications.
    /// "Later" contacts go to UnknownSender with Facebook metadata.
    private func routeUnmatchedContacts(
        candidates: [FacebookImportCandidate],
        classifications: [UUID: FacebookClassification]
    ) {
        for candidate in candidates {
            let classification = classifications[candidate.id] ?? candidate.defaultClassification
            guard classification == .later else { continue }

            // Synthetic unique key: "facebook:{normalized-name}-{timestamp}"
            let nameKey = facebookService.normalizeNameForMatching(candidate.displayName)
            let timestamp = candidate.friendedOn.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let uniqueKey = "facebook:\(nameKey)-\(timestamp)"

            do {
                try unknownSenderRepo.upsertFacebookLater(
                    uniqueKey: uniqueKey,
                    displayName: candidate.displayName,
                    touchScore: candidate.touchScore?.totalScore ?? 0,
                    friendedOn: candidate.friendedOn,
                    messageCount: candidate.messageCount,
                    lastMessageDate: candidate.lastMessageDate
                )
            } catch {
                logger.error("Failed to route Facebook Later contact '\(candidate.displayName)': \(error)")
            }
        }
    }

    // MARK: - Profile Analysis (Phase FB-3)

    /// Runs the Facebook profile analysis AI agent. Safe to call multiple times; guards against concurrent runs.
    func runProfileAnalysis() async {
        guard profileAnalysisStatus != .analyzing else { return }
        guard let snapshot = await BusinessProfileService.shared.facebookSnapshot() else {
            logger.info("Facebook profile analysis skipped: no analysis snapshot available")
            return
        }

        profileAnalysisStatus = .analyzing

        do {
            let data = await buildFacebookAnalysisInput(snapshot: snapshot)
            let previousAnalysis = await BusinessProfileService.shared.profileAnalysis(for: "facebook")
            let previousJSON: String? = {
                guard let prev = previousAnalysis,
                      let encoded = try? JSONEncoder().encode(prev) else { return nil }
                return String(data: encoded, encoding: .utf8)
            }()

            let result = try await FacebookProfileAnalystService.shared.analyze(
                data: data,
                previousAnalysisJSON: previousJSON
            )
            await BusinessProfileService.shared.saveProfileAnalysis(result)
            latestProfileAnalysis = result
            profileAnalysisStatus = .complete
            logger.info("Facebook profile analysis complete: score \(result.overallScore), \(result.praise.count) praise, \(result.improvements.count) improvements")
        } catch {
            logger.error("Facebook profile analysis failed: \(error.localizedDescription)")
            profileAnalysisStatus = .failed
        }
    }

    // MARK: - Cross-Platform Consistency (Phase FB-4)

    /// Runs the cross-platform consistency analysis.
    /// Compares LinkedIn and Facebook profiles and identifies friend overlap.
    func runCrossPlatformAnalysis() async {
        guard crossPlatformAnalysisStatus != .analyzing else { return }

        // Need both LinkedIn and Facebook profiles
        guard let linkedInProfile = await BusinessProfileService.shared.linkedInProfile() else {
            logger.info("Cross-platform analysis skipped: no LinkedIn profile available")
            return
        }

        guard let fbFragment = await BusinessProfileService.shared.facebookProfileFragment(),
              !fbFragment.isEmpty,
              let fbProfile = pendingUserProfile else {
            logger.info("Cross-platform analysis skipped: no Facebook profile available")
            return
        }

        crossPlatformAnalysisStatus = .analyzing

        do {
            // Step 1: Profile field comparison
            let comparison = await CrossPlatformConsistencyService.shared.compareProfiles(
                linkedIn: linkedInProfile,
                facebook: fbProfile
            )
            crossPlatformComparison = comparison

            // Step 2: Friend overlap detection
            let facebookFriendData = pendingFriends.map { (name: $0.name, friendedOn: $0.friendedOn) }

            // Load LinkedIn connections from SamPerson records that have LinkedIn URLs
            let linkedInConnectionData = await loadLinkedInConnectionNames()

            let overlap = await CrossPlatformConsistencyService.shared.findCrossPlatformContacts(
                facebookFriends: facebookFriendData,
                linkedInConnections: linkedInConnectionData
            )
            crossPlatformOverlapCount = overlap.count

            // Step 3: AI analysis
            let result = try await CrossPlatformConsistencyService.shared.analyzeConsistency(
                profileComparison: comparison,
                overlapCount: overlap.count,
                totalLinkedInConnections: linkedInConnectionData.count,
                totalFacebookFriends: pendingFriends.count
            )
            await BusinessProfileService.shared.saveProfileAnalysis(result)
            latestCrossPlatformAnalysis = result
            crossPlatformAnalysisStatus = .complete
            logger.info("Cross-platform analysis complete: score \(result.overallScore), overlap \(overlap.count)")

        } catch {
            logger.error("Cross-platform analysis failed: \(error.localizedDescription)")
            crossPlatformAnalysisStatus = .failed
        }
    }

    /// Loads names and LinkedIn URLs from existing SamPerson records.
    private func loadLinkedInConnectionNames() async -> [(name: String, profileURL: String)] {
        let context = SAMModelContainer.newContext()
        let descriptor = FetchDescriptor<SamPerson>()
        guard let people = try? context.fetch(descriptor) else { return [] }

        return people.compactMap { person -> (name: String, profileURL: String)? in
            guard let url = person.linkedInProfileURL, !url.isEmpty else { return nil }
            let name = person.displayNameCache ?? person.displayName
            return (name: name, profileURL: url)
        }
    }

    /// Assembles the text block sent to the AI for Facebook profile analysis.
    private func buildFacebookAnalysisInput(snapshot: FacebookAnalysisSnapshot) async -> String {
        var lines: [String] = []

        // Identity (from profile if available, otherwise from snapshot context)
        if let profile = pendingUserProfile {
            lines.append("Facebook Profile for \(profile.fullName)")
            if let city = profile.currentCity { lines.append("Current city: \(city)") }
            if let hometown = profile.hometown { lines.append("Hometown: \(hometown)") }

            if !profile.workExperiences.isEmpty {
                lines.append("\nWork Experience:")
                for w in profile.workExperiences {
                    var parts = [w.employer]
                    if let t = w.title { parts.insert(t + " at", at: 0) }
                    if let l = w.location { parts.append("(\(l))") }
                    lines.append("- \(parts.joined(separator: " "))")
                }
            }

            if !profile.educationExperiences.isEmpty {
                lines.append("\nEducation:")
                for e in profile.educationExperiences {
                    var desc = e.name
                    if let t = e.schoolType { desc += " (\(t))" }
                    if !e.concentrations.isEmpty { desc += " — \(e.concentrations.joined(separator: ", "))" }
                    lines.append("- \(desc)")
                }
            }

            if let r = profile.relationship {
                var desc = r.status
                if let partner = r.partner { desc += " to \(partner)" }
                lines.append("\nRelationship: \(desc)")
            }

            if !profile.familyMembers.isEmpty {
                lines.append("Family: \(profile.familyMembers.map { "\($0.name) (\($0.relation))" }.joined(separator: ", "))")
            }

            if !profile.websites.isEmpty {
                lines.append("Websites: \(profile.websites.joined(separator: ", "))")
            }

            if let uri = profile.profileUri {
                lines.append("Profile URL: \(uri)")
            }
        } else if let fragment = await BusinessProfileService.shared.facebookProfileFragment() {
            lines.append(fragment)
        }

        // Profile completeness flags
        lines.append("\nProfile Completeness:")
        lines.append("Current city: \(snapshot.hasCurrentCity ? "Yes" : "Not set")")
        lines.append("Hometown: \(snapshot.hasHometown ? "Yes" : "Not set")")
        lines.append("Work experience: \(snapshot.hasWorkExperience ? "Yes" : "Not set")")
        lines.append("Education: \(snapshot.hasEducation ? "Yes" : "Not set")")
        lines.append("Websites: \(snapshot.hasWebsites ? "Yes" : "Not set")")
        lines.append("Profile URL: \(snapshot.hasProfileUri ? "Yes" : "Not set")")

        // Friend network
        lines.append("\nFriend Network: \(snapshot.friendCount) friends")
        let sortedYears = snapshot.friendsByYear.sorted { $0.key < $1.key }
        if !sortedYears.isEmpty {
            lines.append("Friends added by year: \(sortedYears.map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
        }

        // Messaging activity
        lines.append("\nMessaging Activity:")
        lines.append("Total message threads: \(snapshot.messageThreadCount)")
        lines.append("Total messages: \(snapshot.totalMessageCount)")
        lines.append("Active threads (last 90 days): \(snapshot.activeThreadCount90Days)")

        if !snapshot.topMessaged.isEmpty {
            lines.append("\nTop messaged contacts:")
            for contact in snapshot.topMessaged {
                var desc = "- \(contact.name): \(contact.messageCount) messages"
                if let lastDate = contact.lastMessageDate {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    desc += " (last: \(formatter.string(from: lastDate)))"
                }
                lines.append(desc)
            }
        }

        // Engagement
        lines.append("\nEngagement Activity:")
        lines.append("Comments given: \(snapshot.commentsGivenCount)")
        lines.append("Reactions given: \(snapshot.reactionsGivenCount)")
        lines.append("Friend requests sent: \(snapshot.friendRequestsSentCount)")
        lines.append("Friend requests received: \(snapshot.friendRequestsReceivedCount)")

        // Ratio calculations
        if snapshot.friendCount > 0 {
            let activeRatio = Double(snapshot.activeThreadCount90Days) / Double(snapshot.friendCount)
            lines.append("\nActive conversation ratio: \(String(format: "%.1f%%", activeRatio * 100)) of friends have recent messages")
        }

        return lines.joined(separator: "\n")
    }

    /// Builds a Facebook analysis snapshot from the current pending state.
    private func buildFacebookAnalysisSnapshot() -> FacebookAnalysisSnapshot {
        let userName = pendingUserProfile?.fullName ?? "David Snyder"
        let normalizedUserName = facebookService.normalizeNameForMatching(userName)
        let now = Date()
        let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now

        // Count friends by year
        var friendsByYear: [String: Int] = [:]
        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"
        for friend in pendingFriends {
            let year = yearFormatter.string(from: friend.friendedOn)
            friendsByYear[year, default: 0] += 1
        }

        // Count active threads (any message in last 90 days)
        var threadLastMessage: [String: Date] = [:]
        for msg in pendingMessages {
            if let existing = threadLastMessage[msg.threadId] {
                if msg.date > existing { threadLastMessage[msg.threadId] = msg.date }
            } else {
                threadLastMessage[msg.threadId] = msg.date
            }
        }
        let activeThreadCount = threadLastMessage.values.filter { $0 > ninetyDaysAgo }.count

        // Top messaged contacts
        var messageCountByName: [String: Int] = [:]
        var lastMessageByName: [String: Date] = [:]
        for msg in pendingMessages {
            for participant in msg.participantNames {
                let pNorm = facebookService.normalizeNameForMatching(participant)
                guard pNorm != normalizedUserName else { continue }
                messageCountByName[pNorm, default: 0] += 1
                if let existing = lastMessageByName[pNorm] {
                    if msg.date > existing { lastMessageByName[pNorm] = msg.date }
                } else {
                    lastMessageByName[pNorm] = msg.date
                }
            }
        }

        let topMessaged = messageCountByName.sorted { $0.value > $1.value }
            .prefix(10)
            .map { entry in
                FacebookAnalysisSnapshot.TopContact(
                    name: entry.key,
                    messageCount: entry.value,
                    lastMessageDate: lastMessageByName[entry.key]
                )
            }

        // Post voice snippets (top 5, 500 chars each)
        let postSnippets = pendingPosts.prefix(5).map {
            $0.text.count > 500 ? String($0.text.prefix(500)) + "…" : $0.text
        }

        return FacebookAnalysisSnapshot(
            friendCount: pendingFriends.count,
            friendsByYear: friendsByYear,
            messageThreadCount: parsedMessageThreadCount,
            totalMessageCount: parsedMessageCount,
            activeThreadCount90Days: activeThreadCount,
            topMessaged: Array(topMessaged),
            commentsGivenCount: pendingComments.count,
            reactionsGivenCount: pendingReactions.count,
            friendRequestsSentCount: pendingFriendRequests.filter { $0.direction == .sent }.count,
            friendRequestsReceivedCount: pendingFriendRequests.filter { $0.direction == .received }.count,
            hasCurrentCity: pendingUserProfile?.currentCity != nil,
            hasHometown: pendingUserProfile?.hometown != nil,
            hasWorkExperience: !(pendingUserProfile?.workExperiences.isEmpty ?? true),
            hasEducation: !(pendingUserProfile?.educationExperiences.isEmpty ?? true),
            hasWebsites: !(pendingUserProfile?.websites.isEmpty ?? true),
            hasProfileUri: pendingUserProfile?.profileUri != nil,
            postCount: pendingPosts.count,
            recentPostSnippets: Array(postSnippets),
            writingVoiceSummary: pendingUserProfile?.writingVoiceSummary ?? "",
            snapshotDate: now
        )
    }

    // MARK: - Voice Analysis

    /// Analyze writing voice from Facebook post text using AI.
    /// Uses more samples (up to 10) since Facebook posts tend to be short.
    private func analyzeWritingVoice(posts: [FacebookPostDTO]) async -> String {
        // Use up to 10 posts since Facebook posts are often short (~88 chars avg)
        let samples = posts.prefix(10).map { post in
            post.text.count > 500 ? String(post.text.prefix(500)) + "…" : post.text
        }
        let combined = samples.joined(separator: "\n---\n")

        let instructions = """
            You are a writing style analyst. Respond with ONE single sentence. \
            Never number your response. Never list multiple analyses. \
            Never quote or summarize post content.
            """

        let prompt = """
            Below are several Facebook posts by the same author. Read all of them together, \
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
            logger.warning("Facebook voice analysis failed: \(error.localizedDescription)")
            return ""
        }
    }

    // MARK: - Private: Reset

    private func resetParsedState() {
        pendingFriends = []
        pendingMessages = []
        pendingComments = []
        pendingReactions = []
        pendingFriendRequests = []
        pendingUserProfile = nil
        pendingPosts = []
        parsedPostCount = 0
        touchScores = [:]
        importCandidates = []
        parsedFriendCount = 0
        parsedMessageThreadCount = 0
        parsedMessageCount = 0
        matchedFriendCount = 0
        unmatchedFriendCount = 0
        exactMatchCount = 0
        probableMatchCount = 0
        noMatchCount = 0
        userProfileParsed = false
    }

    // MARK: - Error Type

    private enum ImportError: Error {
        case invalidFolder(String)

        var message: String {
            switch self {
            case .invalidFolder(let msg): return msg
            }
        }
    }
}
