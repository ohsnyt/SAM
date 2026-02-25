//
//  ComposeWindowView.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Phase O: Intelligent Actions
//
//  Auxiliary window for composing and sending messages via iMessage, email,
//  phone, or FaceTime. Supports dictation and direct send (power user mode).
//

import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ComposeWindowView")

struct ComposeWindowView: View {

    let payload: ComposePayload

    // MARK: - Dependencies

    @State private var composeService = ComposeService.shared
    @State private var outcomeRepo = OutcomeRepository.shared
    @State private var dictationService = DictationService.shared

    // MARK: - State

    @State private var channel: CommunicationChannel
    @State private var draftBody: String
    @State private var subject: String
    @State private var isDictating = false
    @State private var accumulatedSegments: [String] = []
    @State private var lastSegmentPeakLength = 0
    @State private var errorMessage: String?
    @State private var isSending = false
    @State private var showCopiedToast = false

    @Environment(\.dismiss) private var dismiss

    // MARK: - Init

    init(payload: ComposePayload) {
        self.payload = payload
        _channel = State(initialValue: payload.channel)
        _draftBody = State(initialValue: payload.draftBody)
        _subject = State(initialValue: payload.subject ?? "")
    }

    // MARK: - Computed

    private var recipientDisplay: String {
        payload.personName ?? payload.recipientAddress
    }

    private var canSend: Bool {
        !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !payload.recipientAddress.isEmpty
        && !isSending
    }

