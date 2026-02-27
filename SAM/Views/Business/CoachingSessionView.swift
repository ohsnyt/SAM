//
//  CoachingSessionView.swift
//  SAM
//
//  Created on February 27, 2026.
//  Strategic Action Coaching Flow — Phase C
//
//  Chat-style interface for AI-assisted strategic planning sessions.
//  Presented as a sheet from StrategicInsightsView when user selects
//  "Plan This" on an implementation approach.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CoachingSessionView")

struct CoachingSessionView: View {

    let context: CoachingSessionContext
    let initialMessages: [CoachingMessage]
    let onDone: () -> Void

    @Environment(\.openWindow) private var openWindow

    // MARK: - State

    @State private var messages: [CoachingMessage] = []
    @State private var inputText: String = ""
    @State private var isGenerating: Bool = false
    @State private var errorMessage: String?
    @State private var showContentDraftSheet = false
    @State private var sessionFeedbackGiven: Bool? // nil=not yet, true=helpful, false=unhelpful

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
                            generatingIndicator
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
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            // Input bar
            inputBar
        }
        .frame(minWidth: 560, idealWidth: 560, minHeight: 500, idealHeight: 600)
        .onAppear {
            messages = initialMessages
        }
        .sheet(isPresented: $showContentDraftSheet) {
            ContentDraftSheet(
                topic: context.recommendation.title,
                keyPoints: [],
                suggestedTone: "educational",
                complianceNotes: nil,
                sourceOutcomeID: nil,
                onPosted: { showContentDraftSheet = false },
                onCancel: { showContentDraftSheet = false }
            )
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Planning: \(context.recommendation.title)")
                        .font(.headline)
                        .lineLimit(1)

                    if let approach = context.approach {
                        Text("Approach: \(approach.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Session feedback
                if let given = sessionFeedbackGiven {
                    HStack(spacing: 4) {
                        Image(systemName: given ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                            .font(.caption)
                            .foregroundStyle(given ? .green : .orange)
                        Text(given ? "Helpful" : "Not helpful")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Button {
                            sessionFeedbackGiven = true
                            Task { await CalibrationService.shared.recordSessionFeedback(category: context.recommendation.category, helpful: true) }
                        } label: {
                            Image(systemName: "hand.thumbsup")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("This session was helpful")

                        Button {
                            sessionFeedbackGiven = false
                            Task { await CalibrationService.shared.recordSessionFeedback(category: context.recommendation.category, helpful: false) }
                        } label: {
                            Image(systemName: "hand.thumbsdown")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("This session was not helpful")
                    }
                }

                Button("Done") {
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding()
    }

    // MARK: - Message Bubble

    private func messageBubble(_ message: CoachingMessage) -> some View {
        VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 6) {
            // Role label
            HStack(spacing: 4) {
                if message.role == .assistant {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text("SAM")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.blue)
                } else {
                    Text("You")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
            }

            // Content
            Text(message.content)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .background(messageBubbleBackground(for: message.role))

            // Action buttons
            if !message.actions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(message.actions) { action in
                        actionButton(action)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .assistant ? .leading : .trailing)
    }

    // MARK: - Action Button

    private func actionButton(_ action: CoachingAction) -> some View {
        Button {
            handleAction(action)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: actionIcon(action.actionType))
                    .font(.caption2)
                Text(action.label)
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(actionTint(action.actionType))
    }

    // MARK: - Generating Indicator

    private var generatingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("SAM is thinking...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a question or refine the plan...", text: $inputText)
                .textFieldStyle(.plain)
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(inputText.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
            .disabled(inputText.isEmpty || isGenerating)
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
                let response = try await CoachingPlannerService.shared.generateResponse(
                    userMessage: text,
                    recentHistory: messages,
                    context: context
                )
                messages.append(response)
            } catch {
                errorMessage = "Could not get response: \(error.localizedDescription)"
                logger.error("Coaching response failed: \(error.localizedDescription)")
            }
            isGenerating = false
        }
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
                contextTitle: context.recommendation.title
            )
            openWindow(id: "compose-message", value: payload)

        case .draftContent:
            showContentDraftSheet = true

        case .scheduleEvent:
            let payload = DeepWorkPayload(
                outcomeID: UUID(),
                personID: nil,
                personName: nil,
                title: action.metadata["title"] ?? context.recommendation.title,
                rationale: action.metadata["description"] ?? context.recommendation.rationale
            )
            openWindow(id: "deep-work-schedule", value: payload)

        case .createNote:
            let payload = QuickNotePayload(
                outcomeID: UUID(),
                personID: nil,
                personName: nil,
                contextTitle: context.recommendation.title,
                prefillText: action.metadata["content"]
            )
            openWindow(id: "quick-note", value: payload)

        case .navigateToPerson:
            if let personIDStr = action.metadata["personID"],
               let personID = UUID(uuidString: personIDStr) {
                NotificationCenter.default.post(
                    name: .samNavigateToPerson,
                    object: nil,
                    userInfo: ["personID": personID]
                )
            }

        case .reviewPipeline:
            NotificationCenter.default.post(
                name: .samNavigateToStrategicInsights,
                object: nil
            )
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func messageBubbleBackground(for role: CoachingMessage.MessageRole) -> some View {
        if role == .assistant {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.06))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
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

    private func actionTint(_ type: CoachingAction.ActionType) -> Color {
        switch type {
        case .composeMessage: return .blue
        case .draftContent: return .purple
        case .scheduleEvent: return .orange
        case .createNote: return .green
        case .navigateToPerson: return .teal
        case .reviewPipeline: return .indigo
        }
    }
}



