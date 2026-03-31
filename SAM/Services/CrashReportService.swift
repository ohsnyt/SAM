//
//  CrashReportService.swift
//  SAM
//
//  Detects unclean shutdowns and locates macOS crash reports (.ips files)
//  from ~/Library/Logs/DiagnosticReports for the previous session.
//  Offers to email the report on the next launch.
//

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CrashReport")

// Keys outside the @MainActor class so nonisolated methods can access them
private enum CrashReportKeys {
    static let cleanShutdown = "sam.cleanShutdown"
    static let lastLaunch = "sam.lastLaunchTimestamp"
    static let dismissedCrash = "sam.crashReport.dismissedTimestamp"
}

@MainActor
@Observable
final class CrashReportService {

    static let shared = CrashReportService()

    // MARK: - Observable State

    /// True when a crash from the previous session has been detected and not yet dismissed.
    var crashDetected = false

    /// The crash report text, ready to email.
    private(set) var crashReportText: String?

    /// Timestamp of the previous session's launch (for display).
    private(set) var previousLaunchDate: Date?

    private init() {}

    // MARK: - Lifecycle Hooks

    /// Call at the very start of app init, before any heavy work.
    /// Sets `cleanShutdown = false` and checks whether the previous session crashed.
    func markLaunchAndCheckPreviousCrash() {
        let wasClean = UserDefaults.standard.bool(forKey: CrashReportKeys.cleanShutdown)
        let lastLaunch = UserDefaults.standard.double(forKey: CrashReportKeys.lastLaunch)

        // Mark this session as not-yet-clean
        UserDefaults.standard.set(false, forKey: CrashReportKeys.cleanShutdown)

        // If previous session didn't shut down cleanly, look for a crash report
        if !wasClean && lastLaunch > 0 {
            let launchDate = Date(timeIntervalSince1970: lastLaunch)
            previousLaunchDate = launchDate

            // Don't re-show if the user already dismissed a crash from this same timestamp
            let dismissedTimestamp = UserDefaults.standard.double(forKey: CrashReportKeys.dismissedCrash)
            if dismissedTimestamp == lastLaunch {
                logger.debug("Crash from \(launchDate) already dismissed — skipping")
                return
            }

            logger.notice("Previous session (launched \(launchDate)) did not shut down cleanly — scanning for crash report")
            if let report = findCrashReport(launchedAfter: launchDate) {
                crashReportText = report
                crashDetected = true
                logger.info("Found crash report for previous session")
            } else {
                logger.info("No crash report found in DiagnosticReports (may not have been written yet)")
                // Still show the banner — we can send a minimal report without the .ips
                crashReportText = buildMinimalReport(launchDate: launchDate)
                crashDetected = true
            }
        }
    }

    /// Call in `applicationShouldTerminate` to record a clean exit.
    nonisolated func markCleanShutdown() {
        UserDefaults.standard.set(true, forKey: CrashReportKeys.cleanShutdown)
    }

    // MARK: - User Actions

    /// Compose an email with the crash report.
    func sendReport() {
        guard let reportText = crashReportText else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateString: String
        if let prev = previousLaunchDate {
            dateString = formatter.string(from: prev)
        } else {
            dateString = formatter.string(from: .now)
        }

        let subject = "[CRASH REPORT] \(dateString) — SAM Crash Report"
        let recipient = "sam@stillwaiting.org"

        let service = NSSharingService(named: .composeEmail)
        if let service {
            service.recipients = [recipient]
            service.subject = subject
            service.perform(withItems: [reportText])
            logger.info("Crash report email composed via NSSharingService")
        } else {
            // Fallback: mailto URL
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = recipient
            components.queryItems = [
                URLQueryItem(name: "subject", value: subject),
                URLQueryItem(name: "body", value: reportText),
            ]
            if let url = components.url {
                NSWorkspace.shared.open(url)
                logger.info("Crash report email composed via mailto URL")
            }
        }
        dismiss()
    }

    /// Dismiss the crash banner without sending.
    func dismiss() {
        crashDetected = false
        // Record which crash timestamp was dismissed so we don't re-show it
        if let prev = previousLaunchDate {
            UserDefaults.standard.set(prev.timeIntervalSince1970, forKey: CrashReportKeys.dismissedCrash)
        }
    }

    // MARK: - Crash Report Discovery

    /// Scan ~/Library/Logs/DiagnosticReports for SAM .ips files
    /// created after the given launch date.
    private func findCrashReport(launchedAfter launchDate: Date) -> String? {
        let fm = FileManager.default

        // macOS writes crash reports to two possible locations
        let diagnosticPaths: [URL] = [
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]

        // Also check the Retired subfolder (macOS sometimes moves reports there)
        var searchDirs: [URL] = []
        for dir in diagnosticPaths {
            searchDirs.append(dir)
            searchDirs.append(dir.appendingPathComponent("Retired"))
        }

        // Look for SAM crash files created after the previous launch
        // macOS names them like: SAM_2026-03-31-102936_MacBook-Air.ips
        // or SAM-2026-03-31-102936.ips depending on OS version
        var bestMatch: (url: URL, date: Date)?

        for dir in searchDirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in contents {
                let name = file.lastPathComponent
                guard (name.hasPrefix("SAM_") || name.hasPrefix("SAM-") || name.hasPrefix("sam.SAM")),
                      (name.hasSuffix(".ips") || name.hasSuffix(".crash")) else { continue }

                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let created = attrs[.creationDate] as? Date else { continue }

                // Must be created after the previous launch
                guard created > launchDate else { continue }

                // Pick the most recent matching file
                if bestMatch == nil || created > bestMatch!.date {
                    bestMatch = (file, created)
                }
            }
        }

        guard let match = bestMatch else { return nil }

        // Read the crash report
        do {
            let content = try String(contentsOf: match.url, encoding: .utf8)
            logger.info("Read crash report: \(match.url.lastPathComponent) (\(content.count) chars)")
            return wrapReport(ipsContent: content, launchDate: launchDate, reportFile: match.url.lastPathComponent)
        } catch {
            logger.warning("Could not read crash report \(match.url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Wrap the raw .ips content with SAM context headers.
    private func wrapReport(ipsContent: String, launchDate: Date, reportFile: String) -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let macModel = String(cString: model)

        return """
        SAM Crash Report
        ================
        App Version:    \(appVersion) (\(buildNumber))
        Schema:         \(SAMModelContainer.schemaVersion)
        macOS:          \(osVersion)
        Hardware:       \(macModel)
        Previous Launch:\(ISO8601DateFormatter().string(from: launchDate))
        Report File:    \(reportFile)

        --- Apple Crash Report ---

        \(ipsContent)
        """
    }

    /// Build a minimal report when no .ips file is found.
    private func buildMinimalReport(launchDate: Date) -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let macModel = String(cString: model)

        return """
        SAM Crash Report (no .ips file found)
        =====================================
        App Version:    \(appVersion) (\(buildNumber))
        Schema:         \(SAMModelContainer.schemaVersion)
        macOS:          \(osVersion)
        Hardware:       \(macModel)
        Previous Launch:\(ISO8601DateFormatter().string(from: launchDate))

        Note: The macOS crash report (.ips file) was not found in
        ~/Library/Logs/DiagnosticReports/. It may not have been
        written yet, or the crash may have been a force-quit.

        If you can locate the crash report manually, please attach it
        to this email. Look for a file named SAM_*.ips in:
          ~/Library/Logs/DiagnosticReports/
        """
    }
}
