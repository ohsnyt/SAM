//
//  SidebarToggleConfigurator.swift
//  SAM
//
//  Adds a sidebar toggle button to the window titlebar as a leading
//  accessory view controller.  This keeps it pinned next to the traffic
//  lights regardless of toolbar layout — unlike SwiftUI's built-in
//  sidebar toggle which migrates to the overflow menu when the sidebar
//  collapses.
//

import AppKit
import SwiftUI

// MARK: - SwiftUI Bridge

/// Embed as a zero-size background view on the NavigationSplitView.
/// On appear it locates the hosting NSWindow and adds a titlebar
/// accessory view controller with a sidebar toggle button.
struct SidebarToggleConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = SidebarToggleInstallerView()
        view.setFrameSize(.zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Installer View

private final class SidebarToggleInstallerView: NSView {

    private var installed = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !installed, let window else { return }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, !self.installed else { return }
            self.installToggle(in: window)
        }
    }

    private func installToggle(in window: NSWindow) {
        // Guard against duplicate installation
        for vc in window.titlebarAccessoryViewControllers {
            if vc is SidebarToggleAccessoryController {
                installed = true
                return
            }
        }

        let accessoryVC = SidebarToggleAccessoryController()
        accessoryVC.layoutAttribute = .leading

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")!
            .withSymbolConfiguration(config)!
        image.isTemplate = true

        let button = NSButton(
            image: image,
            target: nil,
            action: #selector(NSSplitViewController.toggleSidebar(_:))
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.contentTintColor = .labelColor

        // Size to match standard macOS toolbar toggle buttons
        button.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 34),
        ])

        accessoryVC.view = container
        window.addTitlebarAccessoryViewController(accessoryVC)

        installed = true
    }
}

// MARK: - Accessory Controller (for identity check)

private final class SidebarToggleAccessoryController: NSTitlebarAccessoryViewController {}

