//
//  DiagnosticsSettingsPane.swift
//  SAM
//
//  Phase 0a — Dataset Audit UI.
//
//  Shown in Settings → Diagnostics. Runs DatasetAuditService and
//  surfaces row counts + on-disk sizes inline; the user exports the
//  full JSON report (with the weekly histograms) so we can plot her
//  data growth offline.
//

import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsSettingsPane: View {

    @State private var report: DatasetAuditReport?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var showSavePanel = false
    @State private var pendingJSON: Data?
    @State private var mail = DiagnosticsMailService.shared
    @State private var autoSendEnabled: Bool = DiagnosticsMailService.shared.isEnabled
    @State private var isSendingTest = false
    @State private var lastSendStatus: String?

    // Performance — Phase 1a hang watchdog
    @State private var recentHangs: [HangReport] = []

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    Divider()

                    autoSendBlock

                    Divider()

                    if let report {
                        summary(for: report)
                        Divider()
                        modelTable(for: report)
                        Divider()
                        evidenceBreakdown(for: report)
                    } else if isRunning {
                        ProgressView("Walking the store…")
                            .progressViewStyle(.linear)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .samFont(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("No audit yet. Run one to capture row counts, weekly creation histograms, and on-disk sizes.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }

            Section {
                performanceBlock
                    .padding()
            }
        }
        .formStyle(.grouped)
        .task { reloadHangs() }
        .fileExporter(
            isPresented: $showSavePanel,
            document: JSONReportDocument(data: pendingJSON ?? Data()),
            contentType: .json,
            defaultFilename: defaultFilename
        ) { _ in
            pendingJSON = nil
        }
        .dismissOnLock(isPresented: $showSavePanel)
    }

    // MARK: Header / actions

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Dataset Audit", systemImage: "chart.bar.doc.horizontal")
                .samFont(.headline)

            Text("Walks every model in the SAM store and produces a JSON report with row counts, weekly creation histograms, and on-disk file sizes. Used to project long-term data growth.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    runAudit()
                } label: {
                    if isRunning {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Running…")
                        }
                    } else {
                        Label("Run Audit", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)

                Button("Save JSON…") {
                    saveJSON()
                }
                .buttonStyle(.bordered)
                .disabled(report == nil)

                Button("Copy JSON") {
                    copyJSON()
                }
                .buttonStyle(.bordered)
                .disabled(report == nil)
            }
        }
    }

    // MARK: Auto-send

    private var autoSendBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { autoSendEnabled },
                set: { newValue in
                    autoSendEnabled = newValue
                    mail.isEnabled = newValue
                    if newValue {
                        sendTestEmail()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically email diagnostic reports")
                    Text("Sends to \(DiagnosticsMailService.recipient) via Mail.app. macOS will ask once for permission to control Mail.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text("Send from:")
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
                TextField("(Mail's default account)", text: Binding(
                    get: { mail.senderAddress },
                    set: { mail.senderAddress = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            }
            .samFont(.caption)

            Text("Leave blank to use Mail's default account. If sends fail, enter the email address of a working account configured in Mail.app.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 88)

            HStack(spacing: 12) {
                Button("Send test email") {
                    sendTestEmail()
                }
                .buttonStyle(.bordered)
                .disabled(isSendingTest)

                if isSendingTest {
                    ProgressView().scaleEffect(0.7)
                }

                Spacer()

                if let lastSent = mail.lastSentAt {
                    Text("Last sent \(lastSent.formatted(date: .abbreviated, time: .shortened))")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastSendStatus {
                Text(lastSendStatus)
                    .samFont(.caption)
                    .foregroundStyle(lastSendStatus.hasPrefix("Sent") ? .green : .red)
            } else if let mailError = mail.lastError {
                Text("Last error: \(mailError)")
                    .samFont(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Summary

    private func summary(for report: DatasetAuditReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))  ·  schema \(report.schemaVersion)")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            sizeRow("Store (SQLite + WAL)", bytes: report.files.storeBytes)
            sizeRow("Audio (\(report.files.audioFileCount) files)", bytes: report.files.audioBytes)
            sizeRow("Pre-open backups (\(report.files.preOpenBackupCount))", bytes: report.files.preOpenBackupBytes)
            sizeRow("Application Support total", bytes: report.files.applicationSupportBytes)
        }
    }

    private func sizeRow(_ label: String, bytes: Int64) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(bytes)).monospacedDigit()
        }
        .samFont(.caption)
    }

    // MARK: Model table

    private func modelTable(for report: DatasetAuditReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models (\(report.models.count))")
                .samFont(.subheadline)
                .bold()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Model").bold()
                        Spacer()
                        Text("Rows").bold().frame(width: 80, alignment: .trailing)
                        Text("Source").bold().frame(width: 140, alignment: .trailing)
                    }
                    .samFont(.caption)
                    .padding(.vertical, 4)

                    Divider()

                    ForEach(report.models, id: \.name) { model in
                        HStack {
                            Text(model.name)
                            Spacer()
                            Text("\(model.rowCount)")
                                .monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                            Text(model.histogramSource)
                                .foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .trailing)
                        }
                        .samFont(.caption)
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    // MARK: Evidence breakdown

    private func evidenceBreakdown(for report: DatasetAuditReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evidence by source")
                .samFont(.subheadline)
                .bold()

            let sorted = report.evidenceBySource.sorted { $0.value > $1.value }
            if sorted.isEmpty {
                Text("No evidence rows.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sorted, id: \.key) { source, count in
                    HStack {
                        Text(source)
                        Spacer()
                        Text("\(count)").monospacedDigit()
                    }
                    .samFont(.caption)
                }
            }
        }
    }

    // MARK: Performance (hang watchdog)

    private var performanceBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Performance Watchdog", systemImage: "gauge.with.needle")
                    .samFont(.headline)

                Text("Detects when SAM's main thread freezes for 1 second or more. Each hang is written as JSON to ~/Library/Application Support/SAM/diagnostics, naming the operation that was running.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Refresh") { reloadHangs() }
                    .buttonStyle(.bordered)

                Button("Open Diagnostics Folder") { openDiagnosticsFolder() }
                    .buttonStyle(.bordered)

                Spacer()

                Text("\(recentHangs.count) recent")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            if recentHangs.isEmpty {
                Text("No hangs recorded yet. The watchdog runs continuously; reports appear here when the main thread stalls for over a second.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                hangsTable
            }
        }
    }

    private var hangsTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("When").bold()
                Spacer()
                Text("Operation").bold().frame(maxWidth: 240, alignment: .leading)
                Text("Stalled").bold().frame(width: 70, alignment: .trailing)
            }
            .samFont(.caption)
            .padding(.vertical, 4)

            Divider()

            ForEach(recentHangs, id: \.firedAt) { hang in
                HStack(alignment: .top) {
                    Text(hang.firedAt.formatted(date: .abbreviated, time: .standard))
                        .monospacedDigit()
                    Spacer()
                    Text(hang.activeOperation ?? "—")
                        .frame(maxWidth: 240, alignment: .leading)
                        .foregroundStyle(hang.activeOperation == nil ? .secondary : .primary)
                        .lineLimit(2)
                    Text("\(hang.stalledForSeconds, specifier: "%.2f")s")
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
                .samFont(.caption)
                .padding(.vertical, 3)

                Divider()
            }
        }
    }

    private func reloadHangs() {
        recentHangs = HangReportWriter.loadRecent(limit: 10)
    }

    private func openDiagnosticsFolder() {
        guard let dir = PerformanceMonitor.diagnosticsDirectoryURL() else { return }
        NSWorkspace.shared.open(dir)
    }

    // MARK: Actions

    private func runAudit() {
        isRunning = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let result = try DatasetAuditService.shared.generateReport()
                self.report = result
                if mail.isEnabled,
                   let json = try? DatasetAuditService.shared.reportJSON() {
                    let ok = await mail.sendDatasetAudit(json)
                    lastSendStatus = ok ? "Sent audit to \(DiagnosticsMailService.recipient)"
                                        : "Mail.app did not accept the send — see error below"
                }
            } catch {
                self.errorMessage = "Audit failed: \(error.localizedDescription)"
            }
            self.isRunning = false
        }
    }

    private func sendTestEmail() {
        isSendingTest = true
        lastSendStatus = nil
        Task { @MainActor in
            let ok = await mail.sendTestEmail()
            lastSendStatus = ok ? "Sent test to \(DiagnosticsMailService.recipient)"
                                : "Mail.app did not accept the send — see error below"
            isSendingTest = false
        }
    }

    private func saveJSON() {
        do {
            pendingJSON = try DatasetAuditService.shared.reportJSON()
            showSavePanel = true
        } catch {
            errorMessage = "Could not encode report: \(error.localizedDescription)"
        }
    }

    private func copyJSON() {
        do {
            let data = try DatasetAuditService.shared.reportJSON()
            guard let string = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        } catch {
            errorMessage = "Could not encode report: \(error.localizedDescription)"
        }
    }

    private var defaultFilename: String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "sam-dataset-audit-\(stamp)"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Document wrapper

private struct JSONReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
