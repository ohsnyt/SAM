// GrowDashboardView.swift
// SAM
//
// "Grow" sidebar section — Social Profile Analysis and Content hub.
// Displays one expandable section per connected social platform, each
// showing a score gauge when collapsed and the full analysis when expanded.

import SwiftUI
import TipKit

// MARK: - Platform Metadata

/// Display metadata for a known social platform.
struct SocialPlatformMeta {
    let displayName: String
    let icon: String       // SF Symbol
    let iconColor: Color

    static func from(_ platform: String) -> SocialPlatformMeta {
        switch platform {
        case "linkedIn":
            return SocialPlatformMeta(displayName: "LinkedIn",  icon: "person.crop.rectangle.stack", iconColor: .blue)
        case "facebook":
            return SocialPlatformMeta(displayName: "Facebook",  icon: "person.2.circle",             iconColor: Color(red: 0.23, green: 0.35, blue: 0.60))
        case "instagram":
            return SocialPlatformMeta(displayName: "Instagram", icon: "camera.circle",               iconColor: .pink)
        case "x":
            return SocialPlatformMeta(displayName: "X",         icon: "at.circle",                   iconColor: .primary)
        case "substack":
            return SocialPlatformMeta(displayName: "Substack",  icon: "newspaper.fill",              iconColor: .orange)
        default:
            return SocialPlatformMeta(displayName: platform.capitalized, icon: "globe.americas",     iconColor: .secondary)
        }
    }
}

// MARK: - Main View

struct GrowDashboardView: View {

    // MARK: - State

    @State private var selectedTab = 0
    @State private var analyses: [ProfileAnalysisDTO] = []
    @State private var isAnalyzing = false
    @State private var copiedPrompt = false
    @State private var expandedPlatforms: Set<String> = []   // which DisclosureGroups are open

    // Content Ideas sheet
    @State private var selectedContentTopic: ContentTopic?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            TipView(GrowDashboardTip())
                .tipViewStyle(SAMTipViewStyle())
                .padding(.horizontal)
                .padding(.top, 12)

