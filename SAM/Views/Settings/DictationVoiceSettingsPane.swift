//
//  DictationVoiceSettingsPane.swift
//  SAM
//
//  Settings pane for dictation, voice, and related permissions.
//

import SwiftUI
import AVFoundation
import Speech

struct DictationVoiceSettingsPane: View {

    @State private var silenceTimeout: Double = {
        let stored = UserDefaults.standard.double(forKey: "sam.dictation.silenceTimeout")
        return stored > 0 ? stored : 2.0
    }()

    @State private var microphoneStatus: String = "Checking..."
    @State private var speechStatus: String = "Checking..."

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    // Microphone permission
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Permissions")
                            .samFont(.headline)

                        permissionBadge(
                            icon: "mic.fill", color: .purple,
                            name: "Microphone", status: microphoneStatus
                        )

                        if microphoneStatus != "Authorized" {
                            Button("Open System Settings") { openPrivacySettings() }
                                .controlSize(.small)
                        }

                        permissionBadge(
                            icon: "waveform.circle.fill", color: .purple,
                            name: "Speech Recognition", status: speechStatus
                        )

                        if speechStatus != "Authorized" {
                            Button("Open System Settings") { openPrivacySettings() }
                                .controlSize(.small)
                        }
                    }

                    Divider()

                    // Dictation silence timeout
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Dictation")
                            .samFont(.headline)

                        Text("How long SAM waits after you stop speaking before ending dictation.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Silence timeout")
                            Spacer()
                            Text(String(format: "%.1fs", silenceTimeout))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(value: $silenceTimeout, in: 0.5...5.0, step: 0.5)
                            .onChange(of: silenceTimeout) { _, newValue in
                                UserDefaults.standard.set(newValue, forKey: "sam.dictation.silenceTimeout")
                            }

                        HStack {
                            Text("0.5s")
                                .samFont(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("5.0s")
                                .samFont(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Divider()

                    // Narration voice info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Narration")
                            .samFont(.headline)

                        Text("SAM uses the system Samantha voice for reading briefings aloud. Voice selection may be expanded in a future update.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .task {
            checkPermissions()
        }
    }

    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneStatus = "Authorized"
        case .denied, .restricted: microphoneStatus = "Denied"
        case .notDetermined: microphoneStatus = "Not Requested"
        @unknown default: microphoneStatus = "Unknown"
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechStatus = "Authorized"
        case .denied, .restricted: speechStatus = "Denied"
        case .notDetermined: speechStatus = "Not Requested"
        @unknown default: speechStatus = "Unknown"
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
