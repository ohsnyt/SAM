import Foundation

public actor InsightGeneratorNotesAdapter {
    public static let shared = InsightGeneratorNotesAdapter()
    private init() {}

    public func analyzeNote(text: String, noteID: UUID?) async {
        do {
            let artifact = try await NoteLLMAnalyzer.analyze(text: text)
            if let noteID {
                await MainActor.run {
                    do {
                        let container = SAMModelContainer.shared
                        let ctx = container.mainContext
                        if let note = try? ctx.fetch(FetchDescriptor<SamNote>(predicate: #Predicate { $0.id == noteID })).first {
                            // Persist analysis artifact
                            _ = try AnalysisRepository.shared.saveNoteArtifact(artifact: artifact, note: note)
                            // Ensure we have an evidence item for this note
                            let evidence = try NoteEvidenceFactory.evidence(for: note, in: container)
                            // Map artifact -> signals and append
                            let newSignals = ArtifactToSignalsMapper.signals(from: artifact, occurredAt: note.createdAt)
                            if !newSignals.isEmpty {
                                // Remove any prior analysis-derived signals to avoid accumulation on re-analysis
                                evidence.signals.removeAll { sig in
                                    sig.reason.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(AnalysisDerivedReasonPrefix)
                                }
                                evidence.signals.append(contentsOf: newSignals)
                                try ctx.save()
                            }
                        }
                    } catch {
                        // TODO: log error
                    }
                }
            }
            await DebouncedInsightRunner.shared.kick()
        } catch {
            // TODO: Log error via DevLogger
        }
    }
}
