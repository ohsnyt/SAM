//
//  CommitmentExtractionService.swift
//  SAM
//
//  Block 3: Converts `MeetingSummary.actionItems` into durable
//  `SamCommitment` records so follow-through can be tracked after the
//  transcript JSON is long gone. Keeps resolution logic (name → person,
//  fuzzy due date → Date) out of the session coordinator.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CommitmentExtractionService")

@MainActor
enum CommitmentExtractionService {

    /// Extract all action items from a meeting summary as SamCommitment rows
    /// attached to the given session. Returns number of new commitments created.
    ///
    /// Behavior:
    /// - Sarah-owned items → direction `.fromUser`, linkedPerson = best non-Sarah attendee
    /// - Attendee-owned items → direction `.toUser`, linkedPerson = matched attendee
    /// - Unassigned items → skipped (too ambiguous to coach on)
    /// - Duplicates (same session + same text) are skipped so re-summarization
    ///   doesn't double-count.
    @discardableResult
    static func extract(
        from summary: MeetingSummary,
        session: TranscriptSession,
        context: ModelContext,
        sarah: SamPerson?,
        recordedAt: Date
    ) -> Int {
        guard !summary.actionItems.isEmpty else { return 0 }

        let attendees = session.linkedPeople ?? []
        var created = 0

        for item in summary.actionItems {
            let trimmed = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Duplicate check: same transcript + same normalized text
            let needle = trimmed.lowercased()
            let existing = (try? context.fetch(FetchDescriptor<SamCommitment>()))?.first {
                $0.linkedTranscript?.id == session.id
                && $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == needle
            }
            if existing != nil { continue }

            // Direction + person resolution
            let resolution = resolveOwner(
                ownerHint: item.owner,
                sarah: sarah,
                attendees: attendees
            )
            guard let resolution else {
                logger.debug("Skipping unassigned commitment: \(trimmed)")
                continue
            }

            let (dueDate, dueHint) = parseDueDate(from: item.dueDate, anchor: recordedAt)

            let commitment = SamCommitment(
                text: trimmed,
                createdAt: recordedAt,
                dueDate: dueDate,
                dueHint: dueHint,
                direction: resolution.direction,
                source: .meetingTranscript,
                linkedPerson: resolution.person,
                linkedTranscript: session
            )
            context.insert(commitment)
            created += 1
        }

        if created > 0 {
            do {
                try context.save()
                logger.info("Extracted \(created) commitment(s) from session \(session.id.uuidString)")
            } catch {
                logger.error("Failed to save commitments: \(error.localizedDescription)")
            }
        }
        return created
    }

    // MARK: - Owner resolution

    private struct OwnerResolution {
        let direction: CommitmentDirection
        let person: SamPerson?
    }

