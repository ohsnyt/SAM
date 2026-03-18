// GuideScreenshotRunner.swift
// SAM — Automated screenshot capture for the Guide help system
// DEBUG only. Navigates through app sections and captures window screenshots.

#if DEBUG
import AppKit
import SwiftData
import OSLog
import ScreenCaptureKit

/// Captures screenshots for every guide section by navigating the app programmatically
/// and saving window images to the Guide resource directories.
///
/// Triggered from Debug menu: "Capture Guide Screenshots"
/// Requires Harvey Snodgrass test data to be seeded for meaningful content.
///
/// Because SAM is sandboxed, the runner:
/// 1. Asks the user to pick the output folder via NSOpenPanel (grants sandbox write access)
/// 2. Uses ScreenCaptureKit (in-process) to capture the window as a CGImage
/// 3. Writes PNG data directly to the user-selected directory
@MainActor
final class GuideScreenshotRunner {

    static let shared = GuideScreenshotRunner()
    private let logger = Logger(subsystem: "com.sam", category: "GuideScreenshotRunner")

    private init() {}

    // MARK: - Screenshot Manifest

    struct ScreenshotSpec {
        let section: String
        let filename: String
        let description: String
        let navigate: @MainActor () async -> Void
        let delay: TimeInterval

        init(_ section: String, _ filename: String, _ description: String,
             delay: TimeInterval = 1.5,
             navigate: @MainActor @escaping () async -> Void) {
            self.section = section
            self.filename = filename
            self.description = description
            self.delay = delay
            self.navigate = navigate
        }
    }

    private func buildManifest() -> [ScreenshotSpec] {
        [
            // ── Getting Started ──
            ScreenshotSpec("getting-started", "gs-01.png", "SAM main window — Today view") {
                Self.navigateToSection("today")
            },

            // ── Today ──
            ScreenshotSpec("today", "td-01.png", "Daily briefing view") {
                Self.navigateToSection("today")
            },

            // ── People ──
            ScreenshotSpec("people", "pp-01.png", "Contact list with role badges") {
                Self.navigateToSection("people")
            },
            ScreenshotSpec("people", "pp-02.png", "Person detail view", delay: 2.0) {
                Self.navigateToSection("people")
                try? await Task.sleep(for: .seconds(1.0))
                await Self.selectFirstPerson()
            },
            ScreenshotSpec("people", "pp-03.png", "Relationship graph", delay: 2.5) {
                Self.navigateToGraph()
            },

            // ── Business ──
            ScreenshotSpec("business", "bi-01.png", "Business dashboard overview") {
                Self.navigateToSection("business")
            },

            // ── Grow ──
            ScreenshotSpec("grow", "gr-01.png", "Grow dashboard") {
                Self.navigateToSection("grow")
            },

            // ── Events ──
            ScreenshotSpec("events", "ev-01.png", "Events manager overview") {
                Self.navigateToSection("events")
            },

            // ── Search ──
            ScreenshotSpec("search", "sr-01.png", "Universal search view") {
                Self.navigateToSection("search")
            },
        ]
    }

    // MARK: - Run

    func run() async {
        logger.notice("GuideScreenshotRunner: starting capture sequence")

        guard UserDefaults.standard.isTestDataLoaded else {
            await showAlert(
                title: "Test Data Required",
                message: "Please seed the Harvey Snodgrass test data first (Debug > Seed Harvey Snodgrass Test Data), then run this again."
            )
            return
        }

        // Ask user to pick the output directory — this grants sandbox write access.
        // Default to the Guide resource directory if possible.
        guard let outputRoot = await pickOutputDirectory() else {
            logger.notice("GuideScreenshotRunner: user cancelled directory picker")
            return
        }

        let manifest = buildManifest()
        var captured = 0
        var failed = 0
        var filenames: [String] = []
        var errors: [String] = []

        for (index, spec) in manifest.enumerated() {
            logger.notice("GuideScreenshotRunner: [\(index + 1)/\(manifest.count)] \(spec.description)")

            // Navigate
            await spec.navigate()

            // Wait for SwiftUI rendering
            try? await Task.sleep(for: .seconds(spec.delay))

            // Ensure section/images directory exists
            let imagesDir = outputRoot
                .appendingPathComponent(spec.section)
                .appendingPathComponent("images")
            do {
                try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            } catch {
                errors.append("[\(spec.filename)] mkdir failed: \(error.localizedDescription)")
                failed += 1
                continue
            }

            // Capture
            let outputURL = imagesDir.appendingPathComponent(spec.filename)
            let result = await captureMainWindow(to: outputURL)
            if result.success {
                captured += 1
                filenames.append("\(spec.section)/images/\(spec.filename)")
            } else {
                failed += 1
                errors.append("[\(spec.filename)] \(result.error)")
            }
        }

        // Navigate back to Today
        Self.navigateToSection("today")

        let errorSection = errors.isEmpty ? "" : "\n\nErrors:\n\(errors.joined(separator: "\n"))"

        let resultMessage: String
        if captured > 0 {
            resultMessage = """
            Captured \(captured) of \(manifest.count) screenshots.\(failed > 0 ? " \(failed) failed." : "")

            Saved to: \(outputRoot.path)

            Files:
            \(filenames.map { "  • \($0)" }.joined(separator: "\n"))

            Manual screenshots still needed:
            \(manualScreenshotList())
            \(errorSection)
            """
        } else {
            resultMessage = "Captured 0 of \(manifest.count) screenshots. \(failed) failed.\(errorSection)"
        }

        logger.notice("GuideScreenshotRunner: complete — \(captured) captured, \(failed) failed")
        await showAlert(title: "Guide Screenshots Complete", message: resultMessage)
    }

