//
//  DailyBriefingCoordinator.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Daily Briefing System
//
//  Orchestrates daily briefing generation: first-open detection, data gathering,
//  AI narrative enrichment, persistence, evening state machine.
//  Follows InsightGenerator/OutcomeEngine pattern.
//

import Foundation
import SwiftData
import os.log
import AppKit

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DailyBriefingCoordinator")

@MainActor
@Observable
final class DailyBriefingCoordinator {

    // MARK: - Singleton

    static let shared = DailyBriefingCoordinator()

    // MARK: - Observable State

    enum GenerationStatus: String, Sendable {
        case idle
        case generating
        case success
        case failed
    }

    enum EveningState: String, Sendable {
        case idle
        case checking
        case compiling      // pre-compiling briefing before showing prompt
        case prompted
        case viewing
        case postponed
        case completed
    }

    var morningBriefing: SamDailyBriefing?
    var eveningBriefing: SamDailyBriefing?
    var generationStatus: GenerationStatus = .idle
    var showMorningBriefing = false
    var showEveningPrompt = false
    var showEveningBriefing = false
    var eveningState: EveningState = .idle
    var isRecompilingEvening = false

    // MARK: - Private State

    private var context: ModelContext?
    private var dayRolloverTimer: Timer?
    private var eveningTimer: Timer?
    private var postponeTimer: Timer?
    private var activityCheckTimer: Timer?

    /// Evidence IDs of calls we've already prompted a post-call note for (session-scoped).
    private var promptedCallIDs: Set<UUID> = []

    // Dependencies
    private let evidenceRepo = EvidenceRepository.shared
    private let peopleRepo = PeopleRepository.shared
    private let notesRepo = NotesRepository.shared
    private let outcomeRepo = OutcomeRepository.shared
    private let meetingPrep = MeetingPrepCoordinator.shared

    private init() {}

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        self.context = ModelContext(container)

        // Load today's briefings if they exist
        loadTodaysBriefings()

