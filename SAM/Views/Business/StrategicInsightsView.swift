//
//  StrategicInsightsView.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase V: Business Intelligence — Strategic Coordinator
//
//  4th tab in BusinessDashboard — displays the latest StrategicDigest:
//  strategic recommendations, pipeline health, time balance, patterns, content ideas.
//

import SwiftUI
import TipKit

/// Tracks the state of a single plan preparation.
private struct PlanPreparation: Identifiable {
    let id: UUID  // Same as the recommendation ID
    let recommendation: StrategicRec
    let approach: ImplementationApproach?
    var messages: [CoachingMessage] = []
    var isReady: Bool = false
}

struct StrategicInsightsView: View {

    @Bindable var coordinator: StrategicCoordinator
    @State private var projectionEngine = ScenarioProjectionEngine.shared

    // Strategic Action coaching flow state
    @State private var selectedRecForAction: StrategicRec?

    /// Tracks in-flight and completed plan preparations keyed by recommendation ID.
    @State private var preparations: [UUID: PlanPreparation] = [:]

    /// The preparation currently being viewed in the coaching session sheet.
    @State private var activeCoachingPlan: PlanPreparation?

    /// The content topic selected for drafting via ContentDraftSheet.
    @State private var selectedContentTopic: ContentTopic?

    private let strategicInsightsTip = StrategicInsightsTip()

