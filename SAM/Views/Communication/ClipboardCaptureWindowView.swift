//
//  ClipboardCaptureWindowView.swift
//  SAM
//
//  Global Clipboard Capture Hotkey
//
//  Auxiliary window for capturing copied conversations from any app.
//  Four phases: parsing → review → saving → error.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ClipboardCaptureWindowView")

struct ClipboardCaptureWindowView: View {

    let payload: ClipboardCapturePayload

    // MARK: - State

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var phase: Phase = .parsing
    @State private var conversation: ClipboardConversationDTO?
    @State private var title = ""
    @State private var conversationDate = Date()
    @State private var senderMatches: [String: SenderMatch] = [:]
    @State private var errorMessage: String?
    @State private var isSaving = false

    private enum Phase {
        case parsing
        case review
        case saving
        case error
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch phase {
            case .parsing:
                parsingPhase
            case .review:
                reviewPhase
            case .saving:
                savingPhase
            case .error:
                errorPhase
            }
        }
        .frame(width: 600, height: 500)
        .onAppear { FeatureAdoptionTracker.shared.recordUsage(.clipboardCapture) }
        .task {
            await parseClipboard()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.blue)
            Text("Clipboard Capture")
                .font(.headline)

            Spacer()

            if let platform = conversation?.detectedPlatform {
                Text(platform)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.15), in: Capsule())
            }
        }
        .padding()
    }

    // MARK: - Parsing Phase

    private var parsingPhase: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Analyzing clipboard…")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Review Phase

    private var reviewPhase: some View {
        VStack(spacing: 0) {
            // Title & Date
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Title")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)
                    TextField("Conversation title", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Date")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)
                    DatePicker("", selection: $conversationDate, displayedComponents: [.date])
                        .labelsHidden()
                }
            }
            .padding()

            Divider()

            // Senders section
            VStack(alignment: .leading, spacing: 8) {
                Text("Senders")
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(uniqueSenders, id: \.self) { senderName in
                    SenderMatchRow(
                        senderName: senderName,
                        match: senderMatches[senderName] ?? .unmatched,
                        onSelect: { person in
                            senderMatches[senderName] = .matched(person)
                        },
                        onClear: {
                            senderMatches[senderName] = .unmatched
                        }
                    )
                }
            }
            .padding()

            Divider()

            // Messages preview
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let messages = conversation?.messages {
                        ForEach(messages) { msg in
                            MessagePreviewRow(message: msg)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save as Evidence") {
                    Task { await saveEvidence() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
    }

    // MARK: - Saving Phase

    private var savingPhase: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Saving evidence…")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Error Phase

    private var errorPhase: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text(errorMessage ?? "An unknown error occurred.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Try Again") {
                    phase = .parsing
                    Task { await parseClipboard() }
                }

                Button("Save as Note") {
                    saveAsNote()
                }

                Button("Cancel") { dismiss() }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Computed

    private var uniqueSenders: [String] {
        guard let messages = conversation?.messages else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for msg in messages {
            if seen.insert(msg.senderName).inserted {
                result.append(msg.senderName)
            }
        }
        return result
    }

    private var canSave: Bool {
        // At least one non-Me sender must be matched
        senderMatches.values.contains { match in
            if case .matched(let person) = match, !person.isMe {
                return true
            }
            return false
        }
    }

    // MARK: - Actions

    private func parseClipboard() async {
        do {
            let result = try await ClipboardParsingService.shared.parseClipboard()
            conversation = result
            conversationDate = result.conversationDate

            // Generate default title
            let platform = result.detectedPlatform ?? "Conversation"
            let senderNames = uniqueSendersFrom(result.messages)
            title = "\(platform) with \(senderNames)"

            // Auto-match senders
            await autoMatchSenders(result.messages)

            phase = .review
        } catch {
            errorMessage = error.localizedDescription
            phase = .error
            logger.error("Clipboard parse failed: \(error)")
        }
    }

    private func uniqueSendersFrom(_ messages: [ClipboardMessageDTO]) -> String {
        var seen = Set<String>()
        var names: [String] = []
        for msg in messages where !msg.isFromMe {
            if seen.insert(msg.senderName).inserted {
                names.append(msg.senderName)
            }
        }
        return names.isEmpty ? "Unknown" : names.joined(separator: ", ")
    }

    private func autoMatchSenders(_ messages: [ClipboardMessageDTO]) async {
        // Try to match "Me"/"You" senders to the Me contact
        let mePerson = try? PeopleRepository.shared.fetchMe()
        let meNames = Set(["You", "Me", "me", "you"])

        var seen = Set<String>()
        for msg in messages {
            guard seen.insert(msg.senderName).inserted else { continue }

            if msg.isFromMe || meNames.contains(msg.senderName) {
                if let me = mePerson {
                    senderMatches[msg.senderName] = .me(me)
                } else {
                    senderMatches[msg.senderName] = .isMe
                }
            } else {
                // Try name search
                if let people = try? PeopleRepository.shared.search(query: msg.senderName),
                   let firstMatch = people.first {
                    senderMatches[msg.senderName] = .matched(firstMatch)
                } else {
                    senderMatches[msg.senderName] = .unmatched
                }
            }
        }
    }

    @MainActor
    private func saveEvidence() async {
        phase = .saving
        isSaving = true

        do {
            guard let conversation else { return }

            // Group messages by matched person (non-Me)
            var messagesByPerson: [UUID: [(text: String, date: Date, isFromMe: Bool)]] = [:]
            var personMap: [UUID: SamPerson] = [:]

            for msg in conversation.messages {
                let senderMatch = senderMatches[msg.senderName] ?? .unmatched

                // Determine which person this message belongs to
                // For "Me" messages, they go to all matched non-Me persons
                if msg.isFromMe || senderMatch.isMe {
                    for (name, match) in senderMatches {
                        if case .matched(let person) = match, !person.isMe {
                            messagesByPerson[person.id, default: []].append(
                                (text: msg.text, date: msg.timestamp ?? conversationDate, isFromMe: true)
                            )
                            personMap[person.id] = person
                        }
                        // Also check for explicit non-Me matched senders
                        if name != msg.senderName { continue }
                    }
                } else if case .matched(let person) = senderMatch, !person.isMe {
                    messagesByPerson[person.id, default: []].append(
                        (text: msg.text, date: msg.timestamp ?? conversationDate, isFromMe: false)
                    )
                    personMap[person.id] = person
                }
            }

            // For each matched person, analyze and create evidence
            for (personID, messages) in messagesByPerson {
                let person = personMap[personID]
                let contactName = person?.displayName
                let contactRole = person?.roleBadges.first

                // Analyze conversation
                let analysis = try await MessageAnalysisService.shared.analyzeConversation(
                    messages: messages,
                    contactName: contactName,
                    contactRole: contactRole
                )

                // Create evidence
                let sourceUID = "clipboard:\(payload.captureID.uuidString):\(personID.uuidString)"
                _ = try EvidenceRepository.shared.createByIDs(
                    sourceUID: sourceUID,
                    source: .clipboardCapture,
                    occurredAt: conversationDate,
                    title: title,
                    snippet: analysis.summary,
                    bodyText: nil,
                    linkedPeopleIDs: [personID]
                )

                logger.info("Created clipboard evidence for person \(personID): \(analysis.summary.prefix(60))")
            }

            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            phase = .error
            logger.error("Clipboard save failed: \(error)")
        }

        isSaving = false
    }

    private func saveAsNote() {
        let notePayload = QuickNotePayload(
            outcomeID: UUID(),
            personID: nil,
            personName: nil,
            contextTitle: title.isEmpty ? "Clipboard Capture" : title,
            prefillText: nil
        )
        openWindow(id: "quick-note", value: notePayload)
        dismiss()
    }
}

// MARK: - Sender Match

enum SenderMatch {
    case unmatched
    case isMe           // Detected as "Me" but no SamPerson match
    case me(SamPerson)  // Matched to the Me contact
    case matched(SamPerson)

    var isMe: Bool {
        switch self {
        case .isMe, .me: return true
        case .matched(let person): return person.isMe
        case .unmatched: return false
        }
    }

    var person: SamPerson? {
        switch self {
        case .matched(let p), .me(let p): return p
        default: return nil
        }
    }
}

// MARK: - Sender Match Row

private struct SenderMatchRow: View {

    let senderName: String
    let match: SenderMatch
    let onSelect: (SamPerson) -> Void
    let onClear: () -> Void

    @State private var searchText = ""
    @State private var searchResults: [SamPerson] = []
    @State private var showPopover = false

    var body: some View {
        HStack(spacing: 8) {
            Text(senderName)
                .font(.subheadline)
                .frame(width: 120, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch match {
            case .isMe:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Me (auto)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .me(let person):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(person.displayName)
                        .font(.caption)
                    Text("(Me)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            case .matched(let person):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(person.displayName)
                        .font(.caption)
                    if let role = person.roleBadges.first {
                        Text(role)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }

            case .unmatched:
                HStack(spacing: 4) {
                    TextField("Search contacts…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onChange(of: searchText) { _, query in
                            if query.count >= 2 {
                                searchResults = (try? PeopleRepository.shared.search(query: query)) ?? []
                                showPopover = !searchResults.isEmpty
                            } else {
                                searchResults = []
                                showPopover = false
                            }
                        }
                        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(searchResults.prefix(5)) { person in
                                    Button {
                                        onSelect(person)
                                        searchText = ""
                                        showPopover = false
                                    } label: {
                                        HStack {
                                            Text(person.displayName)
                                                .font(.subheadline)
                                            if let role = person.roleBadges.first {
                                                Text(role)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(width: 250)
                            .padding(.vertical, 4)
                        }

                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Spacer()
        }
    }
}

// MARK: - Message Preview Row

private struct MessagePreviewRow: View {

    let message: ClipboardMessageDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.senderName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(message.isFromMe ? .blue : .primary)

                if let ts = message.timestamp {
                    Text(ts, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(message.text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }
}
