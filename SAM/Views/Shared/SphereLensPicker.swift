//
//  SphereLensPicker.swift
//  SAM
//
//  Phase C6 of the multi-sphere classification work (May 2026).
//
//  Compact menu control that lets the user pick which sphere they're
//  viewing the app through. Hidden entirely when no dual-sphere people
//  exist — single-sphere users never see this UI, so the chrome stays
//  clean for the majority case.
//
//  Visual posture:
//    • Unfiltered ("All spheres") → muted, low-contrast — no badge.
//    • Filtered → sphere accent color + name, clearly visible as a
//      "you are filtered" indicator so the user doesn't forget.
//

import SwiftUI

struct SphereLensPicker: View {
    @State private var coordinator = SphereLensCoordinator.shared
    @State private var spheres: [Sphere] = []

    var body: some View {
        if coordinator.isPickerAvailable {
            Menu {
                Button {
                    coordinator.clearLens()
                } label: {
                    Label("All spheres", systemImage: coordinator.currentLens == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(spheres) { sphere in
                    Button {
                        coordinator.setLens(sphere)
                    } label: {
                        Label(
                            sphere.name,
                            systemImage: coordinator.currentLens?.id == sphere.id ? "checkmark" : "circle.fill"
                        )
                        .foregroundStyle(sphere.accentColor.color)
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .help(coordinator.currentLens == nil
                  ? "Viewing all spheres"
                  : "Viewing only the \(coordinator.currentLens!.name) sphere")
            .task { reloadSpheres() }
            .onReceive(NotificationCenter.default.publisher(for: .samSphereDidChange)) { _ in
                reloadSpheres()
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if let lens = coordinator.currentLens {
            HStack(spacing: 6) {
                Circle()
                    .fill(lens.accentColor.color)
                    .frame(width: 8, height: 8)
                Text(lens.name)
                    .font(.callout.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(lens.accentColor.color.opacity(0.15), in: Capsule())
        } else {
            HStack(spacing: 4) {
                Image(systemName: "circle.grid.3x3")
                Text("All spheres")
                    .font(.callout)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func reloadSpheres() {
        spheres = (try? SphereRepository.shared.fetchAll()) ?? []
    }
}
