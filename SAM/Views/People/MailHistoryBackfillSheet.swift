//
//  MailHistoryBackfillSheet.swift
//  SAM
//
//  Per-person mail backfill preview sheet (2026-05-13).
//
//  Surfaced from PersonDetailView's Actions menu. Lets the user pull every
//  historical message to/from this person's email addresses, review the
//  candidate list, and commit only when satisfied. No evidence is written
//  until the user explicitly taps Import.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailBackfillSheet")

struct MailHistoryBackfillSheet: View {

    let person: SamPerson

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var preview: MailImportCoordinator.MailHistoryPreview?
    @State private var errorMessage: String?
    @State private var isCommitting = false
    @State private var committedCount: Int = 0

    enum Phase {
        case loading
        case ready
        case error
        case done
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 480, idealHeight: 620)
        .task {
            await loadPreview()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Mail History")
                    .font(.headline)
                Text(person.displayNameCache ?? person.displayName)
                    .samFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingView
        case .ready:
            if let preview {
                readyView(preview)
            } else {
                loadingView
            }
        case .error:
            errorView
        case .done:
            doneView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning Mail Envelope Index…")
                .samFont(.caption)
                .foregroundStyle(.secondary)
            Text("This may take a few seconds for accounts with years of history.")
                .samFont(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text(errorMessage ?? "Unknown error")
                .samFont(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
            Text(committedCount == 0
                 ? "Nothing to import."
                 : "Imported \(committedCount) message\(committedCount == 1 ? "" : "s").")
                .samFont(.body)
            if committedCount > 0 {
                Text("New evidence is linked to \(person.displayNameCache ?? person.displayName) and will appear in their interaction history.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func readyView(_ preview: MailImportCoordinator.MailHistoryPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryStrip(preview)

            if preview.newCandidates.isEmpty {
                emptyState(preview)
            } else {
                candidateList(preview)
            }
        }
        .padding()
    }

    private func summaryStrip(_ preview: MailImportCoordinator.MailHistoryPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                summaryStat(value: "\(preview.totalFound)", label: "found")
                summaryStat(value: "\(preview.alreadyImportedCount)", label: "already in SAM")
                summaryStat(value: "\(preview.willImportCount)", label: "new", emphasis: true)
                Spacer()
            }
            if let range = preview.dateRange {
                Text("Date range: \(range.oldest.formatted(date: .abbreviated, time: .omitted)) – \(range.newest.formatted(date: .abbreviated, time: .omitted))")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Searched addresses: \(preview.searchedEmails.joined(separator: ", "))")
                .samFont(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func summaryStat(value: String, label: String, emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(emphasis ? .blue : .primary)
            Text(label)
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func emptyState(_ preview: MailImportCoordinator.MailHistoryPreview) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(preview.totalFound == 0
                 ? "No mail found for this person's addresses."
                 : "All \(preview.totalFound) message\(preview.totalFound == 1 ? "" : "s") are already in SAM.")
                .samFont(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateList(_ preview: MailImportCoordinator.MailHistoryPreview) -> some View {
        List(preview.newCandidates) { candidate in
            HStack(spacing: 10) {
                Image(systemName: candidate.direction == .inbound
                      ? "arrow.down.left"
                      : "arrow.up.right")
                    .foregroundStyle(candidate.direction == .inbound ? .blue : .green)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.dto.subject.isEmpty ? "(no subject)" : candidate.dto.subject)
                        .samFont(.body)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(candidate.dto.date.formatted(date: .abbreviated, time: .shortened))
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(candidate.direction == .inbound
                             ? "from \(candidate.dto.senderEmail)"
                             : "sent")
                            .samFont(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if phase == .ready, let preview {
                Text(preview.willImportCount == 0
                     ? "Nothing new to import."
                     : "\(preview.willImportCount) new message\(preview.willImportCount == 1 ? "" : "s") will be added as evidence.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            } else if phase == .done {
                Text("Done.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if phase == .done {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else if phase == .ready, let preview {
                Button(isCommitting ? "Importing…" : "Import \(preview.willImportCount)") {
                    Task { await commit(preview) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.willImportCount == 0 || isCommitting)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func loadPreview() async {
        do {
            let result = try await MailImportCoordinator.shared.previewHistoricalMail(for: person)
            preview = result
            phase = .ready
        } catch {
            errorMessage = error.localizedDescription
            phase = .error
            logger.error("Backfill preview failed: \(error.localizedDescription)")
        }
    }

    private func commit(_ preview: MailImportCoordinator.MailHistoryPreview) async {
        isCommitting = true
        do {
            committedCount = try MailImportCoordinator.shared.commitHistoricalMail(preview)
            phase = .done
            NotificationCenter.default.post(name: .samPersonDidChange, object: nil)
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            phase = .error
            logger.error("Backfill commit failed: \(error.localizedDescription)")
        }
        isCommitting = false
    }
}
