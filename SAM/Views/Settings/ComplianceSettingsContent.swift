//
//  ComplianceSettingsContent.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase Z: Compliance Awareness
//
//  Settings content for compliance scanning configuration.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ComplianceSettings")

struct ComplianceSettingsContent: View {

    let practiceType: PracticeType

    @AppStorage("complianceCustomKeywords") private var customKeywords = ""
    @AppStorage("complianceAuditRetentionDays") private var retentionDays = 90

    @State private var auditCount: Int = 0
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Compliance profile description based on practice type
            complianceProfileSection

            Divider()

            // Custom keywords (available for all practice types)
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom Flagging")
                    .samFont(.subheadline)
                    .fontWeight(.medium)
                Text("Add phrases you want SAM to watch for in your recordings and drafts. One per line.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $customKeywords)
                    .samFont(.caption)
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            // Audit section
            VStack(alignment: .leading, spacing: 8) {
                Text("Audit Trail")
                    .samFont(.subheadline)
                    .fontWeight(.medium)

                Picker("Retention", selection: $retentionDays) {
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)

                HStack {
                    Text("\(auditCount) audit entries")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Clear Audit Log", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .samFont(.caption)
                    .disabled(auditCount == 0)
                }
            }
        }
        .task {
            refreshCount()
        }
        .alert("Clear Audit Log?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                try? ComplianceAuditRepository.shared.clearAll()
                refreshCount()
            }
        } message: {
            Text("This will permanently delete all \(auditCount) compliance audit entries. This cannot be undone.")
        }
        .dismissOnLock(isPresented: $showClearConfirmation)
    }

    // MARK: - Compliance Profile Section

    @ViewBuilder
    private var complianceProfileSection: some View {
        switch practiceType {
        case .wfgFinancialAdvisor:
            VStack(alignment: .leading, spacing: 8) {
                Label("WFG Compliance Active", systemImage: "checkmark.shield.fill")
                    .samFont(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)

                Text("Compliance checking is based on the WFG U.S. Agent Agreement Packet (April 2025). SAM monitors your recordings and drafts for potential compliance issues including guarantees, rebating, misrepresentation, twisting, churning, and other prohibited practices.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This tool is designed to assist you as an agent, but you remain fully responsible for all compliance matters. When in doubt, consult your SMD or WFGIA Compliance.")
                    .samFont(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .italic()
            }

        case .general:
            VStack(alignment: .leading, spacing: 8) {
                Label("No Industry Compliance Rules", systemImage: "shield.slash")
                    .samFont(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Text("No industry-specific compliance rules are applied. SAM will only flag clearly deceptive or misleading statements. You can add custom phrases below to watch for specific terms relevant to your work.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    private func refreshCount() {
        auditCount = (try? ComplianceAuditRepository.shared.count()) ?? 0
    }
}
