//
//  EventEvaluationImportSheet.swift
//  SAM
//
//  Created on April 7, 2026.
//  Import sheet for post-event evaluation materials: chat transcripts,
//  feedback CSV exports, and optional Zoom transcripts.
//

import SwiftUI
import UniformTypeIdentifiers

struct EventEvaluationImportSheet: View {

    let event: SamEvent
    var onComplete: (() -> Void)?

    @State private var coordinator = PostEventEvaluationCoordinator.shared
    @State private var showChatImporter = false
    @State private var showFeedbackImporter = false
    @State private var showTranscriptImporter = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Post-Event Evaluation")
                        .samFont(.title2, weight: .semibold)
                    Text(event.title)
                        .samFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Status banner
                    if let error = coordinator.lastError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .samFont(.caption)
                        }
                        .padding(8)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if !coordinator.progressMessage.isEmpty && coordinator.evaluationStatus != .pending {
                        HStack {
                            if coordinator.evaluationStatus == .importing || coordinator.evaluationStatus == .analyzing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            Text(coordinator.progressMessage)
                                .samFont(.caption)
                        }
                        .padding(8)
                        .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Import cards
                    importCard(
                        title: "Zoom Chat Transcript",
                        icon: "bubble.left.and.text.bubble.right",
                        description: "Import the chat .txt file exported from Zoom. SAM will identify participants, analyze engagement, and detect conversion signals.",
                        importDate: event.evaluation?.chatImportedAt,
                        action: { showChatImporter = true }
                    )

                    importCard(
                        title: "Feedback Form Responses",
                        icon: "list.clipboard",
                        description: "Import the Google Forms CSV export. SAM will map responses to participants and identify warm leads.",
                        importDate: event.evaluation?.feedbackImportedAt,
                        action: { showFeedbackImporter = true }
                    )

                    importCard(
                        title: "Zoom Transcript (Optional)",
                        icon: "text.alignleft",
                        description: "Import a Zoom auto-transcript (.vtt) for deeper content analysis. Not required.",
                        importDate: event.evaluation?.transcriptImportedAt,
                        action: { showTranscriptImporter = true }
                    )

                    // Finalize button
                    if hasImportedData {
                        Divider()

                        Button {
                            Task {
                                await coordinator.finalizeEvaluation(for: event)
                                onComplete?()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "brain")
                                Text("Run Analysis & Generate Follow-Ups")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(coordinator.evaluationStatus == .analyzing)
                    }
                }
                .padding()
            }
        }
        .frame(width: 520, height: 600)
        .fileImporter(
            isPresented: $showChatImporter,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    await coordinator.importChatTranscript(url: url, for: event)
                }
            }
        }
        .fileImporter(
            isPresented: $showFeedbackImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    await coordinator.importFeedbackCSV(url: url, for: event)
                }
            }
        }
        .fileImporter(
            isPresented: $showTranscriptImporter,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            // VTT transcript import — future enhancement
        }
        .sheet(isPresented: $coordinator.showParticipantReview) {
            ParticipantMatchReviewSheet(
                event: event,
                pendingReviews: $coordinator.pendingParticipantReviews
            )
        }
        .sheet(isPresented: $coordinator.showFeedbackColumnMapping) {
            FeedbackColumnMappingSheet(
                headers: coordinator.csvHeaders,
                rows: coordinator.csvRows,
                event: event
            )
        }
    }

    // MARK: - Import Card

    private func importCard(
        title: String,
        icon: String,
        description: String,
        importDate: Date?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 28)
                Text(title)
                    .samFont(.headline)
                Spacer()
                if let date = importDate {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Imported \(date.formatted(.relative(presentation: .named)))")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(description)
                .samFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(importDate != nil ? "Re-import" : "Import") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private var hasImportedData: Bool {
        event.evaluation?.chatImportedAt != nil || event.evaluation?.feedbackImportedAt != nil
    }
}
