//
//  OutcomeBundleGenerator.swift
//  SAM
//
//  Routes person-linked outreach candidates from OutcomeEngine into the
//  per-person OutcomeBundle. Also runs new scanners that don't exist in the
//  legacy SamOutcome pipeline (birthday, anniversary) and emits their results
//  directly as sub-items.
//
//  Single-context safe: only uses personID (UUID) when talking to the
//  bundle repository (see feedback_swiftdata_single_context.md).
//

import Foundation
import Contacts
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "OutcomeBundleGenerator")

@MainActor
final class OutcomeBundleGenerator {

    static let shared = OutcomeBundleGenerator()

    private let bundleRepo = OutcomeBundleRepository.shared
    private let contactsService = ContactsService.shared

    /// Debounced nudge: people whose evidence changed since the last flush.
    private var pendingNudgePersonIDs: Set<UUID> = []
    private var nudgeFlushTask: Task<Void, Never>?
    private let nudgeDebounceSeconds: UInt64 = 30

    private init() {}

    // MARK: - Evidence-driven Recompute

    /// Called by repositories when new evidence is linked to one or more
    /// people. Coalesces multiple calls into one engine pass after a short
    /// debounce so SMS bursts or backfill imports don't thrash the AI.
    nonisolated func nudgeForEvidence(personIDs: [UUID]) {
        guard !personIDs.isEmpty else { return }
        Task { @MainActor in
            self.pendingNudgePersonIDs.formUnion(personIDs)
            self.nudgeFlushTask?.cancel()
            self.nudgeFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: (self?.nudgeDebounceSeconds ?? 30) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.flushNudges()
            }
        }
    }

    private func flushNudges() async {
        let touched = pendingNudgePersonIDs
        pendingNudgePersonIDs.removeAll()
        guard !touched.isEmpty else { return }

        // Mark affected bundles' drafts stale so they regenerate on the
        // engine's next pass. We don't recompute sub-item content here —
        // the OutcomeEngine scanners own that.
        for personID in touched {
            if let bundle = try? bundleRepo.fetchActiveBundle(forPersonID: personID) {
                bundle.draftSignature = nil
            }
        }
        _ = try? bundleRepo.save()
        logger.info("Bundle nudge flushed for \(touched.count) people — requesting engine pass")
        OutcomeEngine.shared.startGeneration()
    }

    // MARK: - Kind Translation

    /// Legacy OutcomeKind → bundle sub-item kind for the seven outreach kinds
    /// that fold into bundles. Other OutcomeKinds (preparation, growth, etc.)
    /// stay as standalone SamOutcome and are not routed through this generator.
    private static let kindMap: [OutcomeKind: OutcomeSubItemKind] = [
        .outreach:                 .cadenceReconnect,
        .followUp:                 .openActionItem,
        .proposal:                 .proposalPrep,
        .commitment:               .openCommitment,
        .clientWithoutStewardship: .stewardshipArc,
        .roleFilling:              .recruitTouch
    ]

    /// True when the candidate outcome should be diverted into a per-person
    /// bundle (it has a person AND a translatable kind). Falsy candidates
    /// continue down the existing SamOutcome persistence path.
    static func shouldRouteToBundle(_ outcome: SamOutcome) -> Bool {
        guard outcome.linkedPerson != nil else { return false }
        return kindMap[outcome.outcomeKind] != nil
    }

    // MARK: - Routing

    /// Result of partitioning OutcomeEngine's candidate array.
    struct PartitionResult: Sendable {
        let bundled: Int           // count of candidates folded into bundles
        let bundlesTouched: Int    // distinct bundles updated
        let suppressed: Int        // candidates dropped by dismissal table
    }

    /// Walk candidate outcomes from OutcomeEngine, route the bundleable ones
    /// into per-person bundles, remove them from `candidates` in place, and
    /// return a summary. Non-bundleable candidates remain in `candidates` so
    /// the existing persistence path handles them.
    @discardableResult
    func routeCandidates(_ candidates: inout [SamOutcome]) async throws -> PartitionResult {
        // Pre-fetch suppression set so we don't hammer the DB per candidate.
        let suppressed = try bundleRepo.suppressedPairs()

        // Group bundleable candidates by personID, keeping the highest-priority
        // candidate per (personID, kind).
        struct Key: Hashable { let personID: UUID; let kind: OutcomeSubItemKind }
        var winners: [Key: SamOutcome] = [:]
        var bundleableIndexes: [Int] = []
        var droppedSuppressed = 0

        for (idx, outcome) in candidates.enumerated() {
            guard Self.shouldRouteToBundle(outcome) else { continue }
            guard let person = outcome.linkedPerson else { continue }
            guard let subKind = Self.kindMap[outcome.outcomeKind] else { continue }

            let personID = person.id
            if suppressed.contains(SuppressionKey(personID: personID, kindRawValue: subKind.rawValue)) {
                droppedSuppressed += 1
                bundleableIndexes.append(idx)  // still pull it out of candidates
                continue
            }

            let key = Key(personID: personID, kind: subKind)
            if let existing = winners[key], existing.priorityScore >= outcome.priorityScore {
                // keep existing winner
            } else {
                winners[key] = outcome
            }
            bundleableIndexes.append(idx)
        }

        // Strip routed candidates from the array (descending index removal).
        for idx in bundleableIndexes.sorted(by: >) {
            candidates.remove(at: idx)
        }

        // Group winners by person → ensure bundle → upsert sub-items.
        var byPerson: [UUID: [(OutcomeSubItemKind, SamOutcome)]] = [:]
        for (key, outcome) in winners {
            byPerson[key.personID, default: []].append((key.kind, outcome))
        }

        var bundlesTouched = 0
        var bundledCount = 0
        for (personID, items) in byPerson {
            do {
                let bundle = try bundleRepo.ensureBundle(forPersonID: personID)
                let keepKinds = Set(items.map { $0.0 })
                for (kind, outcome) in items {
                    try bundleRepo.upsertSubItem(
                        in: bundle,
                        kind: kind,
                        title: outcome.title,
                        rationale: outcome.rationale,
                        priorityScore: outcome.priorityScore,
                        dueDate: outcome.deadlineDate,
                        isMilestone: false
                    )
                    bundledCount += 1
                }
                // Drop stale open sub-items of *bundleable kinds* the scanners
                // didn't produce this cycle. Birthday/anniversary/lifeEvent are
                // added by their own scanners (see below) — don't strip those.
                let allBundleableScannerKinds: Set<OutcomeSubItemKind> = [
                    .cadenceReconnect, .openActionItem, .proposalPrep,
                    .openCommitment, .stewardshipArc, .recruitTouch
                ]
                let toDrop = allBundleableScannerKinds.subtracting(keepKinds)
                // Convert "kinds we DIDN'T emit" into a fresh keep-set by
                // taking the bundle's current open kinds minus toDrop.
                let currentOpen = Set(bundle.openSubItems.map(\.kind))
                let updatedKeep = currentOpen.subtracting(toDrop)
                try bundleRepo.removeStaleOpenSubItems(from: bundle, keepingKinds: updatedKeep)
                try bundleRepo.recomputePriority(bundle)
                bundle.lastTouchSummary = Self.lastTouchSummary(forPersonID: personID)
                bundlesTouched += 1
            } catch {
                logger.error("Failed to route bundle for person \(personID): \(error.localizedDescription)")
            }
            await Task.yield()
        }

        logger.info("Bundle routing: bundled \(bundledCount), touched \(bundlesTouched) bundles, suppressed \(droppedSuppressed)")
        return PartitionResult(bundled: bundledCount, bundlesTouched: bundlesTouched, suppressed: droppedSuppressed)
    }

    // MARK: - Birthday / Anniversary Scanner

    /// Scan the given people for upcoming birthdays/anniversaries in the next
    /// `windowDays` days. Emits a sub-item per match into the person's bundle.
    /// Reads dates from Apple Contacts via ContactsService.
    func scanLifeDates(people: [SamPerson], windowDays: Int = 14) async {
        guard await contactsService.authorizationStatus() == .authorized else { return }

        var bundlesTouched = 0
        let suppressed = (try? bundleRepo.suppressedPairs()) ?? []

        for person in people {
            guard let identifier = person.contactIdentifier else { continue }
            guard let dto = await contactsService.fetchContact(identifier: identifier, keys: .detail) else { continue }

            // Birthday
            if let birthdayItem = upcomingLifeDateSubItem(
                personID: person.id,
                personName: displayName(for: person),
                dateComponents: dto.birthday,
                anniversaryDateString: nil,
                kind: .birthday,
                windowDays: windowDays
            ), !suppressed.contains(SuppressionKey(personID: person.id, kindRawValue: OutcomeSubItemKind.birthday.rawValue)) {
                do {
                    let bundle = try bundleRepo.ensureBundle(forPersonID: person.id)
                    try bundleRepo.upsertSubItem(
                        in: bundle,
                        kind: .birthday,
                        title: birthdayItem.title,
                        rationale: birthdayItem.rationale,
                        priorityScore: birthdayItem.priority,
                        dueDate: birthdayItem.dueDate,
                        isMilestone: birthdayItem.isMilestone
                    )
                    try bundleRepo.recomputePriority(bundle)
                    bundle.lastTouchSummary = Self.lastTouchSummary(forPersonID: person.id)
                    bundlesTouched += 1
                } catch {
                    logger.error("Birthday upsert failed for \(person.id): \(error.localizedDescription)")
                }
            }

            // Anniversary (CNContact stores anniversaries in `dates` with label "anniversary")
            let anniversaryEntry = dto.dates.first { $0.label?.lowercased() == "anniversary" }
            if let anniv = anniversaryEntry,
               let item = upcomingLifeDateSubItem(
                   personID: person.id,
                   personName: displayName(for: person),
                   dateComponents: anniv.date,
                   anniversaryDateString: nil,
                   kind: .anniversary,
                   windowDays: windowDays
               ),
               !suppressed.contains(SuppressionKey(personID: person.id, kindRawValue: OutcomeSubItemKind.anniversary.rawValue)) {
                do {
                    let bundle = try bundleRepo.ensureBundle(forPersonID: person.id)
                    try bundleRepo.upsertSubItem(
                        in: bundle,
                        kind: .anniversary,
                        title: item.title,
                        rationale: item.rationale,
                        priorityScore: item.priority,
                        dueDate: item.dueDate,
                        isMilestone: item.isMilestone
                    )
                    try bundleRepo.recomputePriority(bundle)
                    bundle.lastTouchSummary = Self.lastTouchSummary(forPersonID: person.id)
                    bundlesTouched += 1
                } catch {
                    logger.error("Anniversary upsert failed for \(person.id): \(error.localizedDescription)")
                }
            }

            await Task.yield()
        }

        if bundlesTouched > 0 {
            logger.info("Life-date scan: touched \(bundlesTouched) bundles")
        }
    }

    // MARK: - Life Date Helpers

    private struct LifeDateMatch {
        let title: String
        let rationale: String
        let priority: Double
        let dueDate: Date
        let isMilestone: Bool
    }

    private func upcomingLifeDateSubItem(
        personID: UUID,
        personName: String,
        dateComponents: DateComponents?,
        anniversaryDateString: String?,
        kind: OutcomeSubItemKind,
        windowDays: Int
    ) -> LifeDateMatch? {
        let cal = Calendar.current
        let now = Date()
        guard let nextOccurrence = nextOccurrence(
            dateComponents: dateComponents,
            anniversaryDateString: anniversaryDateString,
            from: now,
            calendar: cal
        ) else { return nil }

        let daysAway = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: nextOccurrence.date)).day ?? 0
        guard daysAway >= 0, daysAway <= windowDays else { return nil }

        let upcomingAge = nextOccurrence.upcomingNumber

        let label = kind == .birthday ? "birthday" : "anniversary"
        let milestone: Bool = {
            guard let n = upcomingAge else { return false }
            if kind == .birthday {
                return [50, 60, 65, 70, 75, 80, 85, 90, 100].contains(n)
            } else {
                return [10, 20, 25, 30, 40, 50, 60, 75].contains(n)
            }
        }()

        let basePriority: Double = daysAway == 0 ? 0.85 : (daysAway <= 3 ? 0.7 : 0.5)
        let priority = min(1.0, basePriority + (milestone ? 0.1 : 0))

        let title: String
        let rationale: String
        if let n = upcomingAge {
            let nth = (milestone ? "\(n)th " : "")
            title = (daysAway == 0)
                ? "Wish \(personName) a happy \(nth)\(label)"
                : "\(personName)'s \(nth)\(label) in \(daysAway) day\(daysAway == 1 ? "" : "s")"
            rationale = (milestone ? "Milestone \(label). " : "") + "Turning \(n) on \(nextOccurrence.date.formatted(date: .abbreviated, time: .omitted))."
        } else {
            title = (daysAway == 0)
                ? "Wish \(personName) a happy \(label)"
                : "\(personName)'s \(label) in \(daysAway) day\(daysAway == 1 ? "" : "s")"
            rationale = "\(label.capitalized) on \(nextOccurrence.date.formatted(date: .abbreviated, time: .omitted))."
        }

        return LifeDateMatch(
            title: title,
            rationale: rationale,
            priority: priority,
            dueDate: nextOccurrence.date,
            isMilestone: milestone
        )
    }

    private struct NextOccurrence {
        let date: Date
        let upcomingNumber: Int?    // age on birthday, years on anniversary
    }

    private func nextOccurrence(
        dateComponents: DateComponents?,
        anniversaryDateString: String?,
        from now: Date,
        calendar: Calendar
    ) -> NextOccurrence? {
        // CNContact birthdays come as DateComponents (year optional).
        if let comps = dateComponents, let month = comps.month, let day = comps.day {
            return computeNextYearly(month: month, day: day, originalYear: comps.year, from: now, calendar: calendar)
        }
        // CNContact anniversaries come as "YYYY-MM-DD" via ContactDTO.
        if let raw = anniversaryDateString {
            let parts = raw.split(separator: "-").map(String.init)
            if parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
                return computeNextYearly(month: m, day: d, originalYear: y, from: now, calendar: calendar)
            }
            if parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]) {
                return computeNextYearly(month: m, day: d, originalYear: nil, from: now, calendar: calendar)
            }
        }
        return nil
    }

    private func computeNextYearly(month: Int, day: Int, originalYear: Int?, from now: Date, calendar: Calendar) -> NextOccurrence? {
        let thisYear = calendar.component(.year, from: now)
        var comps = DateComponents()
        comps.month = month
        comps.day = day
        comps.year = thisYear
        guard var candidate = calendar.date(from: comps) else { return nil }
        if calendar.startOfDay(for: candidate) < calendar.startOfDay(for: now) {
            comps.year = thisYear + 1
            guard let next = calendar.date(from: comps) else { return nil }
            candidate = next
        }
        let upcomingNumber: Int? = originalYear.map { calendar.component(.year, from: candidate) - $0 }
        return NextOccurrence(date: candidate, upcomingNumber: upcomingNumber)
    }

    private func displayName(for person: SamPerson) -> String {
        person.displayNameCache ?? person.displayName
    }

    // MARK: - Bundle Closure Sweep

    /// After all routing is done, close bundles that have no open sub-items.
    /// Walks active bundles and asks the repo to close-if-done.
    func sweepClosedBundles() {
        do {
            for bundle in try bundleRepo.fetchActive() {
                _ = try bundleRepo.closeBundleIfDone(bundle)
            }
        } catch {
            logger.error("Bundle closure sweep failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Combined Draft Generation

    /// Walk active bundles and regenerate `combinedDraftMessage` for any
    /// bundle whose open sub-item set has changed since the last draft.
    /// Outreach-style kinds only — pure pipeline / setup bundles don't
    /// generate a draft (Sarah doesn't message herself a proposal-prep todo).
    /// Runs serially on the main actor with a `Task.yield()` between calls.
    func refreshCombinedDrafts(limit: Int = 12) async {
        let bundles: [OutcomeBundle]
        do { bundles = try bundleRepo.fetchActive() } catch {
            logger.error("refreshCombinedDrafts: fetch failed: \(error.localizedDescription)")
            return
        }

        var refreshed = 0
        for bundle in bundles {
            guard refreshed < limit else { break }

            // Pick only sub-items whose kind makes sense to weave into an
            // outgoing message to the person. Skip pure-internal kinds.
            let candidateItems = bundle.openSubItems.filter { Self.isOutreachKind($0.kind) }
            guard !candidateItems.isEmpty else { continue }

            let signature = candidateItems
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .map { "\($0.kindRawValue):\($0.title)" }
                .joined(separator: "|")
            if bundle.draftSignature == signature, bundle.combinedDraftMessage != nil { continue }

            guard let personName = bundle.person?.displayNameCache ?? bundle.person?.displayName else { continue }
            let channel = bundle.person?.effectiveChannel ?? .iMessage
            let prompt = buildCombinedDraftPrompt(personName: personName, items: candidateItems, channel: channel)
            let systemInstruction = combinedDraftSystemInstruction(channel: channel)

            do {
                let draft = try await AIService.shared.generateNarrative(
                    prompt: prompt,
                    systemInstruction: systemInstruction
                )
                if !draft.isEmpty {
                    bundle.combinedDraftMessage = draft
                    bundle.draftRefreshedAt = .now
                    bundle.draftSignature = signature
                    bundle.suggestedChannelRawValue = channel.rawValue
                    refreshed += 1
                }
            } catch {
                logger.warning("Combined draft generation failed for bundle \(bundle.id): \(error.localizedDescription)")
            }

            await Task.yield()
        }

        if refreshed > 0 {
            do { try bundleRepo.save() } catch {
                logger.error("refreshCombinedDrafts: save failed: \(error.localizedDescription)")
            }
            logger.info("Combined drafts refreshed: \(refreshed)")
        }
    }

    /// True when the kind represents an outreach intent suitable for
    /// folding into a combined draft message (vs an internal-only task).
    private static func isOutreachKind(_ kind: OutcomeSubItemKind) -> Bool {
        switch kind {
        case .cadenceReconnect, .birthday, .anniversary, .annualReview,
             .lifeEventTouch, .openCommitment, .openActionItem, .recruitTouch:
            return true
        case .stewardshipArc, .stalledPipeline, .proposalPrep:
            return false
        }
    }

    private func buildCombinedDraftPrompt(
        personName: String,
        items: [OutcomeSubItem],
        channel: CommunicationChannel
    ) -> String {
        let topicLines = items.map { item -> String in
            "- \(item.kind.displayLabel): \(item.title). \(item.rationale)"
        }.joined(separator: "\n")

        let channelNote: String
        switch channel {
        case .iMessage, .whatsApp:
            channelNote = "a short, warm text message"
        case .email:
            channelNote = "a concise but warm email body"
        case .linkedIn:
            channelNote = "a brief, professional LinkedIn message"
        case .phone, .faceTime:
            channelNote = "a short script of talking points for a call"
        }

        return """
            Write \(channelNote) to \(personName) that naturally weaves the
            following topics into a single message. Do NOT list them as bullets
            — write a single, human-sounding message. Lead with the most
            personal item (birthday, anniversary, life event) if one exists.

            Topics to cover:
            \(topicLines)

            The sender's name is not needed — the message will be sent from
            their account. Keep the tone warm but professional. Reference only
            the topics above; do not invent context.
            """
    }

    private func combinedDraftSystemInstruction(channel: CommunicationChannel) -> String {
        switch channel {
        case .iMessage, .whatsApp:
            return """
                Write ONLY the message text — 3–5 sentences max. Casual but
                professional. No emojis. No signature. No "Hi [Name]," unless
                it fits naturally.
                """
        case .email:
            return """
                Write the email body only — no subject line. 2–3 short
                paragraphs. Open with a greeting, end with a simple closing.
                No signature block.
                """
        case .linkedIn:
            return """
                Write ONLY the message text — under 4 sentences. Professional,
                warm, no emojis. No signature. No connection-request phrasing.
                """
        case .phone, .faceTime:
            return """
                Write 3–5 short talking points, one per line. No bullet
                markers, just plain text lines.
                """
        }
    }

    // MARK: - Last-Touch Summary

    /// Build the short "last touch" line shown on the bundle card so the user
    /// can verify what SAM is actually following up on. Returns nil when there
    /// is no tracked communication evidence for this person — the view renders
    /// "No prior tracked contact — first exchange" in that case.
    static func lastTouchSummary(forPersonID personID: UUID) -> String? {
        guard let item = EvidenceRepository.shared.mostRecentCommunication(forPersonID: personID) else {
            return nil
        }
        let channel = channelDisplayName(for: item.source)
        let direction: String = {
            switch item.direction {
            case .inbound:  return "Inbound"
            case .outbound: return "You sent"
            case .bidirectional, .none: return ""
            }
        }()
        let age = relativeAge(from: item.occurredAt)
        let snippet = trimmedSnippet(item.snippet)

        let lead: String
        if direction.isEmpty {
            lead = "\(channel), \(age)"
        } else {
            lead = "\(direction) \(channel), \(age)"
        }
        if let snippet, !snippet.isEmpty {
            return "\(lead) — \(snippet)"
        }
        return lead
    }

    private static func channelDisplayName(for source: EvidenceSource) -> String {
        switch source {
        case .iMessage:           return "iMessage"
        case .mail, .sentMail:    return "email"
        case .phoneCall:          return "phone call"
        case .faceTime:           return "FaceTime"
        case .whatsApp:           return "WhatsApp"
        case .whatsAppCall:       return "WhatsApp call"
        case .linkedIn:           return "LinkedIn"
        case .facebook:           return "Facebook"
        case .substack:           return "Substack"
        case .zoomChat:           return "Zoom chat"
        case .calendar:           return "meeting"
        case .meetingTranscript:  return "meeting transcript"
        case .voiceCapture:       return "voice note"
        case .clipboardCapture:   return "clipboard capture"
        case .contacts, .note, .manual: return "note"
        }
    }

    private static func relativeAge(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 0 { return "just now" }
        let days = Int(seconds / 86_400)
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 14 { return "\(days)d ago" }
        if days < 60 { return "\(days)d ago" }
        let months = days / 30
        if months < 12 { return "\(months)mo ago" }
        let years = days / 365
        return "\(years)y ago"
    }

    private static func trimmedSnippet(_ raw: String, maxLength: Int = 80) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= maxLength { return cleaned }
        let idx = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
        return cleaned[..<idx].trimmingCharacters(in: .whitespaces) + "…"
    }
}
