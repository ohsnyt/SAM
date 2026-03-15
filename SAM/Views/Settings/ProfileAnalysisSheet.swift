// ProfileAnalysisSheet.swift
// SAM
//
// Phase 7: LinkedIn Profile Analysis — Results Sheet (Spec §10.4)
//
// Displays the structured output from LinkedInProfileAnalystService:
// score indicator, praise, improvements, content strategy,
// network health, changes since last analysis, and deep-dive prompt.

import SwiftUI

struct ProfileAnalysisSheet: View {

    let analysis: ProfileAnalysisDTO
    let onRefresh: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var copiedPrompt = false

    // Sort improvements by priority (high → medium → low)
    private var sortedImprovements: [ImprovementSuggestionDTO] {
        analysis.improvements.sorted { lhs, rhs in
            priorityOrder(lhs.priority) < priorityOrder(rhs.priority)
        }
    }

    private func priorityOrder(_ p: String) -> Int {
        switch p { case "high": return 0; case "low": return 2; default: return 1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("LinkedIn Profile Analysis")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Score indicator
                    scoreIndicator

                    // What's Working Well
                    if !analysis.praise.isEmpty {
                        analysisSection(title: "What's Working Well", icon: "star.fill", color: .green) {
                            praiseSection
                        }
                    }

                    // Suggested Improvements
                    if !sortedImprovements.isEmpty {
                        analysisSection(title: "Suggested Improvements", icon: "arrow.up.circle.fill", color: .orange) {
                            improvementsSection
                        }
                    }

                    // Content Strategy
                    if let cs = analysis.contentStrategy {
                        analysisSection(title: "Content Strategy", icon: "doc.text.fill", color: .purple) {
                            contentStrategySection(cs)
                        }
                    }

                    // Network Health
                    analysisSection(title: "Network Health", icon: "person.3.fill", color: .blue) {
                        networkHealthSection
                    }

                    // Changes Since Last Analysis
                    if let changes = analysis.changesSinceLastAnalysis, !changes.isEmpty {
                        analysisSection(title: "Since Last Analysis", icon: "arrow.triangle.2.circlepath", color: .teal) {
                            changesSection(changes)
                        }
                    }

                    // Deep Dive Prompt
                    if let ep = analysis.externalPrompt {
                        analysisSection(title: "Get Deeper Insights", icon: "rectangle.and.paperclip", color: .indigo) {
                            externalPromptSection(ep)
                        }
                    }

                    // Footer
                    HStack {
                        Text("Last analyzed: \(analysis.analysisDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task {
                                isRefreshing = true
                                await onRefresh()
                                isRefreshing = false
                            }
                        } label: {
                            if isRefreshing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("Refreshing…")
                                }
                            } else {
                                Label("Refresh Analysis", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRefreshing)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 660, idealWidth: 700, minHeight: 500, idealHeight: 600)
    }

    // MARK: - Score Indicator

    private var scoreIndicator: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(scoreColor.opacity(0.15), lineWidth: 12)
                    .frame(width: 88, height: 88)

                Circle()
                    .trim(from: 0, to: CGFloat(analysis.overallScore) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 88, height: 88)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text("\(analysis.overallScore)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(scoreColor)
                    Text("/ 100")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(scoreLabel)
                    .font(.title3.weight(.semibold))
                Text(scoreDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var scoreColor: Color {
        switch analysis.overallScore {
        case 76...100: return .green
        case 61...75:  return .yellow
        case 41...60:  return .orange
        default:       return .red
        }
    }

    private var scoreLabel: String {
        switch analysis.overallScore {
        case 76...100: return "Strong Profile"
        case 61...75:  return "Good Progress"
        case 41...60:  return "Room to Grow"
        default:       return "Needs Attention"
        }
    }

    private var scoreDescription: String {
        switch analysis.overallScore {
        case 76...100: return "Your LinkedIn profile is well-optimized for your business goals."
        case 61...75:  return "Solid foundation — a few targeted improvements can make a real difference."
        case 41...60:  return "Several opportunities to strengthen your presence and visibility."
        default:       return "Priority improvements here will have an outsized impact."
        }
    }

    // MARK: - Praise

    private var praiseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(analysis.praise) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.category)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                        .fixedSize()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.message)
                            .font(.callout)
                        if let metric = item.metric {
                            Text(metric)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Improvements

    private var improvementsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sortedImprovements) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(priorityColor(item.priority))
                            .frame(width: 8, height: 8)

                        Text(item.category)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.12), in: Capsule())
                            .foregroundStyle(.orange)

                        Text(item.priority.capitalized)
                            .font(.caption)
                            .foregroundStyle(priorityColor(item.priority))
                    }

                    Text(item.suggestion)
                        .font(.callout.weight(.semibold))

                    Text(item.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let example = item.exampleOrPrompt {
                        Text(example)
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.75))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .topTrailing) {
                                CopyButton(text: example)
                                    .padding(6)
                            }
                    }
                }
                if item.id != sortedImprovements.last?.id {
                    Divider()
                }
            }
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high":  return .red
        case "low":   return .green
        default:      return .orange
        }
    }

    // MARK: - Content Strategy

    private func contentStrategySection(_ cs: ContentStrategyAssessmentDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cs.summary)
                .font(.callout)

            if let freq = cs.postingFrequency {
                labeledRow(label: "Posting Frequency", value: freq)
            }
            if let mix = cs.contentMix {
                labeledRow(label: "Content Mix", value: mix)
            }
            if let eng = cs.engagementAssessment {
                labeledRow(label: "Engagement", value: eng)
            }
            if !cs.topicSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Topic Suggestions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(cs.topicSuggestions, id: \.self) { topic in
                        HStack(spacing: 6) {
                            Image(systemName: "lightbulb.fill")
                                .imageScale(.small)
                                .foregroundStyle(.yellow)
                            Text(topic)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Network Health

    private var networkHealthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let nh = analysis.networkHealth
            Text(nh.summary).font(.callout)

            if let trend = nh.growthTrend {
                labeledRow(label: "Growth Trend", value: trend)
            }
            if let endorsement = nh.endorsementInsight {
                labeledRow(label: "Endorsements", value: endorsement)
            }
            if let reciprocity = nh.recommendationReciprocity {
                labeledRow(label: "Recommendations", value: reciprocity)
            }
        }
    }

    // MARK: - Changes Since Last

    private func changesSection(_ changes: [ChangeNoteDTO]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(changes) { change in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: change.isImprovement ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(change.isImprovement ? .green : .orange)
                        .imageScale(.small)
                    Text(change.description)
                        .font(.callout)
                }
            }
        }
    }

    // MARK: - External Prompt

    private func externalPromptSection(_ ep: ExternalAIPromptDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !ep.context.isEmpty {
                Text(ep.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(ep.prompt)
                .font(.caption)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)

            Button {
                ClipboardSecurity.copyPersistent(ep.prompt)
                withAnimation { copiedPrompt = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation { copiedPrompt = false }
                }
            } label: {
                Label(copiedPrompt ? "Copied!" : ep.copyButtonLabel,
                      systemImage: copiedPrompt ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(copiedPrompt ? .green : .indigo)
        }
    }

    // MARK: - Helpers

    private func analysisSection<Content: View>(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .imageScale(.medium)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            content()
                .padding(.leading, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func labeledRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
    }
}
