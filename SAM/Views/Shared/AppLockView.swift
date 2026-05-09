//
//  AppLockView.swift
//  SAM
//
//  SwiftUI body for the lock overlay. Hosted inside `LockOverlayWindow`
//  (an NSWindow at .floating level), which is what `LockOverlayCoordinator`
//  attaches to every visible SAM window when the app is locked.
//
//  The visual is a wall of translucent "glass blocks" — each block is a
//  separate `.regularMaterial` tile that samples its own patch of the
//  content behind it, so text that crosses a seam refracts differently
//  on each side. The net effect reads like looking into SAM through a
//  glass-block shower wall: you see pale color washes move behind, but
//  can't read any detail. Palette pulled from the SAM logo — pale
//  cornflower blue on icy white.
//

import SwiftUI

// MARK: - LockOverlayContent

/// Top-level SwiftUI view rendered inside `LockOverlayWindow`. Handles
/// the auto-prompt on appear and the tap-to-retry fallback. This is the
/// only public entry point — everything else in this file is the visual.
struct LockOverlayContent: View {

    @State private var lockService = AppLockService.shared

    var body: some View {
        GlassBlockLockOverlay()
            .contentShape(Rectangle())
            .onTapGesture {
                // Tap is the fallback path. The primary prompt appears
                // automatically from `tryAutoAuthenticate()` on app
                // activation; the user only needs to tap if they
                // dismissed the system Touch ID dialog.
                lockService.authenticate()
            }
            .onAppear {
                lockService.tryAutoAuthenticate()
            }
    }
}

// MARK: - Glass Block Overlay

/// The glass-block wall itself. Each tile independently samples the
/// content behind the overlay, so adjacent tiles produce a staggered
/// refraction that breaks text into unreadable color shapes while
/// preserving the overall feeling of "SAM is still alive behind there."
private struct GlassBlockLockOverlay: View {

    /// SAM-logo palette. The app icon is a pale blue glass swirl on near-
    /// white; these two colors approximate its highlights and shadows.
    private static let iceBlue = Color(red: 0.88, green: 0.94, blue: 1.0)
    private static let skyBlue = Color(red: 0.62, green: 0.78, blue: 0.96)

    /// Target tile edge length. Bigger tiles = fewer rendering passes +
    /// more visible refraction per tile. 96pt lands comfortably between
    /// "clearly block-shaped" and "subtle."
    private let tileSize: CGFloat = 96

    /// Seam between tiles — visible but not heavy. Reads as grout.
    private let seam: CGFloat = 2

    @State private var iconScale: CGFloat = 0.85
    @State private var iconOpacity: Double = 0
    @State private var lockService = AppLockService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Soft diagonal color wash pulled from the SAM palette.
                // Without this, empty screen regions behind the tiles
                // look clinical-white; with it, the whole wall feels
                // cool and cohesive.
                LinearGradient(
                    colors: [
                        Self.iceBlue.opacity(0.55),
                        Self.skyBlue.opacity(0.40)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                glassBlockGrid(size: geo.size)

                centerCard
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            if reduceMotion {
                iconScale = 1
                iconOpacity = 1
            } else {
                withAnimation(.easeOut(duration: 0.45)) {
                    iconScale = 1
                    iconOpacity = 1
                }
            }
        }
    }

    // MARK: Grid

    private func glassBlockGrid(size: CGSize) -> some View {
        let cols = max(1, Int((size.width + seam) / (tileSize + seam)))
        let rows = max(1, Int((size.height + seam) / (tileSize + seam)))
        let tileW = (size.width - seam * CGFloat(cols - 1)) / CGFloat(cols)
        let tileH = (size.height - seam * CGFloat(rows - 1)) / CGFloat(rows)

        return ZStack {
            ForEach(0..<rows, id: \.self) { r in
                ForEach(0..<cols, id: \.self) { c in
                    GlassBlockTile(tint: tileTint(row: r, col: c))
                        .frame(width: tileW, height: tileH)
                        .position(
                            x: (tileW + seam) * CGFloat(c) + tileW / 2,
                            y: (tileH + seam) * CGFloat(r) + tileH / 2
                        )
                }
            }
        }
    }

    /// Deterministic pseudo-random tint per tile so the wall isn't uniform
    /// but also doesn't shimmer between renders. Low opacities only —
    /// the material is doing most of the work; these just add subtle
    /// per-tile color variation.
    private func tileTint(row: Int, col: Int) -> Color {
        let h = abs((row &* 73) &+ (col &* 31)) % 6
        switch h {
        case 0: return Self.skyBlue.opacity(0.06)
        case 1: return Self.iceBlue.opacity(0.10)
        case 2: return .clear
        case 3: return Self.skyBlue.opacity(0.03)
        case 4: return Self.iceBlue.opacity(0.05)
        default: return .white.opacity(0.04)
        }
    }

    // MARK: Center card

    private var centerCard: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 112, height: 112)
                .scaleEffect(iconScale)
                .opacity(iconOpacity)
                .shadow(color: Self.skyBlue.opacity(0.45), radius: 28, y: 4)

            Text("SAM is Locked")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            // Always-visible primary button. The auto-prompt (driven by
            // system events in AppLockService) is still the happy path;
            // this button is the discoverable fallback when the prompt
            // didn't fire or the user dismissed it. LAContext uses
            // `.deviceOwnerAuthentication`, so password fallback appears
            // automatically inside the system prompt.
            if lockService.isAuthenticating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Unlocking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    lockService.authenticate()
                } label: {
                    Label(
                        lockService.isBiometricAvailable ? "Unlock with Touch ID" : "Unlock SAM",
                        systemImage: lockService.isBiometricAvailable ? "touchid" : "lock.open"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let error = lockService.authError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                }
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 32)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                }
                .shadow(color: Self.skyBlue.opacity(0.25), radius: 30, y: 10)
        }
    }
}

/// One cell of the glass wall. Split out so SwiftUI can reuse the same
/// view identity per-tile and the material compositor can cache each
/// tile's blur region independently.
private struct GlassBlockTile: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint)
            }
            .overlay {
                // Highlight + inner shadow — the detail that sells "glass"
                // over "translucent rectangle." Top-left catches light,
                // bottom-right is slightly darker.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.35),
                                .white.opacity(0.08),
                                .black.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
    }
}

// MARK: - Preview

#Preview {
    LockOverlayContent()
        .frame(width: 600, height: 400)
}