        // Start day-rollover timer (every 5 minutes) — also checks for recently ended meetings/calls and sequence triggers
        dayRolloverTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDayRollover()
                self?.checkRecentlyEndedMeetings()
                self?.checkRecentlyEndedCalls()
                self?.checkSequenceTriggers()
            }
        }

        // Listen for system wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkDayRollover()
                self?.recheckEveningState()
            }
        }

        // Listen for app becoming active (evening re-check)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recheckEveningState()
            }
        }

        // Schedule evening timer
        scheduleEveningCheck()
    }

    // MARK: - First Open Check

    /// Called after imports complete. Shows morning briefing if first open of the day.
    func checkFirstOpenOfDay() async {
        let morningEnabled = UserDefaults.standard.object(forKey: "briefingMorningEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "briefingMorningEnabled")
        guard morningEnabled else { return }

        let todayKey = Calendar.current.startOfDay(for: .now)
        let lastDateStr = UserDefaults.standard.string(forKey: "lastBriefingDate") ?? ""
        let lastDate = ISO8601DateFormatter().date(from: lastDateStr)

        if let lastDate, Calendar.current.isDate(lastDate, inSameDayAs: todayKey) {
            // Already briefed today — just load existing
            loadTodaysBriefings()
            return
        }

        // Generate new morning briefing
        await generateMorningBriefing()

        // Check for weekly digest (Monday or first open of the week)
        await checkWeeklyDigest()
    }

    /// Check if this is the first open of the current ISO week and generate weekly priorities.
    private func checkWeeklyDigest() async {
        let enabled = UserDefaults.standard.object(forKey: "weeklyDigestEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "weeklyDigestEnabled")
        guard enabled else { return }

        let currentWeek = Calendar.current.component(.weekOfYear, from: .now)
        let currentYear = Calendar.current.component(.yearForWeekOfYear, from: .now)
        let weekKey = "\(currentYear)-W\(currentWeek)"

        let lastWeekKey = UserDefaults.standard.string(forKey: "lastWeeklyDigestWeek") ?? ""
        guard weekKey != lastWeekKey else { return }

        // Generate weekly priorities and attach to morning briefing
        let priorities = gatherWeeklyPriorities()
        guard !priorities.isEmpty else { return }

        morningBriefing?.weeklyPriorities = priorities
        try? context?.save()

        UserDefaults.standard.set(weekKey, forKey: "lastWeeklyDigestWeek")
        logger.info("Weekly digest generated with \(priorities.count) priorities for \(weekKey)")
    }

    // MARK: - Morning Briefing Generation

    private func generateMorningBriefing() async {
        guard generationStatus != .generating else { return }
        generationStatus = .generating

        do {
            let todayKey = Calendar.current.startOfDay(for: .now)

            // Gather data
            let calendarItems = gatherCalendarItems()
            let priorityActions = gatherPriorityActions()
            let followUps = gatherFollowUps()
            let lifeEvents = gatherLifeEvents()
            let tomorrowPreview = gatherTomorrowPreview()

            // Create briefing
            let briefing = SamDailyBriefing(
                briefingType: .morning,
                dateKey: todayKey,
                calendarItems: calendarItems,
                priorityActions: priorityActions,
                followUps: followUps,
                lifeEventOutreach: lifeEvents,
                tomorrowPreview: tomorrowPreview
            )

            // Metrics
            briefing.meetingCount = calendarItems.count

            // AI narrative (best-effort)
            let narrativeEnabled = UserDefaults.standard.object(forKey: "briefingNarrativeEnabled") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "briefingNarrativeEnabled")

            if narrativeEnabled {
                let narrative = await DailyBriefingService.shared.generateMorningNarrative(
                    calendarItems: calendarItems,
                    priorityActions: priorityActions,
                    followUps: followUps,
                    lifeEvents: lifeEvents,
                    tomorrowPreview: tomorrowPreview
                )
                briefing.narrativeSummary = narrative.visual.isEmpty ? nil : narrative.visual
                briefing.ttsNarrative = narrative.tts.isEmpty ? nil : narrative.tts
            }

            // Persist
            context?.insert(briefing)
            try context?.save()

            // Update state
            morningBriefing = briefing
            showMorningBriefing = true
            generationStatus = .success

            // Record today's date
            let formatter = ISO8601DateFormatter()
            UserDefaults.standard.set(formatter.string(from: todayKey), forKey: "lastBriefingDate")

            logger.info("Morning briefing generated: \(calendarItems.count) calendar, \(priorityActions.count) actions, \(followUps.count) follow-ups")

        } catch {
            generationStatus = .failed
            logger.error("Morning briefing generation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Evening Recap

    /// Called on configurable schedule to begin evening check.
    private func beginEveningCheck() {
        let eveningEnabled = UserDefaults.standard.object(forKey: "briefingEveningEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "briefingEveningEnabled")
        guard eveningEnabled else { return }
        guard eveningState == .idle || eveningState == .postponed else { return }

        eveningState = .checking

        // Check if meeting is currently in progress
        let now = Date()
        let meetingInProgress = meetingPrep.briefings.contains { briefing in
            briefing.startsAt <= now && (briefing.endsAt ?? briefing.startsAt.addingTimeInterval(3600)) > now
        }

        if meetingInProgress {
            // Hard postpone 15 min
            logger.info("Meeting in progress — postponing evening recap 15 min")
            postponeEvening(minutes: 15)
            return
        }

        // Check if note was saved recently (within 10 min)
        let tenMinAgo = Calendar.current.date(byAdding: .minute, value: -10, to: now)!
        let recentNote: Bool
        do {
            let allNotes = try notesRepo.fetchAll()
            recentNote = allNotes.contains { $0.updatedAt >= tenMinAgo }
        } catch {
            recentNote = false
        }

        if recentNote {
            // Soft postpone 10 min
            logger.info("Recent note activity — postponing evening recap 10 min")
            postponeEvening(minutes: 10)
            return
        }

        // All clear — if briefing already pre-compiled (e.g. after postpone), just show prompt
        if eveningBriefing != nil {
            eveningState = .prompted
            showEveningPrompt = true
            startActivityMonitor()
            return
        }

        // Pre-compile briefing in background, then show prompt
        eveningState = .compiling
        Task {
            await precompileEveningBriefing()
        }
    }

    /// User tapped "View" on evening prompt.
    func viewEveningRecap() {
        showEveningPrompt = false
        stopActivityMonitor()

        if eveningBriefing != nil {
            // Pre-compiled — show immediately
            eveningState = .viewing
            showEveningBriefing = true
            recordEveningViewed()
        } else {
            // Fallback: compile on demand
            eveningState = .viewing
            generationStatus = .generating
            Task {
                do {
                    let briefing = try await buildEveningBriefing()
                    eveningBriefing = briefing
                    showEveningBriefing = true
                    generationStatus = .success
                    recordEveningViewed()
                } catch {
                    generationStatus = .failed
                    eveningState = .idle
                    logger.error("Evening briefing fallback failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// User tapped "Later" on evening prompt.
    func postponeEveningFromUser() {
        stopActivityMonitor()
        postponeEvening(minutes: 30)
        showEveningPrompt = false
    }

    /// User dismissed evening prompt (X button) — decline for today.
    func declineEvening() {
        stopActivityMonitor()
        eveningState = .completed
        showEveningPrompt = false
        let formatter = ISO8601DateFormatter()
        let todayKey = Calendar.current.startOfDay(for: .now)
        UserDefaults.standard.set(formatter.string(from: todayKey), forKey: "lastEveningBriefingDate")
    }

    private func postponeEvening(minutes: Int) {
        eveningState = .postponed
        postponeTimer?.invalidate()
        postponeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.beginEveningCheck()
            }
        }
    }

    // MARK: - Evening Pre-compilation

    /// Pre-compile the evening briefing in background, then show prompt.
    private func precompileEveningBriefing() async {
        do {
            let briefing = try await buildEveningBriefing()
            eveningBriefing = briefing
            generationStatus = .success

            // Show prompt now that briefing is ready for instant viewing
            if eveningState == .compiling {
                eveningState = .prompted
                showEveningPrompt = true
                startActivityMonitor()
            }

            logger.info("Evening briefing pre-compiled")
        } catch {
            generationStatus = .failed
            eveningState = .idle
            logger.error("Evening briefing pre-compilation failed: \(error.localizedDescription)")
        }
    }

    /// Core evening briefing generation — gathers data, AI narrative, persists to SwiftData.
    private func buildEveningBriefing() async throws -> SamDailyBriefing {
        let todayKey = Calendar.current.startOfDay(for: .now)

        let accomplishments = gatherAccomplishments()
        let streakUpdates = gatherStreakUpdates()
        let tomorrowPreview = gatherTomorrowPreview()
        let metrics = gatherMetrics()

        let briefing = SamDailyBriefing(
            briefingType: .evening,
            dateKey: todayKey,
            tomorrowPreview: tomorrowPreview,
            accomplishments: accomplishments,
            streakUpdates: streakUpdates
        )

        briefing.meetingCount = metrics.meetingCount
        briefing.notesTakenCount = metrics.notesTakenCount
        briefing.outcomesCompletedCount = metrics.outcomesCompletedCount
        briefing.outcomesDismissedCount = metrics.outcomesDismissedCount
        briefing.followUpsCompletedCount = metrics.followUpsCompletedCount
        briefing.newContactsCount = metrics.newContactsCount
        briefing.emailsProcessedCount = metrics.emailsProcessedCount

        let narrativeEnabled = UserDefaults.standard.object(forKey: "briefingNarrativeEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "briefingNarrativeEnabled")

        if narrativeEnabled {
            let narrative = await DailyBriefingService.shared.generateEveningNarrative(
                accomplishments: accomplishments,
                streakUpdates: streakUpdates,
                metrics: metrics,
                tomorrowHighlights: tomorrowPreview
            )
            briefing.narrativeSummary = narrative.visual.isEmpty ? nil : narrative.visual
            briefing.ttsNarrative = narrative.tts.isEmpty ? nil : narrative.tts
        }

        context?.insert(briefing)
        try context?.save()

        logger.info("Evening briefing built: \(accomplishments.count) accomplishments")
        return briefing
    }

    private func recordEveningViewed() {
        let formatter = ISO8601DateFormatter()
        let todayKey = Calendar.current.startOfDay(for: .now)
        UserDefaults.standard.set(formatter.string(from: todayKey), forKey: "lastEveningBriefingDate")
    }

    // MARK: - Activity Monitoring (recompile if user does more work)

    private func startActivityMonitor() {
        activityCheckTimer?.invalidate()
        activityCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForNewActivity()
            }
        }
    }

    private func stopActivityMonitor() {
        activityCheckTimer?.invalidate()
        activityCheckTimer = nil
    }

    private func checkForNewActivity() {
        guard eveningState == .prompted,
              !isRecompilingEvening,
              let briefing = eveningBriefing else { return }

        let currentMetrics = gatherMetrics()

        // If any metric increased since compilation, recompile
        if currentMetrics.notesTakenCount > briefing.notesTakenCount
            || currentMetrics.outcomesCompletedCount > briefing.outcomesCompletedCount
            || currentMetrics.meetingCount > briefing.meetingCount
            || currentMetrics.emailsProcessedCount > briefing.emailsProcessedCount {
            recompileEveningBriefing()
        }
    }

    private func recompileEveningBriefing() {
        guard !isRecompilingEvening else { return }
        isRecompilingEvening = true
        logger.info("New activity detected — recompiling evening briefing")

        Task {
            do {
                let newBriefing = try await buildEveningBriefing()

                // Swap: delete old, set new
                if let old = eveningBriefing {
                    context?.delete(old)
                    try? context?.save()
                }
                eveningBriefing = newBriefing
            } catch {
                logger.error("Evening briefing recompilation failed: \(error.localizedDescription)")
            }
            isRecompilingEvening = false
        }
    }

    // MARK: - Day Rollover

    private func checkDayRollover() {
        let todayKey = Calendar.current.startOfDay(for: .now)
        let lastDateStr = UserDefaults.standard.string(forKey: "lastBriefingDate") ?? ""
        let lastDate = ISO8601DateFormatter().date(from: lastDateStr)

        if let lastDate, Calendar.current.isDate(lastDate, inSameDayAs: todayKey) {
            return  // Same day
        }

        // New day — reset evening state and check first open
        eveningState = .idle
        showEveningPrompt = false
        showEveningBriefing = false
        eveningBriefing = nil
        scheduleEveningCheck()

        Task {
            await checkFirstOpenOfDay()
        }
    }

    private func recheckEveningState() {
        if eveningState == .postponed {
            beginEveningCheck()
        }
    }

    // MARK: - Evening Timer Scheduling

    private func scheduleEveningCheck() {
        eveningTimer?.invalidate()

        let hour = UserDefaults.standard.integer(forKey: "briefingEveningHour")
        let minute = UserDefaults.standard.integer(forKey: "briefingEveningMinute")
        let targetHour = hour > 0 ? hour : 17
        let targetMinute = minute

        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = targetHour
        components.minute = targetMinute
        components.second = 0

        guard let targetDate = Calendar.current.date(from: components) else { return }

        if targetDate <= now {
            // Already past evening time today — check if we should prompt now
            let lastEvStr = UserDefaults.standard.string(forKey: "lastEveningBriefingDate") ?? ""
            let lastEvDate = ISO8601DateFormatter().date(from: lastEvStr)
            let todayKey = Calendar.current.startOfDay(for: now)

            if let lastEvDate, Calendar.current.isDate(lastEvDate, inSameDayAs: todayKey) {
                return  // Already done today
            }

            // Haven't done evening yet — prompt now
            beginEveningCheck()
            return
        }

        let interval = targetDate.timeIntervalSince(now)
        eveningTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.beginEveningCheck()
            }
        }
        logger.info("Evening check scheduled in \(Int(interval / 60)) minutes")
    }

    // MARK: - Auto Meeting Note Templates

    /// Check for recently ended meetings and create note templates.
    /// Called from the 5-minute day-rollover timer.
    private func checkRecentlyEndedMeetings() {
        let enabled = UserDefaults.standard.object(forKey: "autoMeetingNoteTemplates") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "autoMeetingNoteTemplates")
        guard enabled else { return }

        let now = Date()
        let fiveMinAgo = Calendar.current.date(byAdding: .minute, value: -5, to: now)!

        guard let allEvidence = try? evidenceRepo.fetchAll() else { return }

        // Find calendar events that ended in the last 5 minutes
        let recentlyEnded = allEvidence.filter { item in
            guard item.source == .calendar else { return false }
            let endTime = item.endedAt ?? item.occurredAt.addingTimeInterval(3600)
            return endTime >= fiveMinAgo && endTime <= now && !item.linkedPeople.isEmpty
        }

        for event in recentlyEnded {
            let attendees = event.linkedPeople.filter { !$0.isMe }
            guard !attendees.isEmpty else { continue }

            // Check if a note already exists for any attendee created after event start
            let hasExistingNote: Bool
            if let allNotes = try? notesRepo.fetchAll() {
                hasExistingNote = allNotes.contains { note in
                    note.createdAt >= event.occurredAt
                    && note.linkedPeople.contains(where: { person in
                        attendees.contains(where: { $0.id == person.id })
                    })
                }
            } else {
                hasExistingNote = false
            }
            guard !hasExistingNote else { continue }

            // Check for duplicate template by content prefix
            let titlePrefix = "Meeting: \(event.title)"
            if let allNotes = try? notesRepo.fetchAll() {
                let hasDuplicate = allNotes.contains { $0.content.hasPrefix(titlePrefix) }
                guard !hasDuplicate else { continue }
            }

            // Create the template note
            createMeetingNoteTemplate(event: event, attendees: attendees)
        }
    }

    /// Create a pre-filled note template for a recently ended meeting.
    private func createMeetingNoteTemplate(event: SamEvidenceItem, attendees: [SamPerson]) {
        let dateStr = event.occurredAt.formatted(date: .abbreviated, time: .shortened)
        let names = attendees.map { $0.displayNameCache ?? $0.displayName }.joined(separator: ", ")

        let templateContent = """
            Meeting: \(event.title)
            Date: \(dateStr)
            Attendees: \(names)

            Discussion:


            Action Items:


            Follow-Up:

            """

        let attendeeIDs = attendees.map(\.id)
        do {
            let note = try notesRepo.create(
                content: templateContent,
                sourceType: .typed,
                linkedPeopleIDs: attendeeIDs
            )

            // Create a follow-up outcome so it appears in the Action Queue
            let primary = attendees.first!
            let outcome = SamOutcome(
                title: "Complete meeting notes for \(event.title)",
                rationale: "A note template was created. Fill in discussion points and action items.",
                outcomeKind: .followUp,
                deadlineDate: Calendar.current.date(byAdding: .hour, value: 24, to: .now),
                sourceInsightSummary: "Auto-generated meeting note template",
                suggestedNextStep: "Open the note and capture key takeaways",
                linkedPerson: primary
            )
            try outcomeRepo.upsert(outcome: outcome)

            logger.info("Created meeting note template for '\(event.title)' with \(attendees.count) attendees")
        } catch {
            logger.error("Failed to create meeting note template: \(error.localizedDescription)")
        }
    }

    // MARK: - Multi-Step Sequence Trigger Evaluation

    /// Evaluate pending sequence triggers and activate or dismiss steps.
    /// Called from the 5-minute timer alongside meeting/call checks.
    private func checkSequenceTriggers() {
        do {
            let awaiting = try outcomeRepo.fetchAwaitingTrigger()
            guard !awaiting.isEmpty else { return }

            let now = Date()

            for step in awaiting {
                guard let previousStep = try outcomeRepo.fetchPreviousStep(for: step) else { continue }

                // Previous step must be completed
                guard previousStep.status == .completed, let completedAt = previousStep.completedAt else { continue }

                // Check if enough time has passed
                let triggerDate = completedAt.addingTimeInterval(Double(step.triggerAfterDays) * 86400)
                guard triggerDate <= now else { continue }

                // Evaluate trigger condition
                let condition = step.triggerCondition ?? .always

                switch condition {
                case .always:
                    // Activate unconditionally
                    step.isAwaitingTrigger = false
                    try context?.save()
                    logger.info("Sequence step activated (always): \(step.title)")

                case .noResponse:
                    // Check if the person has communicated since the previous step completed
                    guard let personID = step.linkedPerson?.id ?? previousStep.linkedPerson?.id else {
                        step.isAwaitingTrigger = false
                        try context?.save()
                        continue
                    }

                    let hasResponse = evidenceRepo.hasRecentCommunication(
                        fromPersonID: personID,
                        since: completedAt
                    )

                    if hasResponse {
                        // Person responded — dismiss this step and all remaining
                        if let seqID = step.sequenceID {
                            try outcomeRepo.dismissRemainingSteps(sequenceID: seqID, fromIndex: step.sequenceIndex)
                        }
                        logger.info("Sequence step auto-dismissed (response received): \(step.title)")
                    } else {
                        // No response — activate the step
                        step.isAwaitingTrigger = false
                        try context?.save()
                        logger.info("Sequence step activated (no response): \(step.title)")
                    }
                }
            }
        } catch {
            logger.error("checkSequenceTriggers failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Post-Call Note Prompt (Phase O)

    /// Check for phone calls or FaceTime calls that ended recently and prompt
    /// the user to capture a post-call note. Follows the same pattern as
    /// checkRecentlyEndedMeetings() — runs every 5 minutes from the timer.
    private func checkRecentlyEndedCalls() {
        let commsCallsEnabled = UserDefaults.standard.bool(forKey: "commsCallsEnabled")
        guard commsCallsEnabled else { return }

        let now = Date()
        // 10-minute window (wider than meetings since call import may lag behind)
        let tenMinAgo = Calendar.current.date(byAdding: .minute, value: -10, to: now)!

        guard let allEvidence = try? evidenceRepo.fetchAll() else { return }

        // Find phone/FaceTime calls from known contacts that ended recently
        let recentCalls = allEvidence.filter { item in
            guard item.source == .phoneCall || item.source == .faceTime else { return false }
            // Call evidence uses occurredAt for the call time; duration is in the snippet
            let callTime = item.occurredAt
            return callTime >= tenMinAgo && callTime <= now
                && !item.linkedPeople.isEmpty
                && !promptedCallIDs.contains(item.id)
        }

        guard !recentCalls.isEmpty else { return }

        for call in recentCalls {
            let calledPeople = call.linkedPeople.filter { !$0.isMe }
            guard let primary = calledPeople.first else { continue }

            // Check if a note was already created for this person since the call
            let hasExistingNote: Bool
            if let allNotes = try? notesRepo.fetchAll() {
                hasExistingNote = allNotes.contains { note in
                    note.createdAt >= call.occurredAt
                    && note.linkedPeople.contains(where: { $0.id == primary.id })
                }
            } else {
                hasExistingNote = false
            }

            guard !hasExistingNote else {
                promptedCallIDs.insert(call.id)
                continue
            }

            // Mark as prompted before opening window
            promptedCallIDs.insert(call.id)

            // Open a quick note window for post-call capture
            let personName = primary.displayNameCache ?? primary.displayName
            let callType = call.source == .faceTime ? "FaceTime" : "call"
            let payload = QuickNotePayload(
                outcomeID: UUID(), // No associated outcome — standalone prompt
                personID: primary.id,
                personName: personName,
                contextTitle: "Post-\(callType) note: \(personName)",
                prefillText: ""
            )

            NotificationCenter.default.post(
                name: .samOpenQuickNote,
                object: nil,
                userInfo: ["payload": payload]
            )

            logger.info("Prompted post-call note for \(personName, privacy: .public) (\(callType))")

            // Only prompt for one call at a time to avoid window spam
            break
        }
    }

    // MARK: - Load Existing Briefings

    private func loadTodaysBriefings() {
        guard let context else { return }
        let todayKey = Calendar.current.startOfDay(for: .now)

        do {
            var descriptor = FetchDescriptor<SamDailyBriefing>(
                predicate: #Predicate { $0.dateKey == todayKey }
            )
            descriptor.fetchLimit = 10

            let briefings = try context.fetch(descriptor)
            morningBriefing = briefings.first { $0.briefingTypeRawValue == "morning" }
            eveningBriefing = briefings.first { $0.briefingTypeRawValue == "evening" }
        } catch {
            logger.error("Failed to load today's briefings: \(error.localizedDescription)")
        }
    }

    // MARK: - Mark Viewed

    func markMorningViewed() {
        morningBriefing?.wasViewed = true
        morningBriefing?.viewedAt = .now
        try? context?.save()
        showMorningBriefing = false
    }

    func markEveningViewed() {
        eveningBriefing?.wasViewed = true
        eveningBriefing?.viewedAt = .now
        try? context?.save()
        showEveningBriefing = false
        eveningState = .completed
    }

    // MARK: - Data Gathering

    private func gatherCalendarItems() -> [BriefingCalendarItem] {
        let now = Date()
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now)!

        guard let allEvidence = try? evidenceRepo.fetchAll() else { return [] }

        let todayEvents = allEvidence.filter {
            $0.source == .calendar && $0.occurredAt >= now && $0.occurredAt <= endOfDay
        }.sorted { $0.occurredAt < $1.occurredAt }

        return todayEvents.map { event in
            let attendees = event.linkedPeople.filter { !$0.isMe }
            let names = attendees.map { $0.displayNameCache ?? $0.displayName }
            let roles = attendees.compactMap { $0.roleBadges.first }
            let healthStatuses = attendees.map { person -> String in
                let health = meetingPrep.computeHealth(for: person)
                if let days = health.daysSinceLastInteraction {
                    if days > 60 { return "cold" }
                    if days > 30 { return "at_risk" }
                }
                return "healthy"
            }

            return BriefingCalendarItem(
                eventTitle: event.title,
                startsAt: event.occurredAt,
                endsAt: event.endedAt,
                attendeeNames: names,
                attendeeRoles: roles,
                healthStatus: healthStatuses.first { $0 != "healthy" } ?? "healthy"
            )
        }
    }

    private func gatherPriorityActions() -> [BriefingAction] {
        var actions: [BriefingAction] = []

        // From active outcomes
        if let outcomes = try? outcomeRepo.fetchActive() {
            for outcome in outcomes.prefix(5) {
                let person = outcome.linkedPerson
                actions.append(BriefingAction(
                    title: outcome.title,
                    rationale: outcome.rationale,
                    personName: person?.displayNameCache ?? person?.displayName,
                    personID: person?.id,
                    urgency: outcome.deadlineDate.map { deadline in
                        let hours = deadline.timeIntervalSince(.now) / 3600
                        if hours <= 0 { return "immediate" }
                        if hours <= 24 { return "soon" }
                        return "standard"
                    } ?? "standard",
                    sourceKind: "outcome"
                ))
            }
        }

        return actions
    }

    private func gatherFollowUps() -> [BriefingFollowUp] {
        guard let people = try? peopleRepo.fetchAll() else { return [] }

        let activePeople = people.filter { !$0.isMe && !$0.isArchived }
        var followUps: [BriefingFollowUp] = []

        for person in activePeople {
            let health = meetingPrep.computeHealth(for: person)
            guard let days = health.daysSinceLastInteraction else { continue }

            // Use role-based thresholds
            let threshold: Int
            switch person.roleBadges.first?.lowercased() {
            case "client":          threshold = 45
            case "applicant":       threshold = 14
            case "lead":            threshold = 30
            case "agent":           threshold = 21
            case "external agent":  threshold = 60
            case "vendor":          threshold = 90
            default:                threshold = 60
            }

            guard days >= threshold else { continue }

            let name = person.displayNameCache ?? person.displayName
            let role = person.roleBadges.first ?? "Contact"

            followUps.append(BriefingFollowUp(
                personName: name,
                personID: person.id,
                reason: "\(role) — no interaction in \(days) days",
                daysSinceInteraction: days,
                suggestedAction: "Send a brief check-in message"
            ))
        }

        return followUps.sorted { $0.daysSinceInteraction > $1.daysSinceInteraction }.prefix(5).map { $0 }
    }

    private func gatherLifeEvents() -> [BriefingLifeEvent] {
        guard let allNotes = try? notesRepo.fetchAll() else { return [] }

        var events: [BriefingLifeEvent] = []
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now)!

        for note in allNotes where note.updatedAt >= thirtyDaysAgo {
            for lifeEvent in note.lifeEvents where lifeEvent.status == .pending {
                events.append(BriefingLifeEvent(
                    personName: lifeEvent.personName,
                    eventType: lifeEvent.eventType,
                    eventDescription: lifeEvent.eventDescription,
                    outreachSuggestion: lifeEvent.outreachSuggestion
                ))
            }
        }

        return Array(events.prefix(5))
    }

    private func gatherTomorrowPreview() -> [BriefingCalendarItem] {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        let startOfTomorrow = Calendar.current.startOfDay(for: tomorrow)
        let endOfTomorrow = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: tomorrow)!

        guard let allEvidence = try? evidenceRepo.fetchAll() else { return [] }

        let tomorrowEvents = allEvidence.filter {
            $0.source == .calendar && $0.occurredAt >= startOfTomorrow && $0.occurredAt <= endOfTomorrow
        }.sorted { $0.occurredAt < $1.occurredAt }

        return tomorrowEvents.prefix(5).map { event in
            let names = event.linkedPeople.filter { !$0.isMe }.map { $0.displayNameCache ?? $0.displayName }
            return BriefingCalendarItem(
                eventTitle: event.title,
                startsAt: event.occurredAt,
                endsAt: event.endedAt,
                attendeeNames: names
            )
        }
    }

    private func gatherWeeklyPriorities() -> [BriefingAction] {
        var priorities: [BriefingAction] = []

        guard let allPeople = try? peopleRepo.fetchAll() else { return priorities }
        let activePeople = allPeople.filter { !$0.isMe && !$0.isArchived }

        // 1. Pipeline stuck people (Lead >30d, Applicant >14d)
        for person in activePeople {
            let role = person.roleBadges.first?.lowercased()
            let health = meetingPrep.computeHealth(for: person)
            guard let days = health.daysSinceLastInteraction else { continue }

            let isStuck: Bool
            switch role {
            case "lead":      isStuck = days > 30
            case "applicant": isStuck = days > 14
            default:          isStuck = false
            }

            guard isStuck else { continue }
            let name = person.displayNameCache ?? person.displayName
            priorities.append(BriefingAction(
                title: "Re-engage \(name)",
                rationale: "\(person.roleBadges.first ?? "Contact") — \(days) days since last interaction",
                personName: name,
                personID: person.id,
                urgency: days > 30 ? "immediate" : "soon",
                sourceKind: "pipeline_stuck"
            ))
        }

        // 2. Health-overdue contacts (by role thresholds)
        for person in activePeople where priorities.count < 8 {
            let role = person.roleBadges.first?.lowercased()
            let health = meetingPrep.computeHealth(for: person)
            guard let days = health.daysSinceLastInteraction else { continue }

            let threshold: Int
            switch role {
            case "client":          threshold = 45
            case "applicant":       threshold = 14
            case "lead":            threshold = 30
            case "agent":           threshold = 21
            case "external agent":  threshold = 60
            case "vendor":          threshold = 90
            default:                threshold = 60
            }

            guard days >= threshold else { continue }
            let name = person.displayNameCache ?? person.displayName
            // Avoid duplicates from pipeline stuck
            guard !priorities.contains(where: { $0.personID == person.id }) else { continue }
            priorities.append(BriefingAction(
                title: "Check in with \(name)",
                rationale: "\(person.roleBadges.first ?? "Contact") — overdue by \(days - threshold) days",
                personName: name,
                personID: person.id,
                urgency: "soon",
                sourceKind: "relationship_health"
            ))
        }

        // 3. This week's meetings (high-value attendees)
        let endOfWeek = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: .now))!
        if let allEvidence = try? evidenceRepo.fetchAll() {
            let weekMeetings = allEvidence.filter {
                $0.source == .calendar && $0.occurredAt >= .now && $0.occurredAt <= endOfWeek
            }
            let clientMeetings = weekMeetings.filter { event in
                event.linkedPeople.contains { person in
                    person.roleBadges.contains(where: { ["Client", "Applicant"].contains($0) })
                }
            }
            for event in clientMeetings.prefix(3) where priorities.count < 8 {
                let names = event.linkedPeople.filter { !$0.isMe }.map { $0.displayNameCache ?? $0.displayName }
                priorities.append(BriefingAction(
                    title: "Prepare for \(event.title)",
                    rationale: "\(event.occurredAt.formatted(date: .abbreviated, time: .shortened)) — \(names.joined(separator: ", "))",
                    urgency: "standard",
                    sourceKind: "upcoming_meeting"
                ))
            }
        }

        // 4. Pending outcomes nearing deadline
        if let activeOutcomes = try? outcomeRepo.fetchActive() {
            let weekEnd = endOfWeek
            let nearingDeadline = activeOutcomes.filter { outcome in
                guard let deadline = outcome.deadlineDate else { return false }
                return deadline <= weekEnd
            }
            for outcome in nearingDeadline.prefix(3) where priorities.count < 8 {
                let personName = outcome.linkedPerson?.displayNameCache ?? outcome.linkedPerson?.displayName
                priorities.append(BriefingAction(
                    title: outcome.title,
                    rationale: outcome.rationale,
                    personName: personName,
                    personID: outcome.linkedPerson?.id,
                    urgency: outcome.deadlineDate.map { $0 <= .now ? "immediate" : "soon" } ?? "standard",
                    sourceKind: "outcome_deadline"
                ))
            }
        }

        // 5. Life events requiring outreach
        if let allNotes = try? notesRepo.fetchAll() {
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            for note in allNotes where note.updatedAt >= thirtyDaysAgo && priorities.count < 8 {
                for event in note.lifeEvents where event.status == .pending {
                    priorities.append(BriefingAction(
                        title: "Reach out: \(event.personName) — \(event.eventType)",
                        rationale: event.outreachSuggestion ?? event.eventDescription,
                        personName: event.personName,
                        urgency: "standard",
                        sourceKind: "life_event"
                    ))
                }
            }
        }

        // Return top 5 sorted by urgency
        let urgencyOrder = ["immediate": 0, "soon": 1, "standard": 2, "low": 3]
        return Array(priorities.sorted { urgencyOrder[$0.urgency, default: 9] < urgencyOrder[$1.urgency, default: 9] }.prefix(5))
    }

    private func gatherAccomplishments() -> [BriefingAccomplishment] {
        var accomplishments: [BriefingAccomplishment] = []
        let startOfToday = Calendar.current.startOfDay(for: .now)

        // Completed outcomes today
        if let completed = try? outcomeRepo.fetchCompletedToday() {
            for outcome in completed {
                let personName = outcome.linkedPerson?.displayNameCache ?? outcome.linkedPerson?.displayName
                accomplishments.append(BriefingAccomplishment(
                    title: outcome.title,
                    category: "outcome",
                    personName: personName
                ))
            }
        }

        // Notes taken today
        if let notes = try? notesRepo.fetchAll() {
            let todayNotes = notes.filter { $0.createdAt >= startOfToday }
            if !todayNotes.isEmpty {
                accomplishments.append(BriefingAccomplishment(
                    title: "Captured \(todayNotes.count) note\(todayNotes.count == 1 ? "" : "s")",
                    category: "note"
                ))
            }
        }

        // Meetings attended today
        if let evidence = try? evidenceRepo.fetchAll() {
            let todayMeetings = evidence.filter {
                $0.source == .calendar && $0.occurredAt >= startOfToday && $0.occurredAt <= .now
            }
            if !todayMeetings.isEmpty {
                accomplishments.append(BriefingAccomplishment(
                    title: "Attended \(todayMeetings.count) meeting\(todayMeetings.count == 1 ? "" : "s")",
                    category: "meeting"
                ))
            }
        }

        return accomplishments
    }

    private func gatherStreakUpdates() -> [BriefingStreakUpdate] {
        // Count consecutive days with notes
        var streaks: [BriefingStreakUpdate] = []
        guard let allNotes = try? notesRepo.fetchAll() else { return streaks }

        var noteStreak = 0
        var day = Calendar.current.startOfDay(for: .now)
        while true {
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
            let hasNote = allNotes.contains { note in
                note.createdAt >= day && note.createdAt < nextDay
            }
            if hasNote {
                noteStreak += 1
                day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
            } else {
                break
            }
        }

        if noteStreak > 1 {
            streaks.append(BriefingStreakUpdate(
                streakName: "Daily notes",
                currentCount: noteStreak,
                isNewRecord: false,
                message: "\(noteStreak) day note-taking streak"
            ))
        }

        return streaks
    }

    private func gatherMetrics() -> BriefingMetrics {
        let startOfToday = Calendar.current.startOfDay(for: .now)

        let meetingCount: Int
        let notesCount: Int
        let outcomesCompleted: Int
        let outcomesDismissed: Int

        if let evidence = try? evidenceRepo.fetchAll() {
            meetingCount = evidence.filter {
                $0.source == .calendar && $0.occurredAt >= startOfToday && $0.occurredAt <= .now
            }.count
        } else {
            meetingCount = 0
        }

        if let notes = try? notesRepo.fetchAll() {
            notesCount = notes.filter { $0.createdAt >= startOfToday }.count
        } else {
            notesCount = 0
        }

        if let completed = try? outcomeRepo.fetchCompletedToday() {
            outcomesCompleted = completed.filter { $0.status == .completed }.count
            outcomesDismissed = completed.filter { $0.status == .dismissed }.count
        } else {
            outcomesCompleted = 0
            outcomesDismissed = 0
        }

        return BriefingMetrics(
            meetingCount: meetingCount,
            notesTakenCount: notesCount,
            outcomesCompletedCount: outcomesCompleted,
            outcomesDismissedCount: outcomesDismissed
        )
    }
}
