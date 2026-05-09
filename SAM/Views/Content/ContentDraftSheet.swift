//
//  ContentDraftSheet.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase W: Content Assist & Social Media Coaching
//
//  Sheet for generating AI-powered social media drafts from content outcomes.
//  Supports platform selection, draft editing, clipboard copy, and post logging.
//

import SwiftUI
import TipKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContentDraftSheet")

struct ContentDraftSheet: View {

    let topic: String
    let keyPoints: [String]
    let suggestedTone: String
    let complianceNotes: String?
    let sourceOutcomeID: UUID?
    let onPosted: () -> Void
    let onCancel: () -> Void

    // MARK: - Draft persistence

    private static let draftKind = "content-draft"

    private var draftID: String { sourceOutcomeID?.uuidString ?? "new" }

    // MARK: - State

    @State private var selectedPlatform: ContentPlatform = .linkedin
    @State private var draftText: String = ""
    @State private var complianceFlags: [String] = []
    @State private var localComplianceFlags: [ComplianceFlag] = []
    @State private var isGenerating = false
    @State private var isEditing = false
    @State private var errorMessage: String?
    @State private var hasGenerated = false
    @State private var auditEntryID: UUID?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TipView(ContentDraftTip())
                .tipViewStyle(SAMTipViewStyle())

            // Title
            Text("Content Draft")
                .samFont(.title3)
                .fontWeight(.semibold)

            // Topic context
            VStack(alignment: .leading, spacing: 4) {
                Text(topic)
                    .samFont(.subheadline)
                    .fontWeight(.medium)
                if !keyPoints.isEmpty {
                    Text(keyPoints.joined(separator: " \u{2022} "))
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            // Platform picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Platform")
                    .samFont(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    ForEach([ContentPlatform.linkedin, .facebook, .instagram, .substack], id: \.rawValue) { platform in
                        Button {
                            selectedPlatform = platform
                            // Reset draft when platform changes
                            if hasGenerated {
                                draftText = ""
                                complianceFlags = []
                                hasGenerated = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: platform.icon)
                                    .samFont(.caption)
                                Text(platform.rawValue)
                                    .samFont(.caption)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedPlatform == platform
                                ? platform.color.opacity(0.2)
                                : Color(nsColor: .controlBackgroundColor))
                            .foregroundStyle(selectedPlatform == platform
                                ? platform.color
                                : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Generate button (shown when no draft yet)
            if !hasGenerated && !isGenerating {
                Button {
                    generateDraft()
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("Generate Draft")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            // Loading indicator
            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating \(selectedPlatform.rawValue) draft...")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Draft text area
            if hasGenerated {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Draft")
                            .samFont(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Button(isEditing ? "Done" : "Edit") {
                            isEditing.toggle()
                        }
                        .samFont(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }

                    if isEditing {
                        TextEditor(text: $draftText)
                            .samFont(.body)
                            .frame(minHeight: 200, maxHeight: 400)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        ScrollView {
                            Text(draftText)
                                .samFont(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 160, maxHeight: 400)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Regenerate
                    Button {
                        generateDraft()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .samFont(.caption2)
                            Text("Regenerate")
                                .samFont(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            // Compliance flags (LLM + local scanner)
            if !complianceFlags.isEmpty || !localComplianceFlags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(complianceFlags, id: \.self) { flag in
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .samFont(.caption2)
                                .foregroundStyle(.orange)
                            Text(flag)
                                .samFont(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    ForEach(localComplianceFlags) { flag in
                        HStack(spacing: 4) {
                            Image(systemName: flag.category.icon)
                                .samFont(.caption2)
                                .foregroundStyle(.orange)
                            Text("\"\(flag.matchedPhrase)\"")
                                .samFont(.caption)
                                .foregroundStyle(.orange)
                            if let suggestion = flag.suggestion {
                                Text("— \(suggestion)")
                                    .samFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .samFont(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            // Action buttons
            HStack {
                if hasGenerated {
                    Button {
                        copyToClipboard()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .samFont(.caption)
                            Text("Copy")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Spacer()

                Button("Cancel") {
                    DraftStore.shared.clear(kind: Self.draftKind, id: draftID)
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)

                if hasGenerated {
                    Button("Log as Posted") {
                        logAsPosted()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            FeatureAdoptionTracker.shared.recordUsage(.contentDraft)
            if let stored = DraftStore.shared.load(kind: Self.draftKind, id: draftID),
               let storedText = stored["body"], !storedText.isEmpty {
                draftText = storedText
                hasGenerated = true
            }
        }
        .onChange(of: draftText) {
            localComplianceFlags = ComplianceScanner.scanWithSettings(draftText)
            DraftStore.shared.save(
                kind: Self.draftKind,
                id: draftID,
                fields: ["body": draftText]
            )
        }
    }

    // MARK: - Actions

    private func generateDraft() {
        isGenerating = true
        errorMessage = nil

        Task {
            do {
                let draft = try await ContentAdvisorService.shared.generateDraft(
                    topic: topic,
                    keyPoints: keyPoints,
                    platform: selectedPlatform,
                    tone: suggestedTone,
                    complianceNotes: complianceNotes
                )
                draftText = draft.draftText
                complianceFlags = draft.complianceFlags
                hasGenerated = true

                // Log to compliance audit trail
                let flags = ComplianceScanner.scanWithSettings(draft.draftText)
                if let entry = try? ComplianceAuditRepository.shared.logDraft(
                    channel: "content:\(selectedPlatform.rawValue)",
                    originalDraft: draft.draftText,
                    complianceFlags: flags,
                    outcomeID: sourceOutcomeID
                ) {
                    auditEntryID = entry.id
                }
            } catch {
                errorMessage = "Could not generate draft. \(error.localizedDescription)"
                logger.error("Draft generation failed: \(error.localizedDescription)")
            }
            isGenerating = false
        }
    }

    private func copyToClipboard() {
        ClipboardSecurity.copy(draftText, clearAfter: 60)
    }

    private func logAsPosted() {
        do {
            // Mark audit entry as sent
            if let auditID = auditEntryID {
                try? ComplianceAuditRepository.shared.markSent(
                    entryID: auditID,
                    finalDraft: draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            try ContentPostRepository.shared.logPost(
                platform: selectedPlatform,
                topic: topic,
                sourceOutcomeID: sourceOutcomeID
            )
            logger.debug("Logged content post on \(selectedPlatform.rawValue): \(topic)")
            DraftStore.shared.clear(kind: Self.draftKind, id: draftID)
            onPosted()
        } catch {
            errorMessage = "Could not log post: \(error.localizedDescription)"
        }
    }
}
