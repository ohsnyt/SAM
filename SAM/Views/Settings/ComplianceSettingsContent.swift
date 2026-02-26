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

    @AppStorage("complianceCheckingEnabled") private var masterEnabled = true
    @AppStorage("complianceCat_guarantees") private var catGuarantees = true
    @AppStorage("complianceCat_returns") private var catReturns = true
    @AppStorage("complianceCat_promises") private var catPromises = true
    @AppStorage("complianceCat_comparativeClaims") private var catComparative = true
    @AppStorage("complianceCat_suitability") private var catSuitability = true
    @AppStorage("complianceCat_specificAdvice") private var catSpecificAdvice = true
    @AppStorage("complianceCustomKeywords") private var customKeywords = ""
    @AppStorage("complianceAuditRetentionDays") private var retentionDays = 90

    @State private var auditCount: Int = 0
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Master toggle
            Toggle("Enable compliance checking", isOn: $masterEnabled)

            if masterEnabled {
                // Category toggles
                VStack(alignment: .leading, spacing: 8) {
                    Text("Categories")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    categoryToggle(.guarantees, isOn: $catGuarantees)
                    categoryToggle(.returns, isOn: $catReturns)
                    categoryToggle(.promises, isOn: $catPromises)
                    categoryToggle(.comparativeClaims, isOn: $catComparative)
                    categoryToggle(.suitability, isOn: $catSuitability)
                    categoryToggle(.specificAdvice, isOn: $catSpecificAdvice)
                }

                // Custom keywords
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Keywords")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("One phrase per line. Matched as Specific Advice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $customKeywords)
                        .font(.caption)
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
                        .font(.subheadline)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Clear Audit Log", role: .destructive) {
                            showClearConfirmation = true
                        }
                        .font(.caption)
                        .disabled(auditCount == 0)
                    }
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
    }

    // MARK: - Helpers

    private func categoryToggle(_ category: ComplianceCategory, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.caption)
                    .foregroundStyle(category.color)
                    .frame(width: 16)
                Text(category.displayName)
                    .font(.callout)
            }
        }
    }

    private func refreshCount() {
        auditCount = (try? ComplianceAuditRepository.shared.count()) ?? 0
    }
}
