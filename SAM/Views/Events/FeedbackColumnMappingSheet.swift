//
//  FeedbackColumnMappingSheet.swift
//  SAM
//
//  Created on April 7, 2026.
//  Allows the user to map CSV column headers from a Google Forms export
//  to known feedback form fields.
//

import SwiftUI

struct FeedbackColumnMappingSheet: View {

    let headers: [String]
    let rows: [ParsedFeedbackRow]
    let event: SamEvent

    @State private var mapping = FeedbackColumnMapping()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Map Feedback Columns")
                        .samFont(.title2, weight: .semibold)
                    Text("Match CSV columns to feedback fields. SAM will remember this for future imports.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            Form {
                Section("Contact Information") {
                    columnPicker("Name", selection: $mapping.nameColumn)
                    columnPicker("Email", selection: $mapping.emailColumn)
                    columnPicker("Phone", selection: $mapping.phoneColumn)
                }

                Section("Feedback Questions") {
                    columnPicker("Most helpful/clarifying", selection: $mapping.mostHelpfulColumn)
                    columnPicker("Areas to strengthen", selection: $mapping.areasToStrengthenColumn)
                    columnPicker("Deeper understanding", selection: $mapping.deeperUnderstandingColumn)
                    columnPicker("Overall rating", selection: $mapping.overallRatingColumn)
                    columnPicker("Would continue?", selection: $mapping.wouldContinueColumn)
                    columnPicker("Current situation", selection: $mapping.currentSituationColumn)
                    columnPicker("Other topics", selection: $mapping.otherTopicsColumn)
                }

                Section {
                    HStack {
                        Text("Preview: \(rows.count) responses will be imported")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Apply Mapping") {
                    Task {
                        await PostEventEvaluationCoordinator.shared.applyFeedbackMapping(
                            mapping: mapping,
                            rows: rows,
                            for: event
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasMinimumMapping)
            }
            .padding()
        }
        .frame(width: 500, height: 550)
        .onAppear {
            autoDetectMapping()
        }
    }

    // MARK: - Column Picker

    private func columnPicker(_ label: String, selection: Binding<String?>) -> some View {
        Picker(label, selection: selection) {
            Text("— Not mapped —").tag(String?.none)
            ForEach(headers, id: \.self) { header in
                Text(header)
                    .lineLimit(1)
                    .tag(String?.some(header))
            }
        }
    }

    // MARK: - Auto-Detect

    /// Try to auto-detect column mappings from header text.
    private func autoDetectMapping() {
        for header in headers {
            let lower = header.lowercased()

            if lower.contains("name") && !lower.contains("other") {
                if mapping.nameColumn == nil { mapping.nameColumn = header }
            }
            if lower.contains("email") {
                if mapping.emailColumn == nil { mapping.emailColumn = header }
            }
            if lower.contains("phone") {
                if mapping.phoneColumn == nil { mapping.phoneColumn = header }
            }
            if lower.contains("helpful") || lower.contains("clarif") {
                if mapping.mostHelpfulColumn == nil { mapping.mostHelpfulColumn = header }
            }
            if lower.contains("strengthen") || lower.contains("area") {
                if mapping.areasToStrengthenColumn == nil { mapping.areasToStrengthenColumn = header }
            }
            if lower.contains("deeply") || lower.contains("understand") || lower.contains("more deeply") {
                if mapping.deeperUnderstandingColumn == nil { mapping.deeperUnderstandingColumn = header }
            }
            if lower.contains("overall") || lower.contains("feel") || lower.contains("rate") {
                if mapping.overallRatingColumn == nil { mapping.overallRatingColumn = header }
            }
            if lower.contains("continue") || lower.contains("conversation") || lower.contains("schedule") {
                if mapping.wouldContinueColumn == nil { mapping.wouldContinueColumn = header }
            }
            if lower.contains("situation") || lower.contains("describe") || lower.contains("current") {
                if mapping.currentSituationColumn == nil { mapping.currentSituationColumn = header }
            }
            if lower.contains("other topic") || lower.contains("learn about") {
                if mapping.otherTopicsColumn == nil { mapping.otherTopicsColumn = header }
            }
        }
    }

    private var hasMinimumMapping: Bool {
        // At least one content field must be mapped
        mapping.mostHelpfulColumn != nil ||
        mapping.areasToStrengthenColumn != nil ||
        mapping.overallRatingColumn != nil ||
        mapping.wouldContinueColumn != nil
    }
}
