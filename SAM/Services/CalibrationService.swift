//
//  CalibrationService.swift
//  SAM
//
//  Created on February 27, 2026.
//  Phase AB: Coaching Calibration — Feedback Ledger Service
//
//  Actor managing the CalibrationLedger: records signals from outcome interactions,
//  session feedback, and timing patterns. Produces a calibrationFragment() for AI injection.
//

import Foundation
import os.log

/// Manages the calibration ledger — an actor with UserDefaults persistence and a synchronous cache.
actor CalibrationService {

    static let shared = CalibrationService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CalibrationService")
    private let storageKey = "sam.calibrationLedger"

    /// Synchronous accessor for @MainActor callers. Populated on first load, updated on every save.
    nonisolated(unsafe) static var cachedLedger = CalibrationLedger()

    private var ledger: CalibrationLedger

    private init() {
        if let data = UserDefaults.standard.data(forKey: "sam.calibrationLedger"),
           let decoded = try? JSONDecoder().decode(CalibrationLedger.self, from: data) {
            self.ledger = decoded
            CalibrationService.cachedLedger = decoded
        } else {
            self.ledger = CalibrationLedger()
        }
    }

    // MARK: - Signal Recording

    /// Record that the user completed (acted on) an outcome.
    func recordCompletion(kind: String, responseMinutes: Double, hour: Int, dayOfWeek: Int) {
        var stat = ledger.kindStats[kind] ?? CalibrationLedger.KindStat()
        stat.actedOn += 1

        // Running average for response time
        if responseMinutes > 0 {
            let total = Double(stat.actedOn - 1) * stat.avgResponseMinutes + responseMinutes
            stat.avgResponseMinutes = total / Double(stat.actedOn)
        }

        ledger.kindStats[kind] = stat
        ledger.hourOfDayActs[hour, default: 0] += 1
        ledger.dayOfWeekActs[dayOfWeek, default: 0] += 1

        maybePrune()
        save()
    }

    /// Record that the user dismissed (skipped) an outcome.
    func recordDismissal(kind: String) {
        var stat = ledger.kindStats[kind] ?? CalibrationLedger.KindStat()
        stat.dismissed += 1
        ledger.kindStats[kind] = stat
        save()
    }

    /// Record a 1–5 star rating for an outcome kind.
    func recordRating(kind: String, rating: Int) {
        var stat = ledger.kindStats[kind] ?? CalibrationLedger.KindStat()
        stat.totalRatings += 1
        stat.ratingSum += max(1, min(5, rating))
        ledger.kindStats[kind] = stat
        save()
    }

    /// Record thumbs-up/thumbs-down for a coaching session category.
    func recordSessionFeedback(category: String, helpful: Bool) {
        var stat = ledger.sessionFeedback[category] ?? CalibrationLedger.SessionStat()
        if helpful {
            stat.helpful += 1
        } else {
            stat.unhelpful += 1
        }
        ledger.sessionFeedback[category] = stat
        recomputeStrategicWeights()
        save()
    }

    // MARK: - Muting

    /// Mute or unmute an outcome kind.
    func setMuted(kind: String, muted: Bool) {
        if muted {
            if !ledger.mutedKinds.contains(kind) {
                ledger.mutedKinds.append(kind)
            }
        } else {
            ledger.mutedKinds.removeAll { $0 == kind }
        }
        save()
    }

    // MARK: - AI Fragment

    /// Human-readable summary of learned preferences for injection into AI system instructions.
    func calibrationFragment() -> String {
        let l = ledger
        guard l.totalInteractions > 5 else { return "" }

        var lines: [String] = []
        lines.append("COACHING CALIBRATION (learned from user behavior):")

        // Preferred kinds (highest act rate with enough data)
        let preferredKinds = l.kindStats
            .filter { $0.value.actedOn + $0.value.dismissed >= 5 }
            .sorted { $0.value.actRate > $1.value.actRate }
            .prefix(3)

        if !preferredKinds.isEmpty {
            let kindList = preferredKinds.map { "\($0.key) (\(Int($0.value.actRate * 100))% act rate)" }.joined(separator: ", ")
            lines.append("• Most valued outcome types: \(kindList)")
        }

        // Dismissed kinds
        let dismissedKinds = l.kindStats
            .filter { $0.value.actedOn + $0.value.dismissed >= 5 && $0.value.actRate < 0.3 }
            .map(\.key)

        if !dismissedKinds.isEmpty {
            lines.append("• Often dismissed types (reduce frequency): \(dismissedKinds.joined(separator: ", "))")
        }

        // Muted kinds
        if !l.mutedKinds.isEmpty {
            lines.append("• Muted types (never suggest): \(l.mutedKinds.joined(separator: ", "))")
        }

        // Timing patterns
        if !l.peakHours.isEmpty {
            let hourLabels = l.peakHours.map { formatHour($0) }
            lines.append("• Most productive hours: \(hourLabels.joined(separator: ", "))")
        }

        if !l.peakDays.isEmpty {
            let dayLabels = l.peakDays.map { dayName($0) }
            lines.append("• Most active days: \(dayLabels.joined(separator: ", "))")
        }

        // Average response time
        let allResponseTimes = l.kindStats.values.filter { $0.avgResponseMinutes > 0 }
        if !allResponseTimes.isEmpty {
            let overallAvg = allResponseTimes.map(\.avgResponseMinutes).reduce(0, +) / Double(allResponseTimes.count)
            if overallAvg < 60 {
                lines.append("• Response style: fast responder (avg \(Int(overallAvg)) min)")
            } else if overallAvg > 240 {
                lines.append("• Response style: deliberate responder (avg \(Int(overallAvg / 60))h)")
            }
        }

        // Strategic category preferences
        let adjustedCategories = l.strategicCategoryWeights.filter { $0.value != 1.0 }
        if !adjustedCategories.isEmpty {
            let catList = adjustedCategories.map { "\($0.key): \(String(format: "%.1fx", $0.value))" }.joined(separator: ", ")
            lines.append("• Strategic focus weights: \(catList)")
        }

        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    // MARK: - Resets

    /// Reset stats for a single outcome kind.
    func resetKind(_ kind: String) {
        ledger.kindStats.removeValue(forKey: kind)
        save()
    }

    /// Reset all timing data.
    func resetTiming() {
        ledger.hourOfDayActs = [:]
        ledger.dayOfWeekActs = [:]
        save()
    }

    /// Reset a single strategic category weight.
    func resetStrategicCategory(_ category: String) {
        ledger.strategicCategoryWeights.removeValue(forKey: category)
        save()
    }

    /// Reset all calibration data.
    func resetAll() {
        ledger = CalibrationLedger()
        save()
        logger.info("Calibration ledger reset")
    }

    // MARK: - Ledger Access

    /// Get a snapshot of the current ledger.
    func currentLedger() -> CalibrationLedger {
        ledger
    }

    // MARK: - Strategic Weight Computation (Phase 3)

    /// Recompute strategic category weights from session feedback.
    /// Weights range from 0.5 to 2.0 based on helpful/unhelpful ratio.
    private func recomputeStrategicWeights() {
        let categories = ["pipeline", "time", "pattern"]
        for category in categories {
            guard let stat = ledger.sessionFeedback[category] else { continue }
            let total = stat.helpful + stat.unhelpful
            guard total > 0 else { continue }

            let ratio = Double(stat.helpful - stat.unhelpful) / Double(total) // -1 to +1
            // Map to 0.5–2.0 range: midpoint=1.0, +1→2.0, -1→0.5
            let weight = max(0.5, min(2.0, 1.0 + ratio * 0.75))
            ledger.strategicCategoryWeights[category] = weight
        }
    }

    // MARK: - Pruning (Phase 3)

    /// After 90 days since last update, halve all counters to let recent behavior dominate.
    private func maybePrune() {
        let daysSinceUpdate = Calendar.current.dateComponents([.day], from: ledger.updatedAt, to: .now).day ?? 0
        guard daysSinceUpdate >= 90 else { return }

        for (kind, var stat) in ledger.kindStats {
            stat.actedOn = stat.actedOn / 2
            stat.dismissed = stat.dismissed / 2
            stat.totalRatings = stat.totalRatings / 2
            stat.ratingSum = stat.ratingSum / 2
            ledger.kindStats[kind] = stat
        }

        for (hour, count) in ledger.hourOfDayActs {
            ledger.hourOfDayActs[hour] = count / 2
        }
        // Remove zero entries
        ledger.hourOfDayActs = ledger.hourOfDayActs.filter { $0.value > 0 }

        for (day, count) in ledger.dayOfWeekActs {
            ledger.dayOfWeekActs[day] = count / 2
        }
        ledger.dayOfWeekActs = ledger.dayOfWeekActs.filter { $0.value > 0 }

        for (cat, var stat) in ledger.sessionFeedback {
            stat.helpful = stat.helpful / 2
            stat.unhelpful = stat.unhelpful / 2
            ledger.sessionFeedback[cat] = stat
        }

        logger.info("Calibration ledger pruned (90+ days since last update)")
    }

    // MARK: - Persistence

    private func save() {
        ledger.updatedAt = .now
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        CalibrationService.cachedLedger = ledger
    }

    // MARK: - Formatting Helpers

    private func formatHour(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? "AM" : "PM"
        return "\(h) \(period)"
    }

    private func dayName(_ day: Int) -> String {
        switch day {
        case 1: return "Sunday"
        case 2: return "Monday"
        case 3: return "Tuesday"
        case 4: return "Wednesday"
        case 5: return "Thursday"
        case 6: return "Friday"
        case 7: return "Saturday"
        default: return "Day \(day)"
        }
    }
}
