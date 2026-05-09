//
//  RestoreInProgressOverlay.swift
//  SAM
//
//  Full-window blocking overlay shown while a backup restore is in progress.
//  A restore is non-cancellable once confirmed (it deletes and rewrites the
//  store), so we block all UI input until it completes. The overlay surfaces
//  the current phase and, during the settle wait, names the background
//  coordinators we're waiting on so the user understands why nothing is
//  happening yet.
//

import SwiftUI

struct RestoreInProgressOverlay: View {

    @State private var coordinator = BackupCoordinator.shared

    var body: some View {
        if isRestoring {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { /* swallow taps */ }

                VStack(spacing: 18) {
                    ProgressView()
                        .controlSize(.large)

                    VStack(spacing: 6) {
                        Text("Restoring Backup")
                            .font(.title2.bold())
                        Text("Please don't quit SAM until the restore finishes.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !coordinator.progress.isEmpty {
                        Text(coordinator.progress)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }

                    if !coordinator.blockedBy.isEmpty {
                        VStack(spacing: 4) {
                            Text("Waiting for:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(coordinator.blockedBy.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(28)
                .frame(maxWidth: 380)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 20)
            }
            .transition(.opacity)
        }
    }

    private var isRestoring: Bool {
        if case .importing = coordinator.status { return true }
        return false
    }
}
