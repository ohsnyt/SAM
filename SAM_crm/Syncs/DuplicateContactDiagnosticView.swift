//
//  DuplicateContactDiagnosticView.swift
//  SAM_crm
//
//  UI for diagnosing and fixing duplicate SamPerson records that share
//  the same contactIdentifier.
//

import SwiftUI
import SwiftData
import AppKit

struct DuplicateContactDiagnosticView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var report: DuplicateReport?
    @State private var isScanning: Bool = false
    @State private var isFixing: Bool = false
    @State private var fixResult: FixResult?
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    headerSection
                    
                    // Permission diagnosis
                    permissionSection
                    
                    // Scan results
                    if let report {
                        resultsSection(report: report)
                    }
                    
                    // Fix result
                    if let fixResult {
                        fixResultSection(result: fixResult)
                    }
                    
                    // Error
                    if let errorMessage {
                        errorSection(message: errorMessage)
                    }
                }
                .padding()
            }
            .navigationTitle("Duplicate Contact Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await scanForDuplicates()
            }
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Contact Identifier Duplicates", systemImage: "person.2.badge.gearshape")
                .font(.title2.bold())
            
            Text("This tool finds and fixes SamPerson records that incorrectly share the same contactIdentifier.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 16) {
                Button {
                    Task { await scanForDuplicates() }
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning || isFixing)
                
                if let report, !report.groups.isEmpty {
                    Button {
                        Task { await fixDuplicates() }
                    } label: {
                        Label("Fix All Duplicates", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isScanning || isFixing)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5)
    }
    
    // MARK: - Permission Section
    
    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Permission Race Condition Check", systemImage: "exclamationmark.triangle")
                .font(.headline)
            
            let diagnostics = ContactDuplicateDiagnostics(modelContext: modelContext)
            let permissionReport = diagnostics.checkPermissionRaceCondition()
            
            VStack(alignment: .leading, spacing: 8) {
                #if canImport(Contacts)
                if let status = permissionReport.currentStatus {
                    HStack {
                        Text("Permission Status:")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(status.description)
                            .fontWeight(.medium)
                    }
                }
                #endif
                
                Divider()
                
                ConfigToggleRow(
                    title: "Deduplicate on Every Launch",
                    isEnabled: permissionReport.deduplicateOnEveryLaunch,
                    recommendation: !permissionReport.deduplicateOnEveryLaunch ? "Enable this to fix the issue" : nil
                )
                
                ConfigToggleRow(
                    title: "Deduplicate After Permission Grant",
                    isEnabled: permissionReport.deduplicateAfterPermissionGrant,
                    recommendation: nil
                )
            }
            .padding(.horizontal)
            
            if permissionReport.hasRaceConditionRisk {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Race Condition Detected")
                            .font(.subheadline.bold())
                        Text("Contacts permission is already granted, but deduplication isn't running on every launch. Enable 'deduplicateOnEveryLaunch' in ContactSyncConfiguration.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5)
    }
    
    // MARK: - Results Section
    
    private func resultsSection(report: DuplicateReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if report.groups.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text("No Duplicates Found")
                            .font(.headline)
                        Text("All contactIdentifiers are unique.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                // Summary
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text("\(report.totalDuplicates) Duplicate ContactIdentifier(s)")
                            .font(.headline)
                        Text("Affecting \(report.totalAffectedPeople) people")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
                
                // Duplicate groups
                ForEach(Array(report.groups.enumerated()), id: \.offset) { index, group in
                    duplicateGroupCard(group: group, index: index + 1)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5)
    }
    
    private func duplicateGroupCard(group: DuplicateGroup, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Duplicate #\(index)")
                    .font(.headline)
                Spacer()
                Text("\(group.people.count) people")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Text("Contact ID: \(group.contactIdentifier)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            
            Divider()
            
            ForEach(group.people, id: \.id) { person in
                personCard(person: person)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func personCard(person: PersonInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(person.displayName)
                    .font(.subheadline.bold())
                Spacer()
                if !person.roleBadges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(person.roleBadges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
            }
            
            if let email = person.email {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 16) {
                Label("\(person.participationCount)", systemImage: "person.3")
                Label("\(person.coverageCount)", systemImage: "shield")
                Label("\(person.consentCount)", systemImage: "checkmark.seal")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            
            Text("ID: \(person.id.uuidString)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        .cornerRadius(6)
    }
    
    // MARK: - Fix Result Section
    
    private func fixResultSection(result: FixResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("Duplicates Fixed")
                        .font(.headline)
                    Text("Merged \(result.mergedCount) duplicate(s)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Button("Scan Again") {
                fixResult = nil
                Task { await scanForDuplicates() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
    }
    
    // MARK: - Error Section
    
    private func errorSection(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
    
    // MARK: - Actions
    
    private func scanForDuplicates() async {
        isScanning = true
        errorMessage = nil
        fixResult = nil
        
        do {
            let diagnostics = ContactDuplicateDiagnostics(modelContext: modelContext)
            let newReport = try diagnostics.generateReport()
            report = newReport
            
            // Also print to console for debugging
            try diagnostics.printReport()
            diagnostics.printPermissionDiagnosis()
        } catch {
            errorMessage = "Scan failed: \(error.localizedDescription)"
        }
        
        isScanning = false
    }
    
    private func fixDuplicates() async {
        isFixing = true
        errorMessage = nil
        
        do {
            let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
            let mergedCount = try cleaner.cleanAllDuplicates()
            
            fixResult = FixResult(mergedCount: mergedCount)
            report = nil // Clear report since duplicates are fixed
        } catch {
            errorMessage = "Fix failed: \(error.localizedDescription)"
        }
        
        isFixing = false
    }
}

// MARK: - Helper Views

struct ConfigToggleRow: View {
    let title: String
    let isEnabled: Bool
    let recommendation: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isEnabled ? .green : .red)
            }
            
            if let recommendation {
                Text(recommendation)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct FixResult {
    let mergedCount: Int
}

// MARK: - Preview

#Preview {
    DuplicateContactDiagnosticView()
        .modelContainer(for: [SamPerson.self], inMemory: true)
}
