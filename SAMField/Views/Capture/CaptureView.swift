//
//  CaptureView.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F2: Voice Capture
//
//  Main capture tab — voice recording with live transcription,
//  pause/resume, review/edit, person linking, and save.
//

import SwiftUI
import SwiftData
import AVFoundation

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var coordinator = VoiceCaptureCoordinator.shared
    @State private var recorder = VoiceRecordingService.shared
    @State private var showPersonPicker = false

    var body: some View {
        VStack(spacing: 0) {
            switch coordinator.state {
            case .idle:
                idleView
            case .recording, .paused:
                recordingView
            case .review:
                reviewView
            case .saving:
                savingView
            case .saved:
                savedView
            }
        }
        .navigationTitle("Capture")
        .onAppear {
            coordinator.configure(container: modelContext.container)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { coordinator.clearError() }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { recorder.preferredInput?.uid ?? "" },
            set: { uid in
                let input = recorder.availableInputs.first { $0.uid == uid }
                recorder.selectInput(input)
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.clearError() } }
        )
    }

    // MARK: - Idle State

    @Query(
        filter: #Predicate<SamNote> { $0.sourceTypeRawValue == "dictated" },
        sort: \SamNote.createdAt,
        order: .reverse
    )
    private var savedNotes: [SamNote]

    private var idleView: some View {
        List {
            // Record button section
            Section {
                VStack(spacing: 16) {
                    recordButton
                    Text("Tap to start recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            // Audio settings
            Section("Recording Settings") {
                Picker("Audio Mode", selection: $recorder.audioMode) {
                    ForEach(VoiceRecordingService.AudioMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                if recorder.availableInputs.count > 1 {
                    Picker("Microphone", selection: inputBinding) {
                        Text("Default").tag("" as String)
                        ForEach(recorder.availableInputs, id: \.uid) { input in
                            Text(input.portName).tag(input.uid)
                        }
                    }
                }
            }

            // Saved voice notes
            if !savedNotes.isEmpty {
                Section("Saved Voice Notes") {
                    ForEach(savedNotes, id: \.id) { note in
                        NavigationLink {
                            SavedNoteDetailView(note: note)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.summary ?? String(note.content.prefix(80)))
                                    .font(.subheadline)
                                    .lineLimit(2)

                                HStack(spacing: 8) {
                                    Text(note.createdAt, style: .relative)
                                    if !note.linkedPeople.isEmpty {
                                        Label(
                                            note.linkedPeople.first?.displayNameCache ?? "",
                                            systemImage: "person.fill"
                                        )
                                    }
                                    if note.audioRecordingPath != nil {
                                        Image(systemName: "waveform")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recording State (with live transcript)

    private var recordingView: some View {
        VStack(spacing: 0) {
            // Live transcript area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if coordinator.liveTranscript.isEmpty {
                            Text("Listening...")
                                .foregroundStyle(.tertiary)
                                .italic()
                        } else {
                            Text(coordinator.liveTranscript)
                                .font(.body)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: coordinator.liveTranscript) {
                    withAnimation {
                        proxy.scrollTo("bottom")
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // Bottom panel
            VStack(spacing: 12) {
                // Audio level + time
                HStack {
                    AudioLevelView(level: coordinator.audioLevel)
                        .frame(height: 30)

                    Text(formatTime(coordinator.elapsedTime))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }

                // Paused indicator
                if coordinator.isPaused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.15))
                        .clipShape(Capsule())
                }

                // Controls
                HStack(spacing: 24) {
                    // Cancel
                    Button {
                        coordinator.cancelRecording()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }

                    // Pause / Resume
                    if coordinator.isRecording {
                        Button {
                            coordinator.pauseRecording()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 52, height: 52)
                                Image(systemName: "pause.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                            }
                        }
                    } else {
                        Button {
                            coordinator.resumeRecording()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 52, height: 52)
                                Image(systemName: "mic.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    // Stop (finish recording)
                    Button {
                        coordinator.stopRecording()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.red)
                                .frame(width: 52, height: 52)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white)
                                .frame(width: 20, height: 20)
                        }
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Review State

    private var reviewView: some View {
        VStack(spacing: 0) {
            // Person link
            Button {
                showPersonPicker = true
            } label: {
                HStack {
                    Image(systemName: coordinator.selectedPerson != nil ? "person.fill.checkmark" : "person.badge.plus")
                    Text(coordinator.selectedPerson.flatMap { $0.displayNameCache } ?? "Link to person")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(.fill.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding()

            // Editable transcript
            TextEditor(text: $coordinator.transcript)
                .padding(.horizontal)
                .scrollContentBackground(.hidden)

            // Action buttons
            HStack(spacing: 16) {
                Button("Discard", role: .destructive) {
                    coordinator.reset()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task { await coordinator.save() }
                } label: {
                    Label("Save Note", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .sheet(isPresented: $showPersonPicker) {
            PersonPickerView(selection: $coordinator.selectedPerson)
        }
    }

    // MARK: - Saving State

    private var savingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text("Saving...")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Saved State

    private var savedView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("Note saved")
                .font(.title2.bold())
            Text("Your voice note has been saved and will sync to SAM on your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Button("New Capture") {
                coordinator.reset()
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button {
            coordinator.startRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(.red)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(.red)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Circle()
                            .strokeBorder(.white, lineWidth: 3)
                    )
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Level Visualizer

struct AudioLevelView: View {
    let level: Float
    private let barCount = 20

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(for: index))
                    .frame(width: 4)
                    .frame(height: barHeight(for: index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let position = Float(index) / Float(barCount)
        let distance = abs(position - 0.5) * 2
        let amplitude = max(0, CGFloat(level) - CGFloat(distance) * 0.3)
        return max(3, amplitude * 24)
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index) / Float(barCount)
        return threshold < level ? .blue : .secondary.opacity(0.3)
    }
}

// MARK: - Person Picker

struct PersonPickerView: View {
    @Binding var selection: SamPerson?
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SamPerson.displayNameCache) private var people: [SamPerson]
    @State private var searchText = ""

    private var filteredPeople: [SamPerson] {
        if searchText.isEmpty { return people }
        let query = searchText.lowercased()
        return people.filter { ($0.displayNameCache ?? "").lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filteredPeople, id: \.id) { person in
                let isSelected = selection?.id == person.id
                Button {
                    selection = person
                    dismiss()
                } label: {
                    HStack {
                        Text(person.displayNameCache ?? "Unknown")
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Search people")
            .navigationTitle("Link to Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("None") {
                        selection = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview("Capture - Idle") {
    NavigationStack {
        CaptureView()
    }
    .modelContainer(for: SamNote.self, inMemory: true)
}
