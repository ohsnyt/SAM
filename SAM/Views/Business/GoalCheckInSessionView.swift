//
//  GoalCheckInSessionView.swift
//  SAM
//
//  Created on March 17, 2026.
//  Goal Journal: Check-in chat UI with post-session summarization.
//
//  Reuses CoachingSessionView's chat pattern with goal-specific header
//  and a structured "Done" flow that produces a GoalJournalEntry.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "GoalCheckInSessionView")

struct GoalCheckInSessionView: View {

    let context: GoalCheckInContext
    let onDone: () -> Void

    @Environment(\.openWindow) private var openWindow

    // MARK: - State

    @State private var messages: [CoachingMessage] = []
    @State private var inputText: String = ""
    @State private var isGenerating: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }

                        if isGenerating {
                            generatingIndicator("SAM is thinking...")
                                .id("thinking-indicator")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isGenerating) {
                    if isGenerating {
                        withAnimation {
                            proxy.scrollTo("thinking-indicator", anchor: .bottom)
                        }
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .samFont(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            // Input bar
            inputBar
        }
        .frame(minWidth: 560, idealWidth: 560, minHeight: 500, idealHeight: 600)
        .onAppear {
            let opening = GoalCheckInService.shared.generateOpeningMessage(context: context)
            messages = [opening]
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: context.goalType.icon)
                            .foregroundStyle(context.goalType.color)
                        Text("Check In: \(context.goalTitle)")
                            .samFont(.headline)
                            .lineLimit(1)
                    }

                    HStack(spacing: 12) {
                        // Progress
                        Text("\(Int(context.progress.currentValue))/\(Int(context.progress.targetValue))")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)

                        // Pace badge
                        Text(context.progress.pace.displayName)
                            .samFont(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(context.progress.pace.color)
                            .clipShape(Capsule())

                        // Days remaining
                        if context.progress.daysRemaining > 0 {
                            Text("\(context.progress.daysRemaining) days left")
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Button("Done") {
                    finishCheckIn()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(messages.count < 2 || isGenerating)

                Button("Cancel") {
                    onDone()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
    }

    // MARK: - Message Bubble

    private func messageBubble(_ message: CoachingMessage) -> some View {
        VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 6) {
            HStack(spacing: 4) {
                if message.role == .assistant {
                    Image(systemName: "sparkles")
                        .samFont(.caption2)
                        .foregroundStyle(.blue)
                    Text("SAM")
                        .samFont(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.blue)
                } else {
                    Text("You")
                        .samFont(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
            }

            Text(message.content)
                .samFont(.callout)
                .textSelection(.enabled)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(message.role == .assistant
                              ? Color(nsColor: .controlBackgroundColor)
                              : Color.blue.opacity(0.1))
                )

            // Action buttons
            if !message.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.actions) { action in
                        actionButton(action)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .assistant ? .leading : .trailing)
    }

    private func actionButton(_ action: CoachingAction) -> some View {
        Button {
            handleAction(action)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: actionIcon(action.actionType))
                    .samFont(.caption2)
                Text(action.label)
                    .samFont(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Generating Indicator

    private func generatingIndicator(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $inputText)
                .samFont(.body)
                .frame(minHeight: 72, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("Share what's working, what's not...")
                            .samFont(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            VStack(spacing: 8) {
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .samFont(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(inputText.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
                .disabled(inputText.isEmpty || isGenerating)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }

        let userMessage = CoachingMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""
        errorMessage = nil

        Task {
            isGenerating = true
            do {
                let response = try await GoalCheckInService.shared.generateResponse(
                    userMessage: text,
                    recentHistory: messages,
                    context: context
                )
                messages.append(response)
            } catch {
                errorMessage = "Could not get response: \(error.localizedDescription)"
                logger.error("Check-in response failed: \(error.localizedDescription)")
            }
            isGenerating = false
        }
    }

    private func finishCheckIn() {
        GoalJournalRepository.shared.summarizeAndSave(
            messages: messages,
            context: context
        )
        onDone()
    }

    private func handleAction(_ action: CoachingAction) {
        switch action.actionType {
        case .composeMessage:
            let payload = ComposePayload(
                outcomeID: UUID(),
                personID: nil,
                personName: action.metadata["personName"],
                recipientAddress: action.metadata["address"] ?? "",
                channel: .iMessage,
                subject: nil,
                draftBody: action.metadata["draft"] ?? "",
                contextTitle: context.goalTitle
            )
            openWindow(id: "compose-message", value: payload)
        case .scheduleEvent:
            openWindow(id: "schedule-deep-work")
        case .createNote:
            openWindow(id: "quick-note")
        default:
            break
        }
    }

    private func actionIcon(_ type: CoachingAction.ActionType) -> String {
        switch type {
        case .composeMessage: return "envelope"
        case .draftContent: return "doc.text"
        case .scheduleEvent: return "calendar.badge.plus"
        case .createNote: return "note.text"
        case .navigateToPerson: return "person"
        case .reviewPipeline: return "chart.bar"
        }
    }
}
