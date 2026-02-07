//
//  DevelopmentTab.swift
//  SAM_crm
//
//  Settings → Development tab. Provides developer tooling such as
//  exporting dev logs and restoring the developer fixture.
//

import SwiftUI
import UniformTypeIdentifiers
import SwiftData

// DevLogStore and DevLogger are defined in DevLogStore.swift

struct DevelopmentTab: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showExportLogs = false
    @State private var exportMessage: String? = nil
    
    private var logSnapshot: String {
        DevLogStore.shared.snapshot()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Developer Logs") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Export developer logs to a text file for sharing with the development team.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Export Logs…") { 
                                DevLogger.info("Export logs requested")
                                showExportLogs = true 
                            }
                                .buttonStyle(.borderedProminent)
                            Button("Clear Logs") { 
                                DevLogger.info("Clearing logs")
                                DevLogStore.shared.clear() 
                            }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                #if DEBUG
                GroupBox("Developer Fixture") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quickly replace all data with a deterministic developer fixture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DeveloperFixtureButton()
                    }
                }
                #endif

                GroupBox("Insight Maintenance") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Clean up duplicate insights that may have been created.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DeduplicateInsightsButton()
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .fileExporter(isPresented: $showExportLogs, document: LogDocument(text: logSnapshot), contentType: .plainText, defaultFilename: defaultLogFileName()) { result in
            switch result {
            case .success:
                exportMessage = "Logs exported successfully."
            case .failure(let error):
                exportMessage = "Failed to export logs: \(error.localizedDescription)"
            }
        }
        .alert("Export Status", isPresented: .constant(exportMessage != nil), actions: {
            Button("OK") { exportMessage = nil }
        }, message: {
            if let msg = exportMessage {
                Text(msg)
            }
        })
        .onAppear {
            DevLogger.info("Development tab opened")
        }
    }

    private func defaultLogFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "SAM_DevLogs_\(f.string(from: .now)).txt"
    }
}

// Simple text document for log export
struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents, let s = String(data: data, encoding: .utf8) {
            self.text = s
        } else {
            self.text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return .init(regularFileWithContents: data)
    }
}

// MARK: - Developer Fixture Button
#if DEBUG
private struct DeveloperFixtureButton: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isWorking = false
    @State private var message: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await wipeAndReseed() }
            } label: {
                Label("Restore developer fixture", systemImage: "arrow.counterclockwise.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func wipeAndReseed() async {
        isWorking = true
        defer { isWorking = false }

        DevLogger.info("Starting developer fixture restore")
        let container = modelContext.container

        // Manual deletion: fetch and delete individually to respect relationships
        do {
            // 1. Delete insights first (they reference people and contexts)
            let insights = try modelContext.fetch(FetchDescriptor<SamInsight>())
            for insight in insights { modelContext.delete(insight) }
            DevLogger.info("Deleted \(insights.count) insights")
            
            // 2. Delete evidence and notes (they reference people)
            let evidence = try modelContext.fetch(FetchDescriptor<SamEvidenceItem>())
            for item in evidence { modelContext.delete(item) }
            DevLogger.info("Deleted \(evidence.count) evidence items")
            
            let artifacts = try modelContext.fetch(FetchDescriptor<SamAnalysisArtifact>())
            for artifact in artifacts { modelContext.delete(artifact) }
            DevLogger.info("Deleted \(artifacts.count) analysis artifacts")
            
            let notes = try modelContext.fetch(FetchDescriptor<SamNote>())
            for note in notes { modelContext.delete(note) }
            DevLogger.info("Deleted \(notes.count) notes")
            
            // 3. Delete relationship tables (they reference people and contexts)
            let coverages = try modelContext.fetch(FetchDescriptor<Coverage>())
            for coverage in coverages { modelContext.delete(coverage) }
            
            let participations = try modelContext.fetch(FetchDescriptor<ContextParticipation>())
            for participation in participations { modelContext.delete(participation) }
            
            let responsibilities = try modelContext.fetch(FetchDescriptor<Responsibility>())
            for responsibility in responsibilities { modelContext.delete(responsibility) }
            
            let jointInterests = try modelContext.fetch(FetchDescriptor<JointInterest>())
            for joint in jointInterests { modelContext.delete(joint) }
            
            let consents = try modelContext.fetch(FetchDescriptor<ConsentRequirement>())
            for consent in consents { modelContext.delete(consent) }
            DevLogger.info("Deleted relationship records")
            
            // 4. Delete products (they reference contexts)
            let products = try modelContext.fetch(FetchDescriptor<Product>())
            for product in products { modelContext.delete(product) }
            DevLogger.info("Deleted \(products.count) products")
            
            // 5. Finally delete the main entities
            let contexts = try modelContext.fetch(FetchDescriptor<SamContext>())
            for context in contexts { modelContext.delete(context) }
            DevLogger.info("Deleted \(contexts.count) contexts")
            
            let people = try modelContext.fetch(FetchDescriptor<SamPerson>())
            for person in people { modelContext.delete(person) }
            DevLogger.info("Deleted \(people.count) people")
            
            try modelContext.save()
            DevLogger.info("Successfully cleared all models")
        } catch {
            DevLogger.error("Failed to clear store: \(error.localizedDescription)")
            message = "Failed to clear store: \(error.localizedDescription)"
            return
        }

        // Reseed using the DEBUG seeder - this will re-import contacts and calendar events
        FixtureSeeder.seedIfNeeded(using: container)
        DevLogger.info("Developer fixture restored successfully")
        message = "Developer fixture restored. Contacts and calendar events re-imported."
    }
}
#endif

// MARK: - Deduplicate Insights Button
private struct DeduplicateInsightsButton: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isWorking = false
    @State private var message: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await deduplicate() }
            } label: {
                Label("Deduplicate Insights", systemImage: "square.stack.3d.down.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func deduplicate() async {
        isWorking = true
        defer { isWorking = false }

        DevLogger.info("Starting insight deduplication")
        let container = modelContext.container
        let bgContext = ModelContext(container)
        
        let generator = InsightGenerator(context: bgContext)
        await generator.deduplicateInsights()
        
        DevLogger.info("Insight deduplication completed")
        message = "Duplicate insights removed."
    }
}

