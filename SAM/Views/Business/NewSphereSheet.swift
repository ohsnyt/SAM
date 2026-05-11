//
//  NewSphereSheet.swift
//  SAM
//
//  Phase 5 of the relationship-model refactor (May 2026).
//
//  Modal sheet for creating a new Sphere. Ships with three starter templates:
//    • Blank — empty Sphere, the user adds people and Trajectories on demand
//    • Real Estate — Buyer Funnel + Seller Funnel + Past-clients Stewardship
//    • Sales — generic Sales Funnel + Past-customers Stewardship
//
//  Plan §1 (Phase 5b): "Ship Blank + Real-estate/Sales first, add Faith
//  community/Nonprofit/Promoter/Service as templates iteratively."
//

import SwiftUI

struct NewSphereSheet: View {

    /// Called when a Sphere is successfully created. Receives the new
    /// Sphere.id so the parent can navigate or refresh.
    var onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var template: SphereTemplate = .blank
    @State private var name: String = ""
    @State private var purpose: String = ""
    @State private var accentColor: SphereAccentColor = .blue
    @State private var defaultMode: Mode = .stewardship
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    Picker("Template", selection: $template) {
                        ForEach(SphereTemplate.allCases) { template in
                            Text(template.displayName).tag(template)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: template) { _, newValue in
                        applyTemplateDefaults(newValue)
                    }
                    Text(template.summary)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Sphere") {
                    TextField("Name", text: $name, prompt: Text(template.nameHint))
                    TextField("Purpose", text: $purpose, prompt: Text(template.purposeHint), axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Defaults") {
                    Picker("Default Mode", selection: $defaultMode) {
                        ForEach(Mode.allCases, id: \.self) { mode in
                            HStack {
                                Image(systemName: mode.icon).foregroundStyle(mode.color)
                                Text(mode.displayName)
                            }
                            .tag(mode)
                        }
                    }
                    Text(defaultMode.explanation)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Accent color", selection: $accentColor) {
                        ForEach(SphereAccentColor.allCases, id: \.self) { color in
                            HStack {
                                Circle().fill(color.color).frame(width: 12, height: 12)
                                Text(color.displayName)
                            }
                            .tag(color)
                        }
                    }
                }

                if !template.trajectoryPreview.isEmpty {
                    Section("Trajectories this template will create") {
                        ForEach(template.trajectoryPreview, id: \.name) { preview in
                            HStack(spacing: 6) {
                                Image(systemName: preview.mode.icon)
                                    .foregroundStyle(preview.mode.color)
                                Text(preview.name)
                                Spacer()
                                Text(preview.mode.displayName)
                                    .samFont(.caption)
                                    .foregroundStyle(preview.mode.color)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .samFont(.caption)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Sphere")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
            .onAppear { applyTemplateDefaults(template) }
        }
        .frame(minWidth: 460, minHeight: 540)
    }

    // MARK: - Template defaults

    private func applyTemplateDefaults(_ template: SphereTemplate) {
        // Only fill blank fields so a user who started typing isn't clobbered.
        if name.isEmpty { name = template.defaultName }
        if purpose.isEmpty { purpose = template.defaultPurpose }
        defaultMode = template.defaultMode
        accentColor = template.accentColor
    }

    // MARK: - Create

    private func create() {
        isCreating = true
        errorMessage = nil
        do {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let sphere = try SphereRepository.shared.createSphere(
                name: trimmed,
                purpose: purpose.trimmingCharacters(in: .whitespaces),
                accentColor: accentColor,
                defaultMode: defaultMode,
                defaultCadenceDays: nil,
                isBootstrapDefault: false
            )

            for preview in template.trajectoryPreview {
                let trajectory = try TrajectoryRepository.shared.createTrajectory(
                    sphereID: sphere.id,
                    name: preview.name,
                    mode: preview.mode,
                    notes: preview.notes
                )
                for (idx, stage) in preview.stages.enumerated() {
                    try TrajectoryRepository.shared.addStage(
                        trajectoryID: trajectory.id,
                        name: stage.name,
                        sortOrder: idx,
                        isTerminal: stage.isTerminal
                    )
                }
            }

            PersonModeResolver.invalidateCache()
            isCreating = false
            onCreated(sphere.id)
            dismiss()
        } catch {
            isCreating = false
            errorMessage = "Could not create Sphere: \(error.localizedDescription)"
        }
    }
}

// MARK: - SphereTemplate

enum SphereTemplate: String, CaseIterable, Identifiable {
    case blank
    case realEstate
    case sales

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blank:      return "Blank"
        case .realEstate: return "Real Estate"
        case .sales:      return "Sales"
        }
    }

