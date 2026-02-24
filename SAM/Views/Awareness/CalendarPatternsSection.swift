//
//  CalendarPatternsSection.swift
//  SAM
//
//  Created on February 24, 2026.
//
//  Analyzes calendar patterns and surfaces actionable observations.
//  Pure computation over calendar evidence — no LLM needed.
//

import SwiftUI
import SwiftData

struct CalendarPatternsSection: View {

    @Query private var allEvidence: [SamEvidenceItem]

    private var calendarEvents: [SamEvidenceItem] {
        allEvidence.filter { $0.source == .calendar }
    }

    private var insights: [CalendarInsight] {
        computeInsights()
    }

    var body: some View {
        if !insights.isEmpty {
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(.purple)
                    Text("Calendar Insights")
                        .font(.headline)
                    Text("\(insights.count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.purple)
                        .clipShape(Capsule())
                    Spacer()
                    Text("Last 30 days + next 7")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                VStack(spacing: 8) {
                    ForEach(insights) { insight in
                        InsightRow(insight: insight)
                    }
                }
                .padding()
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Insight Computation

    private func computeInsights() -> [CalendarInsight] {
        let cal = Calendar.current
        let now = Date()

        guard let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: now),
              let sevenDaysAhead = cal.date(byAdding: .day, value: 7, to: now) else {
            return []
        }

        let relevantEvents = calendarEvents.filter {
            $0.occurredAt >= thirtyDaysAgo && $0.occurredAt <= sevenDaysAhead
        }

        guard !relevantEvents.isEmpty else { return [] }

        var results: [CalendarInsight] = []

        // 1. Back-to-back meetings
        if let backToBack = detectBackToBack(events: relevantEvents, cal: cal, now: now) {
            results.append(backToBack)
        }

        // 2. Client meeting ratio
        if let clientRatio = computeClientRatio(events: relevantEvents) {
            results.append(clientRatio)
        }

        // 3. Meeting-free days this week
        if let meetingFree = detectMeetingFreeDays(events: relevantEvents, cal: cal, now: now) {
            results.append(meetingFree)
        }

        // 4. Busiest day of the week
        if let busiest = computeBusiestDay(events: relevantEvents, cal: cal, now: now, thirtyDaysAgo: thirtyDaysAgo) {
            results.append(busiest)
        }

        // 5. Upcoming meeting load comparison
        if let load = computeUpcomingLoad(events: relevantEvents, cal: cal, now: now) {
            results.append(load)
        }

        return results
    }

    // MARK: - Pattern: Back-to-Back Meetings

    /// Finds days with back-to-back meetings (one ends within 15 minutes of the next starting).
    /// Surfaces the worst upcoming day.
    private func detectBackToBack(events: [SamEvidenceItem], cal: Calendar, now: Date) -> CalendarInsight? {
        // Only look at future events (today or later)
        let startOfToday = cal.startOfDay(for: now)
        let futureEvents = events.filter { $0.occurredAt >= startOfToday }

        guard !futureEvents.isEmpty else { return nil }

        // Group by day
        let grouped = Dictionary(grouping: futureEvents) { event in
            cal.startOfDay(for: event.occurredAt)
        }

        var worstDay: Date?
        var worstCount = 0

        for (day, dayEvents) in grouped {
            let sorted = dayEvents.sorted { $0.occurredAt < $1.occurredAt }
            var backToBackCount = 0

            for i in 0..<(sorted.count - 1) {
                let currentEnd = sorted[i].endedAt ?? cal.date(byAdding: .hour, value: 1, to: sorted[i].occurredAt)!
                let nextStart = sorted[i + 1].occurredAt
                let gap = nextStart.timeIntervalSince(currentEnd)

                // Back-to-back: gap is 15 minutes or less (including overlap)
                if gap <= 15 * 60 {
                    backToBackCount += 1
                }
            }

            if backToBackCount > worstCount {
                worstCount = backToBackCount
                worstDay = day
            }
        }

        guard worstCount > 0, let day = worstDay else { return nil }

        let dayName = dayFormatter(day, cal: cal)
        let meetingCount = worstCount + 1 // back-to-back pairs + 1 = meetings involved

        return CalendarInsight(
            id: "back-to-back",
            icon: "arrow.right.arrow.left",
            color: .orange,
            message: "You have \(meetingCount) back-to-back meetings on \(dayName) with no prep time"
        )
    }

    // MARK: - Pattern: Client Meeting Ratio

    private func computeClientRatio(events: [SamEvidenceItem]) -> CalendarInsight? {
        guard !events.isEmpty else { return nil }

        let clientMeetings = events.filter { event in
            event.linkedPeople.contains { person in
                person.roleBadges.contains("Client")
            }
        }

        let count = clientMeetings.count
        guard count > 0 else { return nil }

        let total = events.count
        let percentage = Int(round(Double(count) / Double(total) * 100))

        return CalendarInsight(
            id: "client-ratio",
            icon: "person.2",
            color: .blue,
            message: "\(percentage)% of your meetings are with clients (\(count) of \(total))"
        )
    }

    // MARK: - Pattern: Meeting-Free Days This Week

    private func detectMeetingFreeDays(events: [SamEvidenceItem], cal: Calendar, now: Date) -> CalendarInsight? {
        // Find Monday of the current week
        guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let monday = weekInterval.start

        // Build weekday dates (Mon-Fri)
        var weekdays: [Date] = []
        for offset in 0..<5 {
            if let day = cal.date(byAdding: .day, value: offset, to: monday) {
                weekdays.append(day)
            }
        }

        // Determine which weekdays have meetings
        let eventDays = Set(events.map { cal.startOfDay(for: $0.occurredAt) })
        let freeDays = weekdays.filter { !eventDays.contains($0) }

        let dayNames = freeDays.map { shortDayName($0, cal: cal) }

        if freeDays.isEmpty {
            return CalendarInsight(
                id: "meeting-free",
                icon: "exclamationmark.triangle",
                color: .orange,
                message: "No meeting-free days this week"
            )
        } else {
            let dayList = dayNames.joined(separator: ", ")
            return CalendarInsight(
                id: "meeting-free",
                icon: "sun.max",
                color: .green,
                message: "You have \(freeDays.count) meeting-free day\(freeDays.count == 1 ? "" : "s") this week (\(dayList))"
            )
        }
    }

    // MARK: - Pattern: Busiest Day of Week

    private func computeBusiestDay(events: [SamEvidenceItem], cal: Calendar, now: Date, thirtyDaysAgo: Date) -> CalendarInsight? {
        // Only use past 30 days for historical pattern
        let pastEvents = events.filter { $0.occurredAt >= thirtyDaysAgo && $0.occurredAt <= now }
        guard !pastEvents.isEmpty else { return nil }

        // Count meetings per weekday (1=Sun, 2=Mon, ..., 7=Sat)
        var weekdayCounts: [Int: Int] = [:]
        for event in pastEvents {
            let weekday = cal.component(.weekday, from: event.occurredAt)
            weekdayCounts[weekday, default: 0] += 1
        }

        // Find the busiest weekday
        guard let (busiestWeekday, totalCount) = weekdayCounts.max(by: { $0.value < $1.value }),
              totalCount > 1 else { return nil }

        // Count how many of that weekday fell in the 30-day window
        var occurrences = 0
        var checkDate = thirtyDaysAgo
        while checkDate <= now {
            if cal.component(.weekday, from: checkDate) == busiestWeekday {
                occurrences += 1
            }
            checkDate = cal.date(byAdding: .day, value: 1, to: checkDate)!
        }

        guard occurrences > 0 else { return nil }

        let avg = Double(totalCount) / Double(occurrences)
        let avgFormatted = avg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", avg)
            : String(format: "%.1f", avg)
        let weekdayName = weekdayNames[busiestWeekday] ?? "Unknown"

        return CalendarInsight(
            id: "busiest-day",
            icon: "chart.bar",
            color: .purple,
            message: "\(weekdayName)s are your busiest day (avg \(avgFormatted) meeting\(avg == 1 ? "" : "s"))"
        )
    }

    // MARK: - Pattern: Upcoming Meeting Load

    private func computeUpcomingLoad(events: [SamEvidenceItem], cal: Calendar, now: Date) -> CalendarInsight? {
        guard let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now),
              let sevenDaysAhead = cal.date(byAdding: .day, value: 7, to: now) else {
            return nil
        }

        let lastWeekCount = events.filter { $0.occurredAt >= sevenDaysAgo && $0.occurredAt < now }.count
        let nextWeekCount = events.filter { $0.occurredAt >= now && $0.occurredAt <= sevenDaysAhead }.count

        // Skip if both are zero or no meaningful comparison
        guard lastWeekCount > 0 || nextWeekCount > 0 else { return nil }
        guard lastWeekCount != nextWeekCount else { return nil }

        if lastWeekCount == 0 {
            return CalendarInsight(
                id: "upcoming-load",
                icon: "arrow.up.right",
                color: .orange,
                message: "\(nextWeekCount) meeting\(nextWeekCount == 1 ? "" : "s") coming up in the next 7 days (none last week)"
            )
        }

        let change = Double(nextWeekCount - lastWeekCount) / Double(lastWeekCount) * 100
        let percentChange = Int(abs(round(change)))

        if nextWeekCount > lastWeekCount {
            return CalendarInsight(
                id: "upcoming-load",
                icon: "arrow.up.right",
                color: .orange,
                message: "Next week is \(percentChange)% busier than last week (\(nextWeekCount) vs \(lastWeekCount) meetings)"
            )
        } else {
            return CalendarInsight(
                id: "upcoming-load",
                icon: "arrow.down.right",
                color: .green,
                message: "Next week is \(percentChange)% lighter than last week (\(nextWeekCount) vs \(lastWeekCount) meetings)"
            )
        }
    }

    // MARK: - Formatting Helpers

    private func dayFormatter(_ date: Date, cal: Calendar) -> String {
        if cal.isDateInToday(date) {
            return "today"
        } else if cal.isDateInTomorrow(date) {
            return "tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE" // Full day name
            return formatter.string(from: date)
        }
    }

    private func shortDayName(_ date: Date, cal: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE" // Short day name (Mon, Tue, ...)
        return formatter.string(from: date)
    }

    private var weekdayNames: [Int: String] {
        [1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday",
         5: "Thursday", 6: "Friday", 7: "Saturday"]
    }
}

// MARK: - CalendarInsight Model

private struct CalendarInsight: Identifiable {
    let id: String
    let icon: String
    let color: Color
    let message: String
}

// MARK: - Insight Row

private struct InsightRow: View {

    let insight: CalendarInsight

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: insight.icon)
                .font(.subheadline)
                .foregroundStyle(insight.color)
                .frame(width: 24, alignment: .center)

            Text(insight.message)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
