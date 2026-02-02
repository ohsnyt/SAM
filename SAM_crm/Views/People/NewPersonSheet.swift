//
//  NewPersonSheet.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI

struct NewPersonSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var fullName: String = ""
    @State private var role: PersonRolePreset = .individualClient

    /// Provide these from the caller (store or SwiftData).
    let existingCandidates: [PersonDuplicateCandidate]

    /// Create new person (even if duplicate)
    let onCreate: (NewPersonDraft) -> Void

    /// If user chooses a duplicate match, open/select that person in the list.
    let onOpenExisting: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Person")
                .font(.title2)
                .bold()

            Form {
                TextField("Full name", text: $fullName)
                    .textContentType(.name)
#if os(iOS)
                    .textInputAutocapitalization(.words)
#endif
                    .onSubmit { create() }

                Picker("Role", selection: $role) {
                    ForEach(PersonRolePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                if let warning = duplicateWarning {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(warning.title, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        if !warning.matches.isEmpty {
                            Text("Possible matches:")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(warning.matches.prefix(3)) { m in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.displayName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)

                                            if let secondary = m.secondaryLine {
                                                Text(secondary)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary.opacity(0.9))
                                                    .lineLimit(2)
                                            }
                                        }

                                        Spacer()

                                        Button("Open") {
                                            onOpenExisting(m.id)
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
                    .disabled(trimmedName.isEmpty)
            }
            .padding(.top, 6)
        }
        .padding(18)
        .frame(width: 440)
    }

    // MARK: - Derived

    private var trimmedName: String {
        fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var primaryButtonTitle: String {
        duplicateWarning == nil ? "Create" : "Create Anyway"
    }

    private var duplicateWarning: DuplicateWarning? {
        let candidate = trimmedName
        guard !canonicalName(candidate).isEmpty else { return nil }

        let candidateCanon = canonicalName(candidate)

        // Exact match (canonical string)
        if let exact = existingCandidates.first(where: { canonicalName($0.displayName) == candidateCanon }) {
            let matches = existingCandidates.filter { canonicalName($0.displayName) == candidateCanon }
            return DuplicateWarning(
                title: "A person named \"\(exact.displayName)\" already exists.",
                matches: matches
            )
        }

        // Near-exact match (nickname + last-name heuristics)
        if let near = existingCandidates.first(where: { similarityScore(candidate: candidate, existing: $0.displayName) >= 0.95 }) {
            return DuplicateWarning(
                title: "This looks like the same person (nickname/formatting).",
                matches: [near]
            )
        }

        let scored: [(PersonDuplicateCandidate, Double)] = existingCandidates.map { c in
            (c, similarityScore(candidate: candidate, existing: c.displayName))
        }

        let fuzzy = scored
            .filter { $0.1 >= 0.60 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }

        if !fuzzy.isEmpty {
            return DuplicateWarning(
                title: "This looks similar to an existing person.",
                matches: fuzzy
            )
        }

        return nil
    }


    private func canonicalName(_ s: String) -> String {
        var t = s

        // 1) trim + lowercase
        t = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 2) normalize common separators
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: "+", with: " and ")

        // 3) remove punctuation (keep letters/numbers/spaces)
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        t = t.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }.reduce("") { $0 + String($1) }

        // 4) collapse whitespace
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5) normalize obvious suffix tokens
        // (keeps "jr"/"sr"/"ii" etc as tokens but removes periods/punct already)
        return t
    }

    private func normalizedTokens(_ s: String) -> [String] {
        let c = canonicalName(s)
        guard !c.isEmpty else { return [] }

        var parts = c.split(separator: " ").map(String.init)

        // Drop single-letter middle initials ("john q public" -> ["john","public"])
        if parts.count >= 3 {
            parts.removeAll(where: { $0.count == 1 })
        }

        // Nickname equivalence on first name token
        if let first = parts.first {
            parts[0] = canonicalFirstName(first)
        }

        return parts
    }

    private func canonicalFirstName(_ first: String) -> String {
        let f = first
        // Small, practical nickname map (extend as you discover real data)
        let map: [String: String] = [
            "bob": "robert",
            "bobby": "robert",
            "rob": "robert",
            "robbie": "robert",
            "beth": "elizabeth",
            "liz": "elizabeth",
            "lizzy": "elizabeth",
            "eliza": "elizabeth",
            "bill": "william",
            "billy": "william",
            "will": "william",
            "willy": "william",
            "jim": "james",
            "jimmy": "james",
            "mike": "michael",
            "mikey": "michael",
            "kate": "katherine",
            "katie": "katherine",
            "cathy": "catherine",
            "catie": "catherine",
            "rick": "richard",
            "ricky": "richard",
            "dick": "richard",
            "dave": "david",
            "steve": "steven",
            "stephen": "steven",
            "tony": "anthony",
            "andy": "andrew",
            "ben": "benjamin",
            "jen": "jennifer",
            "jenny": "jennifer",
            "chris": "christopher",
            "alex": "alexander",
            "sue": "susan",
            "susie": "susan"
        ]
        return map[f] ?? f
    }

    private func similarityScore(candidate: String, existing: String) -> Double {
        let a = normalizedTokens(candidate)
        let b = normalizedTokens(existing)
        if a.isEmpty || b.isEmpty { return 0 }

        // Token similarity (Jaccard)
        let sa = Set(a)
        let sb = Set(b)
        let inter = sa.intersection(sb).count
        let uni = sa.union(sb).count
        var score = Double(inter) / Double(uni)

        // Heuristic: boost if last names match (common “household” reality)
        if let la = a.last, let lb = b.last, la == lb {
            score = min(1.0, score + 0.25)
        }

        // Heuristic: if first+last match after nickname normalization, treat as near-exact
        if a.count >= 2, b.count >= 2, a.first == b.first, a.last == b.last {
            score = 1.0
        }

        return score
    }

    private func create() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        onCreate(NewPersonDraft(fullName: name, rolePreset: role))
        dismiss()
    }
}

private struct DuplicateWarning {
    let title: String
    let matches: [PersonDuplicateCandidate]
}

struct PersonDuplicateCandidate: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    /// Prefer a short postal address line; if not available, supply phone; can be nil.
    let addressLine: String?
    let phoneLine: String?

    var secondaryLine: String? {
        if let a = addressLine, !a.isEmpty { return a }
        if let p = phoneLine, !p.isEmpty { return p }
        return nil
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PersonDuplicateCandidate, rhs: PersonDuplicateCandidate) -> Bool {
        lhs.id == rhs.id
    }
}
