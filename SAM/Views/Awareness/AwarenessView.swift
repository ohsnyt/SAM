//
//  AwarenessView.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase I: Insights & Awareness
//
//  Dashboard showing prioritized AI-generated insights from all data sources.
//  Redesigned Phase 1 (3/4/26): 3 zones — Briefing, Outcomes, More.
//

import SwiftUI
import SwiftData
import Combine
struct AwarenessView: View {

    // MARK: - Dependencies

    private var generator: InsightGenerator { InsightGenerator.shared }
    private var meetingPrepCoordinator: MeetingPrepCoordinator { MeetingPrepCoordinator.shared }
    private var calendarCoordinator: CalendarImportCoordinator { CalendarImportCoordinator.shared }
    @Environment(\.modelContext) private var modelContext

    // MARK: - Persisted Insights

    @Query(filter: #Predicate<SamInsight> { $0.dismissedAt == nil },
           sort: \SamInsight.createdAt, order: .reverse)
    private var persistedInsights: [SamInsight]

    // MARK: - State

    @State private var selectedFilter: InsightFilter = .all
    @State private var searchText = ""
    @State private var isGenerating = false
    @State private var showMore = false

    // MARK: - Briefing State

    private var briefingCoordinator: DailyBriefingCoordinator { DailyBriefingCoordinator.shared }
    // MARK: - Body

    @AppStorage("sam.legacyStores.detected") private var legacyStoresDetected = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Legacy data migration notice
                if legacyStoresDetected {
                    LegacyDataNoticeBanner {
                        legacyStoresDetected = false
                    }
                }

                // Zone 1 — Persistent Briefing
                PersistentBriefingSection()

                // Evening recap banner (if prompted)
                if briefingCoordinator.showEveningPrompt {
                    EveningPromptBanner()
                }

                Divider()

                // Zone 2 — Top Outcome Cards (capped at 5)
                OutcomeQueueView(maxVisible: 5)

                Divider()

