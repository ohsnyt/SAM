//
//  SavedNoteDetailView.swift
//  SAM Field
//
//  Created by Assistant on 4/9/26.
//  Phase F2: Voice Capture — note detail view
//
//  Shows the full content of a saved voice note.
//

import SwiftUI

struct SavedNoteDetailView: View {
    let note: SamNote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Summary
                if let summary = note.summary {
                    Text(summary)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // Full content
                Text(note.content)
                    .font(.body)
                    .textSelection(.enabled)

                // Metadata
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text(note.createdAt, format: .dateTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !note.linkedPeople.isEmpty {
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                            Text(note.linkedPeople.compactMap(\.displayNameCache).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if note.audioRecordingPath != nil {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary)
                            Text("Audio recording saved")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.secondary)
                        Text("Voice capture")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Voice Note")
        .navigationBarTitleDisplayMode(.inline)
    }
}
