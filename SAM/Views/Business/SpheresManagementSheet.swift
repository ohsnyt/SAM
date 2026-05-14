//
//  SpheresManagementSheet.swift
//  SAM
//
//  Phase B1 of the multi-sphere classification work (May 2026).
//
//  The user-facing home for "what life areas does SAM track". Reachable
//  from the Relationship Graph toolbar — it's not a top-level tab because
//  most users will configure their spheres once at onboarding and rarely
//  return. Power users open it to add a hobby/volunteer sphere, edit a
//  classification profile, or archive a sphere they no longer use.
//
//  Friction copy at the 3rd and 5th sphere addition discourages
//  proliferation: each new sphere means more classification work for SAM
//  and more cognitive load for the user. We want most users to stay at
//  2–3 spheres; the floor stays at 1.
//

import SwiftUI

struct SpheresManagementSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var spheres: [Sphere] = []
    @State private var selectedSphereID: UUID?
    @State private var isLoading = true
    @State private var errorMessage: String?

    // Add-sphere flow
    @State private var showingAddSheet = false

    // Edit-sphere flow (single sheet bound to ID of sphere being edited)
    @State private var editingSphereID: UUID?

    var body: some View {
        NavigationStack {
            content
                .frame(minWidth: 720, minHeight: 480)
                .navigationTitle("Spheres")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("Add Sphere", systemImage: "plus")
                        }
                    }
                }
        }
        .task { await load() }
        .sheet(isPresented: $showingAddSheet) {
            AddLifeSphereSheet(existingSphereCount: spheres.count) { template in
                Task { await addSphere(from: template) }
            }
        }
        .sheet(item: editingSphereBinding) { sphere in
            EditSphereSheet(sphere: sphere) {
                Task { await load() }
            }
        }
    }

    private var editingSphereBinding: Binding<Sphere?> {
        Binding(
            get: { spheres.first { $0.id == editingSphereID } },
            set: { editingSphereID = $0?.id }
        )
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn't load spheres",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if spheres.isEmpty {
            ContentUnavailableView {
                Label("No spheres yet", systemImage: "circle.dashed")
            } description: {
                Text("Add a sphere to start organizing your relationships by life area.")
            } actions: {
                Button("Add Your First Sphere") { showingAddSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            HSplitView {
                sphereList
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                if let id = selectedSphereID, let sphere = spheres.first(where: { $0.id == id }) {
                    SphereDetailPane(sphere: sphere) {
                        editingSphereID = sphere.id
                    } onArchive: {
                        Task { await archive(sphere) }
                    }
                } else {
                    Text("Select a sphere")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var sphereList: some View {
        List(selection: $selectedSphereID) {
            ForEach(spheres) { sphere in
                SphereRow(sphere: sphere)
                    .tag(sphere.id)
            }
            .onMove(perform: move)
        }
        .listStyle(.inset)
    }

    private func move(from source: IndexSet, to destination: Int) {
        spheres.move(fromOffsets: source, toOffset: destination)
        Task { await persistOrder() }
    }

    // MARK: - Data ops

    private func load() async {
        do {
            let all = try SphereRepository.shared.fetchAll()
            spheres = all
            if selectedSphereID == nil { selectedSphereID = spheres.first?.id }
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func persistOrder() async {
        do {
            for (idx, sphere) in spheres.enumerated() {
                try SphereRepository.shared.updateSphere(id: sphere.id, sortOrder: idx)
            }
        } catch {
            errorMessage = "Couldn't reorder spheres: \(error.localizedDescription)"
        }
    }

    private func addSphere(from template: LifeSphereTemplate) async {
        do {
            let sphere = try SphereRepository.shared.createSphere(from: template)
            await load()
            selectedSphereID = sphere.id
        } catch {
            errorMessage = "Couldn't add sphere: \(error.localizedDescription)"
        }
    }

    private func archive(_ sphere: Sphere) async {
        do {
            try SphereRepository.shared.setArchived(id: sphere.id, true)
            await load()
        } catch {
            errorMessage = "Couldn't archive sphere: \(error.localizedDescription)"
        }
    }
}

// MARK: - Sphere row

private struct SphereRow: View {
    let sphere: Sphere

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(sphere.accentColor.color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(sphere.name)
                    .font(.body)
                if !sphere.purpose.isEmpty {
                    Text(sphere.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if sphere.isBootstrapDefault {
                Text("default")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail pane

private struct SphereDetailPane: View {
    let sphere: Sphere
    let onEdit: () -> Void
    let onArchive: () -> Void

    @State private var memberCount: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                section(title: "Purpose") {
                    Text(sphere.purpose.isEmpty ? "—" : sphere.purpose)
                        .foregroundStyle(sphere.purpose.isEmpty ? .secondary : .primary)
                }
                section(title: "Classification Profile") {
                    if sphere.classificationProfile.isEmpty {
                        Text("No profile yet. SAM will classify evidence into this sphere only after you write one — until then, the sphere counts as \u{201c}catch-all\u{201d} and is harder to distinguish from your other spheres.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(sphere.classificationProfile)
                            .font(.callout)
                    }
                }
                if !sphere.keywordHints.isEmpty {
                    section(title: "Keyword Hints") {
                        keywordChips
                    }
                }
                section(title: "Confirmed Examples (\(sphere.examples.count)/\(Sphere.maxExamples))") {
                    examplesList
                }
                section(title: "Defaults") {
                    HStack {
                        Label(sphere.defaultMode.displayName, systemImage: sphere.defaultMode.icon)
                            .foregroundStyle(sphere.defaultMode.color)
                        Spacer()
                        Text("\(sphere.effectiveDefaultCadenceDays) day cadence")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 24)
                HStack {
                    Button("Edit", systemImage: "pencil") { onEdit() }
                    Spacer()
                    Button("Archive", systemImage: "archivebox", role: .destructive) { onArchive() }
                        .disabled(sphere.isBootstrapDefault)
                        .help(sphere.isBootstrapDefault ? "The bootstrap default sphere can't be archived — rename it instead." : "Hide this sphere from active UI. Memberships are preserved.")
                }
            }
            .padding(20)
        }
    }

    private var keywordChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(sphere.keywordHints, id: \.self) { hint in
                Text(hint)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(sphere.accentColor.color.opacity(0.18), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var examplesList: some View {
        if sphere.examples.isEmpty {
            Text("None yet. SAM populates this pool as you confirm classifier picks in the review batch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sphere.examples.sorted(by: { $0.addedAt > $1.addedAt })) { example in
                    exampleRow(example)
                }
            }
        }
    }

    private func exampleRow(_ example: SphereExample) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: example.wasOverride ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(example.wasOverride ? .orange : .green)
                .help(example.wasOverride ? "User-corrected (classifier picked a different sphere)" : "User-confirmed")
            VStack(alignment: .leading, spacing: 2) {
                Text(example.snippet)
                    .font(.caption)
                    .lineLimit(2)
                Text(example.addedAt, format: .dateTime.month().day().year().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                try? SphereRepository.shared.removeExample(exampleID: example.id, fromSphere: sphere.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this example from the pool")
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(sphere.accentColor.color)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(sphere.name).font(.title2).bold()
                Text("\(memberCount) member\(memberCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .task(id: sphere.id) {
            memberCount = (try? SphereRepository.shared.memberships(forSphere: sphere.id).count) ?? 0
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}

// MARK: - Add sphere sheet

private struct AddLifeSphereSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingSphereCount: Int
    let onPick: (LifeSphereTemplate) -> Void

    @State private var selectedTemplateID: String?
    @State private var typeToConfirm: String = ""

    private var requireExplicitConfirm: Bool { existingSphereCount >= 4 }
    private var showWarning: Bool { existingSphereCount >= 2 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if showWarning {
                    warningBanner
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(LifeSphereTemplate.all) { template in
                            templateRow(template)
                        }
                        customRow
                    }
                }
                if requireExplicitConfirm, let id = selectedTemplateID, let template = LifeSphereTemplate.all.first(where: { $0.id == id }) {
                    typeConfirmField(template: template)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(width: 520, height: 540)
            .navigationTitle("Add a Sphere")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add") {
                        if let id = selectedTemplateID, let template = LifeSphereTemplate.all.first(where: { $0.id == id }) {
                            onPick(template)
                            dismiss()
                        }
                    }
                    .disabled(!canAdd)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: existingSphereCount >= 4 ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(existingSphereCount >= 4 ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(existingSphereCount >= 4 ? "You already have \(existingSphereCount) spheres" : "You already have \(existingSphereCount) sphere\(existingSphereCount == 1 ? "" : "s")")
                    .font(.callout).bold()
                Text(existingSphereCount >= 4
                     ? "More spheres means more classification work and more cognitive load. Most people thrive with 2–3. If this isn't truly a separate life area, consider folding it into an existing sphere instead."
                     : "Each additional sphere means more classification decisions per message. Make sure this is a separate life area, not a sub-topic of one you already have.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func templateRow(_ template: LifeSphereTemplate) -> some View {
        Button {
            selectedTemplateID = template.id
            typeToConfirm = ""
        } label: {
            HStack(spacing: 12) {
                Image(systemName: template.icon)
                    .foregroundStyle(template.accentColor.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name).font(.body).bold()
                    Text(template.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: selectedTemplateID == template.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedTemplateID == template.id ? Color.accentColor : .secondary)
            }
            .padding(10)
            .background(selectedTemplateID == template.id ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var customRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom Sphere").font(.body).bold()
                Text("Create a blank sphere and write your own classification profile. Use only when none of the templates fit.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .opacity(0.5)
        .help("Custom spheres ship in a later build. For now, pick the closest template and rename/edit it.")
    }

    private func typeConfirmField(template: LifeSphereTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type **\(template.name)** below to confirm.")
                .font(.caption)
            TextField("Sphere name to confirm", text: $typeToConfirm)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.top, 4)
    }

    private var canAdd: Bool {
        guard let id = selectedTemplateID,
              let template = LifeSphereTemplate.all.first(where: { $0.id == id }) else { return false }
        if requireExplicitConfirm {
            return typeToConfirm.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(template.name) == .orderedSame
        }
        return true
    }
}

// MARK: - Edit sphere sheet

private struct EditSphereSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sphere: Sphere
    let onSaved: () -> Void

    @State private var name: String = ""
    @State private var purpose: String = ""
    @State private var classificationProfile: String = ""
    @State private var keywordHints: [String] = []
    @State private var keywordInput: String = ""
    @State private var accentColor: SphereAccentColor = .slate
    @State private var defaultMode: Mode = .stewardship
    @State private var saveError: String?

    private static let minProfileChars = 40
    /// Upper bound on the classification profile per the sphere spec.
    /// Caps prompt-token cost and keeps the profile focused — long
    /// rambles dilute the classifier signal.
    private static let maxProfileChars = 500

    private var trimmedProfile: String {
        classificationProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var profileMeetsMinimum: Bool {
        trimmedProfile.count >= Self.minProfileChars
    }

    private var profileWithinMaximum: Bool {
        trimmedProfile.count <= Self.maxProfileChars
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && profileMeetsMinimum
            && profileWithinMaximum
    }

    private var counterText: String {
        if !profileWithinMaximum {
            return "\(trimmedProfile.count) / \(Self.maxProfileChars) — trim to save"
        }
        if !profileMeetsMinimum {
            return "\(trimmedProfile.count) / \(Self.minProfileChars) characters"
        }
        return "\(trimmedProfile.count) / \(Self.maxProfileChars) characters"
    }

    private var counterColor: Color {
        if !profileWithinMaximum { return .red }
        if !profileMeetsMinimum { return .orange }
        return .secondary
    }

    private var saveButtonHelp: String {
        if !profileWithinMaximum {
            return "Classification profile exceeds the \(Self.maxProfileChars)-character limit. Trim before saving."
        }
        if !profileMeetsMinimum {
            return "Add at least \(Self.minProfileChars) characters to the classification profile before saving."
        }
        return ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name & purpose") {
                    TextField("Name", text: $name)
                    TextField("Purpose (optional)", text: $purpose, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    TextEditor(text: $classificationProfile)
                        .frame(minHeight: 140)
                        .font(.callout)
                    HStack {
                        Spacer()
                        Text(counterText)
                            .font(.caption2)
                            .foregroundStyle(counterColor)
                    }
                } header: {
                    Text("Classification profile")
                } footer: {
                    Text("SAM uses this to decide whether a piece of evidence (an email, a meeting, a message) belongs to this sphere when a person has memberships in multiple spheres. Concrete topics, tone cues, and exclusions help most. \(Self.minProfileChars)–\(Self.maxProfileChars) characters keeps the classifier focused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    keywordEditor
                } header: {
                    Text("Keyword hints")
                } footer: {
                    Text("Optional shortcuts — concrete words or phrases that, when they appear in an interaction, lean SAM toward this sphere. Use sparingly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Appearance & defaults") {
                    Picker("Accent color", selection: $accentColor) {
                        ForEach(SphereAccentColor.allCases, id: \.self) { color in
                            HStack {
                                Circle().fill(color.color).frame(width: 12, height: 12)
                                Text(color.displayName)
                            }.tag(color)
                        }
                    }
                    Picker("Default mode", selection: $defaultMode) {
                        ForEach(Mode.allCases, id: \.self) { mode in
                            Label(mode.displayName, systemImage: mode.icon).tag(mode)
                        }
                    }
                }
                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .frame(width: 560, height: 600)
            .navigationTitle("Edit \(sphere.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                        .help(saveButtonHelp)
                }
            }
            .onAppear(perform: loadFields)
        }
    }

    private var keywordEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !keywordHints.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(keywordHints, id: \.self) { hint in
                        HStack(spacing: 4) {
                            Text(hint).font(.caption)
                            Button {
                                keywordHints.removeAll { $0 == hint }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(sphere.accentColor.color.opacity(0.18), in: Capsule())
                    }
                }
            }
            HStack {
                TextField("Add a hint (press Return)", text: $keywordInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitKeyword)
                Button("Add", action: commitKeyword)
                    .disabled(keywordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func commitKeyword() {
        let trimmed = keywordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !keywordHints.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            keywordHints.append(trimmed)
        }
        keywordInput = ""
    }

    private func loadFields() {
        name = sphere.name
        purpose = sphere.purpose
        classificationProfile = sphere.classificationProfile
        keywordHints = sphere.keywordHints
        accentColor = sphere.accentColor
        defaultMode = sphere.defaultMode
    }

    private func save() {
        do {
            try SphereRepository.shared.updateSphere(
                id: sphere.id,
                name: name,
                purpose: purpose,
                classificationProfile: classificationProfile,
                keywordHints: keywordHints,
                accentColor: accentColor,
                defaultMode: defaultMode
            )
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
