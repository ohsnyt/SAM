//
//  SpheresOverviewView.swift
//  SAM
//
//  Phase 5 of the relationship-model refactor (May 2026).
//
//  Lists every active Sphere as a card showing purpose, member count, active
//  Trajectories, and a roll-up of open coaching items in that Sphere. Tapping
//  a card pushes into SphereDetailView. Surfaced as a tab in
//  BusinessDashboardView only when the user has 2+ Spheres — Sarah's single-
//  Sphere experience must remain unchanged (Sarah-regression check).
//

import SwiftUI

struct SpheresOverviewView: View {

    @State private var spheres: [Sphere] = []
    @State private var memberCounts: [UUID: Int] = [:]
    @State private var activeTrajectories: [UUID: [Trajectory]] = [:]
    @State private var openOutcomeCounts: [UUID: Int] = [:]
    @State private var showNewSphereSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    if spheres.isEmpty {
                        emptyState
                    } else {
                        ForEach(spheres) { sphere in
                            NavigationLink {
                                SphereDetailView(sphere: sphere)
                            } label: {
                                sphereCard(sphere)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationDestination(for: Sphere.self) { sphere in
                SphereDetailView(sphere: sphere)
            }
        }
        .task { refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Spheres", systemImage: "circle.grid.3x3.fill")
                .samFont(.headline)
            Spacer()
            Button {
                showNewSphereSheet = true
            } label: {
                Label("New Sphere", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help("Coming soon — Phase 5b")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "No Spheres yet",
            systemImage: "circle.grid.3x3",
            description: Text("Spheres are the different hats you wear — your practice, a board you serve on, a community you lead. SAM coaches each one on its own rhythm.")
        )
        .padding(.top, 40)
    }

    // MARK: - Sphere card

    private func sphereCard(_ sphere: Sphere) -> some View {
        let memberCount = memberCounts[sphere.id] ?? 0
        let trajectories = activeTrajectories[sphere.id] ?? []
        let openCount = openOutcomeCounts[sphere.id] ?? 0
        let accent = sphere.accentColor.color

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(sphere.name)
                            .samFont(.headline)
                        if sphere.isBootstrapDefault {
                            Text("Default")
                                .samFont(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .samFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if !sphere.purpose.isEmpty {
                        Text(sphere.purpose)
                            .samFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            HStack(spacing: 16) {
                metricChip(icon: "person.2.fill", value: "\(memberCount)", label: memberCount == 1 ? "person" : "people")
                metricChip(icon: "arrow.triangle.branch", value: "\(trajectories.count)", label: trajectories.count == 1 ? "trajectory" : "trajectories")
                if openCount > 0 {
                    metricChip(icon: "lightbulb.fill", value: "\(openCount)", label: openCount == 1 ? "open item" : "open items", tint: .orange)
                }
                Spacer()
            }
            .padding(.leading, 14)

            if !trajectories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(trajectories) { trajectory in
                        HStack(spacing: 6) {
                            Image(systemName: trajectory.mode.icon)
                                .foregroundStyle(trajectory.mode.color)
                                .samFont(.caption)
                            Text(trajectory.name)
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(trajectory.mode.displayName)
                                .samFont(.caption2)
                                .foregroundStyle(trajectory.mode.color)
                        }
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(12)
        .background(accent.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func metricChip(icon: String, value: String, label: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .samFont(.caption)
                .foregroundStyle(tint)
            Text(value)
                .samFont(.caption)
                .fontWeight(.semibold)
            Text(label)
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Load

    private func refresh() {
        do {
            spheres = try SphereRepository.shared.fetchAll()

            var members: [UUID: Int] = [:]
            var trajectories: [UUID: [Trajectory]] = [:]
            for sphere in spheres {
                members[sphere.id] = (try? SphereRepository.shared.memberships(forSphere: sphere.id).count) ?? 0
                trajectories[sphere.id] = (try? TrajectoryRepository.shared.fetchAll(forSphere: sphere.id)) ?? []
            }
            memberCounts = members
            activeTrajectories = trajectories

            // Per-Sphere open outcome roll-up: count active SamOutcomes linked
            // to a person who is a member of this Sphere. Keeps the card
            // honest without re-implementing OutcomeRepository's filtering.
            var openCounts: [UUID: Int] = [:]
            if let allOutcomes = try? OutcomeRepository.shared.fetchActive() {
                let allMemberships = (try? SphereRepository.shared.fetchAllMemberships()) ?? []
                let sphereMembersByPerson: [UUID: Set<UUID>] = Dictionary(
                    grouping: allMemberships.compactMap { m -> (UUID, UUID)? in
                        guard let pid = m.person?.id, let sid = m.sphere?.id else { return nil }
                        return (pid, sid)
                    },
                    by: { $0.0 }
                ).mapValues { Set($0.map { $0.1 }) }

                for outcome in allOutcomes {
                    guard let personID = outcome.linkedPerson?.id,
                          let sphereIDs = sphereMembersByPerson[personID] else { continue }
                    for sphereID in sphereIDs {
                        openCounts[sphereID, default: 0] += 1
                    }
                }
            }
            openOutcomeCounts = openCounts
        } catch {
            spheres = []
        }
    }
}
