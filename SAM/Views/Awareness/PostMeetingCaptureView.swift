//
//  PostMeetingCaptureView.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase T: Meeting Lifecycle Automation Enhancement
//
//  Structured post-meeting/call capture sheet with guided Q&A and freeform modes.
//  Accepts CapturePayload with attendee info, talking points, and open actions.
//

import SwiftUI
import TipKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PostMeetingCaptureView")

// MARK: - DTOs

struct CaptureAttendeeInfo: Identifiable, Sendable {
    var id: UUID { personID }
    let personID: UUID
    let displayName: String
    let roleBadges: [String]
    let pendingActionItems: [String]
    let recentLifeEvents: [String]
}

struct CapturePayload: Identifiable, Sendable {
    let id = UUID()
    let captureKind: CaptureKind
    let eventTitle: String
    let eventDate: Date
    let attendees: [CaptureAttendeeInfo]
    let talkingPoints: [String]
    let openActionItems: [String]
    let evidenceID: UUID?
    /// Names of attendees not yet in SAM's contacts. Pre-populates the
    /// "extra attendees" field so the user can confirm or edit them.
    var unknownAttendeeNames: [String] = []

    enum CaptureKind: Sendable {
        case meeting
        case call(source: String) // "phone" or "FaceTime"
        var isMeeting: Bool { if case .meeting = self { return true } else { return false } }
        var sourceLabel: String {
            switch self {
            case .meeting: return "Meeting"
            case .call(let source): return source == "FaceTime" ? "FaceTime" : "Phone Call"
            }
        }
    }
}

// MARK: - View

struct PostMeetingCaptureView: View {

    // MARK: - Parameters

    let payload: CapturePayload
    let onSave: () -> Void

    // MARK: - Mode

    private enum CaptureMode: String, CaseIterable {
        case guided = "Guided"
        case freeform = "Freeform"
    }

