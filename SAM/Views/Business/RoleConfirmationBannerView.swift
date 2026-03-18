//
//  RoleConfirmationBannerView.swift
//  SAM
//
//  Created on March 4, 2026.
//
//  Top-anchored overlay on the relationship graph for batch role confirmation.
//  Follows the same .regularMaterial pattern as the existing focusModeOverlay.
//

import SwiftUI

struct RoleConfirmationBannerView: View {
    @Bindable var engine: RoleDeductionEngine
    let onConfirm: () -> Void
    let onSkip: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack {
            VStack(spacing: 8) {
                // Header row
                HStack(spacing: 8) {
                    if let role = engine.currentBatchRole {
                        let style = RoleBadgeStyle.forBadge(role)
                        Image(systemName: style.icon)
                            .foregroundStyle(style.color)
                        Text("Suggested: \(role)")
                            .samFont(.callout, weight: .bold)
                        Text("(\(engine.currentBatch.count) people)")
                            .samFont(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if engine.totalBatchCount > 1 {
                        Text("Batch \(engine.currentBatchNumber) of \(engine.totalBatchCount)")
                            .samFont(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if engine.remainingAfterCurrentBatch > 0 {
                        Text("(\(engine.remainingAfterCurrentBatch) more to review)")
                            .samFont(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    // Navigation + actions
                    HStack(spacing: 6) {
                        Button {
                            engine.previousBatch()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(engine.currentBatchNumber <= 1)

                        Button {
                            engine.advanceBatch()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(engine.currentBatchNumber >= engine.totalBatchCount)

                        Button("Confirm All") {
                            onConfirm()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Skip Batch") {
                            onSkip()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Exit") {
                            onExit()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // Hint text
                Text("Tap a node to change its role, or confirm the batch.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 8)
            .padding(.horizontal, 8)

            Spacer()
        }
    }
}
