//
//  CustomTopicSheet.swift
//  SAM
//
//  Created on March 20, 2026.
//  Lets the user enter a custom content topic and key points for draft generation.
//

import SwiftUI

struct CustomTopicSheet: View {

    let onSubmit: (ContentTopic) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var topic = ""
    @State private var keyPointsText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Custom Topic")
                    .samFont(.title3, weight: .bold)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Topic")
                        .samFont(.headline)
                    TextField("e.g., ABT semi-annual board meeting", text: $topic)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Key Points")
                        .samFont(.headline)
                    Text("One per line — these guide the draft content")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $keyPointsText)
                        .samFont(.body)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding()

            Spacer()

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Create Topic & Draft") {
                    let points = keyPointsText
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

                    let contentTopic = ContentTopic(
                        topic: topic,
                        keyPoints: points,
                        suggestedTone: "educational"
                    )

                    dismiss()
                    onSubmit(contentTopic)
                }
                .buttonStyle(.borderedProminent)
                .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 560, height: 520)
    }
}