    // MARK: - Directory Picker

    private func pickOutputDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Guide Screenshot Output Folder"
        panel.message = "Select the Guide resource directory (e.g. SAM/Resources/Guide) or any folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        // Try to default to the known project path
        let guideDir = URL(fileURLWithPath: "/Users/david/Swift/SAM/SAM/SAM/Resources/Guide")
        if FileManager.default.fileExists(atPath: guideDir.path) {
            panel.directoryURL = guideDir
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }

    // MARK: - Navigation Helpers

    private static func navigateToSection(_ section: String) {
        NotificationCenter.default.post(
            name: .samNavigateToSection,
            object: nil,
            userInfo: ["section": section]
        )
    }

    private static func navigateToGraph() {
        NotificationCenter.default.post(
            name: .samNavigateToGraph,
            object: nil
        )
    }

    private static func selectFirstPerson() async {
        let context = ModelContext(SAMModelContainer.shared)
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { !$0.isMe },
            sortBy: [SortDescriptor(\.displayNameCache)]
        )
        guard let people = try? context.fetch(descriptor),
              let first = people.first else { return }

        NotificationCenter.default.post(
            name: .samNavigateToPerson,
            object: nil,
            userInfo: ["personID": first.id]
        )
    }

    // MARK: - Window Capture

    struct CaptureResult {
        let success: Bool
        let error: String

        static func ok() -> CaptureResult { CaptureResult(success: true, error: "") }
        static func fail(_ msg: String) -> CaptureResult { CaptureResult(success: false, error: msg) }
    }

    private func captureMainWindow(to finalURL: URL) async -> CaptureResult {
        let candidates = NSApplication.shared.windows.filter { $0.isVisible }

        guard let window = candidates.first(where: {
            $0.title == "SAM" || $0.title.isEmpty
        }) ?? NSApplication.shared.mainWindow ?? candidates.first else {
            return .fail("No visible window")
        }

        let windowID = window.windowNumber
        guard windowID > 0 else {
            return .fail("Invalid windowNumber: \(windowID)")
        }

        // Use ScreenCaptureKit — runs in-process, no sandbox file issues
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
                return .fail("ScreenCaptureKit could not find window \(windowID)")
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width) * 2  // Retina
            config.height = Int(window.frame.height) * 2
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                return .fail("Failed to encode PNG")
            }

            try pngData.write(to: finalURL, options: .atomic)
            return .ok()
        } catch {
            return .fail("ScreenCaptureKit: \(error.localizedDescription)")
        }
    }

    // MARK: - Manual Screenshot List

    private func manualScreenshotList() -> String {
        """
          Settings & Permissions (getting-started/images/gs-02.png)
          Text Size picker in Settings (getting-started/images/gs-03.png)
          Outcome queue cards (today/images/td-02.png)
          Life events section in Today view (today/images/td-03.png)
          Deep work schedule sheet (today/images/td-04.png)
          Deduced relationship alert (people/images/pp-04.png)
          Goals view (business/images/bi-02.png)
          Client pipeline funnel (business/images/bi-03.png)
          Strategic insights (business/images/bi-04.png)
          Recruiting pipeline (business/images/bi-05.png)
          Production dashboard (business/images/bi-06.png)
          Goal check-in session (business/images/bi-07.png)
          Goal journal entries (business/images/bi-08.png)
          Content drafts (grow/images/gr-02.png)
          Social promotion sheet (events/images/05-01.png)
          Presentations tab (events/images/06-01.png)
          Presentation detail (events/images/06-02.png)
          PDF drag-and-drop zone (events/images/06-03.png)
          Presentation delivery history (events/images/07-01.png)
          Identity settings (events/images/08-01.png)
          Undo toast (events/images/09-01.png)
          Command palette (search/images/sr-02.png)
        """
    }

    // MARK: - Alert

    private func showAlert(title: String, message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#endif
