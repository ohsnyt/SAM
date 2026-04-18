//
//  PendingUploadsManagementView.swift
//  SAM Field
//
//  Shows queued recordings waiting to sync to the Mac, with the ability
//  to delete individual items that are stuck or no longer needed.
//

import SwiftUI
import SwiftData

struct PendingUploadsManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(
        filter: #Predicate<PendingUpload> { $0.statusRawValue != "processed" },
        sort: \PendingUpload.createdAt,
        order: .forward
    )
    private var items: [PendingUpload]

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No pending recordings",
                        systemImage: "checkmark.circle",
                        description: Text("All recordings have synced to your Mac.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(items) { item in
                                PendingUploadRow(item: item)
                            }
                            .onDelete(perform: deleteItems)
                        } footer: {
                            Text("Swipe left to delete a recording. Deleted recordings cannot be recovered.")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Pending Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            let item = items[index]
            let localURL = MeetingRecordingService.url(fromRelativePath: item.localWAVPath)
            try? FileManager.default.removeItem(at: localURL)
            modelContext.delete(item)
        }
        try? modelContext.save()
        PendingUploadService.shared.refreshPendingCount()
    }
}

private struct PendingUploadRow: View {
    let item: PendingUpload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.bold())
                Spacer()
                statusBadge
            }
            HStack(spacing: 12) {
                Label(durationText, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(sizeText, systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = item.failureReason, !reason.isEmpty {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if item.attemptCount > 0 {
                Text("\(item.attemptCount) attempt\(item.attemptCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = switch item.status {
        case .pending:      ("Waiting", .secondary)
        case .uploading:    ("Uploading", .blue)
        case .awaitingAck:  ("Processing", .orange)
        case .processed:    ("Done", .green)
        case .failed:       ("Failed", .red)
        }
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var durationText: String {
        let d = Int(item.durationSeconds)
        if d >= 3600 {
            return String(format: "%dh %dm", d / 3600, (d % 3600) / 60)
        }
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    private var sizeText: String {
        let mb = Double(item.byteSize) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%d KB", item.byteSize / 1024)
    }
}
