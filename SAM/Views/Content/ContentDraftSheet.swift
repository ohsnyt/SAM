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

    // MARK: - State

    @State private var selectedPlatform: ContentPlatform = .linkedin
    @State private var draftText: String = ""
    @State private var complianceFlags: [String] = []
    @State private var isGenerating = false
    @State private var isEditing = false
    @State private var errorMessage: String?
    @State private var hasGenerated = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text("Content Draft")
                .font(.title3)
                .fontWeight(.semibold)

            // Topic context
            VStack(alignment: .leading, spacing: 4) {
                Text(topic)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if !keyPoints.isEmpty {
                    Text(keyPoints.joined(separator: " \u{2022} "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            // Platform picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Platform")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    ForEach([ContentPlatform.linkedin, .facebook, .instagram], id: \.rawValue) { platform in
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
                                    .font(.caption)
                                Text(platform.rawValue)
                                    .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Draft text area
            if hasGenerated {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Draft")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Button(isEditing ? "Done" : "Edit") {
                            isEditing.toggle()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }

                    if isEditing {
                        TextEditor(text: $draftText)
                            .font(.body)
                            .frame(minHeight: 120, maxHeight: 200)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        ScrollView {
                            Text(draftText)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 80, maxHeight: 200)
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
                                .font(.caption2)
                            Text("Regenerate")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            // Compliance flags
            if !complianceFlags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(complianceFlags, id: \.self) { flag in
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text(flag)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
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
                                .font(.caption)
                            Text("Copy")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Spacer()

                Button("Cancel") {
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
        .frame(width: 480)
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
            } catch {
                errorMessage = "Could not generate draft. \(error.localizedDescription)"
                logger.error("Draft generation failed: \(error.localizedDescription)")
            }
            isGenerating = false
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draftText, forType: .string)
    }

    private func logAsPosted() {
        do {
            try ContentPostRepository.shared.logPost(
                platform: selectedPlatform,
                topic: topic,
                sourceOutcomeID: sourceOutcomeID
            )
            logger.info("Logged content post on \(selectedPlatform.rawValue): \(topic)")
            onPosted()
        } catch {
            errorMessage = "Could not log post: \(error.localizedDescription)"
        }
    }
}