            // Segmented tab picker
            Picker("", selection: $selectedTab) {
                Text("Profile").tag(0)
                Text("Content").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            switch selectedTab {
            case 0: profileTab
            case 1: contentTab
            default: EmptyView()
            }
        }
        .navigationTitle("Grow")
        .toolbar {
            if selectedTab == 0 {
                ToolbarItem(placement: .primaryAction) {
                    toolbarProfileButton
                }
            }
            ToolbarItem(placement: .primaryAction) {
                GuideButton(articleID: "grow.lead-acquisition")
            }
        }
        .task {
            await loadAnalyses()
            // Auto-expand single platform for convenience
            if analyses.count == 1, let first = analyses.first {
                expandedPlatforms.insert(first.platform)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .samProfileAnalysisDidUpdate)) { _ in
            Task { await loadAnalyses() }
        }
        .sheet(item: $selectedContentTopic) { topic in
            ContentDraftSheet(
                topic: topic.topic,
                keyPoints: topic.keyPoints,
                suggestedTone: topic.suggestedTone,
                complianceNotes: nil,
                sourceOutcomeID: nil,
                onPosted: { selectedContentTopic = nil },
                onCancel: { selectedContentTopic = nil }
            )
        }
    }

    // MARK: - Profile Tab

    @ViewBuilder
    private var profileTab: some View {
        if isAnalyzing && analyses.isEmpty {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Analyzing your profile\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if analyses.isEmpty {
            ContentUnavailableView {
                Label("No Profile Analysis Yet", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("Import your LinkedIn data or connect your Substack in Settings to get a personalized profile analysis with improvement suggestions.")
            } actions: {
                Button("Open Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(analyses, id: \.platform) { analysis in
                        platformSection(analysis)
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Per-Platform DisclosureGroup

    @ViewBuilder
    private func platformSection(_ a: ProfileAnalysisDTO) -> some View {
        let meta = SocialPlatformMeta.from(a.platform)
        let isExpanded = Binding(
            get: { expandedPlatforms.contains(a.platform) },
            set: { open in
                if open { expandedPlatforms.insert(a.platform) }
                else     { expandedPlatforms.remove(a.platform) }
            }
        )

        DisclosureGroup(isExpanded: isExpanded) {
            // Expanded: full analysis content
            VStack(alignment: .leading, spacing: 20) {
                inlineAnalysisContent(a)
            }
            .padding(.top, 12)
        } label: {
            // Collapsed header: platform icon + name + mini score ring
            HStack(spacing: 12) {
                Image(systemName: meta.icon)
                    .font(.title3)
                    .foregroundStyle(meta.iconColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.displayName)
                        .font(.headline)
                    Text("Last analyzed \(a.analysisDate, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Mini score ring (always visible in header)
                miniScoreRing(a)
            }
            .padding(.vertical, 4)
        }
        .padding()
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(scoreColor(a).opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Mini Score Ring (shown in collapsed header)

    private func miniScoreRing(_ a: ProfileAnalysisDTO) -> some View {
        ZStack {
            Circle()
                .stroke(scoreColor(a).opacity(0.15), lineWidth: 5)
                .frame(width: 44, height: 44)
            Circle()
                .trim(from: 0, to: CGFloat(a.overallScore) / 100)
                .stroke(scoreColor(a), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(a.overallScore)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor(a))
                Text("/ 100")
                    .font(.system(size: 7, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Inline Analysis Content

    @ViewBuilder
    private func inlineAnalysisContent(_ a: ProfileAnalysisDTO) -> some View {
        // Large score indicator
        scoreIndicator(a)

        // What's Working Well
        if !a.praise.isEmpty {
            analysisSection(title: "What's Working Well", icon: "star.fill", color: .green) {
                praiseSection(a)
            }
        }

        // Suggested Improvements
        let sortedImprovements = a.improvements.sorted {
            priorityOrder($0.priority) < priorityOrder($1.priority)
        }
        if !sortedImprovements.isEmpty {
            analysisSection(title: "Suggested Improvements", icon: "arrow.up.circle.fill", color: .orange) {
                improvementsSection(sortedImprovements)
            }
        }

        // Content Strategy
        if let cs = a.contentStrategy {
            analysisSection(title: "Content Strategy", icon: "doc.text.fill", color: .purple) {
                contentStrategySection(cs)
            }
        }

        // Network Health / Audience & Reach
        let networkTitle = a.platform == "substack" ? "Audience & Reach" : "Network Health"
        let networkIcon = a.platform == "substack" ? "person.wave.2.fill" : "person.3.fill"
        analysisSection(title: networkTitle, icon: networkIcon, color: .blue) {
            networkHealthSection(a)
        }

        // Changes Since Last Analysis
        if let changes = a.changesSinceLastAnalysis, !changes.isEmpty {
            analysisSection(title: "Since Last Analysis", icon: "arrow.triangle.2.circlepath", color: .teal) {
                changesSection(changes)
            }
        }

        // Deep Dive Prompt
        if let ep = a.externalPrompt {
            analysisSection(title: "Get Deeper Insights", icon: "rectangle.and.paperclip", color: .indigo) {
                externalPromptSection(ep)
            }
        }
    }

    // MARK: - Score Indicator (large, inside expanded section)

    private func scoreIndicator(_ a: ProfileAnalysisDTO) -> some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(scoreColor(a).opacity(0.15), lineWidth: 12)
                    .frame(width: 88, height: 88)
                Circle()
                    .trim(from: 0, to: CGFloat(a.overallScore) / 100)
                    .stroke(scoreColor(a), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 88, height: 88)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(a.overallScore)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(scoreColor(a))
                    Text("/ 100")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(scoreLabel(a)).font(.title3.weight(.semibold))
                Text(scoreDescription(a)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Score Helpers

    private func scoreColor(_ a: ProfileAnalysisDTO) -> Color {
        switch a.overallScore {
        case 76...100: return .green
        case 61...75:  return .yellow
        case 41...60:  return .orange
        default:       return .red
        }
    }

    private func scoreLabel(_ a: ProfileAnalysisDTO) -> String {
        switch a.overallScore {
        case 76...100: return "Strong Profile"
        case 61...75:  return "Good Progress"
        case 41...60:  return "Room to Grow"
        default:       return "Needs Attention"
        }
    }

    private func scoreDescription(_ a: ProfileAnalysisDTO) -> String {
        switch a.overallScore {
        case 76...100: return "Your profile is well-optimized for your business goals."
        case 61...75:  return "Solid foundation — a few targeted improvements can make a real difference."
        case 41...60:  return "Several opportunities to strengthen your presence and visibility."
        default:       return "Priority improvements here will have an outsized impact."
        }
    }

    // MARK: - Praise Section

    private func praiseSection(_ a: ProfileAnalysisDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(a.praise) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.category)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.message).font(.callout)
                        if let metric = item.metric {
                            Text(metric).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Improvements Section

    private func improvementsSection(_ items: [ImprovementSuggestionDTO]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(items) { item in
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
                    Text(item.suggestion).font(.callout.weight(.semibold))
                    Text(item.rationale).font(.caption).foregroundStyle(.secondary)
                    if let example = item.exampleOrPrompt {
                        Text(example)
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.75))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
    }

    private func priorityOrder(_ p: String) -> Int {
        switch p { case "high": return 0; case "low": return 2; default: return 1 }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high":  return .red
        case "low":   return .green
        default:      return .orange
        }
    }

    // MARK: - Content Strategy Section

    private func contentStrategySection(_ cs: ContentStrategyAssessmentDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cs.summary).font(.callout)
            if let freq = cs.postingFrequency      { labeledRow(label: "Posting Frequency", value: freq) }
            if let mix = cs.contentMix             { labeledRow(label: "Content Mix", value: mix) }
            if let eng = cs.engagementAssessment   { labeledRow(label: "Engagement", value: eng) }
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
                            Text(topic).font(.caption)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Network Health Section

    private func networkHealthSection(_ a: ProfileAnalysisDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let nh = a.networkHealth
            Text(nh.summary).font(.callout)
            if let trend = nh.growthTrend              { labeledRow(label: "Growth Trend", value: trend) }
            if let end = nh.endorsementInsight         { labeledRow(label: "Endorsements", value: end) }
            if let rec = nh.recommendationReciprocity  { labeledRow(label: "Recommendations", value: rec) }
        }
    }

    // MARK: - Changes Section

    private func changesSection(_ changes: [ChangeNoteDTO]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(changes) { change in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: change.isImprovement ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(change.isImprovement ? .green : .orange)
                        .imageScale(.small)
                    Text(change.description).font(.callout)
                }
            }
        }
    }

    // MARK: - External Prompt Section

    private func externalPromptSection(_ ep: ExternalAIPromptDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !ep.context.isEmpty {
                Text(ep.context).font(.caption).foregroundStyle(.secondary)
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

    // MARK: - Section Container

    private func analysisSection<Content: View>(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).imageScale(.medium)
                Text(title).font(.subheadline.weight(.semibold))
            }
            content().padding(.leading, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func labeledRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption)
        }
    }

    // MARK: - Content Tab

    @ViewBuilder
    private var contentTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                ContentCadenceSection()
                    .padding(.horizontal)
                    .padding(.vertical, 12)

                Divider().padding(.horizontal)

                if let digest = StrategicCoordinator.shared.latestDigest,
                   !digest.contentSuggestions.isEmpty {
                    contentIdeasSection(digest.contentSuggestions)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "lightbulb")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No Content Ideas Yet")
                            .font(.headline)
                        Text("Content ideas are generated from your business goals, recent meetings, and note topics.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)

                        Button {
                            Task { await StrategicCoordinator.shared.generateDigest(type: .onDemand) }
                        } label: {
                            Label("Generate Ideas", systemImage: "sparkles")
                        }
                        .disabled(StrategicCoordinator.shared.generationStatus == .generating)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
        }
    }

    private func contentIdeasSection(_ raw: String) -> some View {
        let structuredTopics: [ContentTopic]? = {
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([ContentTopic].self, from: data)
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.text.fill").foregroundStyle(.purple)
                Text("Content Ideas").font(.headline)
            }

            if let topics = structuredTopics {
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
                                Text(topic.topic).font(.callout).fontWeight(.medium)
                                if !topic.keyPoints.isEmpty {
                                    Text(topic.keyPoints.joined(separator: " \u{2022} "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                let titles = raw.components(separatedBy: "; ").filter { !$0.isEmpty }
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(title).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Toolbar Button

    @ViewBuilder
    private var toolbarProfileButton: some View {
        let coordinator = LinkedInImportCoordinator.shared
        HStack(spacing: 8) {
            if coordinator.profileAnalysisStatus == .analyzing || isAnalyzing {
                ProgressView().controlSize(.mini)
            }
            Button("Re-Analyze") {
                Task {
                    isAnalyzing = true
                    async let linkedInTask: () = coordinator.runProfileAnalysis()
                    async let substackTask: () = SubstackImportCoordinator.shared.runProfileAnalysis()
                    async let facebookTask: () = FacebookImportCoordinator.shared.runProfileAnalysis()
                    _ = await (linkedInTask, substackTask, facebookTask)
                    await FacebookImportCoordinator.shared.runCrossPlatformAnalysis()
                    await loadAnalyses()
                    isAnalyzing = false
                }
            }
            .disabled(coordinator.profileAnalysisStatus == .analyzing || isAnalyzing)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Data Loading

    private func loadAnalyses() async {
        analyses = await BusinessProfileService.shared.profileAnalyses()
    }
}

// MARK: - Preview

#Preview {
    GrowDashboardView()
        .frame(width: 700, height: 600)
}
