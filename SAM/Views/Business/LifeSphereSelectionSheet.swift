//
//  LifeSphereSelectionSheet.swift
//  SAM
//
//  Phase B2/B4 of the multi-sphere classification work (May 2026).
//
//  The single sheet that asks the user which life spheres they want
//  SAM to track. Used both at first-run onboarding (for new users) and
//  as a one-shot nudge for existing users on first launch after this
//  feature ships. Suggests Work + Family & Close Friends by default,
//  with Church / Volunteer / Hobby as optional adds.
//
//  Friction-discouraging copy ("most people thrive with 2–3 spheres")
//  steers users away from over-categorising at the moment they're most
//  inclined to. Editable later in People → Relationship Graph → Spheres.
//

import SwiftUI

struct LifeSphereSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Spheres the user has explicitly checked.
    @State private var selectedTemplateIDs: Set<String>
    @State private var saveError: String?
    @State private var isSaving = false

    /// Hook called once the user confirms — receives the list of templates
    /// that were actually applied. Caller is responsible for setting any
    /// "shown-this-prompt" UserDefaults flag.
    let onConfirm: ([LifeSphereTemplate]) -> Void

    init(
        prefilled: Set<String> = Set(LifeSphereTemplate.onboardingDefaults.map(\.id)),
        onConfirm: @escaping ([LifeSphereTemplate]) -> Void
    ) {
        _selectedTemplateIDs = State(initialValue: prefilled)
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intro

                    suggestedSection
                    optionalSection

                    Spacer(minLength: 8)
                    footerHint

                    if let saveError {
                        Text(saveError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
            }
            .frame(width: 580, height: 620)
            .navigationTitle("Your life spheres")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip for now") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isSaving ? "Adding…" : "Continue") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedTemplateIDs.isEmpty || isSaving)
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How do you want to organize your relationships?")
                .font(.title3).bold()
            Text("SAM uses **spheres** to keep relationship health honest. The same person can show up in more than one — a coworker who's also a friend has separate cadences, separate health, and separate coaching depending on which sphere is in view.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var suggestedSection: some View {
        sphereGroup(
            title: "Start with these",
            subtitle: "Most users do well with just these two.",
            templates: LifeSphereTemplate.onboardingDefaults
        )
    }

    private var optionalSection: some View {
        sphereGroup(
            title: "Add only if you have meaningful ongoing conversations there",
            subtitle: "Fewer spheres = less classification friction.",
            templates: LifeSphereTemplate.onboardingOptionals
        )
    }

    private func sphereGroup(
        title: String,
        subtitle: String,
        templates: [LifeSphereTemplate]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).bold()
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(templates) { template in
                    templateRow(template)
                }
            }
        }
    }

    private func templateRow(_ template: LifeSphereTemplate) -> some View {
        let isSelected = selectedTemplateIDs.contains(template.id)
        return Button {
            if isSelected { selectedTemplateIDs.remove(template.id) }
            else { selectedTemplateIDs.insert(template.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.title3)
                Image(systemName: template.icon)
                    .foregroundStyle(template.accentColor.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name).font(.body).bold()
                    Text(template.purpose).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footerHint: some View {
        Text("You can change this anytime in **People → Relationship Graph → Spheres**.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Apply

    private func apply() {
        let templates = LifeSphereTemplate.all.filter { selectedTemplateIDs.contains($0.id) }
        guard !templates.isEmpty else { return }
        isSaving = true
        do {
            for template in templates {
                _ = try SphereRepository.shared.createSphere(from: template)
            }
            onConfirm(templates)
            dismiss()
        } catch {
            saveError = "Couldn't add spheres: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