    var summary: String {
        switch self {
        case .blank:
            return "An empty Sphere. Add people and arcs as you go."
        case .realEstate:
            return "Buyer funnel, seller funnel, and an ongoing stewardship arc for past clients."
        case .sales:
            return "A generic sales funnel plus a stewardship arc for past customers."
        }
    }

    var defaultName: String {
        switch self {
        case .blank:      return ""
        case .realEstate: return "Real Estate Practice"
        case .sales:      return "Sales Practice"
        }
    }

    var nameHint: String {
        switch self {
        case .blank:      return "e.g. Board of ABT, Worship Team"
        case .realEstate: return "Real Estate Practice"
        case .sales:      return "Sales Practice"
        }
    }

    var defaultPurpose: String {
        switch self {
        case .blank:      return ""
        case .realEstate: return "Your real-estate work — buyers, sellers, past clients, and the people who refer them."
        case .sales:      return "Your sales practice — active prospects, customers, and the people who refer them."
        }
    }

    var purposeHint: String {
        switch self {
        case .blank:      return "Why does this Sphere exist? Encouraged to be a role, not a category."
        case .realEstate: return "Your real-estate work — buyers, sellers, past clients, and the people who refer them."
        case .sales:      return "Your sales practice — active prospects, customers, and the people who refer them."
        }
    }

    var defaultMode: Mode {
        switch self {
        case .blank:      return .stewardship
        case .realEstate: return .stewardship
        case .sales:      return .stewardship
        }
    }

    var accentColor: SphereAccentColor {
        switch self {
        case .blank:      return .blue
        case .realEstate: return .green
        case .sales:      return .orange
        }
    }

    struct StagePreview {
        let name: String
        let isTerminal: Bool
    }

    struct TrajectoryPreview {
        let name: String
        let mode: Mode
        let notes: String?
        let stages: [StagePreview]
    }

    var trajectoryPreview: [TrajectoryPreview] {
        switch self {
        case .blank:
            return []
        case .realEstate:
            return [
                TrajectoryPreview(
                    name: "Buyer Pipeline",
                    mode: .funnel,
                    notes: "Inquiry → Showing → Offer → Closed.",
                    stages: [
                        StagePreview(name: "Inquiry", isTerminal: false),
                        StagePreview(name: "Showing", isTerminal: false),
                        StagePreview(name: "Offer", isTerminal: false),
                        StagePreview(name: "Closed", isTerminal: true),
                    ]
                ),
                TrajectoryPreview(
                    name: "Seller Pipeline",
                    mode: .funnel,
                    notes: "Listing → Showing → Offer → Closed.",
                    stages: [
                        StagePreview(name: "Listing", isTerminal: false),
                        StagePreview(name: "Showing", isTerminal: false),
                        StagePreview(name: "Offer", isTerminal: false),
                        StagePreview(name: "Closed", isTerminal: true),
                    ]
                ),
                TrajectoryPreview(
                    name: "Past Clients — Stewardship",
                    mode: .stewardship,
                    notes: "Ongoing relationship cadence after a closed deal.",
                    stages: [
                        StagePreview(name: "Active", isTerminal: false),
                    ]
                ),
            ]
        case .sales:
            return [
                TrajectoryPreview(
                    name: "Sales Pipeline",
                    mode: .funnel,
                    notes: "Lead → Qualified → Proposal → Closed.",
                    stages: [
                        StagePreview(name: "Lead", isTerminal: false),
                        StagePreview(name: "Qualified", isTerminal: false),
                        StagePreview(name: "Proposal", isTerminal: false),
                        StagePreview(name: "Closed", isTerminal: true),
                    ]
                ),
                TrajectoryPreview(
                    name: "Past Customers — Stewardship",
                    mode: .stewardship,
                    notes: "Ongoing relationship cadence after the sale.",
                    stages: [
                        StagePreview(name: "Active", isTerminal: false),
                    ]
                ),
            ]
        }
    }
}