    /// Decide whether the action item is Sarah's or an attendee's and link the
    /// other party. Returns nil when there's no usable signal.
    private static func resolveOwner(
        ownerHint: String?,
        sarah: SamPerson?,
        attendees: [SamPerson]
    ) -> OwnerResolution? {
        let nonSarahAttendees = attendees.filter { $0.id != sarah?.id }
        let raw = (ownerHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // No owner at all: can't coach, skip.
        if raw.isEmpty { return nil }

        if matchesSarah(raw, sarah: sarah) {
            // Sarah committed. The counterparty is the primary non-Sarah attendee.
            return OwnerResolution(
                direction: .fromUser,
                person: nonSarahAttendees.first
            )
        }

        // Try to match against attendees.
        if let match = bestAttendeeMatch(ownerHint: raw, attendees: nonSarahAttendees) {
            return OwnerResolution(direction: .toUser, person: match)
        }

        // Owner named but couldn't be resolved to a known person.
        // Record as attendee-direction with nil person so Sarah can still
        // see it on the session's commitment list. Downstream coaching
        // that requires a linked person will skip these.
        return OwnerResolution(direction: .toUser, person: nil)
    }

    private static func matchesSarah(_ raw: String, sarah: SamPerson?) -> Bool {
        let lower = raw.lowercased()
        let selfTokens: Set<String> = ["me", "i", "self", "you"]
        if selfTokens.contains(lower) { return true }
        guard let sarah else { return false }
        let name = (sarah.displayNameCache ?? sarah.displayName).lowercased()
        if name.isEmpty { return false }
        if lower == name { return true }
        // First-name match: "sarah" vs "Sarah Snyder"
        if let first = name.split(separator: " ").first.map(String.init),
           !first.isEmpty, lower == first {
            return true
        }
        return false
    }

    private static func bestAttendeeMatch(
        ownerHint: String,
        attendees: [SamPerson]
    ) -> SamPerson? {
        let lower = ownerHint.lowercased()
        // Exact displayName match first.
        if let exact = attendees.first(where: {
            ($0.displayNameCache ?? $0.displayName).lowercased() == lower
        }) {
            return exact
        }
        // First-name match.
        if let firstMatch = attendees.first(where: { person in
            let name = (person.displayNameCache ?? person.displayName).lowercased()
            return name.split(separator: " ").first.map(String.init) == lower
        }) {
            return firstMatch
        }
        // Substring match as a last resort (handles "Mike" in "Michael Ross").
        if let sub = attendees.first(where: { person in
            let name = (person.displayNameCache ?? person.displayName).lowercased()
            return name.contains(lower)
        }) {
            return sub
        }
        return nil
    }

    // MARK: - Due-date parsing

    /// Convert the LLM's fuzzy due-date hint into an absolute Date when the
    /// phrasing is unambiguous enough. Returns the original hint either way
    /// so UI can display it verbatim.
    static func parseDueDate(
        from hint: String?,
        anchor: Date
    ) -> (date: Date?, hint: String?) {
        guard let hint, !hint.isEmpty else { return (nil, nil) }
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (nil, nil) }

        let calendar = Calendar.current
        let lower = trimmed.lowercased()

        // "today"
        if lower == "today" {
            return (calendar.endOfDay(for: anchor), trimmed)
        }
        // "tomorrow"
        if lower == "tomorrow" {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: anchor) ?? anchor
            return (calendar.endOfDay(for: tomorrow), trimmed)
        }
        // "next week" / "end of week"
        if lower == "next week" || lower == "end of week" || lower == "end of the week" {
            let days = lower == "next week" ? 7 : daysUntilFriday(from: anchor, calendar: calendar)
            let target = calendar.date(byAdding: .day, value: days, to: anchor) ?? anchor
            return (calendar.endOfDay(for: target), trimmed)
        }
        // "end of month" / "end of the month"
        if lower == "end of month" || lower == "end of the month" {
            if let range = calendar.range(of: .day, in: .month, for: anchor),
               let firstOfMonth = calendar.date(
                   from: calendar.dateComponents([.year, .month], from: anchor)
               ),
               let target = calendar.date(byAdding: .day, value: range.count - 1, to: firstOfMonth) {
                return (calendar.endOfDay(for: target), trimmed)
            }
        }
        // Weekday name: "Friday", "Monday", …
        if let weekdayTarget = nextWeekday(named: lower, from: anchor, calendar: calendar) {
            return (calendar.endOfDay(for: weekdayTarget), trimmed)
        }
        // "in N day(s)" / "in N week(s)"
        if let delta = parseRelativeInterval(lower) {
            let target = calendar.date(byAdding: delta.component, value: delta.value, to: anchor) ?? anchor
            return (calendar.endOfDay(for: target), trimmed)
        }

        // Unknown phrasing: preserve the hint for display, no absolute date.
        return (nil, trimmed)
    }

    private static func daysUntilFriday(from anchor: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: anchor) // 1 = Sun … 7 = Sat
        let friday = 6
        let delta = friday - weekday
        return delta > 0 ? delta : (7 + delta)
    }

    private static func nextWeekday(named: String, from anchor: Date, calendar: Calendar) -> Date? {
        let map: [String: Int] = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7
        ]
        let key = named.hasPrefix("next ") ? String(named.dropFirst(5)) : named
        guard let targetWeekday = map[key] else { return nil }

        let anchorWeekday = calendar.component(.weekday, from: anchor)
        var delta = targetWeekday - anchorWeekday
        if delta <= 0 { delta += 7 }
        if named.hasPrefix("next ") && delta < 7 { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: anchor)
    }

    private static func parseRelativeInterval(_ lower: String) -> (component: Calendar.Component, value: Int)? {
        // "in 3 days" / "in 2 weeks"
        let tokens = lower.split(separator: " ").map(String.init)
        guard tokens.count >= 3, tokens[0] == "in", let value = Int(tokens[1]) else {
            return nil
        }
        let unit = tokens[2]
        if unit.hasPrefix("day") { return (.day, value) }
        if unit.hasPrefix("week") { return (.weekOfYear, value) }
        if unit.hasPrefix("month") { return (.month, value) }
        return nil
    }
}

// MARK: - Calendar helper

private extension Calendar {
    func endOfDay(for date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}
