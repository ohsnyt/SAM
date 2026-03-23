//
//  AppLockView.swift
//  SAM
//
//  Created on March 13, 2026.
//  Full-screen lock overlay requiring authentication to access the app.
//

import SwiftUI

struct AppLockView: View {

    @State private var lockService = AppLockService.shared
    @State private var iconScale: CGFloat = 0.8
    @State private var iconOpacity: Double = 0.0

    // MARK: - Body

    var body: some View {
        ZStack {
            // Tappable background — clicking anywhere triggers authentication
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    lockService.authenticate()
                }

            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 24) {
                // App Icon
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                // Title
                Text("SAM is Locked")
                    .samFont(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text("Click anywhere to unlock")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)

                // Unlock Button
                Button(action: { lockService.authenticate() }) {
                    Label("Unlock", systemImage: lockService.isBiometricAvailable ? "touchid" : "lock.open")
                        .samFont(.body, weight: .medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(lockService.isAuthenticating)

                // Error Text
                if let error = lockService.authError {
                    Text(error)
                        .samFont(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }

            // Attempt authentication immediately on appear
            lockService.authenticate()
        }
    }
}

// MARK: - Lock Guard Modifier

/// Overlay any window with a lock screen when the app is locked.
/// Clicking the overlay brings the main window to front and triggers authentication.
struct LockGuardModifier: ViewModifier {
    @State private var lockService = AppLockService.shared

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: lockService.isLocked ? 20 : 0)
                .allowsHitTesting(!lockService.isLocked)

            if lockService.isLocked {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "lock.fill")
                                .samFont(.title)
                                .foregroundStyle(.secondary)
                            Text("SAM is Locked")
                                .samFont(.headline)
                                .foregroundStyle(.secondary)
                            Text("Click to unlock")
                                .samFont(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .onTapGesture {
                        bringMainWindowToFront()
                        lockService.authenticate()
                    }
            }
        }
    }

    private func bringMainWindowToFront() {
        // Find the main app window (the one without an auxiliary identifier)
        let auxiliaryIDs: Set<String> = ["prompt-lab", "guide", "quick-note", "clipboard-capture", "compose-message"]
        for window in NSApplication.shared.windows where window.isVisible {
            let id = window.identifier?.rawValue ?? ""
            let isAuxiliary = auxiliaryIDs.contains(where: { id.contains($0) })
            let isSettings = id.contains("Settings")
            if !isAuxiliary && !isSettings && !id.isEmpty {
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return
            }
        }
        // Fallback: just activate the app
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

extension View {
    /// Guard this window's content behind the app lock screen.
    func lockGuarded() -> some View {
        modifier(LockGuardModifier())
    }
}

// MARK: - Preview

#Preview {
    AppLockView()
        .frame(width: 600, height: 400)
}
