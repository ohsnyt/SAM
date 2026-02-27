//
//  AwarenessView.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase I: Insights & Awareness
//
//  Dashboard showing prioritized AI-generated insights from all data sources.
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
    @State private var reorderTick: Int = 0
    @State private var showReview = false

    // MARK: - Briefing State

    private var briefingCoordinator: DailyBriefingCoordinator { DailyBriefingCoordinator.shared }
    @State private var showBriefingPopover = false

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Subtle last-updated timestamp
                headerSection

                // Evening recap banner (if prompted)
                if briefingCoordinator.showEveningPrompt {
                    EveningPromptBanner()
                }

                // Zone 1 — Hero Card: top coaching recommendation
                heroCardSection
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                Divider()

                // Zone 2 — Today's Actions: merged actionQueue + todaysFocus sections
                todayActionsSection

                Divider()

                // Zone 3 — Review & Analytics (collapsed by default)
                reviewAnalyticsSection

                Divider()

                // Filter Bar + Insights (below review)
                filterBar

                Divider()

                if filteredInsights.isEmpty {
                    emptyState
                } else {
                    insightsSection
                }
            }
        }
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    // Briefing popover button
                    Button(action: {
                        showBriefingPopover.toggle()
                    }) {
                        Label("Briefing", systemImage: "text.book.closed")
                    }
                    .disabled(briefingCoordinator.morningBriefing == nil)
                    .popover(isPresented: $showBriefingPopover) {
                        DailyBriefingPopover()
                            .frame(width: 400, height: 500)
                    }

                    Button(action: {
                        refreshInsights()
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isGenerating)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { briefingCoordinator.showMorningBriefing },
            set: { briefingCoordinator.showMorningBriefing = $0 }
        )) {
            DailyBriefingOverlay()
        }
        .sheet(isPresented: Binding(
            get: { briefingCoordinator.showEveningBriefing },
            set: { briefingCoordinator.showEveningBriefing = $0 }
        )) {
            EveningRecapOverlay()
        }
        .task {
            await loadInsights()
            await meetingPrepCoordinator.refresh()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            reorderTick += 1
        }
        .onChange(of: calendarCoordinator.importStatus) {
            if calendarCoordinator.importStatus == .success {
                Task {
                    await meetingPrepCoordinator.refresh()
                }
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack {
            Text(timeOfDayGreeting)
                .font(.largeTitle)
                .fontWeight(.bold)

            Spacer()

            if let lastGenerated = generator.lastGeneratedAt {
                Text("Updated \(lastGenerated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
    }

    private var timeOfDayGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case ..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:     return "Good evening"
        }
    }

    // MARK: - Hero Card Section

    private var heroCardSection: some View {
        Group {
            if let topOutcome = heroOutcome {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Top Priority")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    OutcomeCardView(
                        outcome: topOutcome,
                        onAct: nil,
                        onDone: {},
                        onSkip: {}
                    )
                }
                .padding()
                .background(Color.blue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.title)
                        .foregroundStyle(.green)
                    Text("You're on track")
                        .font(.headline)
                    Text("No urgent coaching recommendations right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var heroOutcome: SamOutcome? {
        try? OutcomeRepository.shared.fetchActive().first
    }

    // MARK: - Today's Actions Section

    private var todayActionsSection: some View {
        let actionSections = sectionsForGroup(.actionQueue).filter { $0 != .outcomes }
        let focusSections = sectionsForGroup(.todaysFocus)
        let allSections = actionSections + focusSections

        return VStack(spacing: 0) {
            if !allSections.isEmpty {
                ForEach(Array(allSections.enumerated()), id: \.element) { index, section in
                    sectionView(for: section)
                    if index < allSections.count - 1 {
                        Divider()
                            .padding(.horizontal)
                    }
                }
            }
        }
    }

    // MARK: - Review & Analytics Section

    private var reviewAnalyticsSection: some View {
        DisclosureGroup("Review & Analytics", isExpanded: $showReview) {
            VStack(spacing: 0) {
                let sections = AwarenessSectionGroup.reviewAnalytics.sections
                ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                    sectionView(for: section)
                    if index < sections.count - 1 {
                        Divider()
                            .padding(.horizontal)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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

    // MARK: - Section Grouping & Time-of-Day Ordering

    /// Sections in the awareness dashboard, dynamically reordered.
    enum AwarenessSection: String, CaseIterable {
        case outcomes
        case unknownSenders
        case followUpCoach
        case lifeEvents
        case meetingPrep
        case pipeline
        case engagementVelocity
        case meetingQuality
        case streaks
        case contentCadence
        case calendarPatterns
        case timeAllocation
        case referralTracking
        case goalPacing
        case networkGrowth
    }

    /// Collapsible section groups with time-based ordering.
    enum AwarenessSectionGroup: String, CaseIterable, Hashable {
        case actionQueue
        case todaysFocus
        case reviewAnalytics

        var title: String {
            switch self {
            case .actionQueue:     return "Action Queue"
            case .todaysFocus:     return "Today's Focus"
            case .reviewAnalytics: return "Review & Analytics"
            }
        }

        var icon: String {
            switch self {
            case .actionQueue:     return "bolt.fill"
            case .todaysFocus:     return "calendar.badge.clock"
            case .reviewAnalytics: return "chart.bar.fill"
            }
        }

        var sections: [AwarenessSection] {
            switch self {
            case .actionQueue:     return [.outcomes, .followUpCoach, .unknownSenders]
            case .todaysFocus:     return [.goalPacing, .meetingPrep, .pipeline, .lifeEvents, .engagementVelocity]
            case .reviewAnalytics: return [.streaks, .contentCadence, .meetingQuality, .calendarPatterns, .timeAllocation, .referralTracking, .networkGrowth]
            }
        }
    }

    /// Current time period for contextual ordering.
    enum TimePeriod {
        case morning, afternoon, evening

        var label: String {
            switch self {
            case .morning:   return "Morning Focus"
            case .afternoon: return "Afternoon"
            case .evening:   return "Evening Review"
            }
        }

        var icon: String {
            switch self {
            case .morning:   return "sunrise"
            case .afternoon: return "sun.max"
            case .evening:   return "sunset"
            }
        }

        static func current(hour: Int) -> TimePeriod {
            switch hour {
            case ..<12:   return .morning
            case 12..<17: return .afternoon
            default:      return .evening
            }
        }
    }

    /// Current time period, refreshed via reorderTick.
    private var currentTimePeriod: TimePeriod {
        _ = reorderTick
        let hour = Calendar.current.component(.hour, from: Date())
        return TimePeriod.current(hour: hour)
    }

    /// Sections within a group, with float-to-top rules applied.
    private func sectionsForGroup(_ group: AwarenessSectionGroup) -> [AwarenessSection] {
        _ = reorderTick
        var sections = group.sections
        let now = Date()

        if group == .todaysFocus {
            // Float MeetingPrep to top if a meeting starts within 30 min
            let thirtyMinFromNow = Calendar.current.date(byAdding: .minute, value: 30, to: now)!
            let hasSoonMeeting = meetingPrepCoordinator.briefings.contains { briefing in
                briefing.startsAt > now && briefing.startsAt <= thirtyMinFromNow
            }
            if hasSoonMeeting {
                sections.removeAll { $0 == .meetingPrep }
                sections.insert(.meetingPrep, at: 0)
            }
        }

        if group == .actionQueue {
            // Float FollowUpCoach to top if a meeting ended within 1 hour
            let oneHourAgo = Calendar.current.date(byAdding: .hour, value: -1, to: now)!
            let hasRecentMeeting = meetingPrepCoordinator.followUpPrompts.contains { prompt in
                prompt.endedAt >= oneHourAgo && prompt.endedAt <= now
            }
            if hasRecentMeeting {
                sections.removeAll { $0 == .followUpCoach }
                sections.insert(.followUpCoach, at: 0)
            }
        }

        return sections
    }

    @ViewBuilder
    private func sectionView(for section: AwarenessSection) -> some View {
        switch section {
        case .outcomes:           OutcomeQueueView()
        case .unknownSenders:     UnknownSenderTriageSection()
        case .followUpCoach:      FollowUpCoachSection()
        case .lifeEvents:         LifeEventsSection()
        case .meetingPrep:        MeetingPrepSection()
        case .pipeline:           PipelineStageSection()
        case .engagementVelocity: EngagementVelocitySection()
        case .meetingQuality:     MeetingQualitySection()
        case .streaks:            StreakTrackingSection()
        case .contentCadence:     ContentCadenceSection()
        case .calendarPatterns:   CalendarPatternsSection()
        case .timeAllocation:     TimeAllocationSection()
        case .referralTracking:   ReferralTrackingSection()
        case .goalPacing:         GoalPacingSection()
        case .networkGrowth:      NetworkGrowthSection()
        }
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
        _ = await generator.generateInsights()
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

// MARK: - Preview

#Preview("Awareness View") {
    NavigationStack {
        AwarenessView()
    }
    .frame(width: 900, height: 700)
}