    @State private var mode: CaptureMode = .guided
    private var hasFreeformEdits: Bool {
        !discussionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || actionItemEntries.contains(where: { !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        || !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !lifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Guided State

    @State private var guidedStep: Int = 0
    @State private var attendancePresent: Set<UUID> = []
    @State private var extraAttendeeNames: [String] = []
    @State private var callAnswered: Bool = true
    @State private var mainOutcomeText = ""
    @State private var talkingPointResponses: [String: String] = [:]  // point → response
    @State private var actionItemResponses: [String: String] = [:]    // action → response
    @State private var guidedActionItemsText = ""
    @State private var guidedFollowUpText = ""
    @State private var guidedLifeEventsText = ""
    @State private var voicemailNoteText = ""

    // MARK: - Freeform State

    @State private var discussionText = ""
    @State private var actionItemEntries: [ActionItemEntry] = [ActionItemEntry()]
    @State private var followUpText = ""
    @State private var lifeEventsText = ""

    // MARK: - Shared State

    @State private var isSaving = false
    @State private var isPolishing = false
    @State private var errorMessage: String?
    @State private var activeDictationSection: DictationTarget?
    @State private var dictationService = DictationService.shared
    @State private var accumulatedSegments: [String] = []
    @State private var lastSegmentPeakLength = 0

    @Environment(\.dismiss) private var dismiss

    // MARK: - Types

    struct ActionItemEntry: Identifiable {
        let id = UUID()
        var description: String = ""
    }

    private enum DictationTarget: Equatable {
        // Freeform sections
        case discussion, followUp, lifeEvents
        // Guided steps
        case mainOutcome, guidedActionItems, guidedFollowUp, guidedLifeEvents, voicemailNote
        case talkingPoint(String)
        case actionPoint(String)
    }

    // MARK: - Guided Steps

    private var guidedSteps: [GuidedStep] {
        var steps: [GuidedStep] = []

        // Step 0: Attendance
        steps.append(GuidedStep(
            index: 0,
            title: payload.captureKind.isMeeting ? "Attendance" : "Connection",
            icon: "person.2.circle"
        ))

        // Step 1: Main outcome
        steps.append(GuidedStep(
            index: 1,
            title: payload.captureKind.isMeeting ? "Main Outcome" : "Discussion",
            icon: "text.bubble"
        ))

        // Step 1a: Talking points (meetings only, if available)
        if payload.captureKind.isMeeting && !payload.talkingPoints.isEmpty {
            steps.append(GuidedStep(
                index: 2,
                title: "Talking Points",
                icon: "list.bullet.rectangle"
            ))
        }

        // Step 1b: Pending actions (meetings only, if available)
        if payload.captureKind.isMeeting && !payload.openActionItems.isEmpty {
            steps.append(GuidedStep(
                index: 3,
                title: "Pending Actions",
                icon: "arrow.triangle.2.circlepath"
            ))
        }

        // Step 2: Action items
        steps.append(GuidedStep(
            index: 4,
            title: payload.captureKind.isMeeting ? "Action Items" : "Next Steps",
            icon: "checklist"
        ))

        // Step 3: Follow-up
        steps.append(GuidedStep(
            index: 5,
            title: "Follow-Up",
            icon: "arrow.turn.up.right"
        ))

        // Step 4: Life events
        steps.append(GuidedStep(
            index: 6,
            title: "Life Events",
            icon: "star"
        ))

        return steps
    }

    private struct GuidedStep: Identifiable {
        let index: Int
        let title: String
        let icon: String
        var id: Int { index }
    }

    private var currentStepIndex: Int {
        let steps = guidedSteps
        guard guidedStep >= 0 && guidedStep < steps.count else { return 0 }
        return guidedStep
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            TipView(PostMeetingCaptureTip())
                .tipViewStyle(SAMTipViewStyle())
            header
            Divider()

            if mode == .guided {
                guidedContent
            } else {
                freeformContent
            }

            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 680)
        .interactiveDismissDisabled(hasContent)
        .onAppear {
            FeatureAdoptionTracker.shared.recordUsage(.postMeetingCapture)
            // Pre-check all attendees as present
            attendancePresent = Set(payload.attendees.map(\.personID))
            // Pre-populate unknown attendee names so the user can confirm/edit
            if !payload.unknownAttendeeNames.isEmpty {
                extraAttendeeNames = payload.unknownAttendeeNames
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(payload.captureKind.isMeeting ? "Meeting Notes" : "\(payload.captureKind.sourceLabel) Notes")
                        .samFont(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        Text(payload.eventTitle)
                            .samFont(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(payload.eventDate.formatted(date: .abbreviated, time: .shortened))
                            .samFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Picker("", selection: $mode) {
                    ForEach(CaptureMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: mode) { _, newMode in
                    if newMode == .freeform {
                        mapGuidedToFreeform()
                    }
                }
            }

            // Attendee badges
            if !payload.attendees.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(payload.attendees) { attendee in
                            attendeeBadge(attendee)
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func attendeeBadge(_ attendee: CaptureAttendeeInfo) -> some View {
        HStack(spacing: 4) {
            Text(attendee.displayName)
                .samFont(.caption)
                .fontWeight(.medium)
            ForEach(attendee.roleBadges, id: \.self) { badge in
                Text(badge)
                    .samFont(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoleBadgeStyle.forBadge(badge).color, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Guided Content

    private var guidedContent: some View {
        VStack(spacing: 0) {
            // Progress bar
            let steps = guidedSteps
            GeometryReader { geo in
                let progress = steps.isEmpty ? 0 : CGFloat(currentStepIndex) / CGFloat(max(steps.count - 1, 1))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * progress, height: 4)
                    }
            }
            .frame(height: 4)
            .padding(.horizontal)
            .padding(.top, 8)

            // Step content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let step = steps[safe: currentStepIndex] {
                        switch step.index {
                        case 0: attendanceStep
                        case 1: mainOutcomeStep
                        case 2: talkingPointsStep
                        case 3: pendingActionsStep
                        case 4: actionItemsStep
                        case 5: followUpStep
                        case 6: lifeEventsStep
                        default: EmptyView()
                        }
                    }
                }
                .padding()
            }

            // Navigation
            guidedNavigation
        }
    }

    // MARK: - Step 0: Attendance

    private var attendanceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("person.2.circle", title: payload.captureKind.isMeeting ? "Who attended?" : "Did they answer?")

            if payload.captureKind.isMeeting {
                // Checklist of attendees
                ForEach(payload.attendees) { attendee in
                    Button {
                        if attendancePresent.contains(attendee.personID) {
                            attendancePresent.remove(attendee.personID)
                        } else {
                            attendancePresent.insert(attendee.personID)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: attendancePresent.contains(attendee.personID)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(attendancePresent.contains(attendee.personID) ? .green : .secondary)
                            Text(attendee.displayName)
                                .samFont(.body)
                            ForEach(attendee.roleBadges, id: \.self) { badge in
                                Text(badge)
                                    .samFont(.caption2)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(RoleBadgeStyle.forBadge(badge).color, in: Capsule())
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Add extra attendee
                HStack(spacing: 8) {
                    ForEach(extraAttendeeNames.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            TextField("Name", text: $extraAttendeeNames[i])
                                .textFieldStyle(.plain)
                                .samFont(.body)
                            Button {
                                extraAttendeeNames.remove(at: i)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .samFont(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    }
                }

                Button {
                    extraAttendeeNames.append("")
                } label: {
                    Label("Add attendee", systemImage: "plus.circle")
                        .samFont(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                // Call: did they answer?
                HStack(spacing: 16) {
                    if let primary = payload.attendees.first {
                        Text(primary.displayName)
                            .samFont(.body)
                    }
                    Picker("", selection: $callAnswered) {
                        Text("Answered").tag(true)
                        Text("No answer").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
        }
    }

    // MARK: - Step 1: Main Outcome

    private var mainOutcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if payload.captureKind.isMeeting {
                stepHeader("text.bubble", title: "What was the main outcome or decision?")
            } else {
                if callAnswered {
                    stepHeader("text.bubble", title: "What did you discuss?")
                } else {
                    stepHeader("text.bubble", title: "Left a voicemail? Any notes?")
                }
            }

            if !payload.captureKind.isMeeting && !callAnswered {
                // Voicemail note for unanswered calls
                captureTextEditor(text: $voicemailNoteText, placeholder: "Optional note...", dictationTarget: .voicemailNote, minHeight: 60)
            } else {
                // Main discussion/outcome
                captureTextEditor(text: $mainOutcomeText, placeholder: "Key points, decisions, context...", dictationTarget: .mainOutcome, minHeight: 100)
            }

            // Contextual reminders from briefing
            if !payload.talkingPoints.isEmpty && payload.captureKind.isMeeting {
                contextualReminders("Prepared talking points:", items: payload.talkingPoints)
            }
        }
    }

    // MARK: - Step 1a: Talking Points

    private var talkingPointsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("list.bullet.rectangle", title: "Talking Points Review")
            Text("Were these discussed?")
                .samFont(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(payload.talkingPoints, id: \.self) { point in
                VStack(alignment: .leading, spacing: 4) {
                    Text(point)
                        .samFont(.body)
                        .fontWeight(.medium)
                    captureTextEditor(
                        text: bindingForTalkingPoint(point),
                        placeholder: "Notes on this topic... (skip if not discussed)",
                        dictationTarget: .talkingPoint(point),
                        minHeight: 40
                    )
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Step 1b: Pending Actions

    private var pendingActionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("arrow.triangle.2.circlepath", title: "Pending Actions")
            Text("Were any of these addressed?")
                .samFont(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(payload.openActionItems, id: \.self) { action in
                VStack(alignment: .leading, spacing: 4) {
                    Text(action)
                        .samFont(.body)
                        .fontWeight(.medium)
                    captureTextEditor(
                        text: bindingForActionPoint(action),
                        placeholder: "Update... (skip if not addressed)",
                        dictationTarget: .actionPoint(action),
                        minHeight: 40
                    )
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Step 2: Action Items

    private var actionItemsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("checklist", title: payload.captureKind.isMeeting ? "Any action items or next steps?" : "Any next steps?")

            captureTextEditor(
                text: $guidedActionItemsText,
                placeholder: "List action items, one per line...",
                dictationTarget: .guidedActionItems,
                minHeight: 80
            )
        }
    }

    // MARK: - Step 3: Follow-Up

    private var followUpStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("arrow.turn.up.right", title: "Any commitments or deadlines to track?")

            captureTextEditor(
                text: $guidedFollowUpText,
                placeholder: "Follow-up commitments, deadlines...",
                dictationTarget: .guidedFollowUp,
                minHeight: 60
            )
        }
    }

    // MARK: - Step 4: Life Events

    private var lifeEventsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("star", title: "Any personal milestones mentioned?")

            captureTextEditor(
                text: $guidedLifeEventsText,
                placeholder: "Birthdays, anniversaries, milestones...",
                dictationTarget: .guidedLifeEvents,
                minHeight: 60
            )

            // Contextual reminders of known life events
            let knownEvents = payload.attendees.flatMap(\.recentLifeEvents)
            if !knownEvents.isEmpty {
                contextualReminders("Known recent life events:", items: knownEvents)
            }
        }
    }

    // MARK: - Guided Navigation

    private var guidedNavigation: some View {
        HStack {
            if currentStepIndex > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { guidedStep -= 1 }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .samFont(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            let steps = guidedSteps
            Text("\(currentStepIndex + 1) of \(steps.count)")
                .samFont(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            if currentStepIndex < steps.count - 1 {
                Button("Skip") {
                    withAnimation(.easeInOut(duration: 0.2)) { guidedStep += 1 }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { guidedStep += 1 }
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Freeform Content

    private var freeformContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                freeformDiscussionSection
                freeformActionItemsSection
                freeformFollowUpSection
                freeformLifeEventsSection
            }
            .padding()
        }
    }

    private var freeformDiscussionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Discussion", icon: "text.bubble", dictationTarget: .discussion)

            captureTextEditor(
                text: $discussionText,
                placeholder: payload.talkingPoints.isEmpty
                    ? "Key discussion points, decisions made, important context..."
                    : "Topics: \(payload.talkingPoints.prefix(3).joined(separator: ", "))...",
                dictationTarget: .discussion,
                minHeight: 120
            )
        }
    }

    private var freeformActionItemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundStyle(.orange)
                Text("Action Items")
                    .samFont(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            ForEach($actionItemEntries) { $item in
                HStack(spacing: 8) {
                    Image(systemName: "circle")
                        .samFont(.caption)
                        .foregroundStyle(.orange)
                    TextField("Action item...", text: $item.description)
                        .textFieldStyle(.plain)
                        .samFont(.body)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }

            Button {
                actionItemEntries.append(ActionItemEntry())
            } label: {
                Label("Add Action Item", systemImage: "plus.circle")
                    .samFont(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var freeformFollowUpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Follow-Up", icon: "arrow.turn.up.right", dictationTarget: .followUp)

            captureTextEditor(
                text: $followUpText,
                placeholder: "Commitments made, next steps, deadlines...",
                dictationTarget: .followUp,
                minHeight: 60
            )
        }
    }

    private var freeformLifeEventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Life Events", icon: "star", dictationTarget: .lifeEvents)

            captureTextEditor(
                text: $lifeEventsText,
                placeholder: "Birthdays, anniversaries, milestones mentioned...",
                dictationTarget: .lifeEvents,
                minHeight: 40
            )
        }
    }

    // MARK: - Shared Components

    private func stepHeader(_ icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .samFont(.title3)
            Text(title)
                .samFont(.title3)
                .fontWeight(.semibold)
        }
    }

    private func sectionHeader(_ title: String, icon: String, dictationTarget: DictationTarget) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.blue)
            Text(title)
                .samFont(.subheadline)
                .fontWeight(.semibold)
            Spacer()
            dictationButton(for: dictationTarget)
        }
    }

    private func captureTextEditor(text: Binding<String>, placeholder: String, dictationTarget: DictationTarget, minHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            TextEditor(text: text)
                .samFont(.body)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .samFont(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    dictationButton(for: dictationTarget)
                        .padding(8)
                }
        }
    }

    private func dictationButton(for target: DictationTarget) -> some View {
        Button {
            if activeDictationSection == target {
                stopDictation()
            } else {
                startDictation(for: target)
            }
        } label: {
            Image(systemName: activeDictationSection == target ? "mic.fill" : "mic")
                .samFont(.caption)
                .foregroundStyle(activeDictationSection == target ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .help(activeDictationSection == target ? "Stop dictation" : "Dictate")
    }

    private func contextualReminders(_ label: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .samFont(.caption)
                .foregroundStyle(.tertiary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 4) {
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(item)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if isPolishing {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Polishing...")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage {
                Text(error)
                    .samFont(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button("Cancel") {
                stopDictation()
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])

            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(isSaving || isPolishing || !hasContent)
        }
        .padding()
    }

    // MARK: - Computed

    private var hasContent: Bool {
        if mode == .guided {
            // For unanswered calls, always allow save (status: no answer)
            if !payload.captureKind.isMeeting && !callAnswered {
                return true
            }
            return !mainOutcomeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !guidedActionItemsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !guidedFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !guidedLifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !voicemailNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || talkingPointResponses.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                || actionItemResponses.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        } else {
            return !discussionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || actionItemEntries.contains(where: { !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                || !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Mode Switching

    private func mapGuidedToFreeform() {
        // Map guided Q&A answers into freeform section fields
        var discussion: [String] = []

        let outcome = mainOutcomeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outcome.isEmpty {
            discussion.append(outcome)
        }

        // Talking point responses
        for point in payload.talkingPoints {
            if let resp = talkingPointResponses[point]?.trimmingCharacters(in: .whitespacesAndNewlines), !resp.isEmpty {
                discussion.append("\(point): \(resp)")
            }
        }

        // Action point responses
        for action in payload.openActionItems {
            if let resp = actionItemResponses[action]?.trimmingCharacters(in: .whitespacesAndNewlines), !resp.isEmpty {
                discussion.append("\(action): \(resp)")
            }
        }

        if !discussion.isEmpty {
            discussionText = discussion.joined(separator: "\n\n")
        }

        // Action items
        let guidedActions = guidedActionItemsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidedActions.isEmpty {
            let lines = guidedActions.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            actionItemEntries = lines.map { line in
                var entry = ActionItemEntry()
                entry.description = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^[\\-•] ?", with: "", options: .regularExpression)
                return entry
            }
            if actionItemEntries.isEmpty { actionItemEntries = [ActionItemEntry()] }
        }

        // Follow-up
        let guidedFU = guidedFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidedFU.isEmpty { followUpText = guidedFU }

        // Life events
        let guidedLE = guidedLifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidedLE.isEmpty { lifeEventsText = guidedLE }
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        errorMessage = nil

        let content: String
        if mode == .guided {
            content = composeGuidedContent()
        } else {
            content = composeFreeformContent()
        }

        // Determine linked people IDs
        let linkedIDs: [UUID]
        if payload.captureKind.isMeeting {
            linkedIDs = Array(attendancePresent)
        } else {
            if let primary = payload.attendees.first {
                linkedIDs = [primary.personID]
            } else {
                linkedIDs = []
            }
        }

        do {
            let note = try NotesRepository.shared.create(
                content: content,
                sourceType: .typed,
                linkedPeopleIDs: linkedIDs
            )

            logger.debug("Created capture note for '\(payload.eventTitle)' with \(linkedIDs.count) linked people")

            Task {
                await NoteAnalysisCoordinator.shared.analyzeNote(note)
            }

            isSaving = false
            onSave()
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            isSaving = false
            logger.error("Capture note save failed: \(error)")
        }
    }

    private func composeGuidedContent() -> String {
        let dateStr = payload.eventDate.formatted(date: .abbreviated, time: .shortened)
        var parts: [String] = []

        // Header
        if payload.captureKind.isMeeting {
            parts.append("Meeting: \(payload.eventTitle)")
        } else {
            let source: String
            if case .call(let s) = payload.captureKind { source = s } else { source = "phone" }
            let personName = payload.attendees.first?.displayName ?? "Unknown"
            parts.append("Call: \(personName) (\(source))")
        }
        parts.append("Date: \(dateStr)")

        // Attendance
        if payload.captureKind.isMeeting {
            let present = payload.attendees.filter { attendancePresent.contains($0.personID) }.map(\.displayName)
            let absent = payload.attendees.filter { !attendancePresent.contains($0.personID) }.map(\.displayName)
            let extras = extraAttendeeNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if !present.isEmpty || !extras.isEmpty {
                parts.append("Attendees: \((present + extras).joined(separator: ", "))")
            }
            if !absent.isEmpty {
                parts.append("Absent: \(absent.joined(separator: ", "))")
            }
        } else if !callAnswered {
            parts.append("Status: No answer")
            let vm = voicemailNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !vm.isEmpty {
                parts.append(vm)
            }
            return parts.joined(separator: "\n")
        }

        parts.append("")

        // Discussion
        var discussion: [String] = []
        let outcome = mainOutcomeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outcome.isEmpty { discussion.append(outcome) }

        for point in payload.talkingPoints {
            if let resp = talkingPointResponses[point]?.trimmingCharacters(in: .whitespacesAndNewlines), !resp.isEmpty {
                discussion.append("\(point): \(resp)")
            }
        }

        for action in payload.openActionItems {
            if let resp = actionItemResponses[action]?.trimmingCharacters(in: .whitespacesAndNewlines), !resp.isEmpty {
                discussion.append("[\(action)] \(resp)")
            }
        }

        if !discussion.isEmpty {
            parts.append("Discussion:")
            parts.append(discussion.joined(separator: "\n"))
            parts.append("")
        }

        // Action Items
        let actions = guidedActionItemsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !actions.isEmpty {
            parts.append("Action Items:")
            let lines = actions.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for line in lines {
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.hasPrefix("-") || cleaned.hasPrefix("•") {
                    parts.append(cleaned)
                } else {
                    parts.append("- \(cleaned)")
                }
            }
            parts.append("")
        }

        // Follow-Up
        let fu = guidedFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fu.isEmpty {
            parts.append("Follow-Up:")
            parts.append(fu)
            parts.append("")
        }

        // Life Events
        let le = guidedLifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !le.isEmpty {
            parts.append("Life Events:")
            parts.append(le)
        }

        return parts.joined(separator: "\n")
    }

    private func composeFreeformContent() -> String {
        let dateStr = payload.eventDate.formatted(date: .abbreviated, time: .shortened)
        var parts: [String] = []

        // Header
        if payload.captureKind.isMeeting {
            parts.append("Meeting: \(payload.eventTitle)")
        } else {
            let source: String
            if case .call(let s) = payload.captureKind { source = s } else { source = "phone" }
            let personName = payload.attendees.first?.displayName ?? "Unknown"
            parts.append("Call: \(personName) (\(source))")
        }
        parts.append("Date: \(dateStr)")

        // Attendance for meetings
        if payload.captureKind.isMeeting {
            let present = payload.attendees.filter { attendancePresent.contains($0.personID) }.map(\.displayName)
            let absent = payload.attendees.filter { !attendancePresent.contains($0.personID) }.map(\.displayName)
            let extras = extraAttendeeNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if !present.isEmpty || !extras.isEmpty {
                parts.append("Attendees: \((present + extras).joined(separator: ", "))")
            }
            if !absent.isEmpty {
                parts.append("Absent: \(absent.joined(separator: ", "))")
            }
        }
        parts.append("")

        let discussion = discussionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !discussion.isEmpty {
            parts.append("Discussion:")
            parts.append(discussion)
            parts.append("")
        }

        let validActions = actionItemEntries.map(\.description).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !validActions.isEmpty {
            parts.append("Action Items:")
            for action in validActions {
                parts.append("- \(action)")
            }
            parts.append("")
        }

        let fu = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fu.isEmpty {
            parts.append("Follow-Up:")
            parts.append(fu)
            parts.append("")
        }

        let le = lifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !le.isEmpty {
            parts.append("Life Events:")
            parts.append(le)
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Bindings for Talking Points / Action Points

    private func bindingForTalkingPoint(_ point: String) -> Binding<String> {
        Binding(
            get: { talkingPointResponses[point] ?? "" },
            set: { talkingPointResponses[point] = $0 }
        )
    }

    private func bindingForActionPoint(_ action: String) -> Binding<String> {
        Binding(
            get: { actionItemResponses[action] ?? "" },
            set: { actionItemResponses[action] = $0 }
        )
    }

    // MARK: - Dictation

    private func startDictation(for target: DictationTarget) {
        if activeDictationSection != nil {
            stopDictation()
        }

        let availability = dictationService.checkAvailability()
        guard availability == .available else {
            errorMessage = "Speech recognition is not available"
            return
        }

        activeDictationSection = target
        accumulatedSegments = []
        lastSegmentPeakLength = 0

        let existingText = currentText(for: target).trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingText.isEmpty {
            accumulatedSegments.append(existingText)
        }

        Task {
            do {
                let stream = try await dictationService.startRecognition()
                for await result in stream {
                    let currentText = result.text

                    if currentText.count < lastSegmentPeakLength / 2 && lastSegmentPeakLength > 5 {
                        let previousSegment = extractCurrentSegment(for: target)
                        if !previousSegment.isEmpty {
                            accumulatedSegments.append(previousSegment)
                        }
                        lastSegmentPeakLength = 0
                    }

                    lastSegmentPeakLength = max(lastSegmentPeakLength, currentText.count)

                    let prefix = accumulatedSegments.joined(separator: " ")
                    let fullText = prefix.isEmpty ? currentText : "\(prefix) \(currentText)"
                    setCurrentText(fullText, for: target)

                    if result.isFinal {
                        activeDictationSection = nil
                        polishDictatedText(for: target)
                    }
                }
                if activeDictationSection != nil {
                    activeDictationSection = nil
                    dictationService.stopRecognition()
                    polishDictatedText(for: target)
                }
            } catch {
                errorMessage = error.localizedDescription
                activeDictationSection = nil
            }
        }
    }

    private func stopDictation() {
        let target = activeDictationSection
        dictationService.stopRecognition()
        activeDictationSection = nil

        if let target {
            polishDictatedText(for: target)
        }
    }

    private func polishDictatedText(for target: DictationTarget) {
        let rawText = currentText(for: target)
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isPolishing = true
        Task {
            do {
                let polished = try await NoteAnalysisService.shared.polishDictation(rawText: rawText)
                setCurrentText(polished, for: target)
            } catch {
                logger.debug("Dictation polish unavailable: \(error.localizedDescription)")
            }
            isPolishing = false
        }
    }

    private func currentText(for target: DictationTarget) -> String {
        switch target {
        case .discussion: return discussionText
        case .followUp: return followUpText
        case .lifeEvents: return lifeEventsText
        case .mainOutcome: return mainOutcomeText
        case .guidedActionItems: return guidedActionItemsText
        case .guidedFollowUp: return guidedFollowUpText
        case .guidedLifeEvents: return guidedLifeEventsText
        case .voicemailNote: return voicemailNoteText
        case .talkingPoint(let point): return talkingPointResponses[point] ?? ""
        case .actionPoint(let action): return actionItemResponses[action] ?? ""
        }
    }

    private func setCurrentText(_ text: String, for target: DictationTarget) {
        switch target {
        case .discussion: discussionText = text
        case .followUp: followUpText = text
        case .lifeEvents: lifeEventsText = text
        case .mainOutcome: mainOutcomeText = text
        case .guidedActionItems: guidedActionItemsText = text
        case .guidedFollowUp: guidedFollowUpText = text
        case .guidedLifeEvents: guidedLifeEventsText = text
        case .voicemailNote: voicemailNoteText = text
        case .talkingPoint(let point): talkingPointResponses[point] = text
        case .actionPoint(let action): actionItemResponses[action] = text
        }
    }

    private func extractCurrentSegment(for target: DictationTarget) -> String {
        let prefix = accumulatedSegments.joined(separator: " ")
        let full = currentText(for: target).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { return full }
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
