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
    @State private var pairingToRemove: TrustedMacRecord?
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if pairing.trustedMacs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Mac found yet")
                            Text("SAM Field pairs automatically with any Mac running SAM under the same iCloud account. Open SAM on your Mac at least once, then pull down to refresh.")
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
                        Task {
                            isRefreshing = true
                            await pairing.refreshFromCloudKit()
                            AudioStreamingService.shared.restartBrowsing()
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            HStack { ProgressView(); Text("Checking iCloud…") }
                        } else {
                            Label("Refresh from iCloud", systemImage: "arrow.clockwise.icloud")
                        }
                    }
                    .disabled(isRefreshing)
                } header: {
                    Text("Mac Connection")
                } footer: {
                    Text("Pairing tokens are distributed via your iCloud private database, so SAM Field trusts every Mac running SAM under the same iCloud account automatically. Different iCloud accounts can't read the token.")
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
                Text("This Mac will be removed from the list, but it will reappear automatically on the next iCloud refresh because the pairing token still gives it access. Use Reset Pairing Token on the Mac to lock it out completely.")
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
