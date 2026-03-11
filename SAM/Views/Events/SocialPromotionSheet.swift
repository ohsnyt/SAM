//
//  SocialPromotionSheet.swift
//  SAM
//
//  Created on March 11, 2026.
//  Draft and manage social media promotions for events.
//

import SwiftUI

struct SocialPromotionSheet: View {

    let event: SamEvent
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlatform: String = "linkedin"
    @State private var isGenerating = false
    @State private var draftText = ""
    @State private var copiedPlatform: String?

    private let platforms = [
        ("linkedin", "LinkedIn", "link"),
        ("facebook", "Facebook", "person.2"),
        ("substack", "Substack", "newspaper"),
        ("instagram", "Instagram", "camera"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Social Promotion")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            HSplitView {
                // Left: platform picker + status
                platformList
                    .frame(minWidth: 180, idealWidth: 200, maxWidth: 250)

                // Right: draft editor
                draftEditor
            }

            Divider()

            // Footer
            HStack {
                if let copied = copiedPlatform {
                    Text("Copied \(copied) post to clipboard")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            .padding()
        }
        .frame(width: 700, height: 500)
        .onChange(of: selectedPlatform) { _, newPlatform in
            loadDraftForPlatform(newPlatform)
        }
        .onAppear {
            loadDraftForPlatform(selectedPlatform)
        }
    }

    // MARK: - Platform List

    private var platformList: some View {
        List(selection: $selectedPlatform) {
            Section("Platforms") {
                ForEach(platforms, id: \.0) { platform in
                    HStack {
                        Image(systemName: platform.2)
                            .frame(width: 20)
                        Text(platform.1)

                        Spacer()

                        if let promo = event.socialPromotions.first(where: { $0.platform == platform.0 }) {
                            if promo.isPosted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            } else if promo.draftText != nil {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.blue)
                                    .font(.caption)
                            }
                        }
                    }
                    .tag(platform.0)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Draft Editor

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(platformDisplayName(selectedPlatform))
                    .font(.headline)

                Spacer()

                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await generateDraft() }
                    } label: {
                        Label(
                            draftText.isEmpty ? "Generate Draft" : "Regenerate",
                            systemImage: "sparkles"
                        )
                    }
                    .controlSize(.small)
                }
            }

            if let promo = event.socialPromotions.first(where: { $0.platform == selectedPlatform }),
               promo.isPosted, let postedAt = promo.postedAt {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Posted \(postedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $draftText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("\(draftText.count) characters")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Copy & Mark Posted") {
                    copyAndMarkPosted()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(draftText.isEmpty)

                Button("Save Draft") {
                    saveDraft()
                }
                .controlSize(.small)
                .disabled(draftText.isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func loadDraftForPlatform(_ platform: String) {
        if let promo = event.socialPromotions.first(where: { $0.platform == platform }) {
            draftText = promo.draftText ?? ""
        } else {
            draftText = ""
        }
    }

    private func generateDraft() async {
        isGenerating = true
        do {
            let draft = try await EventCoordinator.shared.generateSocialPromotion(
                for: event,
                platform: selectedPlatform
            )
            draftText = draft
        } catch {
            draftText = "Error generating draft: \(error.localizedDescription)"
        }
        isGenerating = false
    }

    private func saveDraft() {
        try? EventRepository.shared.upsertSocialPromotion(
            eventID: event.id,
            platform: selectedPlatform,
            draftText: draftText
        )
    }

    private func copyAndMarkPosted() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draftText, forType: .string)
        try? EventRepository.shared.markSocialPromotionPosted(
            eventID: event.id,
            platform: selectedPlatform
        )
        copiedPlatform = platformDisplayName(selectedPlatform)
        Task {
            try? await Task.sleep(for: .seconds(3))
            copiedPlatform = nil
        }
    }

    private func platformDisplayName(_ platform: String) -> String {
        platforms.first(where: { $0.0 == platform })?.1 ?? platform.capitalized
    }
}
