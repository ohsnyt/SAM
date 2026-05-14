//
//  UnfinishedDraftBanner.swift
//  SAM
//
//  Phase 4 of the sheet-tear-down work loss fix.
//
//  Surfaces unfinished form drafts on the Today view so Sarah always
//  has a clear path back to in-progress work that was interrupted by
//  displacement, lock, crash, or just walking away. Also delivers the
//  plain-English notice when the 7-day auto-discard job clears stale
//  drafts on launch.
//
//  Two display states:
//    • One or more unfinished drafts → list each row with Resume /
//      Discard. Resume reconstructs the CapturePayload from the draft's
//      snapshot and posts `.samOpenPostMeetingCapture`; AppShellView's
//      existing listener picks it up and presents the sheet through
//      ModalCoordinator.
//    • Auto-discard notice pending → one row with the plain-English
//      message and an OK button to acknowledge.
//
//  The banner refreshes on appear and on `.samFormDraftsDidChange`,
//  which any path that creates / clears a draft can post if it needs
//  the banner to reflect the change immediately (most submits already
//  trigger a refresh on the next view appear).
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "UnfinishedDraftBanner")

struct UnfinishedDraftBanner: View {

    @State private var drafts: [DraftPersistenceService.Descriptor] = []
    @State private var pendingDiscardCount: Int = 0
    @State private var discardToConfirm: DraftPersistenceService.Descriptor?

    var body: some View {
        Group {
            if pendingDiscardCount > 0 || !drafts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if pendingDiscardCount > 0 {
                        autoDiscardNotice
                        if !drafts.isEmpty {
                            Divider().padding(.horizontal, 16)
                        }
                    }
                    if !drafts.isEmpty {
                        draftList
                    }
                }
                .padding(.vertical, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .samFormDraftsDidChange)) { _ in
            refresh()
        }
        .alert(
            "Discard unfinished notes?",
            isPresented: Binding(
                get: { discardToConfirm != nil },
                set: { if !$0 { discardToConfirm = nil } }
            ),
            presenting: discardToConfirm
        ) { descriptor in
            Button("Discard", role: .destructive) {
                discard(descriptor)
            }
            Button("Cancel", role: .cancel) {
                discardToConfirm = nil
            }
        } message: { descriptor in
            Text("Your in-progress notes for \"\(descriptor.displayTitle ?? "this capture")\" will be deleted. This can't be undone.")
        }
        .dismissOnLock(isPresented: Binding(
            get: { discardToConfirm != nil },
            set: { if !$0 { discardToConfirm = nil } }
        ))
    }

    // MARK: - Auto-discard notice (plain English)

    private var autoDiscardNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(autoDiscardHeadline)
                    .samFont(.subheadline)
                    .fontWeight(.semibold)
                Text("SAM keeps unfinished work for one week. Older notes are cleared automatically so the Today view stays tidy.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("OK") {
                acknowledgeNotice()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var autoDiscardHeadline: String {
        switch pendingDiscardCount {
        case 1:  return "1 unfinished note was cleared"
        default: return "\(pendingDiscardCount) unfinished notes were cleared"
        }
    }

    // MARK: - Draft list

    private var draftList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text.below.ecg")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(listHeadline)
                    .samFont(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)

            ForEach(drafts.prefix(3)) { descriptor in
                draftRow(descriptor)
            }

            if drafts.count > 3 {
                Text("+\(drafts.count - 3) more")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var listHeadline: String {
        switch drafts.count {
        case 1:  return "1 unfinished note"
        default: return "\(drafts.count) unfinished notes"
        }
    }

    @ViewBuilder
    private func draftRow(_ descriptor: DraftPersistenceService.Descriptor) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayTitle ?? "Unfinished note")
                    .samFont(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let subtitle = descriptor.displaySubtitle {
                        Text(subtitle)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·")
                            .samFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text("Last edited \(descriptor.updatedAt.formatted(.relative(presentation: .named)))")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Resume") {
                resume(descriptor)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Discard") {
                discardToConfirm = descriptor
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func refresh() {
        drafts = DraftPersistenceService.shared.unfinishedDraftDescriptors()
        pendingDiscardCount = DraftPersistenceService.shared.pendingAutoDiscardNotice().count
    }

    private func acknowledgeNotice() {
        DraftPersistenceService.shared.acknowledgePendingAutoDiscardNotice()
        pendingDiscardCount = 0
    }

    private func resume(_ descriptor: DraftPersistenceService.Descriptor) {
        guard descriptor.formKind == .postMeetingCapture else {
            logger.warning("Resume requested for unsupported form kind \(descriptor.formKind.rawValue)")
            return
        }
        guard let stored = DraftPersistenceService.shared.load(
            PostMeetingCaptureCoordinator.StoredPayload.self,
            kind: .postMeetingCapture,
            subjectID: descriptor.subjectID
        ) else {
            logger.warning("Failed to load StoredPayload for resume of \(descriptor.subjectID)")
            return
        }
        guard let snapshot = stored.payloadSnapshot else {
            // Draft pre-dates the snapshot field. Without payload context
            // (attendees, talking points) we can't reconstruct the sheet.
            // Surface the issue rather than silently failing.
            logger.warning("Draft \(descriptor.subjectID) has no payload snapshot; resume aborted")
            return
        }
        let payload = snapshot.toCapturePayload()
        NotificationCenter.default.post(
            name: .samOpenPostMeetingCapture,
            object: nil,
            userInfo: ["payload": payload]
        )
    }

    private func discard(_ descriptor: DraftPersistenceService.Descriptor) {
        DraftPersistenceService.shared.delete(
            kind: descriptor.formKind,
            subjectID: descriptor.subjectID
        )
        discardToConfirm = nil
        refresh()
        NotificationCenter.default.post(name: .samFormDraftsDidChange, object: nil)
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted after any code path mutates the FormDraft set (create,
    /// delete, auto-discard). The Today restore banner observes this so
    /// its row list stays current without waiting for the next view
    /// appear.
    static let samFormDraftsDidChange = Notification.Name("samFormDraftsDidChange")
}
