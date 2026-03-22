//
//  BusinessDashboardView.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase R: Pipeline Intelligence
//
//  Container view with segmented picker for Client and Recruiting pipelines.
//

import SwiftUI
import TipKit

struct BusinessDashboardView: View {

    @State private var tracker = PipelineTracker.shared
    @State private var strategic = StrategicCoordinator.shared
    @State private var selectedTab = 0  // 0 = Strategic (default)
    @State private var isFinancial = true

    /// Tab definitions that adapt to practice type.
    private var tabs: [(label: String, tag: Int)] {
        if isFinancial {
            return [("Strategic", 0), ("Pipeline", 1), ("Production", 2), ("Goals", 3)]
        } else {
            return [("Strategic", 0), ("Pipeline", 1), ("Goals", 3)]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Business Health Summary + Tab Picker (always visible, never scrolls)
            VStack(spacing: 0) {
                businessHealthSummary
                    .padding()

                TipView(BusinessDashboardTip())
                    .tipViewStyle(SAMTipViewStyle())
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                Divider()

                Picker("Section", selection: $selectedTab) {
                    ForEach(tabs, id: \.tag) { tab in
                        Text(tab.label).tag(tab.tag)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()
            }

            // Tab content
            ScrollView {
                switch selectedTab {
                case 0:
                    StrategicInsightsView(coordinator: strategic)
                case 1:
                    PipelineDashboardView(tracker: tracker)
                case 2:
                    ProductionDashboardView(tracker: tracker)
                case 3:
                    GoalProgressView()
                default:
                    EmptyView()
                }
            }
        }
        .navigationTitle("Business")
        .toolbar {
            ToolbarItem {
                Button {
                    tracker.refresh()
                    if selectedTab == 0 {
                        Task { await strategic.generateDigest(type: .onDemand) }
                        ScenarioProjectionEngine.shared.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh pipeline metrics")
            }
            ToolbarItem {
                GuideButton(articleID: "business.overview")
            }
        }
        .task {
            isFinancial = await BusinessProfileService.shared.isFinancialPractice()
        }
        .onAppear {
            tracker.refresh()
            FeatureAdoptionTracker.shared.recordUsage(.businessDashboard)
        }
        .onReceive(NotificationCenter.default.publisher(for: .samNavigateToStrategicInsights)) { _ in
            selectedTab = 0
        }
    }

    // MARK: - Business Health Summary

    private var businessHealthSummary: some View {
        let recruitTotal = tracker.recruitFunnel.reduce(0) { $0 + $1.count }
        let columnCount = isFinancial ? 4 : 2

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: columnCount), spacing: 12) {
            BusinessMetricCard(
                title: "Active Pipeline",
                value: "\(tracker.clientFunnel.leadCount + tracker.clientFunnel.applicantCount)",
                color: .blue
            )
            BusinessMetricCard(
                title: "Clients",
                value: "\(tracker.clientFunnel.clientCount)",
                color: .green
            )
            if isFinancial {
                BusinessMetricCard(
                    title: "Recruiting",
                    value: "\(recruitTotal)",
                    color: .teal
                )
                BusinessMetricCard(
                    title: "This Month",
                    value: formattedProduction,
                    color: .orange
                )
            }
        }
    }

    private var formattedProduction: String {
        let total = tracker.productionTotalPremium
        if total >= 1000 {
            return "$\(Int(total / 1000))k"
        } else if total > 0 {
            return "$\(Int(total))"
        }
        return "$0"
    }
}

// MARK: - Business Metric Card

private struct BusinessMetricCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .samFont(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(title)
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
