//
//  BlockingActivityOverlay.swift
//  SAM
//
//  Full-window blocking screen shown when SAM is in a state that must not be
//  interrupted by normal UI interaction — currently a backup restore (the
//  store is being deleted and rewritten) or a graceful quit (we're waiting
//  for background AI work to finish before tearing down). The view is
//  rendered IN PLACE OF the main app shell (not as a `.overlay`) so that
//  underlying @Query observers stop firing while the data layer is in flux.
//
//  Both backup restore and shutdown route through the same overlay; shutdown
//  takes precedence when both are active. The "Waiting for:" line names the
//  blocking coordinators so the user understands why nothing visible is
//  happening yet.
//

import SwiftUI

struct BlockingActivityOverlay: View {

    @State private var backup = BackupCoordinator.shared
    @State private var shutdown = ShutdownCoordinator.shared

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)

                VStack(spacing: 6) {
                    Text(activity.title)
                        .font(.title2.bold())
                    Text(activity.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !activity.progress.isEmpty {
                    Text(activity.progress)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }

                if !activity.blockedBy.isEmpty {
                    VStack(spacing: 4) {
                        Text("Waiting for:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(activity.blockedBy.joined(separator: ", "))
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
    }

    private struct Activity {
        let title: String
        let subtitle: String
        let progress: String
        let blockedBy: [String]
    }

    private var activity: Activity {
        if shutdown.isShuttingDown {
            return Activity(
                title: "Quitting SAM",
                subtitle: "Waiting for background work to finish before quit.",
                progress: shutdown.progress,
                blockedBy: shutdown.blockedBy
            )
        }
        return Activity(
            title: "Restoring Backup",
            subtitle: "Please don't quit SAM until the restore finishes.",
            progress: backup.progress,
            blockedBy: backup.blockedBy
        )
    }
}
