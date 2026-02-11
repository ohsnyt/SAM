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

struct AwarenessView: View {
    
    // MARK: - Dependencies
    
    @State private var generator = InsightGenerator.shared
    @State private var peopleRepository = PeopleRepository.shared
    
    // MARK: - State
    
    @State private var selectedFilter: InsightFilter = .all
    @State private var searchText = ""
    @State private var insights: [GeneratedInsight] = []
    @State private var isGenerating = false
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            // Filter Bar
            filterBar
            
            Divider()
            
            // Insights List
            if insights.isEmpty {
                emptyState
            } else {
                insightsList
            }
        }
        .navigationTitle("Awareness")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    refreshInsights()
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isGenerating)
            }
        }
        .task {
            await loadInsights()
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Awareness Dashboard")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    if let lastGenerated = generator.lastGeneratedAt {
                        Text("Last updated \(lastGenerated, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No insights generated yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                // Status Badge
                statusBadge
            }
            
            // Quick Stats
            HStack(spacing: 20) {
                StatCard(
                    icon: "exclamationmark.triangle.fill",
                    label: "High Priority",
                    value: "\(highPriorityCount)",
                    color: .red
                )
                
                StatCard(
                    icon: "clock.fill",
                    label: "Follow-ups",
                    value: "\(followUpCount)",
                    color: .orange
                )
                
                StatCard(
                    icon: "sparkles",
                    label: "Opportunities",
                    value: "\(opportunityCount)",
                    color: .green
                )
            }
            .padding(.top, 8)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var statusBadge: some View {
        Group {
            switch generator.generationStatus {
            case .idle:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .generating:
                Label("Generating...", systemImage: "hourglass")
                    .foregroundStyle(.blue)
            case .success:
                Label("Complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
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
    
    private var insightsList: some View {
        ScrollView {
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
                            viewPerson(insight.personID)
                        }
                    )
                }
            }
            .padding()
        }
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
    
    private var filteredInsights: [GeneratedInsight] {
        var filtered = insights
        
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
                $0.body.lowercased().contains(query)
            }
        }
        
        return filtered
    }
    
    private var highPriorityCount: Int {
        insights.filter { $0.urgency == .high }.count
    }
    
    private var followUpCount: Int {
        insights.filter { $0.kind == .followUpNeeded }.count
    }
    
    private var opportunityCount: Int {
        insights.filter { $0.kind == .opportunity }.count
    }
    
    // MARK: - Actions
    
    private func loadInsights() async {
        isGenerating = true
        
        // Generate real insights from actual data
        insights = await generator.generateInsights()
        
        isGenerating = false
    }
    
    private func refreshInsights() {
        Task {
            await loadInsights()
        }
    }
    
    private func markInsightAsDone(_ insight: GeneratedInsight) {
        // Remove from list (in full implementation, update SamInsight model)
        insights.removeAll(where: { $0.id == insight.id })
        print("✅ [AwarenessView] Marked insight as done: \(insight.title)")
    }
    
    private func dismissInsight(_ insight: GeneratedInsight) {
        // Remove from list (in full implementation, mark as dismissed)
        insights.removeAll(where: { $0.id == insight.id })
        print("🗑️ [AwarenessView] Dismissed insight: \(insight.title)")
    }
    
    private func viewPerson(_ personID: UUID?) {
        guard let personID = personID else { return }
        // TODO: Navigate to person detail view
        print("👤 [AwarenessView] View person: \(personID)")
    }
}

// MARK: - Insight Card

private struct InsightCard: View {
    let insight: GeneratedInsight
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
                    
                    Text(insight.body)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    
                    // Actions
                    HStack(spacing: 12) {
                        Button(action: onMarkDone) {
                            Label("Mark Done", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        
                        if insight.personID != nil {
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

// MARK: - Stat Card

private struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
