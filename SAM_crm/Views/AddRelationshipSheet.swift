//
//  AddRelationshipSheet.swift
//  SAM_crm
//
//  Sheet for adding family relationships to Apple Contacts.
//  Both relationship label and name are editable before submission.
//  Supports standard labels (son, daughter, spouse) and custom labels.
//

import SwiftUI
import Contacts

struct AddRelationshipSheet: View {
    let parentPerson: SamPerson
    let suggestedName: String
    let suggestedLabel: String
    let onAdd: (String, String) -> Void  // (name, label)
    let onCancel: () -> Void
    
    @State private var editableName: String
    @State private var editableLabel: String
    @State private var showCustomLabel = false
    
    init(
        parentPerson: SamPerson,
        suggestedName: String,
        suggestedLabel: String,
        onAdd: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.parentPerson = parentPerson
        self.suggestedName = suggestedName
        self.suggestedLabel = suggestedLabel
        self.onAdd = onAdd
        self.onCancel = onCancel
        
        _editableName = State(initialValue: suggestedName)
        _editableLabel = State(initialValue: suggestedLabel)
        
        // Show custom label field if suggested label is not standard
        _showCustomLabel = State(initialValue: !Self.standardLabels.contains(suggestedLabel))
    }
    
    // Standard relationship labels from CNContact
    private static let standardLabels = [
        CNLabelContactRelationSpouse,
        CNLabelContactRelationPartner,
        CNLabelContactRelationChild,
        CNLabelContactRelationSon,
        CNLabelContactRelationDaughter,
        CNLabelContactRelationParent,
        CNLabelContactRelationMother,
        CNLabelContactRelationFather,
        CNLabelContactRelationSister,
        CNLabelContactRelationBrother,
        "step-son",
        "step-daughter",
        "step-parent",
        "guardian",
        "dependent"
    ]
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                
                Text("Add Family Member")
                    .font(.title2)
                    .bold()
                
                Text("Adding to \(parentPerson.displayNameCache ?? "contact")'s family")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            // Editable fields
            VStack(alignment: .leading, spacing: 16) {
                // Name field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.headline)
                    
                    TextField("Name", text: $editableName)
                        .textFieldStyle(.roundedBorder)
                }
                
                // Relationship label
                VStack(alignment: .leading, spacing: 6) {
                    Text("Relationship")
                        .font(.headline)
                    
                    if showCustomLabel {
                        HStack {
                            TextField("Relationship", text: $editableLabel)
                                .textFieldStyle(.roundedBorder)
                            
                            Button {
                                showCustomLabel = false
                                editableLabel = CNLabelContactRelationChild
                            } label: {
                                Image(systemName: "list.bullet.circle")
                            }
                            .help("Choose standard label")
                        }
                    } else {
                        HStack {
                            Picker("", selection: $editableLabel) {
                                Text("Son").tag(CNLabelContactRelationSon)
                                Text("Daughter").tag(CNLabelContactRelationDaughter)
                                Text("Child").tag(CNLabelContactRelationChild)
                                Text("Spouse").tag(CNLabelContactRelationSpouse)
                                Text("Partner").tag(CNLabelContactRelationPartner)
                                Text("Mother").tag(CNLabelContactRelationMother)
                                Text("Father").tag(CNLabelContactRelationFather)
                                Text("Parent").tag(CNLabelContactRelationParent)
                                Text("Sister").tag(CNLabelContactRelationSister)
                                Text("Brother").tag(CNLabelContactRelationBrother)
                                Divider()
                                Text("Step-son").tag("step-son")
                                Text("Step-daughter").tag("step-daughter")
                                Text("Step-parent").tag("step-parent")
                                Text("Guardian").tag("guardian")
                                Text("Dependent").tag("dependent")
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity)
                            
                            Button {
                                showCustomLabel = true
                            } label: {
                                Image(systemName: "pencil.circle")
                            }
                            .help("Enter custom label")
                        }
                    }
                    
                    Text("This will appear in Contacts.app as: \"\(editableName) (\(localizedLabel(editableLabel)))\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            // Preview
            GroupBox("Preview") {
                HStack(spacing: 12) {
                    Image(systemName: iconForLabel(editableLabel))
                        .foregroundStyle(.secondary)
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(editableName)
                            .font(.callout)
                            .bold()
                        Text(localizedLabel(editableLabel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            
            // Actions
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Add to Contacts") {
                    onAdd(editableName, editableLabel)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(editableName.trimmingCharacters(in: .whitespaces).isEmpty ||
                         editableLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 450)
    }
    
    private func localizedLabel(_ label: String) -> String {
        // Check if it's a standard CNContact label
        if Self.standardLabels.contains(label) {
            return CNLabeledValue<NSString>.localizedString(forLabel: label)
        }
        // Custom label - return as-is
        return label
    }
    
    private func iconForLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("son") || lower.contains("daughter") || lower.contains("child") {
            return "person.fill"
        } else if lower.contains("spouse") || lower.contains("partner") {
            return "heart.fill"
        } else if lower.contains("mother") || lower.contains("father") || lower.contains("parent") {
            return "person.2.fill"
        } else if lower.contains("sister") || lower.contains("brother") {
            return "person.2"
        } else if lower.contains("guardian") {
            return "shield.lefthalf.filled"
        } else if lower.contains("dependent") {
            return "figure.and.child.holdinghands"
        }
        return "person.crop.circle"
    }
}

// MARK: - Preview

#Preview("Add Son") {
    AddRelationshipSheet(
        parentPerson: SamPerson(
            id: UUID(),
            displayName: "Harvey Snodgrass",
            roleBadges: ["Client"],
            contactIdentifier: "test-identifier"
        ),
        suggestedName: "William",
        suggestedLabel: CNLabelContactRelationSon,
        onAdd: { name, label in
            print("Add: \(name) (\(label))")
        },
        onCancel: {
            print("Cancel")
        }
    )
}

#Preview("Add Step-Daughter") {
    AddRelationshipSheet(
        parentPerson: SamPerson(
            id: UUID(),
            displayName: "Harvey Snodgrass",
            roleBadges: ["Client"],
            contactIdentifier: "test-identifier"
        ),
        suggestedName: "Emily",
        suggestedLabel: "step-daughter",
        onAdd: { name, label in
            print("Add: \(name) (\(label))")
        },
        onCancel: {
            print("Cancel")
        }
    )
}

#Preview("Add Custom Relationship") {
    AddRelationshipSheet(
        parentPerson: SamPerson(
            id: UUID(),
            displayName: "Harvey Snodgrass",
            roleBadges: ["Client"],
            contactIdentifier: "test-identifier"
        ),
        suggestedName: "Frank",
        suggestedLabel: "godchild",
        onAdd: { name, label in
            print("Add: \(name) (\(label))")
        },
        onCancel: {
            print("Cancel")
        }
    )
}
