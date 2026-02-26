//
//  TimeAllocationSection.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase Q: Time Tracking & Categorization
//
//  Shows a percentage breakdown of time allocation in the Review & Analytics
//  group of the Awareness dashboard. Uses @Query on TimeEntry, filtered to
//  the last 7 days.
//

import SwiftUI
import SwiftData

struct TimeAllocationSection: View {

    @Query private var allEntries: [TimeEntry]

    private var thisWeekEntries: [TimeEntry] {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        return allEntries.filter { $0.startedAt >= sevenDaysAgo }
    }

    private var breakdown: [(category: TimeCategory, minutes: Int, percent: Double)] {
        computeBreakdown(entries: thisWeekEntries)
    }

    private var totalMinutes: Int {
        thisWeekEntries.reduce(0) { $0 + $1.durationMinutes }
    }

    private var totalHours: String {
        let hours = Double(totalMinutes) / 60.0
        return hours.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fh", hours)
            : String(format: "%.1fh", hours)
    }

    private var trend: String? {
        computeTrend()
    }

    var body: some View {
        if !thisWeekEntries.isEmpty {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.blue)
                    Text("Time Allocation")
                        .font(.headline)
                    Text(totalHours)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue)
                        .clipShape(Capsule())
                    Spacer()
                    Text("Last 7 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                VStack(spacing: 8) {
                    // Stacked horizontal bar
                    stackedBar

                    // Legend rows — top 6, rest collapsed into Other
                    ForEach(displayRows, id: \.category) { row in
                        legendRow(row)
                    }

                    // Trend line
                    if let trend {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(trend)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }
                .padding()
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Stacked Bar

    private var stackedBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(breakdown, id: \.category) { item in
                    let width = max(2, geometry.size.width * item.percent / 100.0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.category.color)
                        .frame(width: width)
                }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Legend

    /// Show top 6 categories; collapse remaining into "Other" bucket.
    private var displayRows: [(category: TimeCategory, minutes: Int, percent: Double)] {
        if breakdown.count <= 6 {
            return breakdown
        }
        let top = Array(breakdown.prefix(6))
        let restMinutes = breakdown.dropFirst(6).reduce(0) { $0 + $1.minutes }
        let restPercent = breakdown.dropFirst(6).reduce(0.0) { $0 + $1.percent }
        return top + [(category: .other, minutes: restMinutes, percent: restPercent)]
    }

    private func legendRow(_ row: (category: TimeCategory, minutes: Int, percent: Double)) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(row.category.color)
                .frame(width: 8, height: 8)

            Text(row.category.rawValue)
                .font(.subheadline)

            // Mini bar
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                    .fill(row.category.color.opacity(0.3))
                    .frame(width: geometry.size.width * row.percent / 100.0)
            }
            .frame(height: 6)

            Text("\(Int(round(row.percent)))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            Text(formatHours(row.minutes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Computation

    private func computeBreakdown(entries: [TimeEntry]) -> [(category: TimeCategory, minutes: Int, percent: Double)] {
        guard !entries.isEmpty else { return [] }

        var byCategory: [TimeCategory: Int] = [:]
        for entry in entries {
            byCategory[entry.category, default: 0] += entry.durationMinutes
        }

        let total = Double(entries.reduce(0) { $0 + $1.durationMinutes })
        guard total > 0 else { return [] }

        return byCategory
            .map { (category: $0.key, minutes: $0.value, percent: Double($0.value) / total * 100.0) }
            .sorted { $0.minutes > $1.minutes }
    }

    private func computeTrend() -> String? {
        let cal = Calendar.current
        let now = Date.now
        guard let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now),
              let fourteenDaysAgo = cal.date(byAdding: .day, value: -14, to: now) else {
            return nil
        }

        let thisWeek = allEntries.filter { $0.startedAt >= sevenDaysAgo }
        let lastWeek = allEntries.filter { $0.startedAt >= fourteenDaysAgo && $0.startedAt < sevenDaysAgo }

        guard !lastWeek.isEmpty else { return nil }

        // Compare client meeting time specifically
        let thisClientMin = thisWeek.filter { $0.category == .clientMeeting }.reduce(0) { $0 + $1.durationMinutes }
        let lastClientMin = lastWeek.filter { $0.category == .clientMeeting }.reduce(0) { $0 + $1.durationMinutes }

        guard lastClientMin > 0 else {
            if thisClientMin > 0 {
                return "+\(formatHours(thisClientMin)) client time vs last week"
            }
            return nil
        }

        let change = Double(thisClientMin - lastClientMin) / Double(lastClientMin) * 100.0
        let percentChange = Int(abs(round(change)))

        if percentChange < 5 { return nil } // negligible change

        if change > 0 {
            return "+\(percentChange)% client time vs last week"
        } else {
            return "-\(percentChange)% client time vs last week"
        }
    }

    private func formatHours(_ minutes: Int) -> String {
        let hours = Double(minutes) / 60.0
        if hours < 1 {
            return "\(minutes)m"
        }
        return hours.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fh", hours)
            : String(format: "%.1fh", hours)
    }
}
