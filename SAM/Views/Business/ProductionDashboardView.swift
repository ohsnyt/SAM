//
//  ProductionDashboardView.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase S: Production Tracking
//
//  Dashboard view showing production metrics: status overview, product mix,
//  pending aging, and window picker.
//

import SwiftUI

struct ProductionDashboardView: View {

    @Bindable var tracker: PipelineTracker

    var body: some View {
        VStack(spacing: 16) {
            // Status overview cards
            statusOverview

            // Product mix
            if !tracker.productionByType.isEmpty {
                productMixSection
            }

            // Window picker
            windowPicker

            // Pending aging
            if !tracker.productionPendingAging.isEmpty {
                pendingAgingSection
            }

            // All records
            if !tracker.productionAllRecords.isEmpty {
                allRecordsSection
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Status Overview

    private var statusOverview: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Production Overview")
                    .font(.headline)
                Spacer()
                Text(tracker.productionTotalPremium, format: .currency(code: "USD"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {
                ForEach(tracker.productionByStatus) { summary in
                    VStack(spacing: 4) {
                        Image(systemName: summary.status.icon)
                            .font(.title3)
                            .foregroundStyle(summary.status.color)

                        Text("\(summary.count)")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text(summary.status.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if summary.totalPremium > 0 {
                            Text(summary.totalPremium, format: .currency(code: "USD"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(summary.status.color.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Product Mix

    private var productMixSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Product Mix")
                .font(.headline)

            ForEach(tracker.productionByType) { summary in
                HStack(spacing: 8) {
                    Image(systemName: summary.productType.icon)
                        .font(.caption)
                        .foregroundStyle(summary.productType.color)
                        .frame(width: 16)

                    Text(summary.productType.displayName)
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer()

                    Text("\(summary.count)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .monospacedDigit()

                    Text(summary.totalPremium, format: .currency(code: "USD"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Window Picker

    private var windowPicker: some View {
        HStack {
            Text("Production window:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Window", selection: $tracker.productionWindowDays) {
                Text("30 days").tag(30)
                Text("60 days").tag(60)
                Text("90 days").tag(90)
                Text("180 days").tag(180)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)
            .onChange(of: tracker.productionWindowDays) {
                tracker.refresh()
            }

            Spacer()
        }
    }

    // MARK: - All Records

    private var allRecordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All Production Records")
                .font(.headline)

            ForEach(tracker.productionAllRecords) { item in
                Button {
                    if let pid = item.personID {
                        NotificationCenter.default.post(
                            name: .samNavigateToPerson,
                            object: nil,
                            userInfo: ["personID": pid]
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.productType.icon)
                            .font(.caption)
                            .foregroundStyle(item.productType.color)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.personName)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(item.productType.displayName) · \(item.carrierName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(item.annualPremium, format: .currency(code: "USD"))
                            .font(.caption)
                            .monospacedDigit()

                        HStack(spacing: 3) {
                            Image(systemName: item.status.icon)
                                .font(.system(size: 9))
                            Text(item.status.displayName)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(item.status.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.status.color.opacity(0.12))
                        .clipShape(Capsule())

                        Text(item.submittedDate, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
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

    // MARK: - Pending Aging

    private var pendingAgingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Pending Submissions")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }

            ForEach(tracker.productionPendingAging) { item in
                Button {
                    if let pid = item.personID {
                        NotificationCenter.default.post(
                            name: .samNavigateToPerson,
                            object: nil,
                            userInfo: ["personID": pid]
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.productType.icon)
                            .font(.caption)
                            .foregroundStyle(item.productType.color)
                            .frame(width: 16)

                        Text(item.personName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(item.carrierName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()

                        Text(item.premium, format: .currency(code: "USD"))
                            .font(.caption)
                            .monospacedDigit()

                        Text("\(item.daysPending)d pending")
                            .font(.caption)
                            .foregroundStyle(item.daysPending > 30 ? .red : .orange)
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
}