                // Zone 3 — Everything else, collapsed by default
                moreSection
            }
        }
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    refreshInsights()
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isGenerating)
            }
            ToolbarItem(placement: .primaryAction) {
                GuideButton(articleID: "today.daily-briefing")
            }
        }
        .sheet(isPresented: Binding(
            get: { briefingCoordinator.showEveningBriefing },
            set: { briefingCoordinator.showEveningBriefing = $0 }
        )) {
            EveningRecapOverlay()
        }
        .onReceive(NotificationCenter.default.publisher(for: .samExpandMeetingPrep)) { _ in
            withAnimation { showMore = true }
        }
        .task {
            await loadInsightsIfNeeded()
            await meetingPrepCoordinator.refreshIfNeeded()
        }
        .onChange(of: calendarCoordinator.importStatus) {
            if calendarCoordinator.importStatus == .success {
                Task {
                    await meetingPrepCoordinator.refresh()
                }
            }
        }
    }

    // MARK: - More Section (collapsed)

    private var moreSection: some View {
        VStack(spacing: 0) {
            // Full-width toggle button
            Button(action: { withAnimation { showMore.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: showMore ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("More")
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if showMore {
                VStack(spacing: 0) {
                    // Completed outcomes today
                    completedTodaySection

                    // All individual sections
                    FollowUpCoachSection()
                    Divider().padding(.horizontal)
                    UnknownSenderTriageSection()
                    Divider().padding(.horizontal)
                    GoalPacingSection()
                    Divider().padding(.horizontal)
                    MeetingPrepSection()
                    Divider().padding(.horizontal)
                    PipelineStageSection()
                    Divider().padding(.horizontal)
                    LifeEventsSection()
                    Divider().padding(.horizontal)
                    EngagementVelocitySection()
                    Divider().padding(.horizontal)
                    ProfileAnalysisReadySection()
                    Divider().padding(.horizontal)
                    StreakTrackingSection()
                    Divider().padding(.horizontal)
                    ContentCadenceSection()
                    Divider().padding(.horizontal)
                    MeetingQualitySection()
                    Divider().padding(.horizontal)
                    CalendarPatternsSection()
                    Divider().padding(.horizontal)
                    TimeAllocationSection()
                    Divider().padding(.horizontal)
                    ReferralTrackingSection()
                    Divider().padding(.horizontal)
                    NetworkGrowthSection()

                    Divider()

                    // Filter Bar + Insights
                    filterBar

                    Divider()

                    if filteredInsights.isEmpty {
                        emptyState
                    } else {
                        insightsSection
                    }
                }
            }
        }
    }

    // MARK: - Completed Today (moved from OutcomeQueueView)

    @Query(sort: \SamOutcome.completedAt, order: .reverse)
    private var allOutcomesForCompleted: [SamOutcome]

    private var completedToday: [SamOutcome] {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return allOutcomesForCompleted.filter {
            $0.status == .completed
            && $0.completedAt != nil
            && $0.completedAt! >= startOfDay
        }
    }

    @State private var showCompleted = false

    @ViewBuilder
    private var completedTodaySection: some View {
        if !completedToday.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { withAnimation { showCompleted.toggle() } }) {
                    HStack {
                        Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("Completed Today (\(completedToday.count))")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                if showCompleted {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(completedToday) { outcome in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Text(outcome.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            Divider().padding(.horizontal)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: $selectedFilter) {
                ForEach(InsightFilter.allCases, id: \.self) { filter in
                    Text(filter.displayText).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 600)

            Spacer()

            Text("\(filteredInsights.count) insight\(filteredInsights.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Insights List

    private var insightsSection: some View {
        LazyVStack(spacing: 12) {
            ForEach(filteredInsights) { insight in
                InsightCard(
                    insight: insight,
                    onMarkDone: {
                        markInsightAsDone(insight)
                    },
                    onDismiss: {
                        dismissInsight(insight)
                    },
                    onViewPerson: {
                        viewPerson(insight.samPerson?.id)
                    }
                )
            }
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Insights Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Insights will appear here after you create notes, import calendar events, and add contacts.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button(action: {
                refreshInsights()
            }) {
                Label("Generate Insights", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGenerating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Computed Properties

    private var filteredInsights: [SamInsight] {
        var filtered = persistedInsights

        // Apply filter
        switch selectedFilter {
        case .all:
            break
        case .highPriority:
            filtered = filtered.filter { $0.urgency == .high }
        case .followUps:
            filtered = filtered.filter { $0.kind == .followUpNeeded }
        case .opportunities:
            filtered = filtered.filter { $0.kind == .opportunity }
        case .risks:
            filtered = filtered.filter {
                $0.kind == .relationshipAtRisk || $0.kind == .complianceWarning
            }
        }

        // Apply search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(query) ||
                $0.message.lowercased().contains(query)
            }
        }

        return filtered
    }



    // MARK: - Actions

    private func loadInsights() async {
        isGenerating = true
        // Generate insights — persistence happens inside the generator;
        // @Query auto-updates the list from SwiftData.
        _ = await generator.generateInsights(force: true)
        isGenerating = false
    }

    /// Throttled insight load — skips if run within the last 5 minutes.
    /// Uses the generator's built-in throttle (force: false).
    private func loadInsightsIfNeeded() async {
        isGenerating = true
        _ = await generator.generateInsights(force: false)
        isGenerating = false
    }

    private func refreshInsights() {
        Task {
            await loadInsights()
            await meetingPrepCoordinator.refresh()
        }
    }

    private func markInsightAsDone(_ insight: SamInsight) {
        let snapshot = InsightSnapshot(id: insight.id, title: insight.title)
        insight.dismissedAt = .now
        try? modelContext.save()

        if let entry = try? UndoRepository.shared.capture(
            operation: .statusChanged,
            entityType: .insight,
            entityID: insight.id,
            entityDisplayName: insight.title,
            snapshot: snapshot
        ) {
            UndoCoordinator.shared.showToast(for: entry)
        }
    }

    private func dismissInsight(_ insight: SamInsight) {
        let snapshot = InsightSnapshot(id: insight.id, title: insight.title)
        insight.dismissedAt = .now
        try? modelContext.save()

        if let entry = try? UndoRepository.shared.capture(
            operation: .statusChanged,
            entityType: .insight,
            entityID: insight.id,
            entityDisplayName: insight.title,
            snapshot: snapshot
        ) {
            UndoCoordinator.shared.showToast(for: entry)
        }
    }

    private func viewPerson(_ personID: UUID?) {
        guard let personID else { return }
        NotificationCenter.default.post(
            name: .samNavigateToPerson,
            object: nil,
            userInfo: ["personID": personID]
        )
    }
}

// MARK: - Insight Card

private struct InsightCard: View {
    let insight: SamInsight
    let onMarkDone: () -> Void
    let onDismiss: () -> Void
    let onViewPerson: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                // Icon
                Image(systemName: insight.kind.icon)
                    .font(.title2)
                    .foregroundStyle(insight.kind.color)
                    .frame(width: 40, height: 40)
                    .background(insight.kind.color.opacity(0.1))
                    .clipShape(Circle())

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(insight.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        // Urgency Badge
                        Text(insight.urgency.displayText)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(urgencyColor(insight.urgency))
                            .clipShape(Capsule())

                        // Source Badge
                        Text(insight.sourceType.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())

                        Spacer()

                        // Timestamp
                        Text(insight.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Expand Button
                Button(action: {
                    withAnimation {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Expanded Content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()

                    Text(insight.message)
                        .font(.body)
                        .foregroundStyle(.secondary)

                    // Actions
                    HStack(spacing: 12) {
                        Button(action: onMarkDone) {
                            Label("Mark Done", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)

                        if insight.samPerson != nil {
                            Button(action: onViewPerson) {
                                Label("View Person", systemImage: "person.fill")
                            }
                            .buttonStyle(.bordered)
                        }

                        Spacer()

                        Button(action: onDismiss) {
                            Label("Dismiss", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func urgencyColor(_ urgency: InsightPriority) -> Color {
        switch urgency {
        case .low: return .gray
        case .medium: return .orange
        case .high: return .red
        }
    }
}



// MARK: - Filter Enum

enum InsightFilter: String, CaseIterable {
    case all = "All"
    case highPriority = "High Priority"
    case followUps = "Follow-ups"
    case opportunities = "Opportunities"
    case risks = "Risks"

    var displayText: String {
        self.rawValue
    }
}

// MARK: - InsightKind Extension

extension InsightKind {
    var icon: String {
        switch self {
        case .relationshipAtRisk:
            return "exclamationmark.triangle.fill"
        case .consentMissing:
            return "checkmark.shield.fill"
        case .complianceWarning:
            return "exclamationmark.shield.fill"
        case .opportunity:
            return "sparkles"
        case .followUpNeeded:
            return "clock.arrow.circlepath"
        case .informational:
            return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .relationshipAtRisk:
            return .orange
        case .consentMissing:
            return .red
        case .complianceWarning:
            return .red
        case .opportunity:
            return .green
        case .followUpNeeded:
            return .blue
        case .informational:
            return .gray
        }
    }
}

// MARK: - Profile Analysis Ready Section

/// A compact card shown in Today's Focus when any profile analysis is fresh (< 7 days old).
/// Shows the most recently analyzed platform. Tapping "View in Grow" navigates there.
struct ProfileAnalysisReadySection: View {

    @State private var analyses: [ProfileAnalysisDTO] = []
    @AppStorage("sam.grow.lastViewedAnalysisDate") private var lastViewedRaw: Double = 0

    private var lastViewed: Date? {
        lastViewedRaw > 0 ? Date(timeIntervalSince1970: lastViewedRaw) : nil
    }

    /// The freshest analysis that is < 7 days old and newer than the last view of Grow.
    private var freshAnalysis: ProfileAnalysisDTO? {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return analyses
            .filter { $0.analysisDate > cutoff }
            .filter { a in
                if let viewed = lastViewed { return a.analysisDate > viewed }
                return true
            }
            .sorted { $0.analysisDate > $1.analysisDate }
            .first
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 76...100: return .green
        case 61...75:  return .yellow
        case 41...60:  return .orange
        default:       return .red
        }
    }

    var body: some View {
        Group {
            if let a = freshAnalysis {
                let meta = SocialPlatformMeta.from(a.platform)
                let color = scoreColor(a.overallScore)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        // Platform icon
                        Image(systemName: meta.icon)
                            .font(.title3)
                            .foregroundStyle(meta.iconColor)
                            .frame(width: 28)

                        // Mini score ring
                        ZStack {
                            Circle()
                                .stroke(color.opacity(0.2), lineWidth: 5)
                                .frame(width: 40, height: 40)
                            Circle()
                                .trim(from: 0, to: CGFloat(a.overallScore) / 100)
                                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .frame(width: 40, height: 40)
                                .rotationEffect(.degrees(-90))
                            Text("\(a.overallScore)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(color)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(meta.displayName) Profile Analysis Ready")
                                .font(.subheadline.weight(.semibold))
                            Text("Score: \(a.overallScore)/100 \u{2022} \(a.improvements.count) improvement\(a.improvements.count == 1 ? "" : "s") suggested")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("View in Grow") {
                            lastViewedRaw = Date().timeIntervalSince1970
                            NotificationCenter.default.post(name: .samNavigateToGrow, object: nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding()
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            // No fresh analysis — render nothing (section is invisible)
        }
        .task { analyses = await BusinessProfileService.shared.profileAnalyses() }
    }
}

// MARK: - Legacy Data Notice Banner

/// Informational banner shown on the Today view when the current store is
/// empty and legacy stores from previous SAM versions are detected.
private struct LegacyDataNoticeBanner: View {
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Data from a previous SAM version was found")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Go to Settings \u{2192} General to migrate your data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding()
    }
}

// MARK: - Preview

#Preview("Awareness View") {
    NavigationStack {
        AwarenessView()
    }
    .frame(width: 900, height: 700)
}
