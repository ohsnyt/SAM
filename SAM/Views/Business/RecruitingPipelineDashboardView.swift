//
//  RecruitingPipelineDashboardView.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase R: Pipeline Intelligence
//
//  Recruiting pipeline dashboard: 7-stage funnel, licensing rate,
//  mentoring cadence alerts with click-through navigation.
//

import SwiftUI

struct RecruitingPipelineDashboardView: View {

    @Bindable var tracker: PipelineTracker

    var body: some View {
        VStack(spacing: 16) {
            // 7-stage funnel
            funnelSection

            // Licensing rate hero metric
            licensingRateCard

            // Mentoring cadence
            if !tracker.recruitMentoringAlerts.isEmpty {
                mentoringSection
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Funnel

    private var funnelSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Recruiting Funnel")
                    .font(.headline)
                Spacer()
                let total = tracker.recruitFunnel.reduce(0) { $0 + $1.count }
                Text("\(total) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let maxCount = max(1, tracker.recruitFunnel.map(\.count).max() ?? 1)

            LazyVGrid(columns: Array(
                repeating: GridItem(.flexible(), spacing: 4),
                count: RecruitingStageKind.allCases.count
            ), spacing: 8) {
                ForEach(tracker.recruitFunnel) { summary in
                    VStack(spacing: 4) {
                        Text("\(summary.count)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(summary.stage.color)

                        GeometryReader { geo in
                            let fraction = CGFloat(summary.count) / CGFloat(maxCount)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(summary.stage.color.opacity(0.2))
                                .frame(height: geo.size.height)
                                .overlay(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(summary.stage.color)
                                        .frame(height: geo.size.height * max(0.05, fraction))
                                }
                        }
                        .frame(height: 50)

                        Image(systemName: summary.stage.icon)
                            .font(.caption2)
                            .foregroundStyle(summary.stage.color)

                        Text(summary.stage.rawValue)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Licensing Rate

    private var licensingRateCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.purple)
                Text("Licensing Rate")
                    .font(.headline)
            }

            Text(tracker.recruitLicensingRate > 0
                ? String(format: "%.0f%%", tracker.recruitLicensingRate * 100)
                : "—")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.purple)

            Text("Licensed or beyond")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Mentoring Alerts

    private var mentoringSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "bell.badge")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Mentoring Overdue")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }

            ForEach(tracker.recruitMentoringAlerts) { alert in
                HStack(spacing: 8) {
                    Button {
                        NotificationCenter.default.post(
                            name: .samNavigateToPerson,
                            object: nil,
                            userInfo: ["personID": alert.personID]
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: alert.stage.icon)
                                .font(.caption)
                                .foregroundStyle(alert.stage.color)

                            Text(alert.personName)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(alert.stage.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(alert.stage.color.opacity(0.15))
                                .foregroundStyle(alert.stage.color)
                                .clipShape(Capsule())

                            Spacer()

                            Text("\(alert.daysSinceContact)d overdue")
                                .font(.caption)
                                .foregroundStyle(alert.daysSinceContact > 21 ? .red : .orange)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        try? PipelineRepository.shared.updateMentoringContact(personID: alert.personID)
                        tracker.refresh()
                    } label: {
                        Label("Log", systemImage: "hand.wave")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
