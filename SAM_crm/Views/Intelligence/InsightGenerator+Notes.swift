import Foundation
import SwiftData

public actor InsightGeneratorNotesAdapter {
    public static let shared = InsightGeneratorNotesAdapter()
    private init() {}

    public func analyzeNote(text: String, noteID: UUID?) async {
        print("🔍 [InsightGeneratorNotesAdapter] Starting analysis for note: \(noteID?.uuidString ?? "nil")")
        do {
            let artifact = try await NoteLLMAnalyzer.analyze(text: text)
            print("🔍 [InsightGeneratorNotesAdapter] LLM analysis complete")
            if let noteID {
                await MainActor.run {
                    let container = SAMModelContainer.shared
                    let ctx = container.mainContext
                    print("🔍 [InsightGeneratorNotesAdapter] Fetching note from SwiftData...")
                    do {
                        let fetchDescriptor = FetchDescriptor<SamNote>(predicate: #Predicate<SamNote> { $0.id == noteID })
                        let notes = try ctx.fetch(fetchDescriptor)
                        
                        if let note = notes.first {
                            print("✅ [InsightGeneratorNotesAdapter] Note found in SwiftData")
                            print("🔍 [InsightGeneratorNotesAdapter] Note has \(note.people.count) people: \(note.people.map { $0.displayName })")
                            
                            // Persist analysis artifact
                            _ = try AnalysisRepository.shared.saveNoteArtifact(artifact: artifact, note: note)
                            print("✅ [InsightGeneratorNotesAdapter] Analysis artifact saved")
                            
                            // Ensure we have an evidence item for this note
                            let evidence = try NoteEvidenceFactory.evidence(for: note, in: container)
                            print("✅ [InsightGeneratorNotesAdapter] Evidence item obtained: \(evidence.id)")
                            
                            // Map artifact -> signals and append
                            let newSignals = ArtifactToSignalsMapper.signals(from: artifact, occurredAt: note.createdAt)
                            print("🔍 [InsightGeneratorNotesAdapter] Generated \(newSignals.count) signals from artifact")
                            
                            if !newSignals.isEmpty {
                                // Remove any prior analysis-derived signals to avoid accumulation on re-analysis
                                evidence.signals.removeAll { sig in
                                    sig.reason.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(AnalysisDerivedReasonPrefix)
                                }
                                evidence.signals.append(contentsOf: newSignals)
                                try ctx.save()
                                print("✅ [InsightGeneratorNotesAdapter] Signals saved to evidence item")
                            }
                        } else {
                            print("❌ [InsightGeneratorNotesAdapter] Note NOT found in SwiftData with ID: \(noteID)")
                            print("❌ [InsightGeneratorNotesAdapter] Fetched \(notes.count) notes, expected 1")
                        }
                    } catch {
                        print("❌ [InsightGeneratorNotesAdapter] Error processing note: \(error)")
                    }
                }
            } else {
                print("⚠️ [InsightGeneratorNotesAdapter] noteID is nil, skipping evidence creation")
            }
            await DebouncedInsightRunner.shared.run()
            print("✅ [InsightGeneratorNotesAdapter] DebouncedInsightRunner triggered")
        } catch {
            print("❌ [InsightGeneratorNotesAdapter] Error during analysis: \(error)")
        }
    }
}
