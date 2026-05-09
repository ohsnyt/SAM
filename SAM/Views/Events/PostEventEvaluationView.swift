//
//  PostEventEvaluationView.swift
//  SAM
//
//  Created on April 7, 2026.
//  Analytics dashboard shown on EventDetailView for completed events.
//  Displays chat engagement, feedback summary, content analysis,
//  and participant breakdown.
//

import SwiftUI

struct PostEventEvaluationView: View {

    let event: SamEvent
    @State private var showImportSheet = false
    @State private var expandedSections: Set<String> = ["summary", "engagement", "feedback", "content", "participants"]

    private var evaluation: EventEvaluation? { event.evaluation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header with import button
                header

                if let eval = evaluation, eval.status == .complete {
                    // Summary cards
                    summaryCards(eval)

                    // Overall AI summary
                    if let summary = eval.overallSummary {
                        collapsibleSection("summary", title: "Event Summary", icon: "text.quote") {
                            Text(summary)
                                .samFont(.body)
                                .textSelection(.enabled)
                                .padding(12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    // Engagement breakdown
                    collapsibleSection("engagement", title: "Participant Engagement", icon: "chart.bar") {
                        engagementBreakdown(eval)
                    }

                    // Content analysis
                    if eval.contentGapSummary != nil || eval.effectiveSectionsSummary != nil {
                        collapsibleSection("content", title: "Content Analysis", icon: "doc.text.magnifyingglass") {
                            contentAnalysis(eval)
                        }
                    }

                    // Feedback summary
                    if !eval.feedbackResponses.isEmpty {
                        collapsibleSection("feedback", title: "Feedback Responses", icon: "list.clipboard") {
                            feedbackSummary(eval)
                        }
                    }

                    // Top questions
                    if !eval.topQuestions.isEmpty {
                        collapsibleSection("questions", title: "Top Questions Asked", icon: "questionmark.bubble") {
                            topQuestionsList(eval)
                        }
                    }

                    // Participant cards
                    collapsibleSection("participants", title: "Individual Participants", icon: "person.3") {
                        participantCards(eval)
                    }
                } else if evaluation != nil {
                    // Import in progress or pending analysis
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(PostEventEvaluationCoordinator.shared.progressMessage)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                } else {
                    // No evaluation yet
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No evaluation data yet")
                            .samFont(.headline)
                        Text("Import your Zoom chat transcript and feedback form responses to analyze this workshop.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Import Workshop Materials") {
                            showImportSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showImportSheet) {
            EventEvaluationImportSheet(event: event)
        }
        .restoreOnUnlock(isPresented: $showImportSheet)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workshop Evaluation")
                    .samFont(.title3, weight: .semibold)
                if let date = event.evaluation?.analysisCompletedAt {
                    Text("Analyzed \(date.formatted(.relative(presentation: .named)))")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                showImportSheet = true
            } label: {
                Label(evaluation != nil ? "Update Data" : "Import Data", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Summary Cards

    private func summaryCards(_ eval: EventEvaluation) -> some View {
        HStack(spacing: 12) {
            metricCard(
                title: "Participants",
                value: "\(eval.totalAttendeeCount)",
                icon: "person.3",
                color: .blue
            )

            metricCard(
                title: "Avg Rating",
                value: eval.averageOverallRating.map { String(format: "%.1f", $0) } ?? "—",
                subtitle: eval.averageOverallRating != nil ? "/ 4.0" : nil,
                icon: "star",
                color: ratingColor(eval.averageOverallRating)
            )

            metricCard(
                title: "Conversion",
                value: eval.conversionRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                subtitle: "want follow-up",
                icon: "arrow.right.circle",
                color: .green
            )

            metricCard(
                title: "Responses",
                value: "\(eval.feedbackResponseCount)",
                subtitle: eval.totalAttendeeCount > 0 ? "\(Int(Double(eval.feedbackResponseCount) / Double(max(eval.totalAttendeeCount, 1)) * 100))% response rate" : nil,
                icon: "list.clipboard",
                color: .purple
            )
        }
    }

    private func metricCard(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        color: Color
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .samFont(.title2, weight: .bold)
            Text(title)
                .samFont(.caption)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .samFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Engagement Breakdown

    private func engagementBreakdown(_ eval: EventEvaluation) -> some View {
        let analyses = eval.participantAnalyses.filter { $0.inferredRole == .attendee }
        let high = analyses.filter { $0.engagementLevel == .high }.count
        let medium = analyses.filter { $0.engagementLevel == .medium }.count
        let low = analyses.filter { $0.engagementLevel == .low }.count
        let observer = analyses.filter { $0.engagementLevel == .observer }.count

        return VStack(alignment: .leading, spacing: 8) {
            engagementBar(label: "High", count: high, total: analyses.count, color: .green)
            engagementBar(label: "Medium", count: medium, total: analyses.count, color: .blue)
            engagementBar(label: "Low", count: low, total: analyses.count, color: .orange)
            engagementBar(label: "Observer", count: observer, total: analyses.count, color: .gray)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func engagementBar(label: String, count: Int, total: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .samFont(.caption)
                .frame(width: 60, alignment: .trailing)
            GeometryReader { geo in
                let width = total > 0 ? CGFloat(count) / CGFloat(total) * geo.size.width : 0
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(width, 2), height: 16)
            }
            .frame(height: 16)
            Text("\(count)")
                .samFont(.caption, weight: .medium)
                .frame(width: 24, alignment: .trailing)
        }
    }

    // MARK: - Content Analysis

    private func contentAnalysis(_ eval: EventEvaluation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let gaps = eval.contentGapSummary, !gaps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Areas to Improve")
                            .samFont(.subheadline, weight: .medium)
                    }
                    Text(gaps)
                        .samFont(.caption)
                        .textSelection(.enabled)
                }
            }

            if let effective = eval.effectiveSectionsSummary, !effective.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("What Worked Well")
                            .samFont(.subheadline, weight: .medium)
                    }
                    Text(effective)
                        .samFont(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Feedback Summary

    private func feedbackSummary(_ eval: EventEvaluation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Areas to strengthen (aggregated)
            let allAreas = eval.feedbackResponses.flatMap(\.areasToStrengthen)
            let areaCounts = Dictionary(grouping: allAreas, by: { $0 })
                .mapValues(\.count)
                .sorted { $0.value > $1.value }

            if !areaCounts.isEmpty {
                Text("Top Areas of Interest")
                    .samFont(.subheadline, weight: .medium)
                ForEach(areaCounts.prefix(5), id: \.key) { area, count in
                    HStack {
                        Text(area)
                            .samFont(.caption)
                        Spacer()
                        Text("\(count) attendee\(count == 1 ? "" : "s")")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Follow-up interest
            let yesCount = eval.feedbackResponses.filter { $0.wouldContinue == .yes }.count
            let maybeCount = eval.feedbackResponses.filter { $0.wouldContinue == .maybe }.count
            let noCount = eval.feedbackResponses.filter { $0.wouldContinue == .notNow }.count

            Text("Follow-Up Interest")
                .samFont(.subheadline, weight: .medium)
            HStack(spacing: 16) {
                followUpBadge(label: "Yes", count: yesCount, color: .green)
                followUpBadge(label: "Maybe", count: maybeCount, color: .orange)
                followUpBadge(label: "Not now", count: noCount, color: .gray)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func followUpBadge(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label): \(count)")
                .samFont(.caption)
        }
    }

    // MARK: - Top Questions

    private func topQuestionsList(_ eval: EventEvaluation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(eval.topQuestions.prefix(8).enumerated()), id: \.offset) { index, question in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .samFont(.caption, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(question)
                        .samFont(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Participant Cards

    private func participantCards(_ eval: EventEvaluation) -> some View {
        let sorted = eval.participantAnalyses
            .sorted { $0.messageCount > $1.messageCount }

        return VStack(spacing: 6) {
            ForEach(sorted) { analysis in
                participantCard(analysis)
            }
        }
    }

    private func participantCard(_ analysis: ChatParticipantAnalysis) -> some View {
        HStack(spacing: 10) {
            // Engagement indicator
            Circle()
                .fill(engagementColor(analysis.engagementLevel))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(analysis.displayName)
                        .samFont(.body, weight: .medium)

                    if analysis.inferredRole != .attendee {
                        Text(analysis.inferredRole.displayName)
                            .samFont(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.15), in: Capsule())
                    }

                    Spacer()

                    Text("\(analysis.messageCount) msg")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                // Topic interests
                if !analysis.topicInterests.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(analysis.topicInterests.prefix(3), id: \.self) { topic in
                            Text(topic)
                                .samFont(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.1), in: Capsule())
                        }
                    }
                }

                // Conversion signals
                if !analysis.conversionSignals.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "flame")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                        Text(analysis.conversionSignals.first ?? "")
                            .samFont(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Collapsible Section

    private func collapsibleSection(
        _ id: String,
        title: String,
        icon: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedSections.contains(id) {
                        expandedSections.remove(id)
                    } else {
                        expandedSections.insert(id)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                    Text(title)
                        .samFont(.headline)
                    Spacer()
                    Image(systemName: expandedSections.contains(id) ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedSections.contains(id) {
                content()
            }
        }
    }

    // MARK: - Helpers

    private func engagementColor(_ level: EngagementLevel) -> Color {
        switch level {
        case .high:     return .green
        case .medium:   return .blue
        case .low:      return .orange
        case .observer: return .gray
        }
    }

    private func ratingColor(_ rating: Double?) -> Color {
        guard let r = rating else { return .gray }
        if r >= 3.5 { return .green }
        if r >= 2.5 { return .blue }
        if r >= 1.5 { return .orange }
        return .red
    }
}
