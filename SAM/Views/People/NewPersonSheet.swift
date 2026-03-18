//
//  NewPersonSheet.swift
//  SAM
//
//  Created on March 18, 2026.
//  Quick-add a SAM person without requiring an Apple Contact record.
//

import SwiftUI

struct NewPersonSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// Called after successful creation with the new person's ID.
    var onCreated: (UUID) -> Void = { _ in }

    // MARK: - Form State

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var errorMessage: String?

    private var displayName: String {
        let trimmed = "\(firstName.trimmingCharacters(in: .whitespaces)) \(lastName.trimmingCharacters(in: .whitespaces))"
            .trimmingCharacters(in: .whitespaces)
        return trimmed
    }

    private var canSave: Bool {
        !displayName.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Person")
                    .samFont(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Form
            Form {
                Section {
                    TextField("First Name", text: $firstName)
                    TextField("Last Name", text: $lastName)
                }

                Section("Optional") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                    TextField("Phone", text: $phone)
                        .textContentType(.telephoneNumber)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .samFont(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Text("No Apple Contact required. You can link one later.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Person") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 380, height: 320)
    }

    // MARK: - Save

    private func save() {
        let name = displayName
        guard !name.isEmpty else { return }

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = phone.trimmingCharacters(in: .whitespaces)

        do {
            let person = try PeopleRepository.shared.insertStandalone(
                displayName: name,
                phone: trimmedPhone.isEmpty ? nil : trimmedPhone,
                email: trimmedEmail.isEmpty ? nil : trimmedEmail
            )
            NotificationCenter.default.post(name: .samPersonDidChange, object: nil)
            onCreated(person.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
