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

    @State private var selectedBackend: String = UserDefaults.standard.string(forKey: "aiBackend") ?? "foundationModels"
    @State private var selectedModelID: String = UserDefaults.standard.string(forKey: "mlxSelectedModelID") ?? ""
    @State private var coachingStyle: String = UserDefaults.standard.string(forKey: "coachingStyle") ?? "auto"
    @State private var autoGenerate: Bool = UserDefaults.standard.bool(forKey: "outcomeAutoGenerate")
    @State private var advisor = CoachingAdvisor.shared
    @State private var showResetConfirmation = false
    @State private var mlxModels: [MLXModelManager.ModelInfo] = []
    @State private var downloadingModelID: String?
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String?
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

    // Business Intelligence (Phase V)
    @State private var strategicDigestEnabled: Bool = {
        UserDefaults.standard.object(forKey: "strategicDigestEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "strategicDigestEnabled")
    }()
    @State private var strategicBriefingIntegration: Bool = {
        UserDefaults.standard.object(forKey: "strategicBriefingIntegration") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "strategicBriefingIntegration")
    }()

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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ── AI Backend ─────────────────────────────
            aiBackendSection

            Divider()

            // ── MLX Model ──────────────────────────────
            if selectedBackend == "mlx" || selectedBackend == "hybrid" {
                mlxModelSection
                Divider()
            }

            // ── Coaching Style ─────────────────────────
            coachingStyleSection

            Divider()

            // ── Outcome Generation ─────────────────────
            outcomeGenerationSection

            Divider()

            // ── Autonomous Actions ────────────────────────
            autonomousActionsSection

            Divider()

            // ── Re-analyze ───────────────────────────────
            reanalyzeSection

            Divider()

            // ── Business Intelligence ────────────────────
            businessIntelligenceSection

            Divider()

            // ── Feedback ───────────────────────────────
            feedbackSection
        }
        .task {
            mlxModels = await MLXModelManager.shared.availableModels
        }
    }

    // MARK: - AI Backend Section

    private var aiBackendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Backend")
                .font(.headline)

            Text("Choose which AI model powers coaching suggestions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Backend", selection: $selectedBackend) {
                Text("Apple Intelligence (Default)").tag("foundationModels")
                Text("MLX Local Model").tag("mlx")
                Text("Hybrid (Apple + MLX)").tag("hybrid")
            }
            .pickerStyle(.radioGroup)
            .onChange(of: selectedBackend) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "aiBackend")
                logger.info("AI backend changed to: \(newValue)")
                if newValue == "foundationModels" {
                    Task { await AIService.shared.unloadMLXModel() }
                }
            }

            Text(backendDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - MLX Model Section

    private var mlxModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MLX Model")
                .font(.headline)

            Text("Select and download a local model for AI-powered coaching.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(mlxModels) { model in
                VStack(spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.subheadline)
                            Text("\(String(format: "%.1f", model.sizeGB)) GB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if model.isDownloaded {
                            modelDownloadedActions(for: model)
                        } else if downloadingModelID == model.id {
                            Button("Cancel") {
                                cancelDownload()
                            }
                            .controlSize(.small)
                        } else {
                            Button("Download") {
                                startDownload(modelID: model.id)
                            }
                            .controlSize(.small)
                            .disabled(downloadingModelID != nil)
                        }
                    }

                    // Progress bar during download
                    if downloadingModelID == model.id {
                        ProgressView(value: downloadProgress)
                            .progressViewStyle(.linear)
                        Text("Downloading… \(Int(downloadProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let error = downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func modelDownloadedActions(for model: MLXModelManager.ModelInfo) -> some View {
        if selectedModelID == model.id {
            HStack(spacing: 8) {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.green)

                Button(role: .destructive) {
                    deleteModel(id: model.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        } else {
            HStack(spacing: 8) {
                Button("Select") {
                    selectedModelID = model.id
                    UserDefaults.standard.set(model.id, forKey: "mlxSelectedModelID")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    deleteModel(id: model.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Coaching Style Section

    private var coachingStyleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coaching Style")
                .font(.headline)

            Text("How SAM frames encouragement when you complete outcomes.")
                .font(.caption)
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var backendDescription: String {
        switch selectedBackend {
        case "foundationModels":
            return "Uses Apple's on-device intelligence. No download required."
        case "mlx":
            return "Uses a locally downloaded open-source model. More powerful reasoning but requires disk space."
        case "hybrid":
            return "Structured extraction uses Apple Intelligence; summaries and prose use the MLX model for deeper reasoning."
        default:
            return ""
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

    // MARK: - Outcome Generation Section

    private var outcomeGenerationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outcome Generation")
                .font(.headline)

            Toggle("Auto-generate on launch", isOn: $autoGenerate)
                .onChange(of: autoGenerate) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "outcomeAutoGenerate")
                }

            Text("When enabled, SAM generates coaching outcomes automatically after data imports complete.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Generate Now") {
                Task { await OutcomeEngine.shared.generateOutcomes() }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Re-analyze Section

    private var reanalyzeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Re-analyze")
                .font(.headline)

            Text("Re-run AI analysis on all notes using the current backend. Emails and messages require a fresh import.")
                .font(.caption)
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
                    .font(.caption)
                    .foregroundStyle(status.contains("Failed") ? .red : .secondary)
            }
        }
    }

    // MARK: - Feedback Section — "What SAM Has Learned"

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What SAM Has Learned")
                .font(.headline)

            Text("SAM adapts to your patterns over time. Here's what it's learned so far.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let ledger = CalibrationService.cachedLedger

            // ── Overview Stats ──
            if let profile = try? advisor.fetchOrCreateProfile() {
                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("\(profile.totalActedOn)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Completed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text("\(profile.totalDismissed)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Skipped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text(profile.avgRating > 0 ? String(format: "%.1f", profile.avgRating) : "—")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Avg Rating")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // ── Outcome Preferences ──
            if !ledger.kindStats.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("Outcome Preferences")
                    .font(.subheadline)
                    .fontWeight(.medium)

                let sortedKinds = ledger.kindStats.sorted { $0.value.actRate > $1.value.actRate }
                ForEach(sortedKinds, id: \.key) { kind, stat in
                    let total = stat.actedOn + stat.dismissed
                    if total > 0 {
                        HStack(spacing: 8) {
                            Text(OutcomeKind(rawValue: kind)?.displayName ?? kind)
                                .font(.caption)
                                .frame(width: 90, alignment: .leading)

                            ProgressView(value: stat.actRate)
                                .tint(stat.actRate > 0.5 ? .green : stat.actRate > 0.25 ? .yellow : .orange)

                            Text("\(Int(stat.actRate * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 35, alignment: .trailing)

                            Button {
                                Task { await CalibrationService.shared.resetKind(kind) }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption2)
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
                    .font(.subheadline)
                    .fontWeight(.medium)

                if !ledger.peakHours.isEmpty {
                    let hourLabels = ledger.peakHours.map { formatSettingsHour($0) }
                    Text("Peak hours: \(hourLabels.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !ledger.peakDays.isEmpty {
                    let dayLabels = ledger.peakDays.map { formatSettingsDay($0) }
                    Text("Most active days: \(dayLabels.joined(separator: ", "))")
                        .font(.caption)
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
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(adjustedCategories.sorted(by: { $0.key < $1.key }), id: \.key) { category, weight in
                    HStack {
                        Text(category.capitalized)
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.1fx", weight))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(weight > 1.0 ? .green : .orange)
                        Button {
                            Task { await CalibrationService.shared.resetStrategicCategory(category) }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Reset \(category) weight")
                    }
                }
            }

            // ── Muted Types ──
            if !ledger.mutedKinds.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("Muted Types")
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(ledger.mutedKinds, id: \.self) { kind in
                    HStack {
                        Text(OutcomeKind(rawValue: kind)?.displayName ?? kind)
                            .font(.caption)
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
                    .font(.caption)

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
                .font(.headline)

            Text("Let SAM proactively create content for your review.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Auto-create meeting note templates", isOn: $autoMeetingNoteTemplates)
                .onChange(of: autoMeetingNoteTemplates) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "autoMeetingNoteTemplates")
                }

            Text("When a calendar event ends, SAM creates a pre-filled note template for you to complete.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Auto-suggest actions on role change", isOn: $autoRoleTransitionOutcomes)
                .onChange(of: autoRoleTransitionOutcomes) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "autoRoleTransitionOutcomes")
                }

            Text("When you add a role like Applicant or Client, SAM generates relevant action items.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Weekly priorities digest", isOn: $weeklyDigestEnabled)
                .onChange(of: weeklyDigestEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "weeklyDigestEnabled")
                }

            Text("On Monday mornings, your briefing includes a \"This Week's Priorities\" section.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Send messages directly from SAM", isOn: $directSendEnabled)
                .onChange(of: directSendEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "directSendEnabled")
                }

            Text("When enabled, SAM sends iMessages and emails via AppleScript without leaving the app. Requires one-time Automation permission grant.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Content posting suggestions", isOn: $contentSuggestionsEnabled)
                .onChange(of: contentSuggestionsEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "contentSuggestionsEnabled")
                }

            Text("SAM suggests 3 educational content topics per week based on your recent meetings and client conversations.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Business Intelligence Section

    private var businessIntelligenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Business Intelligence")
                .font(.headline)

            Text("Strategic insights analyze your pipeline, time allocation, and relationship patterns to suggest business-level actions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Enable strategic digest", isOn: $strategicDigestEnabled)
                .onChange(of: strategicDigestEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "strategicDigestEnabled")
                }

            Text("When enabled, SAM periodically analyzes your business data and generates strategic recommendations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Toggle("Include in daily briefing", isOn: $strategicBriefingIntegration)
                .onChange(of: strategicBriefingIntegration) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "strategicBriefingIntegration")
                }
                .disabled(!strategicDigestEnabled)

            Text("When enabled, your morning briefing includes top strategic recommendations.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func startDownload(modelID: String) {
        downloadingModelID = modelID
        downloadProgress = 0
        downloadError = nil

        Task {
            do {
                let progressTask = Task {
                    while !Task.isCancelled {
                        let progress = await MLXModelManager.shared.downloadProgress ?? 0
                        await MainActor.run { downloadProgress = progress }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }

                try await MLXModelManager.shared.downloadModel(id: modelID)
                progressTask.cancel()

                mlxModels = await MLXModelManager.shared.availableModels
                selectedModelID = modelID
                UserDefaults.standard.set(modelID, forKey: "mlxSelectedModelID")
                downloadingModelID = nil

                logger.info("Model downloaded and selected: \(modelID)")
            } catch is CancellationError {
                downloadingModelID = nil
            } catch {
                downloadingModelID = nil
                downloadError = "Download failed: \(error.localizedDescription)"
                logger.error("Model download failed: \(error.localizedDescription)")
            }
        }
    }

    private func cancelDownload() {
        Task {
            await MLXModelManager.shared.cancelDownload()
            downloadingModelID = nil
            downloadProgress = 0
        }
    }

    private func deleteModel(id: String) {
        Task {
            do {
                try await MLXModelManager.shared.deleteModel(id: id)
                await AIService.shared.unloadMLXModel()
                mlxModels = await MLXModelManager.shared.availableModels
                if selectedModelID == id {
                    selectedModelID = ""
                }
                logger.info("Model deleted: \(id)")
            } catch {
                downloadError = "Delete failed: \(error.localizedDescription)"
                logger.error("Model delete failed: \(error.localizedDescription)")
            }
        }
    }

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
                logger.info("Re-analyzed \(count) notes")
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
            logger.info("Coaching profile reset")
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

// MARK: - Standalone wrapper

struct CoachingSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Coaching", systemImage: "brain.head.profile")
                        .font(.title2)
                        .bold()

                    Divider()

                    CoachingSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}
