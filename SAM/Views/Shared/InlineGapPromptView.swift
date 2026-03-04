//
//  InlineGapPromptView.swift
//  SAM
//
//  Created by Assistant on 3/4/26.
//  Phase 2: Suggestion Quality Overhaul
//
//  Reusable inline question card shown when SAM detects a knowledge gap.
//  Stores answers in UserDefaults; once answered, the prompt disappears
//  and the answer feeds into future AI context.
//

import SwiftUI

struct InlineGapPromptView: View {

    let gap: KnowledgeGap
    var onAnswered: (() -> Void)?

    @State private var answer: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: gap.icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(gap.question)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                TextField(gap.placeholder, text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { saveAnswer() }

                HStack {
                    Spacer()
                    Button("Save") {
                        saveAnswer()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    private func saveAnswer() {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: gap.storageKey)
        onAnswered?()
    }
}
