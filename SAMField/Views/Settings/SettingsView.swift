//
//  SettingsView.swift
//  SAM Field
//
//  Created by Assistant on 4/18/26.
//
//  Settings sheet for SAM Field. Currently hosts the About section;
//  future preferences (notifications, mileage rate, voice polish, etc.)
//  will live here alongside it.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = DevicePairingService.shared
    @State private var showingPINEntry = false
    @State private var pairingToRemove: TrustedMacRecord?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if pairing.trustedMacs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Mac paired")
                            Text("Tap \"Pair with Mac\" here, then open SAM on your Mac and tap Pair New iPhone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(pairing.trustedMacs) { mac in
                            HStack {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.macDisplayName)
                                    Text("Paired \(mac.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    pairingToRemove = mac
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        showingPINEntry = true
                    } label: {
                        Label("Pair with Mac", systemImage: "iphone.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Mac Connection")
                } footer: {
                    Text("SAM Field connects only with Macs you've explicitly paired. Open SAM on your Mac, tap Pair New iPhone to get a 6-digit code, then enter it here.")
                }

                Section {
                    NavigationLink {
                        TripSettingsView()
                    } label: {
                        Label("Trip Settings", systemImage: "car.fill")
                    }
                } header: {
                    Text("Trips")
                } footer: {
                    Text("Home address, favorite addresses, and nearby-contact radius used during trip entry.")
                }

                Section("About") {
                    LabeledContent("Version", value: Self.versionString)
                    LabeledContent("Built", value: Self.buildDateString)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPINEntry) {
                PinEntryView()
            }
            .confirmationDialog(
                pairingToRemove.map { "Unpair from \($0.macDisplayName)?" } ?? "Unpair",
                isPresented: Binding(
                    get: { pairingToRemove != nil },
                    set: { if !$0 { pairingToRemove = nil } }
                ),
                titleVisibility: .visible,
                presenting: pairingToRemove
            ) { mac in
                Button("Unpair", role: .destructive) {
                    Task { await pairing.unpair(macDeviceID: mac.macDeviceID) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("You'll need to pair with this Mac again using SAM on your Mac.")
            }
        }
    }

    private static var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?[kCFBundleVersionKey as String] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static var buildDateString: String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let date = attrs[.modificationDate] as? Date else {
            return "Unknown"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

#Preview("Settings") {
    SettingsView()
}
