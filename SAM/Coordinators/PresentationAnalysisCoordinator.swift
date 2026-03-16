//
//  PresentationAnalysisCoordinator.swift
//  SAM
//
//  Created on March 11, 2026.
//  Extracts text from presentation PDFs and generates content summaries.
//

import Foundation
import PDFKit
import os.log

@MainActor
@Observable
final class PresentationAnalysisCoordinator {

    static let shared = PresentationAnalysisCoordinator()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PresentationAnalysis")

    // MARK: - Status (observed by MinionsView)

    enum AnalysisStatus: Equatable {
        case idle
        case extracting
        case analyzing
        case success
        case failed
    }

    var analysisStatus: AnalysisStatus = .idle
    var currentPresentationTitle: String?

    private init() {}

    // MARK: - Analyze Presentation

    /// Extract text from attached files and generate content summary via AI.
    func analyze(presentation: SamPresentation) async {
        guard !presentation.fileAttachments.isEmpty else { return }

        currentPresentationTitle = presentation.title
        analysisStatus = .extracting
        logger.debug("Starting analysis of presentation: \(presentation.title)")

        do {
            // Step 1: Extract text from all attached files
            let extractedText = extractText(from: presentation.fileAttachments)

            guard !extractedText.isEmpty else {
                logger.warning("No text extracted from presentation files")
                analysisStatus = .failed
                resetStatusAfterDelay()
                return
            }

            // Step 2: Generate summary and talking points via AI
            analysisStatus = .analyzing

            let (summary, talkingPoints, tags) = try await generateSummary(
                title: presentation.title,
                extractedText: extractedText
            )

            // Step 3: Update the presentation
            presentation.contentSummary = summary
            presentation.keyTalkingPoints = talkingPoints
            presentation.contentAnalyzedAt = .now

            // Merge any new tags (don't overwrite user-set tags)
            let existingTags = Set(presentation.topicTags.map { $0.lowercased() })
            let newTags = tags.filter { !existingTags.contains($0.lowercased()) }
            presentation.topicTags.append(contentsOf: newTags)

            presentation.updatedAt = .now

            analysisStatus = .success
            logger.info("Analysis complete for: \(presentation.title) — \(talkingPoints.count) talking points")

        } catch {
            logger.error("Analysis failed for \(presentation.title): \(error.localizedDescription)")
            analysisStatus = .failed
        }

        resetStatusAfterDelay()
    }

    // MARK: - PDF Text Extraction

    /// Extract text from presentation files using PDFKit.
    private func extractText(from files: [PresentationFile]) -> String {
        var allText: [String] = []

        for file in files {
            guard file.fileType.lowercased() == "pdf" else {
                logger.debug("Skipping non-PDF file: \(file.fileName)")
                continue
            }

            // Resolve security-scoped bookmark
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: file.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                logger.warning("Could not resolve bookmark for \(file.fileName)")
                continue
            }

            guard url.startAccessingSecurityScopedResource() else {
                logger.warning("Could not access security-scoped resource for \(file.fileName)")
                continue
            }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let document = PDFDocument(url: url) else {
                logger.warning("Could not open PDF: \(file.fileName)")
                continue
            }

            var pageTexts: [String] = []
            for pageIndex in 0..<document.pageCount {
                if let page = document.page(at: pageIndex),
                   let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pageTexts.append("--- Slide \(pageIndex + 1) ---\n\(text)")
                }
            }

            if !pageTexts.isEmpty {
                allText.append("File: \(file.fileName)\n\(pageTexts.joined(separator: "\n\n"))")
                logger.debug("Extracted text from \(document.pageCount) pages in \(file.fileName)")
            } else {
                logger.debug("No extractable text in \(file.fileName) (may be image-only slides)")
            }
        }

        return allText.joined(separator: "\n\n")
    }

    // MARK: - AI Summary Generation

    private func generateSummary(
        title: String,
        extractedText: String
    ) async throws -> (summary: String, talkingPoints: [String], tags: [String]) {
        // Truncate to keep within context window
        let truncated = String(extractedText.prefix(6000))

        let prompt = """
            Analyze this presentation content and produce a structured summary.

            PRESENTATION TITLE: \(title)

            EXTRACTED CONTENT:
            \(truncated)

            Respond with ONLY valid JSON (no markdown):
            {
              "summary": "2-4 sentence overview of what this presentation covers and its target audience",
              "talking_points": ["key point 1", "key point 2", ...],
              "topic_tags": ["tag1", "tag2", ...]
            }

            Rules:
            - Summary should capture the main theme and value proposition
            - Talking points should be 5-10 specific, actionable points a presenter would make
            - Topic tags should be 3-6 short keywords for categorization
            - Focus on the educational/business content, not slide formatting
            """

        let persona = await BusinessProfileService.shared.personaFragment()

        let systemInstruction = """
            You are analyzing a presentation for \(persona)'s CRM coaching assistant. \
            Extract the key content that would be useful for marketing, invitations, and follow-up communications. \
            Be specific and concrete — reference actual topics covered, not generic descriptions.
            """

        let response = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: systemInstruction,
            maxTokens: 2048
        )

        // Parse JSON response
        let cleaned = JSONExtraction.extractJSON(from: response)
        guard let data = cleaned.data(using: .utf8) else {
            return (response, [], [])
        }

        struct LLMResponse: Codable {
            let summary: String?
            let talking_points: [String]?
            let topic_tags: [String]?
        }

        do {
            let parsed = try JSONDecoder().decode(LLMResponse.self, from: data)
            return (
                summary: parsed.summary ?? response,
                talkingPoints: parsed.talking_points ?? [],
                tags: parsed.topic_tags ?? []
            )
        } catch {
            // Fallback: use raw response as summary
            return (response, [], [])
        }
    }

    // MARK: - Helpers

    private func resetStatusAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(5))
            if analysisStatus == .success || analysisStatus == .failed {
                analysisStatus = .idle
                currentPresentationTitle = nil
            }
        }
    }
}
