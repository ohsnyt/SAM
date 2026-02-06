//
//  DeduplicatePeopleView.swift
//  SAM_crm
//
//  UI for finding and merging duplicate people.
//  Add this to Settings or as a debug tool.
//

import SwiftUI
import SwiftData

struct DeduplicatePeopleView: View {
    @Environment(\.modelContext) private var modelContext
    
    @State private var duplicateGroups: [[SamPerson]] = []
    @State private var isScanning = false
    @State private var isMerging = false
    @State private var mergedCount: Int?
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            Text("Deduplicate People")
                .font(.title)
                .bold()
            
            Text("Find and merge duplicate person records that may have been created during contact imports or manual entry.")
                .foregroundStyle(.secondary)
            
            // Actions
            HStack {
                Button {
                    Task { await scanForDuplicates() }
                } label: {
                    Label("Scan for Duplicates", systemImage: "magnifyingglass")
                }
                .disabled(isScanning || isMerging)
                
                if !duplicateGroups.isEmpty {
                    Button {
                        Task { await mergeAll() }
                    } label: {
                        Label("Merge All", systemImage: "arrow.triangle.merge")
                    }
                    .disabled(isScanning || isMerging)
                    .foregroundStyle(.orange)
                }
            }
            
            if isScanning {
                ProgressView("Scanning for duplicates...")
            }
            
            if isMerging {
                ProgressView("Merging duplicates...")
            }
            
            // Results
            if let merged = mergedCount {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Merged \(merged) duplicate\(merged == 1 ? "" : "s")")
                        .font(.headline)
                }
                .padding()
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                }
                .padding()
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            
            // Duplicate groups
            if !duplicateGroups.isEmpty {
                Divider()
                
                Text("Found \(duplicateGroups.count) group\(duplicateGroups.count == 1 ? "" : "s") of duplicates:")
                    .font(.headline)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(duplicateGroups.enumerated()), id: \.offset) { index, group in
                            DuplicateGroupView(index: index + 1, people: group)
                        }
                    }
                }
            } else if !isScanning && mergedCount == nil {
                Text("No duplicates found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            }
        }
        .padding()
        .frame(maxWidth: 700)
    }
    
    private func scanForDuplicates() async {
        isScanning = true
        errorMessage = nil
        mergedCount = nil
        
        defer { isScanning = false }
        
        do {
            let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
            duplicateGroups = try cleaner.findAllDuplicates()
        } catch {
            errorMessage = "Failed to scan: \(error.localizedDescription)"
        }
    }
    
    private func mergeAll() async {
        isMerging = true
        errorMessage = nil
        
        defer { isMerging = false }
        
        do {
            let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
            let count = try cleaner.cleanAllDuplicates()
            mergedCount = count
            duplicateGroups = []
        } catch {
            errorMessage = "Failed to merge: \(error.localizedDescription)"
        }
    }
}

// MARK: - Duplicate Group Card

private struct DuplicateGroupView: View {
    let index: Int
    let people: [SamPerson]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group \(index)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            ForEach(people) { person in
                HStack(spacing: 12) {
                    Image(systemName: person.contactIdentifier != nil ? "person.crop.circle.fill" : "person.crop.circle")
                        .foregroundStyle(person.contactIdentifier != nil ? .blue : .secondary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.displayName)
                            .font(.body)
                        
                        HStack(spacing: 8) {
                            if let ci = person.contactIdentifier {
                                Text("Linked: \(String(ci.prefix(12)))...")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Unlinked")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            
                            if !person.roleBadges.isEmpty {
                                Text("• \(person.roleBadges.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding(8)
                .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview

#Preview {
    DeduplicatePeopleView()
        .modelContainer(for: [SamPerson.self], inMemory: true)
}
