//
//  LifeEventCoachingView.swift
//  SAM
//
//  Created on February 27, 2026.
//  Life Event Coaching — Phase H
//
//  Chat-style interface for AI-assisted life event coaching sessions.
//  Helps the user think through messaging, outreach, and follow-up for
//  life events detected in their contacts.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LifeEventCoachingView")

struct LifeEventCoachingView: View {

    let context: LifeEventCoachingContext
    let onDone: () -> Void

    @Environment(\.openWindow) private var openWindow

    // MARK: - State

    @State private var messages: [CoachingMessage] = []
    @State private var inputText: String = ""
    @State private var isGenerating: Bool = false
    @State private var errorMessage: String?
    @State private var showContentDraftSheet = false

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
        .task {
            await loadInitialCoaching()
        }
        .sheet(isPresented: $showContentDraftSheet) {
            ContentDraftSheet(
                topic: "\(context.event.eventTypeLabel) — \(context.personName)",
                keyPoints: [],
                suggestedTone: "warm",
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
                    HStack(spacing: 6) {
                        Image(systemName: iconForEventType(context.event.eventType))
                            .foregroundStyle(.pink)
                        Text(context.personName)
                            .font(.headline)
                        Text(context.event.eventTypeLabel)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.pink.opacity(0.15))
                            .foregroundStyle(.pink)
                            .clipShape(Capsule())
                    }

                    Text(context.event.eventDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

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
                        .foregroundStyle(.pink)
                    Text("SAM")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.pink)
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
            TextField("Ask about messaging, approach, or follow-up...", text: $inputText)
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
            .foregroundStyle(inputText.isEmpty ? Color.gray.opacity(0.4) : Color.pink)
            .disabled(inputText.isEmpty || isGenerating)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func loadInitialCoaching() async {
        isGenerating = true
        do {
            let initialMessage = try await LifeEventCoachingService.shared
                .generateInitialCoaching(context: context)
            messages = [initialMessage]
        } catch {
            errorMessage = "Could not start coaching session: \(error.localizedDescription)"
            logger.error("Life event coaching initial load failed: \(error.localizedDescription)")
        }
        isGenerating = false
    }

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
                let response = try await LifeEventCoachingService.shared.generateResponse(
                    userMessage: text,
                    recentHistory: messages,
                    context: context
                )
                messages.append(response)
            } catch {
                errorMessage = "Could not get response: \(error.localizedDescription)"
                logger.error("Life event coaching response failed: \(error.localizedDescription)")
            }
            isGenerating = false
        }
    }

    private func handleAction(_ action: CoachingAction) {
        switch action.actionType {
        case .composeMessage:
            let personID: UUID? = if let idStr = action.metadata["personID"], !idStr.isEmpty {
                UUID(uuidString: idStr)
            } else {
                context.personID
            }
            let payload = ComposePayload(
                outcomeID: UUID(),
                personID: personID,
                personName: action.metadata["personName"] ?? context.personName,
                recipientAddress: action.metadata["address"] ?? "",
                channel: .iMessage,
                subject: nil,
                draftBody: action.metadata["draft"] ?? "",
                contextTitle: "\(context.event.eventTypeLabel) — \(context.personName)"
            )
            openWindow(id: "compose-message", value: payload)

        case .draftContent:
            showContentDraftSheet = true

        case .scheduleEvent:
            let payload = DeepWorkPayload(
                outcomeID: UUID(),
                personID: context.personID,
                personName: context.personName,
                title: action.metadata["title"] ?? "\(context.event.eventTypeLabel) follow-up with \(context.personName)",
                rationale: action.metadata["description"] ?? context.event.eventDescription
            )
            openWindow(id: "deep-work-schedule", value: payload)

        case .createNote:
            let payload = QuickNotePayload(
                outcomeID: UUID(),
                personID: context.personID,
                personName: context.personName,
                contextTitle: "\(context.event.eventTypeLabel) — \(context.personName)",
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
                .fill(Color.pink.opacity(0.06))
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

    private func iconForEventType(_ type: String) -> String {
        switch type {
        case "new_baby": return "stroller"
        case "marriage": return "heart.fill"
        case "graduation": return "graduationcap"
        case "job_change": return "briefcase"
        case "retirement": return "sun.horizon"
        case "moving": return "house"
        case "health_issue": return "cross.case"
        case "promotion": return "star.fill"
        case "anniversary": return "gift"
        case "loss": return "leaf"
        default: return "heart.circle"
        }
    }
}
