//
//  SphereDetailView.swift
//  SAM
//
//  Phase 5 of the relationship-model refactor (May 2026).
//
//  Drill-down for a single Sphere: purpose, default Mode, member list with
//  per-person Mode chip, active Trajectories with their stages and entries,
//  and the open coaching items rolled up to this Sphere.
//
//  Read-only in Phase 5a. Edit/archive/rename happens in Settings → Spheres
//  (Phase 5d). New-Trajectory creation also deferred — Phase 5 ships the
//  bootstrap-default and the first user-created Sphere flow first, and
//  Trajectory authoring rides on top in a later cut.
//

import SwiftUI

struct SphereDetailView: View {

    let sphere: Sphere

    @State private var memberships: [PersonSphereMembership] = []
    @State private var trajectories: [Trajectory] = []
    @State private var entriesByTrajectory: [UUID: [PersonTrajectoryEntry]] = [:]
    @State private var openOutcomes: [SamOutcome] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                trajectoriesSection
                membersSection
                openItemsSection
            }
            .padding()
        }
        .navigationTitle(sphere.name)
        .task { refresh() }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(sphere.accentColor.color)
                    .frame(width: 14, height: 14)
                Text(sphere.accentColor.displayName)
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                modeChip(sphere.defaultMode, label: "Default Mode")
            }

            if !sphere.purpose.isEmpty {
                Text(sphere.purpose)
                    .samFont(.body)
            } else {
                Text("No purpose statement yet.")
                    .samFont(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            }

            HStack(spacing: 16) {
                Label("\(memberships.count) \(memberships.count == 1 ? "person" : "people")",
                      systemImage: "person.2.fill")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                Label("Default cadence: \(sphere.effectiveDefaultCadenceDays) days",
                      systemImage: "calendar")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(sphere.accentColor.color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Trajectories

    private var trajectoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Trajectories", icon: "arrow.triangle.branch", count: trajectories.count)

            if trajectories.isEmpty {
                Text("No active trajectories. Add one when you start moving people through a defined arc inside this Sphere.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(trajectories) { trajectory in
                    trajectoryRow(trajectory)
                }
            }
        }
    }

    private func trajectoryRow(_ trajectory: Trajectory) -> some View {
        let entries = entriesByTrajectory[trajectory.id] ?? []

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: trajectory.mode.icon)
                    .foregroundStyle(trajectory.mode.color)
                Text(trajectory.name)
                    .samFont(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                modeChip(trajectory.mode)
                Text("\(entries.count)")
                    .samFont(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
            if let notes = trajectory.notes, !notes.isEmpty {
                Text(notes)
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Members

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Members", icon: "person.2.fill", count: memberships.count)

            if memberships.isEmpty {
                Text("Nobody is in this Sphere yet.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(memberships) { membership in
                    memberRow(membership)
                }
            }
        }
    }

    private func memberRow(_ membership: PersonSphereMembership) -> some View {
        let person = membership.person
        let name = person?.displayNameCache ?? person?.displayName ?? "Unknown"
        let mode = person.map { PersonModeResolver.effectiveMode(for: $0.id) } ?? sphere.defaultMode

        return HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text(name)
                .samFont(.body)
            Spacer()
            modeChip(mode)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Open items

    private var openItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Open coaching items", icon: "lightbulb.fill", count: openOutcomes.count)

            if openOutcomes.isEmpty {
                Text("No open coaching items for people in this Sphere.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(openOutcomes.prefix(10)) { outcome in
                    outcomeRow(outcome)
                }
                if openOutcomes.count > 10 {
                    Text("+ \(openOutcomes.count - 10) more")
                        .samFont(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func outcomeRow(_ outcome: SamOutcome) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(priorityColor(outcome.priorityScore))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.title)
                    .samFont(.subheadline)
                if let person = outcome.linkedPerson {
                    Text(person.displayNameCache ?? person.displayName)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
                .samFont(.headline)
            Text("(\(count))")
                .samFont(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func modeChip(_ mode: Mode, label: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: mode.icon)
                .samFont(.caption2)
            Text(label ?? mode.displayName)
                .samFont(.caption2)
                .fontWeight(.medium)
        }
        .foregroundStyle(mode.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(mode.color.opacity(0.12))
        .clipShape(Capsule())
    }

    private func priorityColor(_ score: Double) -> Color {
        switch score {
        case 0.75...: return .red
        case 0.5..<0.75: return .orange
        case 0.25..<0.5: return .yellow
        default: return .green
        }
    }

    // MARK: - Load

    private func refresh() {
        do {
            memberships = try SphereRepository.shared.memberships(forSphere: sphere.id)
            trajectories = try TrajectoryRepository.shared.fetchAll(forSphere: sphere.id)

            var entriesMap: [UUID: [PersonTrajectoryEntry]] = [:]
            for trajectory in trajectories {
                entriesMap[trajectory.id] = (try? PersonTrajectoryRepository.shared
                    .activeEntries(forTrajectory: trajectory.id)) ?? []
            }
            entriesByTrajectory = entriesMap

            let memberIDs = Set(memberships.compactMap { $0.person?.id })
            let allActive = (try? OutcomeRepository.shared.fetchActive()) ?? []
            openOutcomes = allActive.filter { outcome in
                guard let pid = outcome.linkedPerson?.id else { return false }
                return memberIDs.contains(pid)
            }
        } catch {
            memberships = []
            trajectories = []
            openOutcomes = []
        }
    }
}
