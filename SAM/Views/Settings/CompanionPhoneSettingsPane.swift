//
//  CompanionPhoneSettingsPane.swift
//  SAM
//
//  Lists iPhones currently paired to this Mac and lets the user reset the
//  pairing token. New iPhones pair automatically via CloudKit (private DB,
//  same iCloud account) — there is no PIN/QR/handshake UX.
//

import SwiftUI
import AppKit

struct CompanionPhoneSettingsPane: View {
    @State private var pairing = DevicePairingService.shared
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
                                Text("Any iPhone signed into the same iCloud account picks up this Mac's pairing token automatically — no PIN required.")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    // ── Paired iPhones ──
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paired iPhones")
                            .samFont(.headline)

                        if pairing.pairedDevices.isEmpty {
                            Text("No iPhones have connected yet. Open SAM Field on your iPhone — it will pair automatically when both devices are signed into the same iCloud account.")
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

                        Text("Generates a new token and republishes it via iCloud. Every paired iPhone will pick up the new token on its next launch.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
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
            Text("All iPhones currently paired with this Mac will need to fetch the new token from iCloud before they can reconnect.")
        }
        .dismissOnLock(isPresented: $showingResetConfirm)
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
                Text("This iPhone will be removed from the paired list, but it will re-appear here on its next connection because the iCloud pairing token still gives it access. Use Reset Pairing Token to lock it out completely.")
            }
            .dismissOnLock(isPresented: $showingUnpairConfirm)
        }
        .padding(.vertical, 2)
    }
}
