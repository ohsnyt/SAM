//
//  VoiceCaptureCoordinator.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F2: Voice Capture
//
//  Orchestrates the full voice capture flow:
//  record (with live transcription) → review/edit → save as SamNote + SamEvidenceItem
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "VoiceCaptureCoordinator")

@MainActor
@Observable
final class VoiceCaptureCoordinator {

    static let shared = VoiceCaptureCoordinator()

    // MARK: - State

    enum CaptureState: Sendable {
        case idle
        case recording
        case paused
        case review
        case saving
        case saved
    }

    private(set) var state: CaptureState = .idle

    /// The transcript text — live during recording, editable during review
    var transcript: String = ""

    /// Audio file URL (set after recording completes)
    private(set) var audioFileURL: URL?

    /// Selected person to link the note to
    var selectedPerson: SamPerson?

    /// Error message to display
    private(set) var errorMessage: String?

    // MARK: - Dependencies

    private var container: ModelContainer?
    private let recorder = VoiceRecordingService.shared
    private let ai = FieldAIService.shared

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Recording Flow

    /// Start a new voice capture session.
    func startRecording() {
        errorMessage = nil

        Task {
            let authorized = await recorder.requestAuthorization()
            guard authorized else {
                errorMessage = "Microphone and speech recognition access are required. Please enable them in Settings."
                return
            }

            do {
                try recorder.startRecording()
                state = .recording
            } catch {
                errorMessage = "Could not start recording: \(error.localizedDescription)"
                logger.error("Start recording failed: \(error)")
            }
        }
    }

    /// Pause recording (excludes chit-chat, sensitive info).
    func pauseRecording() {
        recorder.pauseRecording()
        state = .paused
    }

    /// Resume recording after pause.
    func resumeRecording() {
        do {
            try recorder.resumeRecording()
            state = .recording
        } catch {
            errorMessage = "Could not resume recording: \(error.localizedDescription)"
        }
    }

    /// Stop recording and move to review.
    func stopRecording() {
        recorder.stopRecording()
        transcript = recorder.liveTranscript
        audioFileURL = recorder.audioFileURL
        state = .review
    }

    /// Cancel the current recording.
    func cancelRecording() {
        recorder.cancelRecording()
        reset()
    }

    // MARK: - Live State

    /// Live transcript from the recorder (updates in real time).
    var liveTranscript: String { recorder.liveTranscript }

    /// Whether the recorder is actively capturing audio.
    var isRecording: Bool { state == .recording }

    /// Whether recording is paused.
    var isPaused: Bool { state == .paused }

    /// Current audio level from the recorder (0.0–1.0).
    var audioLevel: Float { recorder.audioLevel }

    /// Elapsed recording time from the recorder.
    var elapsedTime: TimeInterval { recorder.elapsedTime }

    // MARK: - Save

    /// Save the transcript as a SamNote + SamEvidenceItem.
    func save() async {
        guard let container else {
            errorMessage = "Not configured"
            return
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Cannot save an empty note"
            return
        }

        state = .saving

        let context = ModelContext(container)

        // Create the note
        let note = SamNote(
            content: transcript,
            sourceType: .dictated
        )

        // Set audio recording path if we have one
        if let url = audioFileURL {
            note.audioRecordingPath = VoiceRecordingService.relativePath(for: url)
        }

        // Link to person if selected
        if let person = selectedPerson {
            let personID = person.id
            let descriptor = FetchDescriptor<SamPerson>(
                predicate: #Predicate { $0.id == personID }
            )
            if let localPerson = try? context.fetch(descriptor).first {
                note.linkedPeople = [localPerson]
            }
        }

        // Generate summary (skipped if AI unavailable — e.g., iPhone 11)
        let summary = await ai.summarize(transcript)
        note.summary = summary

        context.insert(note)

        // Create evidence item
        let evidence = SamEvidenceItem(
            id: UUID(),
            state: .done,
            sourceUID: "voiceCapture:\(note.id.uuidString)",
            source: .voiceCapture,
            occurredAt: .now,
            title: summary ?? String(transcript.prefix(80)),
            snippet: String(transcript.prefix(200)),
            bodyText: transcript
        )

        if let person = selectedPerson {
            let personID = person.id
            let descriptor = FetchDescriptor<SamPerson>(
                predicate: #Predicate { $0.id == personID }
            )
            if let localPerson = try? context.fetch(descriptor).first {
                evidence.linkedPeople = [localPerson]
            }
        }

        context.insert(evidence)
        note.linkedEvidence = [evidence]

        do {
            try context.save()
            logger.info("Saved voice capture note \(note.id) with evidence \(evidence.id)")
            state = .saved
            recorder.reset()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            logger.error("Save failed: \(error)")
            state = .review
        }
    }

    // MARK: - Reset

    /// Clear the error message.
    func clearError() {
        errorMessage = nil
    }

    /// Reset all state for a new capture.
    func reset() {
        state = .idle
        transcript = ""
        audioFileURL = nil
        selectedPerson = nil
        errorMessage = nil
        recorder.reset()
    }
}