    var body: some View {
        VStack(spacing: 16) {
            // Scenario Projections (Phase Y)
            ScenarioProjectionsView(engine: projectionEngine)

            // Status banner
            statusBanner

            if coordinator.generationStatus == .generating {
                ProgressView("Analyzing business data...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else if coordinator.strategicRecommendations.isEmpty && coordinator.latestDigest == nil {
                emptyState
            } else {
                // Strategic Actions
                if !coordinator.strategicRecommendations.isEmpty {
                    recommendationsSection
                }

                // Pipeline Health
                if let digest = coordinator.latestDigest, !digest.pipelineSummary.isEmpty {
                    narrativeSection(title: "Pipeline Health", content: digest.pipelineSummary, icon: "chart.bar.fill")
                }

                // Time Balance
                if let digest = coordinator.latestDigest, !digest.timeSummary.isEmpty {
                    narrativeSection(title: "Time Balance", content: digest.timeSummary, icon: "clock.fill")
                }

                // Patterns
                if let digest = coordinator.latestDigest, !digest.patternInsights.isEmpty {
                    narrativeSection(title: "Patterns", content: digest.patternInsights, icon: "waveform.path.ecg")
                }

                // Content Ideas
                if let digest = coordinator.latestDigest, !digest.contentSuggestions.isEmpty {
                    contentIdeasSection(digest.contentSuggestions)
                }
            }

            Spacer()
        }
        .padding()
        .popoverTip(strategicInsightsTip, arrowEdge: .top)
        .task {
            projectionEngine.refresh()
        }
        .sheet(item: $selectedRecForAction) { rec in
            StrategicActionSheet(
                recommendation: rec,
                onFeedback: { feedback in
                    coordinator.recordFeedback(recommendationID: rec.id, feedback: feedback)
                    selectedRecForAction = nil
                },
                onPlanApproach: { rec, approach in
                    selectedRecForAction = nil
                    startPlanPreparation(for: rec, approach: approach)
                }
            )
        }
        .sheet(item: $activeCoachingPlan) { plan in
            CoachingSessionView(
                context: CoachingSessionContext(
                    recommendation: plan.recommendation,
                    approach: plan.approach,
                    businessSnapshot: coordinator.condensedBusinessSnapshot()
                ),
                initialMessages: plan.messages,
                onDone: {
                    coordinator.recordFeedback(recommendationID: plan.id, feedback: .actedOn)
                    activeCoachingPlan = nil
                    preparations.removeValue(forKey: plan.id)
                }
            )
        }
        .sheet(item: $selectedContentTopic) { topic in
            ContentDraftSheet(
                topic: topic.topic,
                keyPoints: topic.keyPoints,
                suggestedTone: topic.suggestedTone,
                complianceNotes: topic.complianceNotes,
                sourceOutcomeID: nil,
                onPosted: { selectedContentTopic = nil },
                onCancel: { selectedContentTopic = nil }
            )
        }
    }

    // MARK: - Status Banner

    private var statusBanner: some View {
        HStack {
            if let lastGen = coordinator.lastGeneratedAt {
                let formatter = RelativeDateTimeFormatter()
                Text("Last updated: \(formatter.localizedString(for: lastGen, relativeTo: .now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No analysis yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await coordinator.generateDigest(type: .onDemand) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(coordinator.generationStatus == .generating)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No strategic insights yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap Refresh to generate business intelligence from your pipeline, time tracking, and relationship data.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Recommendations

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.orange)
                Text("Strategic Actions")
                    .font(.headline)
                Spacer()
                Text("\(coordinator.strategicRecommendations.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(coordinator.strategicRecommendations) { rec in
                recommendationCard(rec)
            }
        }
    }

    private func recommendationCard(_ rec: StrategicRec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // Priority indicator
                Circle()
                    .fill(priorityColor(rec.priority))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(rec.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        categoryBadge(rec.category)
                    }

                    Text(rec.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            // Preparing indicator, ready indicator, or feedback buttons
            if let prep = preparations[rec.id], !prep.isReady {
                HStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                        .controlSize(.mini)
                    Text("SAM is developing a plan...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let prep = preparations[rec.id], prep.isReady {
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        activeCoachingPlan = prep
                    } label: {
                        Label("View Plan", systemImage: "doc.text.magnifyingglass")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.blue)

                    Button {
                        preparations.removeValue(forKey: rec.id)
                    } label: {
                        Label("Discard", systemImage: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.secondary)
                }
            } else if rec.feedback == nil {
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        selectedRecForAction = rec
                    } label: {
                        Label("Act", systemImage: "checkmark.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.green)

                    Button {
                        coordinator.recordFeedback(recommendationID: rec.id, feedback: .dismissed)
                    } label: {
                        Label("Dismiss", systemImage: "xmark.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.secondary)
                }
            } else {
                HStack {
                    Spacer()
                    Text(rec.feedback == .actedOn ? "Acted on" : "Dismissed")
                        .font(.caption2)
                        .foregroundStyle(rec.feedback == .actedOn ? .green : .secondary)
                }
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Narrative Sections

    private func narrativeSection(title: String, content: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                Text(title)
                    .font(.headline)
            }

            Text(content)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Content Ideas

    /// Decodes structured ContentTopic JSON; falls back to semicolon-separated plain text for older digests.
    private func contentIdeasSection(_ raw: String) -> some View {
        let structuredTopics: [ContentTopic]? = {
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([ContentTopic].self, from: data)
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.purple)
                Text("Content Ideas")
                    .font(.headline)
            }

            if let topics = structuredTopics {
                // Structured: clickable items that launch ContentDraftSheet
                ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                    Button {
                        selectedContentTopic = topic
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(index + 1).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.topic)
                                    .font(.callout)
                                    .fontWeight(.medium)
                                if !topic.keyPoints.isEmpty {
                                    Text(topic.keyPoints.joined(separator: " \u{2022} "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Legacy fallback: plain semicolon-separated titles
                let titles = raw.components(separatedBy: "; ").filter { !$0.isEmpty }
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(title)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Plan Preparation

    private func startPlanPreparation(for rec: StrategicRec, approach: ImplementationApproach?) {
        let recID = rec.id
        preparations[recID] = PlanPreparation(
            id: recID,
            recommendation: rec,
            approach: approach
        )

        Task {
            do {
                let context = CoachingSessionContext(
                    recommendation: rec,
                    approach: approach,
                    businessSnapshot: coordinator.condensedBusinessSnapshot()
                )
                let initialMessage = try await CoachingPlannerService.shared.generateInitialPlan(context: context)
                // Only update if this preparation hasn't been discarded
                if preparations[recID] != nil {
                    preparations[recID]?.messages = [initialMessage]
                    preparations[recID]?.isReady = true

                    // Post system notification so user knows even if they navigated away
                    await SystemNotificationService.shared.postPlanReady(
                        recommendationID: recID,
                        title: rec.title
                    )
                }
            } catch {
                // Remove the failed preparation
                preparations.removeValue(forKey: recID)
            }
        }
    }

    // MARK: - Helpers

    private func priorityColor(_ priority: Double) -> Color {
        if priority >= 0.7 { return .red }
        if priority >= 0.4 { return .orange }
        return .green
    }

    private func categoryBadge(_ category: String) -> some View {
        Text(category.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(categoryColor(category).opacity(0.15), in: Capsule())
            .foregroundStyle(categoryColor(category))
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "pipeline": return .blue
        case "time": return .orange
        case "pattern": return .purple
        case "content": return .green
        default: return .secondary
        }
    }
}
