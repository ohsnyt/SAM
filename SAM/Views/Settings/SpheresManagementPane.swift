//
//  SpheresManagementPane.swift
//  SAM
//
//  Phase 5 of the relationship-model refactor (May 2026).
//
//  Settings pane for managing Spheres: create, rename, edit purpose,
//  change accent color / default Mode / cadence, archive, unarchive.
//  Read-only Sphere browsing lives in BusinessDashboardView's Spheres
//  tab; structural edits live here to keep the dashboard focused on
//  the active picture.
//

import SwiftUI

struct SpheresManagementPane: View {

    @State private var allSpheres: [Sphere] = []
    @State private var memberCounts: [UUID: Int] = [:]
    @State private var trajectoryCounts: [UUID: Int] = [:]
    @State private var editingSphere: Sphere?
    @State private var showNewSphereSheet = false

    var body: some View {
        Form {
            Section {
                header
            }

            if !activeSpheres.isEmpty {
                Section("Active") {
                    ForEach(activeSpheres) { sphere in
                        sphereRow(sphere)
                    }
                }
            } else {
                Section("Active") {
                    Text("No active Spheres yet.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !archivedSpheres.isEmpty {
                Section("Archived") {
                    ForEach(archivedSpheres) { sphere in
                        archivedRow(sphere)
                    }
                }
            }

            Section {
                Text("Spheres are the different hats you wear — your practice, a board you serve on, a community you lead. SAM coaches each one on its own rhythm. Archiving a Sphere hides it from active views but preserves its membership history.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
        .managedSheet(
            isPresented: $showNewSphereSheet,
            priority: .userInitiated,
            identifier: "settings.new-sphere"
        ) {
            NewSphereSheet { _ in refresh() }
        }
        .managedSheet(
            item: $editingSphere,
            priority: .userInitiated,
            identifier: "settings.edit-sphere"
        ) { sphere in
            EditSphereSheet(sphere: sphere) { refresh() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Spheres")
                    .samFont(.headline)
                Text("\(activeSpheres.count) active, \(archivedSpheres.count) archived")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showNewSphereSheet = true
            } label: {
                Label("New Sphere", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Rows

    private func sphereRow(_ sphere: Sphere) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(sphere.accentColor.color)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sphere.name)
                        .samFont(.body)
                    if sphere.isBootstrapDefault {
                        Text("Default")
                            .samFont(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 10) {
                    Label("\(memberCounts[sphere.id] ?? 0)", systemImage: "person.2.fill")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                    Label("\(trajectoryCounts[sphere.id] ?? 0)", systemImage: "arrow.triangle.branch")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                    Label(sphere.defaultMode.displayName, systemImage: sphere.defaultMode.icon)
                        .samFont(.caption)
                        .foregroundStyle(sphere.defaultMode.color)
                }
            }
            Spacer()
            Button("Edit") { editingSphere = sphere }
                .buttonStyle(.bordered)
            Button {
                archive(sphere)
            } label: {
                Image(systemName: "archivebox")
            }
            .buttonStyle(.bordered)
            .disabled(sphere.isBootstrapDefault)
            .help(sphere.isBootstrapDefault
                  ? "The default Sphere can't be archived"
                  : "Archive this Sphere (preserves history)")
        }
        .padding(.vertical, 2)
    }

    private func archivedRow(_ sphere: Sphere) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(sphere.accentColor.color.opacity(0.4))
                .frame(width: 14, height: 14)
            Text(sphere.name)
                .samFont(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Unarchive") { unarchive(sphere) }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Derived

    private var activeSpheres: [Sphere] {
        allSpheres.filter { !$0.archived }
    }

    private var archivedSpheres: [Sphere] {
        allSpheres.filter { $0.archived }
    }

    // MARK: - Mutations

    private func archive(_ sphere: Sphere) {
        try? SphereRepository.shared.setArchived(id: sphere.id, true)
        PersonModeResolver.invalidateCache()
        refresh()
    }

    private func unarchive(_ sphere: Sphere) {
        try? SphereRepository.shared.setArchived(id: sphere.id, false)
        PersonModeResolver.invalidateCache()
        refresh()
    }

    // MARK: - Load

    private func refresh() {
        allSpheres = (try? SphereRepository.shared.fetchAllIncludingArchived()) ?? []
        var members: [UUID: Int] = [:]
        var trajectories: [UUID: Int] = [:]
        for sphere in allSpheres {
            members[sphere.id] = (try? SphereRepository.shared.memberships(forSphere: sphere.id).count) ?? 0
            trajectories[sphere.id] = (try? TrajectoryRepository.shared.fetchAll(forSphere: sphere.id).count) ?? 0
        }
        memberCounts = members
        trajectoryCounts = trajectories
    }
}

// MARK: - Edit sheet

private struct EditSphereSheet: View {

    let sphere: Sphere
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var purpose: String
    @State private var accentColor: SphereAccentColor
    @State private var defaultMode: Mode
    @State private var useCadenceOverride: Bool
    @State private var cadenceDays: Int
    @State private var errorMessage: String?

    init(sphere: Sphere, onSaved: @escaping () -> Void) {
        self.sphere = sphere
        self.onSaved = onSaved
        _name = State(initialValue: sphere.name)
        _purpose = State(initialValue: sphere.purpose)
        _accentColor = State(initialValue: sphere.accentColor)
        _defaultMode = State(initialValue: sphere.defaultMode)
        _useCadenceOverride = State(initialValue: sphere.defaultCadenceDays != nil)
        _cadenceDays = State(initialValue: sphere.defaultCadenceDays ?? sphere.defaultMode.defaultCadenceDays)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sphere") {
                    TextField("Name", text: $name)
                    TextField("Purpose", text: $purpose, axis: .vertical)
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

                Section("Cadence") {
                    Toggle("Override default cadence", isOn: $useCadenceOverride)
                    if useCadenceOverride {
                        Stepper("Every \(cadenceDays) days",
                                value: $cadenceDays,
                                in: 1...365)
                    } else {
                        Text("Uses the \(defaultMode.displayName) default of \(defaultMode.defaultCadenceDays) days.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .samFont(.caption)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Sphere")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 540)
    }

    private func save() {
        do {
            try SphereRepository.shared.updateSphere(
                id: sphere.id,
                name: name.trimmingCharacters(in: .whitespaces),
                purpose: purpose.trimmingCharacters(in: .whitespaces),
                accentColor: accentColor,
                defaultMode: defaultMode,
                defaultCadenceDays: useCadenceOverride ? .some(cadenceDays) : .some(nil),
                sortOrder: nil
            )
            PersonModeResolver.invalidateCache()
            onSaved()
            dismiss()
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
