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

// MARK: - Dev Log Store

final class DevLogStore: @unchecked Sendable {
    static let shared = DevLogStore()
    private let queue = DispatchQueue(label: "com.sam-crm.devlogs", qos: .utility)
    private var lines: [String] = []

    func append(_ line: String) {
        queue.async { [weak self] in
            self?.lines.append(line)
        }
    }

    func snapshot() -> String {
        var snapshot: String = ""
        queue.sync {
            snapshot = lines.joined(separator: "\n")
        }
        return snapshot
    }

    func clear() {
        queue.async { [weak self] in
            self?.lines.removeAll()
        }
    }
}

// Extend DevLogger to write into DevLogStore
extension DevLogger {
    static func logToStore(_ message: String, level: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        DevLogStore.shared.append("[\(level)] \(timestamp): \(message)")
    }
}

struct DevelopmentTab: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showExportLogs = false
    @State private var exportMessage: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Developer Logs") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Export developer logs to a text file for sharing with the development team.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Export Logs…") { showExportLogs = true }
                                .buttonStyle(.glass)
                            Button("Clear Logs") { DevLogStore.shared.clear() }
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
        .fileExporter(isPresented: $showExportLogs, document: LogDocument(text: DevLogStore.shared.snapshot()), contentType: .plainText, defaultFilename: defaultLogFileName()) { result in
            switch result {
            case .success:
                exportMessage = "Logs exported successfully."
            case .failure(let error):
                exportMessage = "Failed to export logs: \(error.localizedDescription)"
            }
        }
        .overlay(alignment: .top) {
            if let msg = exportMessage {
                ToastView(message: msg)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { exportMessage = nil }
                        }
                    }
            }
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

        let container = modelContext.container

        // Simple wipe: delete all instances of these models.
        do {
            try modelContext.delete(model: SamEvidenceItem.self)
            try modelContext.delete(model: SamPerson.self)
            try modelContext.delete(model: SamContext.self)
            try modelContext.delete(model: Product.self)
            try modelContext.delete(model: ConsentRequirement.self)
            try modelContext.delete(model: Responsibility.self)
            try modelContext.delete(model: JointInterest.self)
            try modelContext.delete(model: ContextParticipation.self)
            try modelContext.delete(model: Coverage.self)
        } catch {
            message = "Failed to clear store: \(error.localizedDescription)"
            return
        }

        // Reseed using the DEBUG seeder.
        FixtureSeeder.seedIfNeeded(using: container)
        message = "Developer fixture restored."
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

        let container = modelContext.container
        let bgContext = ModelContext(container)
        
        let generator = InsightGenerator(context: bgContext)
        await generator.deduplicateInsights()
        
        message = "Duplicate insights removed."
    }
}

