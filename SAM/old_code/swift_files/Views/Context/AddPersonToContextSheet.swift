//
//  AddPersonToContextSheet.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI
import Foundation

struct AddPersonToContextSheet: View {
    @Environment(\.dismiss) private var dismiss

    let personID: UUID
    let personName: String
    let contexts: [ContextListItemModel]
    let onAdd: (UUID, RelationshipRole) -> Void

    @State private var searchText: String = ""
    @State private var selectedContextID: UUID?
    @State private var role: RelationshipRole = .primary

    private var filtered: [ContextListItemModel] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return contexts }
        return contexts.filter {
            $0.name.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Context")
                .font(.title2).bold()

            Text(personName)
                .font(.headline)
                .foregroundStyle(.secondary)

            Form {
                Picker("Role", selection: $role) {
                    ForEach(RelationshipRole.allCases, id: \.self) { r in
                        Text(r.title).tag(r)
                    }
                }

                Section("Choose a context") {
                    TextField("Search contexts", text: $searchText)

                    List(filtered, selection: $selectedContextID) { ctx in
                        HStack(spacing: 10) {
                            Image(systemName: ctx.kind.icon)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(ctx.name)
                                Text(ctx.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .tag(ctx.id as UUID?)
                    }
                    .frame(minHeight: 220)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    guard let id = selectedContextID else { return }
                    onAdd(id, role)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedContextID == nil)
            }
            .padding(.top, 6)
        }
        .padding(18)
        .frame(width: 520, height: 520)
        .onAppear {
            if selectedContextID == nil { selectedContextID = contexts.first?.id }
        }
    }
}

