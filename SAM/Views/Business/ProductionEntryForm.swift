//
//  ProductionEntryForm.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase S: Production Tracking
//
//  Sheet form for adding or editing a production record.
//

import SwiftUI

struct ProductionEntryForm: View {

    let personName: String
    let personID: UUID
    var existingRecord: ProductionRecord?
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - Draft persistence

    private static let draftKind = "production-form"

    private var draftID: String { existingRecord?.id.uuidString ?? "new" }

    @State private var productType: WFGProductType = .iul
    @State private var carrierName: String = ""
    @State private var annualPremium: Double = 0
    @State private var submittedDate: Date = .now
    @State private var notes: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(existingRecord != nil ? "Edit Production" : "Add Production")
                    .samFont(.headline)
                Spacer()
                Text(personName)
                    .samFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            Form {
                Picker("Product Type", selection: $productType) {
                    ForEach(WFGProductType.allCases, id: \.rawValue) { type in
                        Label(type.displayName, systemImage: type.icon)
                            .tag(type)
                    }
                }

                TextField("Carrier", text: $carrierName, prompt: Text("e.g., Transamerica"))

                TextField("Annual Premium", value: $annualPremium, format: .currency(code: "USD"))

                DatePicker("Submitted Date", selection: $submittedDate, displayedComponents: .date)

                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return)
                .disabled(carrierName.trimmingCharacters(in: .whitespaces).isEmpty || annualPremium <= 0)
            }
            .padding()
        }
        .frame(width: 420, height: 420)
        .onAppear {
            if let record = existingRecord {
                productType = record.productType
                carrierName = record.carrierName
                annualPremium = record.annualPremium
                submittedDate = record.submittedDate
                notes = record.notes ?? ""
            }
            if let stored = DraftStore.shared.load(kind: Self.draftKind, id: draftID) {
                if let v = stored["carrierName"] { carrierName = v }
                if let v = stored["notes"] { notes = v }
            }
        }
        .onChange(of: carrierName) { saveDraft() }
        .onChange(of: notes) { saveDraft() }
    }

    private func saveDraft() {
        DraftStore.shared.save(
            kind: Self.draftKind,
            id: draftID,
            fields: ["carrierName": carrierName, "notes": notes]
        )
    }

    private func save() {
        let trimmedCarrier = carrierName.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)

        if let record = existingRecord {
            // Update existing
            record.productType = productType
            record.carrierName = trimmedCarrier
            record.annualPremium = annualPremium
            record.submittedDate = submittedDate
            record.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            record.updatedAt = .now
            do {
                try ProductionRepository.shared.updateRecord(
                    recordID: record.id,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes
                )
            } catch {}
        } else {
            // Create new
            do {
                try ProductionRepository.shared.createRecord(
                    personID: personID,
                    productType: productType,
                    carrierName: trimmedCarrier,
                    annualPremium: annualPremium,
                    submittedDate: submittedDate,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes
                )
            } catch {}
        }

        DraftStore.shared.clear(kind: Self.draftKind, id: draftID)
        onSave()
        dismiss()
    }
}
