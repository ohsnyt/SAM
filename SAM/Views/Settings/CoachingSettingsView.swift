//
//  CoachingSettingsView.swift
//  SAM
//
//  Created by Assistant on 2/22/26.
//  Phase N: Outcome-Focused Coaching Engine
//
//  Settings for AI backend, MLX model management, coaching style,
//  outcome generation frequency, and feedback preferences.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CoachingSettingsView")

// MARK: - Content (embeddable in DisclosureGroup)

struct CoachingSettingsContent: View {

    // MARK: - State

    @State private var coachingStyle: String = UserDefaults.standard.string(forKey: "coachingStyle") ?? "auto"
    @State private var advisor = CoachingAdvisor.shared
    @State private var showResetConfirmation = false
    @State private var reanalyzeStatus: String?
    @State private var isReanalyzing = false
    @State private var mutePickerSelection: String = ""

    // Content Suggestions (Phase W)
    @State private var contentSuggestionsEnabled: Bool = {
        UserDefaults.standard.object(forKey: "contentSuggestionsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "contentSuggestionsEnabled")
    }()

    // Direct Send
    @State private var directSendEnabled: Bool = UserDefaults.standard.bool(forKey: "directSendEnabled")

    // Autonomous Actions
    @State private var autoMeetingNoteTemplates: Bool = {
        UserDefaults.standard.object(forKey: "autoMeetingNoteTemplates") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "autoMeetingNoteTemplates")
    }()
    @State private var autoRoleTransitionOutcomes: Bool = {
        UserDefaults.standard.object(forKey: "autoRoleTransitionOutcomes") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "autoRoleTransitionOutcomes")
    }()
    @State private var weeklyDigestEnabled: Bool = {
        UserDefaults.standard.object(forKey: "weeklyDigestEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "weeklyDigestEnabled")
    }()
    @State private var meetingPrepNotifications: Bool = {
        UserDefaults.standard.object(forKey: "meetingPrepNotificationsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "meetingPrepNotificationsEnabled")
    }()

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ── Coaching Style ─────────────────────────
            coachingStyleSection

            Divider()

            // ── Autonomous Actions ────────────────────────
            autonomousActionsSection

            Divider()

            // ── Re-analyze ───────────────────────────────
            reanalyzeSection

            Divider()

            // ── Feedback ───────────────────────────────
            feedbackSection
        }
    }

    // MARK: - Coaching Style Section

    private var coachingStyleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coaching Style")
                .samFont(.headline)

            Text("How SAM frames encouragement when you complete outcomes.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            Picker("Style", selection: $coachingStyle) {
                Text("Let SAM Learn").tag("auto")
                Text("Direct").tag("direct")
                Text("Supportive").tag("supportive")
                Text("Achievement-Focused").tag("achievement")
                Text("Analytical").tag("analytical")
            }
            .labelsHidden()
            .onChange(of: coachingStyle) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "coachingStyle")
                if newValue != "auto" {
                    Task {
                        if let profile = try? advisor.fetchOrCreateProfile() {
                            profile.encouragementStyle = newValue
                        }
                    }
                }
            }

            Text(styleDescription)
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var styleDescription: String {
        switch coachingStyle {
        case "auto":       return "SAM will experiment with different styles and learn which you prefer."
        case "direct":     return "Brief, factual: \"Done. Sarah's proposal is ready.\""
        case "supportive": return "Encouraging: \"Great progress! You're building strong momentum.\""
        case "achievement": return "Goal-oriented: \"That's 3 client proposals this week.\""
        case "analytical": return "Data-driven: \"Your response time for Clients improved 20% this month.\""
        default:           return ""
        }
    }

    // MARK: - Re-analyze Section

    private var reanalyzeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Re-analyze")
                .samFont(.headline)

            Text("Re-run AI analysis on all notes using the current backend. Emails and messages require a fresh import.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Re-analyze All Notes") {
                    reanalyzeAllNotes()
                }
                .controlSize(.small)
                .disabled(isReanalyzing)

                if isReanalyzing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let status = reanalyzeStatus {
                Text(status)
                    .samFont(.caption)
                    .foregroundStyle(status.contains("Failed") ? .red : .secondary)
            }
        }
    }

    // MARK: - Feedback Section — "What SAM Has Learned"

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What SAM Has Learned")
                    .samFont(.headline)
                Spacer()
                GuideButton(articleID: "today.coaching")
            }

            Text("SAM adapts to your patterns over time. Here's what it's learned so far.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            let ledger = CalibrationService.cachedLedger

            // ── Overview Stats ──
            if let profile = try? advisor.fetchOrCreateProfile() {
                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("\(profile.totalActedOn)")
                            .samFont(.title3)
                            .fontWeight(.semibold)
                        Text("Completed")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text("\(profile.totalDismissed)")
                            .samFont(.title3)
                            .fontWeight(.semibold)
                        Text("Skipped")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text(profile.avgRating > 0 ? String(format: "%.1f", profile.avgRating) : "—")
                            .samFont(.title3)
                            .fontWeight(.semibold)
                        Text("Avg Rating")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // ── Outcome Preferences ──
            if !ledger.kindStats.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("Outcome Preferences")
                    .samFont(.subheadline)
                    .fontWeight(.medium)

                let sortedKinds = ledger.kindStats.sorted { $0.value.actRate > $1.value.actRate }
                ForEach(sortedKinds, id: \.key) { kind, stat in
                    let total = stat.actedOn + stat.dismissed
                    if total > 0 {
                        HStack(spacing: 8) {
                            Text(OutcomeKind(rawValue: kind)?.displayName ?? kind)
                                .samFont(.caption)
                                .frame(width: 90, alignment: .leading)

                            ProgressView(value: stat.actRate)
                                .tint(stat.actRate > 0.5 ? .green : stat.actRate > 0.25 ? .yellow : .orange)

                            Text("\(Int(stat.actRate * 100))%")
                                .samFont(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 35, alignment: .trailing)

                            Button {
                                Task { await CalibrationService.shared.resetKind(kind) }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .samFont(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .help("Reset \(kind) learning")
                        }
                    }
                }
            }

            // ── Active Hours ──
            if !ledger.peakHours.isEmpty || !ledger.peakDays.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("Your Active Hours")
                    .samFont(.subheadline)
                    .fontWeight(.medium)

                if !ledger.peakHours.isEmpty {
                    let hourLabels = ledger.peakHours.map { formatSettingsHour($0) }
                    Text("Peak hours: \(hourLabels.joined(separator: ", "))")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                if !ledger.peakDays.isEmpty {
                    let dayLabels = ledger.peakDays.map { formatSettingsDay($0) }
                    Text("Most active days: \(dayLabels.joined(separator: ", "))")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Reset Timing Data") {
                    Task { await CalibrationService.shared.resetTiming() }
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
            }

            // ── Strategic Focus ──
            let adjustedCategories = ledger.strategicCategoryWeights.filter { $0.value != 1.0 }
            if !adjustedCategories.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("Strategic Focus")
                    .samFont(.subheadline)
                    .fontWeight(.medium)

                ForEach(adjustedCategories.sorted(by: { $0.key < $1.key }), id: \.key) { category, weight in
                    HStack {
                        Text(category.capitalized)
                            .samFont(.caption)
                        Spacer()
                        Text(String(format: "%.1fx", weight))
                            .samFont(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(weight > 1.0 ? .green : .orange)
                        Button {
                            Task { await CalibrationService.shared.resetStrategicCategory(category) }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .samFont(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Reset \(category) weight")
                    }
                }
            }

            // ── RSVP Detection Accuracy ──
            if let rsvpStats = ledger.rsvpAccuracyStats {
                Divider()
                    .padding(.vertical, 4)

                Text("RSVP Detection Accuracy")
                    .samFont(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("\(rsvpStats.confirmed)")
                            .samFont(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                        Text("Confirmed")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text("\(rsvpStats.dismissed)")
                            .samFont(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(.red)
                        Text("Wrong")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text("\(Int(rsvpStats.accuracy * 100))%")
                            .samFont(.title3)
                            .fontWeight(.semibold)
                        Text("Accuracy")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                let threshold = EventCoordinator.computeRSVPThreshold(from: ledger)
                Text("Auto-confirm threshold: \(Int(threshold * 100))%")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset RSVP Stats") {
                    Task {
                        await CalibrationService.shared.resetKind("rsvpAccepted")
                        await CalibrationService.shared.resetKind("rsvpDeclined")
                        await CalibrationService.shared.resetKind("rsvpTentative")
                    }
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
            }

            // ── Muted Types ──
            if !ledger.mutedKinds.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("Muted Types")
                    .samFont(.subheadline)
                    .fontWeight(.medium)

                ForEach(ledger.mutedKinds, id: \.self) { kind in
                    HStack {
                        Text(OutcomeKind(rawValue: kind)?.displayName ?? kind)
                            .samFont(.caption)
                        Spacer()
                        Button("Unmute") {
                            Task { await CalibrationService.shared.setMuted(kind: kind, muted: false) }
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    }
                }
            }

            // ── Mute a Type ──
            Divider()
                .padding(.vertical, 4)

            HStack {
                Text("Mute a type:")
                    .samFont(.caption)

                Picker("", selection: $mutePickerSelection) {
                    Text("Select…").tag("")
                    ForEach(OutcomeKind.allCases, id: \.rawValue) { kind in
                        if !ledger.mutedKinds.contains(kind.rawValue) {
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: mutePickerSelection) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    Task { await CalibrationService.shared.setMuted(kind: newValue, muted: true) }
                    mutePickerSelection = ""
                }
            }

            // ── Reset All ──
            Divider()
                .padding(.vertical, 4)

            Button("Reset All Learning") {
                showResetConfirmation = true
            }
            .controlSize(.small)
            .alert("Reset All Learning?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    resetProfile()
                    Task { await CalibrationService.shared.resetAll() }
                }
            } message: {
                Text("This clears all learned preferences, timing data, and calibration. SAM will start fresh.")
            }
        }
    }

    // MARK: - Autonomous Actions Section

    private var autonomousActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Autonomous Actions")
                .samFont(.headline)

            Text("Let SAM proactively create content for your review.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            Toggle("Auto-create meeting note templates", isOn: $autoMeetingNoteTemplates)
                .onChange(of: autoMeetingNoteTemplates) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "autoMeetingNoteTemplates")
                }

            Text("When a calendar event ends, SAM creates a pre-filled note template for you to complete.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Auto-suggest actions on role change", isOn: $autoRoleTransitionOutcomes)
                .onChange(of: autoRoleTransitionOutcomes) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "autoRoleTransitionOutcomes")
                }

            Text("When you add a role like Applicant or Client, SAM generates relevant action items.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Weekly priorities digest", isOn: $weeklyDigestEnabled)
                .onChange(of: weeklyDigestEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "weeklyDigestEnabled")
                }

            Text("On Monday mornings, your briefing includes a \"This Week's Priorities\" section.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Meeting prep notifications", isOn: $meetingPrepNotifications)
                .onChange(of: meetingPrepNotifications) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "meetingPrepNotificationsEnabled")
                }

            Text("SAM sends a notification ~15 minutes before meetings with a briefing summary.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Send messages directly from SAM", isOn: $directSendEnabled)
                .onChange(of: directSendEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "directSendEnabled")
                }

            Text("When enabled, SAM sends iMessages and emails via AppleScript without leaving the app. Requires one-time Automation permission grant.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Content posting suggestions", isOn: $contentSuggestionsEnabled)
                .onChange(of: contentSuggestionsEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "contentSuggestionsEnabled")
                }

            Text("SAM suggests 3 educational content topics per week based on your recent meetings and client conversations.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func reanalyzeAllNotes() {
        isReanalyzing = true
        reanalyzeStatus = nil

        Task {
            do {
                let count = try NotesRepository.shared.markAllUnanalyzed()
                if count == 0 {
                    reanalyzeStatus = "No analyzed notes to re-process."
                    isReanalyzing = false
                    return
                }
                reanalyzeStatus = "Re-analyzing \(count) notes…"
                await NoteAnalysisCoordinator.shared.analyzeUnanalyzedNotes()
                reanalyzeStatus = "Done — \(count) notes re-analyzed with current backend."
                logger.debug("Re-analyzed \(count) notes")
            } catch {
                reanalyzeStatus = "Failed: \(error.localizedDescription)"
                logger.error("Re-analyze failed: \(error.localizedDescription)")
            }
            isReanalyzing = false
        }
    }

    private func resetProfile() {
        do {
            if let profile = try? advisor.fetchOrCreateProfile() {
                profile.encouragementStyle = "direct"
                profile.preferredOutcomeKinds = []
                profile.dismissPatterns = []
                profile.avgResponseTimeMinutes = 0
                profile.totalActedOn = 0
                profile.totalDismissed = 0
                profile.totalRated = 0
                profile.avgRating = 0
                profile.updatedAt = .now
            }
            logger.debug("Coaching profile reset")
        }
    }

    // MARK: - Formatting Helpers

    private func formatSettingsHour(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? "AM" : "PM"
        return "\(h) \(period)"
    }

    private func formatSettingsDay(_ day: Int) -> String {
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

