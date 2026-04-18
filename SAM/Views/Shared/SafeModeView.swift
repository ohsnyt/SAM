//
//  SafeModeView.swift
//  SAM
//
//  Full-window Safe Mode UI shown when the user holds Option during launch.
//  Runs deep integrity checks, displays results, offers to email the report,
//  then restarts SAM in normal mode.
//

import SwiftUI
import os.log

struct SafeModeView: View {

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SafeModeView")

    @State private var phase: Phase = .running
    @State private var report: SafeModeReport?
    @State private var logLines: [LogLine] = []
    @State private var emailSent = false

    private enum Phase {
        case running
        case done
        case restarting
    }

    private struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let severity: SafeModeCheckResult.Severity
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            // Log area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(logLines) { line in
                            logRow(line)
                                .id(line.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: logLines.count) {
                    if let last = logLines.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)

            Divider()

            // Actions
            actionBar
                .padding()
        }
        .frame(minWidth: 600, minHeight: 500)
        .task {
            await runChecks()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("SAM Safe Mode")
                .font(.title.bold())

            Text(phase == .running
                 ? "Running database integrity checks..."
                 : "Checks complete")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func logRow(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: line.severity.icon)
                .font(.caption)
                .foregroundStyle(colorForSeverity(line.severity))
                .frame(width: 16)

            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if let report {
            HStack {
                // Summary
                VStack(alignment: .leading, spacing: 2) {
                    let errors = report.checks.filter { $0.severity == .error }.count
                    let warnings = report.checks.filter { $0.severity == .warning }.count
                    let repairs = report.repairsPerformed

                    Text("\(report.checks.count) checks \u{2022} \(repairs) repair\(repairs == 1 ? "" : "s") \u{2022} \(warnings) warning\(warnings == 1 ? "" : "s") \u{2022} \(errors) error\(errors == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if emailSent {
                    Label("Report Sent", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                Button("Email Report") {
                    emailReport()
                }
                .disabled(emailSent)

                Button("Restart SAM") {
                    restartApp()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        } else {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Please wait...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Logic

    @MainActor
    private func runChecks() async {
        appendLog("Starting Safe Mode integrity checks...", severity: .ok)
        appendLog("Store: \(SAMModelContainer.defaultStoreURL.lastPathComponent)", severity: .ok)
        appendLog("Schema version: \(SAMModelContainer.schemaVersion)", severity: .ok)
        appendLog("", severity: .ok)

        // Run checks off the main actor to avoid blocking UI
        let result = await Task.detached(priority: .userInitiated) {
            SafeModeService.runFullCheck()
        }.value

        // Stream results into the log
        for check in result.checks {
            let prefix: String
            switch check.severity {
            case .ok:       prefix = "  OK"
            case .warning:  prefix = "WARN"
            case .repaired: prefix = " FIX"
            case .error:    prefix = " ERR"
            }
            appendLog("[\(prefix)] \(check.category): \(check.description)", severity: check.severity)
            if !check.detail.isEmpty {
                appendLog("       \(check.detail)", severity: check.severity)
            }
        }

        appendLog("", severity: .ok)
        appendLog("Complete: \(result.repairsPerformed) repair(s) performed", severity: result.repairsPerformed > 0 ? .repaired : .ok)

        report = result
        phase = .done
    }

    private func appendLog(_ text: String, severity: SafeModeCheckResult.Severity) {
        logLines.append(LogLine(text: text, severity: severity))
    }

    private func colorForSeverity(_ severity: SafeModeCheckResult.Severity) -> Color {
        switch severity {
        case .ok:       return .green
        case .warning:  return .yellow
        case .repaired: return .orange
        case .error:    return .red
        }
    }

    // MARK: - Email

    private func emailReport() {
        guard let report else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateString = formatter.string(from: report.timestamp)
        let subject = "[DATABASE REBUILDDoc] \(dateString) — SAM Safe Mode Report"
        let body = report.plainText
        let recipient = "sam@stillwaiting.org"

        // Use NSSharingService for reliable email composition
        let service = NSSharingService(named: .composeEmail)
        if let service {
            service.recipients = [recipient]
            service.subject = subject
            service.perform(withItems: [body])
            emailSent = true
            logger.info("Safe Mode report sent via NSSharingService")
        } else {
            // Fallback: mailto URL
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = recipient
            components.queryItems = [
                URLQueryItem(name: "subject", value: subject),
                URLQueryItem(name: "body", value: body),
            ]
            if let url = components.url {
                NSWorkspace.shared.open(url)
                emailSent = true
                logger.info("Safe Mode report sent via mailto URL")
            }
        }
    }

    // MARK: - Restart

    private func restartApp() {
        phase = .restarting

        // Set flag so the relaunched instance skips safe mode
        // (Option key might still be held)
        UserDefaults.standard.set(true, forKey: "sam.safeMode.justCompleted")

        // Launch a new instance of SAM
        let appURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                logger.error("Failed to relaunch SAM: \(error.localizedDescription)")
                Task { @MainActor in phase = .done }
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}
