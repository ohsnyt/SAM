//
//  PinEntryView.swift
//  SAM Field
//
//  6-digit PIN entry sheet. The user reads the code from the Mac's
//  "Pair New iPhone" screen, types it here, and taps Pair. The heavy
//  lifting lives in AudioStreamingService.pairWithPIN — this view just
//  collects the PIN and observes `pinPairingState` for status updates.
//

import SwiftUI

struct PinEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var streaming = AudioStreamingService.shared
    @State private var pinDigits: String = ""
    @FocusState private var pinFocused: Bool

    private var canSubmit: Bool {
        pinDigits.count == 6 && !isBusy
    }

    private var isBusy: Bool {
        switch streaming.pinPairingState {
        case .searching, .sending: return true
        default: return false
        }
    }

    private var statusView: some View {
        Group {
            switch streaming.pinPairingState {
            case .idle:
                EmptyView()
            case .searching:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Looking for your Mac…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .sending:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Sending code to Mac…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .success(let macName):
                Label("Paired with \(macName)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .failure(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minHeight: 32)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Image(systemName: "desktopcomputer.and.arrow.down")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(.tint)
                        .padding(.top, 8)

                    Text("Enter the code shown on your Mac")
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text("On your Mac, open SAM → Settings → Companion iPhone → Pair New iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                TextField("123456", text: $pinDigits)
                    .font(.system(size: 32, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($pinFocused)
                    .frame(maxWidth: 240)
                    .padding(.vertical, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(isBusy)
                    .onChange(of: pinDigits) { _, newValue in
                        // Keep only digits, max 6.
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered != newValue || filtered.count > 6 {
                            pinDigits = String(filtered.prefix(6))
                        }
                        // Reset any prior failure as soon as the user edits.
                        if case .failure = streaming.pinPairingState {
                            // leave the state alone so the banner persists until
                            // a fresh submission, but clearing it on next submit
                            // below keeps the UX responsive.
                        }
                    }

                statusView

                Button {
                    streaming.pairWithPIN(pinDigits)
                } label: {
                    if isBusy {
                        ProgressView().progressViewStyle(.circular)
                    } else {
                        Text("Pair")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: 240)
                .disabled(!canSubmit)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                pinFocused = true
            }
            .onChange(of: streaming.pinPairingState) { _, newValue in
                if case .success = newValue {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(700))
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview("PIN Entry") {
    PinEntryView()
}
