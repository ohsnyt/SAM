//
//  NewContextSheet.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI

struct NewContextSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var kind: ContextKind = .household
    @State private var includeDefaultParticipants: Bool = true

    /// Provide from caller (store / SwiftData / etc.)
    let existingContexts: [ContextListItemModel]

    let onCreate: (NewContextDraft) -> Void

    /// If user chooses a duplicate match, open/select that existing context.
    let onOpenExisting: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Context")
                .font(.title2)
                .bold()

            Form {
                TextField("Name", text: $name)
#if os(iOS)
                    .textInputAutocapitalization(.words)
#endif
                    .onSubmit { create() }

                Picker("Type", selection: $kind) {
                    Text("Household").tag(ContextKind.household)
                    Text("Business").tag(ContextKind.business)
                    Text("Recruiting").tag(ContextKind.recruiting)
                }

                Toggle("Add starter participants", isOn: $includeDefaultParticipants)
                    .help("Creates a minimal set of participants so the detail view doesn’t look empty.")

                if let warning = duplicateWarning {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(warning.title, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        if !warning.matches.isEmpty {
                            Text("Possible matches:")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(warning.matches.prefix(3)) { match in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(match.name)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)

                                            Text(match.kind.displayName)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary.opacity(0.9))
                                        }

                                        Spacer()

                                        Button("Open") {
                                            onOpenExisting(match.id)
                                            dismiss()
                                        }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(primaryButtonTitle) { create() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(18)
        .frame(width: 460)
    }

    // MARK: - Derived

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name we will actually use (so warning matches create behavior).
    private var candidateName: String {
        trimmedName.isEmpty ? defaultName(for: kind) : trimmedName
    }

    private var primaryButtonTitle: String {
        duplicateWarning == nil ? "Create" : "Create Anyway"
    }

    private var duplicateWarning: DuplicateWarning? {
        let q = normalized(candidateName)
        guard !q.isEmpty else { return nil }

        let existingNames = existingContexts.map(\.name)

        // Exact match (case/whitespace-insensitive)
        if let exactName = existingNames.first(where: { normalized($0) == q }) {
            let matches = existingContexts.filter { normalized($0.name) == q }
            return DuplicateWarning(
                title: "A context named “\(exactName)” already exists.",
                matches: matches
            )
        }

        // Fuzzy: contains match
        let fuzzy = existingContexts
            .filter { normalized($0.name).contains(q) || q.contains(normalized($0.name)) }
            .sorted { $0.name.count < $1.name.count }

        if !fuzzy.isEmpty {
            return DuplicateWarning(
                title: "This looks similar to an existing context.",
                matches: fuzzy
            )
        }

        return nil
    }

    private func normalized(_ s: String) -> String {
        s
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func create() {
        let finalName = candidateName

        onCreate(NewContextDraft(
            name: finalName,
            kind: kind,
            includeDefaultParticipants: includeDefaultParticipants
        ))
        dismiss()
    }

    private func defaultName(for kind: ContextKind) -> String {
        switch kind {
        case .household: return "New Household"
        case .business: return "New Business"
        case .recruiting: return "New Recruiting Context"
        }
    }
}

private struct DuplicateWarning {
    let title: String
    let matches: [ContextListItemModel]
}

// Draft object: what the sheet produces
struct NewContextDraft {
    let name: String
    let kind: ContextKind
    let includeDefaultParticipants: Bool
}
