//
//  CompanionPhoneSettingsPane.swift
//  SAM
//
//  Pair/unpair iPhones that are allowed to stream audio and sync with this Mac.
//  Pairing uses a 6-digit PIN: the Mac shows it, the phone types it in.
//

import SwiftUI
import AppKit

struct CompanionPhoneSettingsPane: View {
    @State private var pairing = DevicePairingService.shared
    @State private var showingPairingSheet = false
    @State private var showingResetConfirm = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {

                    // ── This Mac ──
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This Mac")
                            .samFont(.headline)

                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pairing.macDisplayName)
                                Text("SAM will accept audio streaming only from paired iPhones.")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    // ── Paired iPhones ──
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Paired iPhones")
                                .samFont(.headline)
                            Spacer()
                            Button {
                                showingPairingSheet = true
                            } label: {
                                Label("Pair New iPhone", systemImage: "iphone.radiowaves.left.and.right")
                            }
                        }

                        if pairing.pairedDevices.isEmpty {
                            Text("No iPhones paired yet. Tap \"Pair New iPhone\" and follow the prompts on your phone.")
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(pairing.pairedDevices) { device in
                                PairedDeviceRow(device: device) {
                                    pairing.unpair(phoneDeviceID: device.id)
                                }
                            }
                        }
                    }

                    Divider()

                    // ── Reset ──
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Advanced")
                            .samFont(.headline)

                        Button(role: .destructive) {
                            showingResetConfirm = true
                        } label: {
                            Label("Reset Pairing Token", systemImage: "arrow.counterclockwise")
                        }

                        Text("Invalidates every paired iPhone. You'll need to pair each device again.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPairingSheet) {
            PairingExperienceSheet()
        }
        .confirmationDialog(
            "Reset pairing token?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset & Unpair All", role: .destructive) {
                Task { await pairing.resetPairingToken() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All iPhones currently paired with this Mac will lose access.")
        }
    }
}

// MARK: - Paired Device Row

private struct PairedDeviceRow: View {
    let device: PairedDeviceRecord
    let onUnpair: () -> Void

    @State private var showingUnpairConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                HStack(spacing: 6) {
                    Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                    if let seen = device.lastSeenAt {
                        Text("•")
                        Text("Last seen \(seen, style: .relative) ago")
                    }
                }
                .samFont(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                showingUnpairConfirm = true
            } label: {
                Text("Unpair")
            }
            .confirmationDialog(
                "Unpair \(device.displayName)?",
                isPresented: $showingUnpairConfirm,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive, action: onUnpair)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This iPhone won't be able to stream audio or sync until re-paired.")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pairing Experience Sheet

/// Simple PIN-display pairing sheet. The Mac generates a 6-digit PIN and
/// shows it; the phone types it in and pairs without any further action
/// on the Mac.
private struct PairingExperienceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = DevicePairingService.shared

    @State private var pin: String = "------"
    @State private var remainingSeconds: Int = 90
    @State private var countdownTask: Task<Void, Never>?
    @State private var didStart = false
    @State private var initialPairedCount = 0

    private var formattedPIN: String {
        guard pin.count == 6 else { return pin }
        return "\(pin.prefix(3)) \(pin.suffix(3))"
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.tint)

                Text("Pair iPhone")
                    .samFont(.title)
                    .padding(.top, 4)
            }
            .padding(.top, 24)

            VStack(spacing: 6) {
                Text("SAM Pairing Code")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(1)

                Text(formattedPIN)
                    .font(.system(size: 52, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                Text("Open SAM Field on your iPhone, tap Settings → Pair with Mac, and enter this code.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .padding(.top, 2)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 24)

            Group {
                if remainingSeconds > 0 {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Waiting for iPhone… expires in \(remainingSeconds)s")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Code expired — close and try again.")
                        .samFont(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(minHeight: 24)

            Button("Cancel") {
                pairing.stopPINPairing()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, 20)
        }
        .frame(width: 420)
        .onAppear {
            guard !didStart else { return }
            didStart = true
            initialPairedCount = pairing.pairedDevices.count
            pin = pairing.startPINPairing(duration: 90)
            startCountdown()
        }
        .onDisappear {
            countdownTask?.cancel()
            pairing.stopPINPairing()
        }
        .onChange(of: pairing.pairedDevices.count) { _, newValue in
            // A new paired device appeared → auto-dismiss shortly after.
            if newValue > initialPairedCount {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    dismiss()
                }
            }
        }
    }

    private func startCountdown() {
        let expiry = Date().addingTimeInterval(90)
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while !Task.isCancelled {
                let diff = Int(expiry.timeIntervalSinceNow.rounded(.down))
                remainingSeconds = max(0, diff)
                if diff <= 0 { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
