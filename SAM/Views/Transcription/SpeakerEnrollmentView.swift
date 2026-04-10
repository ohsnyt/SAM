//
//  SpeakerEnrollmentView.swift
//  SAM
//
//  Wizard for enrolling the agent's voice. Records 30 seconds of the agent
//  reading a passage, extracts an embedding, saves as a SpeakerProfile.
//  Enables auto-labeling of the agent in meeting transcripts (M4 diarization).
//

import SwiftUI
import SwiftData

struct SpeakerEnrollmentView: View {
    @State private var coordinator = SpeakerEnrollmentCoordinator()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Passage for the agent to read during enrollment.
    private let passage = """
    I've been working in financial services for years, and one of the things \
    I enjoy most is helping families build a clear picture of their future. \
    Everyone's situation is different, so I like to start by listening — \
    understanding what matters most to you, where you're headed, and what's \
    been on your mind. From there, we can look at what the right next steps \
    might be, whether that's protecting your income, saving for your children's \
    education, or planning for a comfortable retirement.
    """

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    switch coordinator.state {
                    case .idle:
                        idleView
                    case .recording:
                        recordingView
                    case .processing:
                        processingView
                    case .saved:
                        savedView
                    case .error(let message):
                        errorView(message)
                    }
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 500, idealHeight: 620)
        .onAppear {
            coordinator.configure(container: modelContext.container)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enroll Your Voice")
                    .font(.title2.bold())
                Text("Train SAM to recognize you in meeting transcripts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Close") {
                coordinator.cancel()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleView: some View {
        if coordinator.existingAgentProfileID != nil {
            existingProfileCard
        }

        VStack(alignment: .leading, spacing: 16) {
            Label("How it works", systemImage: "info.circle")
                .font(.headline)

            stepRow(number: 1, text: "Find a quiet room and position your Mac's mic close to you (headset is best).")
            stepRow(number: 2, text: "Click Start and read the passage below naturally, at a normal pace.")
            stepRow(number: 3, text: "After 30 seconds, SAM builds your voice profile and auto-labels you in transcripts.")
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

        GroupBox("Read this passage") {
            Text(passage)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }

        Button {
            do {
                try coordinator.startRecording()
            } catch {
                // Error state already set by coordinator
            }
        } label: {
            Label("Start Recording", systemImage: "record.circle.fill")
                .font(.title3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
    }

    private var existingProfileCard: some View {
        HStack {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Voice profile already enrolled")
                    .font(.headline)
                Text("Re-recording will replace your existing profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Delete", role: .destructive) {
                coordinator.deleteExistingProfile()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.1)))
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.body.bold())
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)

            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Recording

    private var recordingView: some View {
        VStack(spacing: 20) {
            // Animated recording indicator
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 140, height: 140)
                    .scaleEffect(1 + CGFloat(coordinator.audioLevel) * 0.3)
                    .animation(.easeOut(duration: 0.1), value: coordinator.audioLevel)

                Circle()
                    .fill(Color.red)
                    .frame(width: 80, height: 80)

                Image(systemName: "mic.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
            }

            Text(formatTime(coordinator.elapsedTime))
                .font(.system(size: 48, weight: .thin, design: .monospaced))
                .monospacedDigit()

            ProgressView(value: coordinator.recordingProgress) {
                Text("\(Int(coordinator.recordingProgress * 100))% complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)
            .tint(.red)
            .frame(maxWidth: 300)

            GroupBox {
                Text(passage)
                    .font(.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) {
                    coordinator.cancel()
                }
                .buttonStyle(.bordered)

                Button("Stop & Save") {
                    coordinator.stopRecording()
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.elapsedTime < 10)
            }
        }
    }

    // MARK: - Processing

    private var processingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            Text("Building your voice profile…")
                .font(.headline)

            Text("Extracting features and averaging embeddings")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }

    // MARK: - Saved

    private var savedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            Text("Voice Profile Saved")
                .font(.title.bold())

            Text("SAM will now auto-label you as the Agent in meeting transcripts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Record Again") {
                    coordinator.reset()
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top)
        }
        .padding(40)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)

            Text("Enrollment Failed")
                .font(.title2.bold())

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                coordinator.reset()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