    private var directSendEnabled: Bool {
        UserDefaults.standard.bool(forKey: "directSendEnabled")
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // To line
            HStack(spacing: 8) {
                Text("To:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text(recipientDisplay)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
            }

            // Channel picker
            HStack(spacing: 8) {
                Text("Via:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Picker("Channel", selection: $channel) {
                    ForEach(availableChannels, id: \.self) { ch in
                        Label(ch.displayName, systemImage: ch.icon).tag(ch)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Spacer()
            }

            // Subject line (email only)
            if channel == .email {
                HStack(spacing: 8) {
                    Text("Subject:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    TextField("Subject", text: $subject)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Divider()

            // Draft body
            TextEditor(text: $draftBody)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 250)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if draftBody.isEmpty && !isDictating {
                        Text("Type your message...")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            // Context
            if !payload.contextTitle.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(payload.contextTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Error
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Copied toast
            if showCopiedToast {
                Text("Draft copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Divider()

            // Bottom bar
            HStack {
                // Dictation
                Button {
                    if isDictating {
                        stopDictation()
                    } else {
                        startDictation()
                    }
                } label: {
                    Image(systemName: isDictating ? "mic.fill" : "mic")
                        .font(.body)
                        .foregroundStyle(isDictating ? .red : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(isDictating ? "Stop dictation" : "Start dictation")

                Spacer()

                // Copy Draft
                Button("Copy Draft") {
                    composeService.copyToClipboard(draftBody)
                    showCopiedToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showCopiedToast = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)

                if directSendEnabled && (channel == .iMessage || channel == .email) {
                    // Power user: direct send + fallback
                    Button("Send Directly") {
                        sendDirectly()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(!canSend)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        sendViaSystemApp()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Open in \(channel == .email ? "Mail" : "Messages")")
                } else {
                    // Standard: system handoff
                    Button("Send") {
                        sendViaSystemApp()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(!canSend)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(minWidth: 480, idealWidth: 540, minHeight: 340, idealHeight: 400)
    }

    // MARK: - Available Channels

    private var availableChannels: [CommunicationChannel] {
        var channels: [CommunicationChannel] = []
        let address = payload.recipientAddress

        // iMessage available if we have a phone number or email
        if !address.isEmpty {
            channels.append(.iMessage)
        }
        // Email available if address looks like an email
        if address.contains("@") {
            channels.append(.email)
        }
        // Phone/FaceTime available if address looks like a phone number
        let digits = address.filter(\.isNumber)
        if digits.count >= 7 {
            channels.append(.phone)
            channels.append(.faceTime)
        }

        // Always include at least iMessage as fallback
        if channels.isEmpty {
            channels.append(.iMessage)
        }

        return channels
    }

    // MARK: - Send Actions

    private func sendViaSystemApp() {
        isSending = true
        errorMessage = nil

        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = payload.recipientAddress

        switch channel {
        case .iMessage:
            let success = composeService.composeIMessage(recipient: recipient, body: body)
            if success {
                completeAndDismiss()
            } else {
                errorMessage = "Draft copied to clipboard — paste into Messages"
                isSending = false
            }

        case .email:
            let success = composeService.composeEmail(
                recipient: recipient,
                subject: subject.isEmpty ? nil : subject,
                body: body
            )
            if success {
                completeAndDismiss()
            } else {
                errorMessage = "Could not open Mail — draft copied to clipboard"
                composeService.copyToClipboard(body)
                isSending = false
            }

        case .phone:
            composeService.initiateCall(recipient: recipient)
            completeAndDismiss()

        case .faceTime:
            composeService.initiateFaceTime(recipient: recipient)
            completeAndDismiss()
        }
    }

    private func sendDirectly() {
        isSending = true
        errorMessage = nil

        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = payload.recipientAddress

        Task {
            var success = false
            switch channel {
            case .iMessage:
                success = await composeService.sendDirectIMessage(recipient: recipient, body: body)
            case .email:
                success = await composeService.sendDirectEmail(
                    recipient: recipient,
                    subject: subject.isEmpty ? nil : subject,
                    body: body
                )
            default:
                // Direct send not supported for phone/FaceTime
                sendViaSystemApp()
                return
            }

            if success {
                completeAndDismiss()
            } else {
                errorMessage = "Direct send failed — try 'Send' to open in the system app"
                isSending = false
            }
        }
    }

    private func completeAndDismiss() {
        try? outcomeRepo.markCompleted(id: payload.outcomeID)
        logger.info("Compose completed — outcome \(payload.outcomeID) marked done")
        dismiss()
    }

    // MARK: - Dictation

    private func startDictation() {
        let availability = dictationService.checkAvailability()
        switch availability {
        case .available:
            break
        case .notAuthorized:
            Task {
                let granted = await dictationService.requestAuthorization()
                guard granted else {
                    errorMessage = "Speech recognition permission not granted"
                    return
                }
                beginDictationStream()
            }
            return
        case .notAvailable:
            errorMessage = "Speech recognition is not available"
            return
        case .restricted:
            errorMessage = "Speech recognition is restricted"
            return
        }
        beginDictationStream()
    }

    private func beginDictationStream() {
        isDictating = true
        errorMessage = nil
        accumulatedSegments = []
        lastSegmentPeakLength = 0

        let existing = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            accumulatedSegments.append(existing)
        }

        Task {
            do {
                let stream = try await dictationService.startRecognition()
                for await result in stream {
                    let currentText = result.text
                    if currentText.count < lastSegmentPeakLength / 2 && lastSegmentPeakLength > 5 {
                        let seg = extractCurrentSegment()
                        if !seg.isEmpty { accumulatedSegments.append(seg) }
                        lastSegmentPeakLength = 0
                    }
                    lastSegmentPeakLength = max(lastSegmentPeakLength, currentText.count)
                    let prefix = accumulatedSegments.joined(separator: " ")
                    draftBody = prefix.isEmpty ? currentText : "\(prefix) \(currentText)"
                    if result.isFinal { isDictating = false }
                }
                if isDictating {
                    isDictating = false
                    dictationService.stopRecognition()
                }
            } catch {
                errorMessage = error.localizedDescription
                isDictating = false
            }
        }
    }

    private func extractCurrentSegment() -> String {
        let prefix = accumulatedSegments.joined(separator: " ")
        let full = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { return full }
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }

    private func stopDictation() {
        dictationService.stopRecognition()
        isDictating = false
    }
}
