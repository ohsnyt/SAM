//
//  ScenarioProjectionsView.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase Y: Scenario Projections
//
//  Displays 5 projection cards (2-column grid) with 3/6/12 month horizons,
//  trend badges, and confidence ranges. Embedded in StrategicInsightsView.
//

import SwiftUI

struct ScenarioProjectionsView: View {

    var engine: ScenarioProjectionEngine

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.blue)
                Text("Scenario Projections")
                    .font(.headline)
                Spacer()
                Text("Based on 90-day trailing pace")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if engine.projections.isEmpty {
                Text("No projection data yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(engine.projections) { projection in
                        projectionCard(projection)
                    }
                }
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Projection Card

    private func projectionCard(_ projection: ScenarioProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Category header + trend
            HStack(spacing: 6) {
                Image(systemName: projection.category.icon)
                    .foregroundStyle(categoryColor(projection.category))
                    .font(.callout)

                Text(projection.category.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                trendBadge(projection.trend)
            }

            if !projection.hasEnoughData {
                Text("Limited data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            // 3-column horizons
            HStack(spacing: 0) {
                ForEach(projection.points) { point in
                    VStack(spacing: 2) {
                        Text("\(point.months)mo")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(formatValue(point.mid, category: projection.category))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Text("\(formatValue(point.low, category: projection.category))–\(formatValue(point.high, category: projection.category))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Trend Badge

    private func trendBadge(_ trend: ProjectionTrend) -> some View {
        HStack(spacing: 2) {
            Image(systemName: trendIcon(trend))
                .font(.caption2)
            Text(trendLabel(trend))
                .font(.caption2)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(trendColor(trend).opacity(0.15), in: Capsule())
        .foregroundStyle(trendColor(trend))
    }

    // MARK: - Formatting

    private func formatValue(_ value: Double, category: ProjectionCategory) -> String {
        if category.isCurrency {
            return formatCurrency(value)
        }
        return "\(Int(value.rounded()))"
    }

    private func formatCurrency(_ value: Double) -> String {
        if value >= 1_000_000 {
            return "$\(String(format: "%.1f", value / 1_000_000))M"
        } else if value >= 1_000 {
            return "$\(String(format: "%.0f", value / 1_000))K"
        } else {
            return "$\(Int(value.rounded()))"
        }
    }

    private func categoryColor(_ category: ProjectionCategory) -> Color {
        switch category {
        case .clientPipeline: return .green
        case .recruiting:     return .teal
        case .revenue:        return .purple
        case .meetings:       return .orange
        case .content:        return .pink
        }
    }

    private func trendIcon(_ trend: ProjectionTrend) -> String {
        switch trend {
        case .accelerating:     return "arrow.up.right"
        case .steady:           return "arrow.right"
        case .decelerating:     return "arrow.down.right"
        case .insufficientData: return "questionmark"
        }
    }

    private func trendLabel(_ trend: ProjectionTrend) -> String {
        switch trend {
        case .accelerating:     return "Up"
        case .steady:           return "Steady"
        case .decelerating:     return "Down"
        case .insufficientData: return "Low data"
        }
    }

    private func trendColor(_ trend: ProjectionTrend) -> Color {
        switch trend {
        case .accelerating:     return .green
        case .steady:           return .blue
        case .decelerating:     return .orange
        case .insufficientData: return .secondary
        }
    }
}
