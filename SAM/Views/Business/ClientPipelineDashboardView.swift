//
//  ClientPipelineDashboardView.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase R: Pipeline Intelligence
//
//  Full client pipeline dashboard: funnel, conversion rates, velocity,
//  time-in-stage, stuck callouts, and recent transitions timeline.
//

import SwiftUI

struct ClientPipelineDashboardView: View {

    @Bindable var tracker: PipelineTracker

    var body: some View {
        VStack(spacing: 16) {
            // Funnel visualization
            funnelSection

            // Metrics grid
            metricsGrid

            // Window picker
            windowPicker

            // Stuck callouts
            if !tracker.clientStuckPeople.isEmpty {
                stuckSection
            }

            // Recent transitions
            if !tracker.recentClientTransitions.isEmpty {
                recentTransitionsSection
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Funnel

    private var funnelSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Funnel")
                    .font(.headline)
                Spacer()
                Text("\(tracker.clientFunnel.total) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let maxCount = max(
                1,
                max(tracker.clientFunnel.leadCount,
                    max(tracker.clientFunnel.applicantCount,
                        tracker.clientFunnel.clientCount))
            )

            HStack(spacing: 8) {
                funnelBar(
                    label: "Lead",
                    count: tracker.clientFunnel.leadCount,
                    maxCount: maxCount,
                    color: RoleBadgeStyle.forBadge("Lead").color
                )

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                funnelBar(
                    label: "Applicant",
                    count: tracker.clientFunnel.applicantCount,
                    maxCount: maxCount,
                    color: RoleBadgeStyle.forBadge("Applicant").color
                )

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                funnelBar(
                    label: "Client",
                    count: tracker.clientFunnel.clientCount,
                    maxCount: maxCount,
                    color: RoleBadgeStyle.forBadge("Client").color
                )
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func funnelBar(label: String, count: Int, maxCount: Int, color: Color) -> some View {
        VStack(spacing: 6) {
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)

            GeometryReader { geo in
                let fraction = CGFloat(count) / CGFloat(maxCount)
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.25))
                    .frame(height: geo.size.height)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .frame(height: geo.size.height * max(0.05, fraction))
                    }
            }
            .frame(height: 60)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Metrics Grid

    private var metricsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            metricCard(
                title: "Lead → Applicant",
                value: formatPercent(tracker.clientConversionRates.leadToApplicant),
                icon: "arrow.right.circle",
                color: .orange
            )

            metricCard(
                title: "Applicant → Client",
                value: formatPercent(tracker.clientConversionRates.applicantToClient),
                icon: "arrow.right.circle.fill",
                color: .green
            )

            metricCard(
                title: "Avg Days as Lead",
                value: tracker.clientTimeInStage.avgDaysAsLead > 0
                    ? "\(Int(tracker.clientTimeInStage.avgDaysAsLead))d" : "—",
                icon: "clock",
                color: .orange
            )

            metricCard(
                title: "Velocity",
                value: String(format: "%.1f/wk", tracker.clientVelocity),
                icon: "gauge.with.dots.needle.67percent",
                color: .blue
            )
        }
    }

    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Window Picker

    private var windowPicker: some View {
        HStack {
            Text("Conversion window:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Window", selection: $tracker.configWindowDays) {
                Text("30 days").tag(30)
                Text("60 days").tag(60)
                Text("90 days").tag(90)
                Text("180 days").tag(180)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)
            .onChange(of: tracker.configWindowDays) {
                tracker.refresh()
            }

            Spacer()
        }
    }

    // MARK: - Stuck Section

    private var stuckSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Needs Attention")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }

            ForEach(tracker.clientStuckPeople) { item in
                Button {
                    NotificationCenter.default.post(
                        name: .samNavigateToPerson,
                        object: nil,
                        userInfo: ["personID": item.personID]
                    )
                } label: {
                    HStack(spacing: 8) {
                        let style = RoleBadgeStyle.forBadge(item.stage)
                        Image(systemName: style.icon)
                            .font(.caption)
                            .foregroundStyle(style.color)

                        Text(item.personName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer()

                        Text("stuck \(item.daysStuck)d as \(item.stage)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Recent Transitions

    private var recentTransitionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Transitions")
                .font(.headline)

            ForEach(tracker.recentClientTransitions) { t in
                Button {
                    if let pid = t.personID {
                        NotificationCenter.default.post(
                            name: .samNavigateToPerson,
                            object: nil,
                            userInfo: ["personID": pid]
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(t.personName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer()

                        if t.fromStage.isEmpty {
                            Text("→ \(t.toStage)")
                                .font(.caption)
                                .foregroundStyle(RoleBadgeStyle.forBadge(t.toStage).color)
                        } else if t.toStage.isEmpty {
                            Text("\(t.fromStage) → exited")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(t.fromStage) → \(t.toStage)")
                                .font(.caption)
                                .foregroundStyle(RoleBadgeStyle.forBadge(t.toStage).color)
                        }

                        Text(t.date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func formatPercent(_ value: Double) -> String {
        if value == 0 { return "—" }
        return String(format: "%.0f%%", value * 100)
    }
}
