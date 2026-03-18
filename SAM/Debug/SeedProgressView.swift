// SeedProgressView.swift
// SAM — DEBUG-only progress panel shown while seedFresh() drains background tasks.

#if DEBUG
import SwiftUI
import AppKit

// MARK: - SwiftUI View

struct SeedProgressView: View {

    @State private var monitor = BackgroundTaskMonitor.shared

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)

            Text("Preparing to reseed…")
                .samFont(.headline)

            if monitor.isIdle {
                Text("All tasks complete — relaunching…")
                    .samFont(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Waiting for:")
                        .samFont(.caption)
                        .foregroundStyle(.tertiary)
                    ForEach(monitor.activeDescriptions, id: \.self) { description in
                        Label(description, systemImage: "arrow.trianglehead.2.clockwise")
                            .samFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(28)
        .frame(width: 300)
    }
}

// MARK: - Panel Controller

/// Displays SeedProgressView in a floating NSPanel.
/// Call show() before seedFresh() and close() (or just terminate) when done.
@MainActor
final class SeedProgressPanel {

    static let shared = SeedProgressPanel()
    private var panel: NSPanel?

    private init() {}

    func show() {
        let hostingView = NSHostingView(rootView: SeedProgressView())
        hostingView.sizingOptions = .preferredContentSize

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Reseeding…"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}
#endif
