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
    /// True when the sheet is part of a "review all pending meetings" walker.
    /// Enables the remaining-count badge and "Skip for now" button.
    var isQueueWalk: Bool = false

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
    @Bindable var coordinator: PostMeetingCaptureCoordinator

    // MARK: - Type aliases for in-view shorthand
    //
    // The form's state types now live on the coordinator. Aliases keep
    // the existing render code readable without `coordinator.` prefixes
    // on every type reference.

    typealias CaptureMode = PostMeetingCaptureCoordinator.CaptureMode
    typealias OccurrenceDecision = PostMeetingCaptureCoordinator.OccurrenceDecision
    typealias ActionItemEntry = PostMeetingCaptureCoordinator.ActionItemEntry

    private var hasFreeformEdits: Bool {
        !coordinator.discussionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || coordinator.actionItemEntries.contains(where: { !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        || !coordinator.followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !coordinator.lifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Transient view-only state
    //
    // Polishing and dictation lifecycle are bound to the visible sheet,
    // not the form's logical content — these stay as @State and reset
    // on each presentation.

    @State private var isPolishing = false
    @State private var activeDictationSection: DictationTarget?
    @State private var dictationService = DictationService.shared
    @State private var dictationAccumulator = DictationService.Accumulator()
    @State private var showDiscardConfirmation = false

    @Environment(\.dismiss) private var dismiss

    // MARK: - Types

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
        guard coordinator.guidedStep >= 0 && coordinator.guidedStep < steps.count else { return 0 }
        return coordinator.guidedStep
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            TipView(PostMeetingCaptureTip())
                .tipViewStyle(SAMTipViewStyle())
            header
            Divider()

            if coordinator.mode == .guided {
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
            // Seeding (pre-checking attendees, copying unknown names) now
            // happens in PostMeetingCaptureCoordinator.init, so it stays in
            // sync with restoreFromDraft. The coordinator already reflects
            // either a fresh seed or a restored draft by the time we mount.
        }
        .onDisappear {
            // Flush the latest debounced edits before the view tears down.
            // ModalCoordinator-driven displacement, lock, or ⌘W can all
            // unmount this view inside the debounce window; without this
            // call the last ~1.5 s of typing would only live in memory.
            coordinator.flushNow()
        }
        .alert(
            "Discard these notes?",
            isPresented: $showDiscardConfirmation
        ) {
            Button("Discard", role: .destructive) {
                stopDictation()
                coordinator.clearDraft()
                dismiss()
            }
            Button("Keep editing", role: .cancel) {
                showDiscardConfirmation = false
            }
        } message: {
            Text("Your in-progress notes will be deleted. This can't be undone. To keep your work and close, use Close instead.")
        }
        .dismissOnLock(isPresented: $showDiscardConfirmation)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(payload.captureKind.isMeeting ? "Meeting Notes" : "\(payload.captureKind.sourceLabel) Notes")
                            .samFont(.title2)
                            .fontWeight(.semibold)
                        if payload.isQueueWalk, remainingReviewCount > 0 {
                            Text("\(remainingReviewCount) remaining")
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }

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

                Picker("", selection: $coordinator.mode) {
                    ForEach(CaptureMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: coordinator.mode) { _, newMode in
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
                occurrenceDecisionPicker

                if coordinator.occurrenceDecision != .happened {
                    occurrenceExplanation
                } else {
                    attendanceChecklist
                }
            } else {
                callAnsweredPicker
            }
        }
    }

    /// "Did this meeting happen?" selector. Non-"happened" choices short-circuit
    /// the rest of the capture flow.
    private var occurrenceDecisionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Did this meeting happen?")
                .samFont(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Occurrence", selection: $coordinator.occurrenceDecision) {
                ForEach(OccurrenceDecision.allCases) { decision in
                    Text(decision.label).tag(decision)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Short explanation shown when the user picks cancelled / rescheduled / didn't happen.
    /// The footer's primary button switches to the appropriate "Mark…" action in these cases.
    private var occurrenceExplanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            let message: String = {
                switch coordinator.occurrenceDecision {
                case .rescheduled:
                    return "Got it. SAM won't count this as a completed meeting. If the new time is on your calendar, SAM will prompt you again after it ends."
                case .cancelled:
                    return "Thanks — SAM will mark this as cancelled and drop it from your pipeline history."
                case .didNotHappen:
                    return "Noted. SAM will record this as a no-show. Repeated no-shows with the same person will surface as a coaching signal."
                case .happened:
                    return ""
                }
            }()
            Text(message)
                .samFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    /// The original attendance checklist, shown only when the meeting actually happened.
    @ViewBuilder
    private var attendanceChecklist: some View {
        // Checklist of attendees
        ForEach(payload.attendees) { attendee in
                    Button {
                        if coordinator.attendancePresent.contains(attendee.personID) {
                            coordinator.attendancePresent.remove(attendee.personID)
                        } else {
                            coordinator.attendancePresent.insert(attendee.personID)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: coordinator.attendancePresent.contains(attendee.personID)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(coordinator.attendancePresent.contains(attendee.personID) ? .green : .secondary)
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
                    ForEach(coordinator.extraAttendeeNames.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            TextField("Name", text: $coordinator.extraAttendeeNames[i])
                                .textFieldStyle(.plain)
                                .samFont(.body)
                            Button {
                                coordinator.extraAttendeeNames.remove(at: i)
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
                    coordinator.extraAttendeeNames.append("")
                } label: {
                    Label("Add attendee", systemImage: "plus.circle")
                        .samFont(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
    }

    /// Call flow: did the other side answer?
    private var callAnsweredPicker: some View {
        HStack(spacing: 16) {
            if let primary = payload.attendees.first {
                Text(primary.displayName)
                    .samFont(.body)
            }
            Picker("", selection: $coordinator.callAnswered) {
                Text("Answered").tag(true)
                Text("No answer").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
    }

    // MARK: - Step 1: Main Outcome

    private var mainOutcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if payload.captureKind.isMeeting {
                stepHeader("text.bubble", title: "What was the main outcome or decision?")
            } else {
                if coordinator.callAnswered {
                    stepHeader("text.bubble", title: "What did you discuss?")
                } else {
                    stepHeader("text.bubble", title: "Left a voicemail? Any notes?")
                }
            }

            if !payload.captureKind.isMeeting && !coordinator.callAnswered {
                // Voicemail note for unanswered calls
                captureTextEditor(text: $coordinator.voicemailNoteText, placeholder: "Optional note...", dictationTarget: .voicemailNote, minHeight: 60)
            } else {
                // Main discussion/outcome
                captureTextEditor(text: $coordinator.mainOutcomeText, placeholder: "Key points, decisions, context...", dictationTarget: .mainOutcome, minHeight: 100)
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
                text: $coordinator.guidedActionItemsText,
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
                text: $coordinator.guidedFollowUpText,
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
                text: $coordinator.guidedLifeEventsText,
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
                    withAnimation(.easeInOut(duration: 0.2)) { coordinator.guidedStep -= 1 }
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
                    withAnimation(.easeInOut(duration: 0.2)) { coordinator.guidedStep += 1 }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { coordinator.guidedStep += 1 }
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
                text: $coordinator.discussionText,
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

            ForEach($coordinator.actionItemEntries) { $item in
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
                coordinator.actionItemEntries.append(ActionItemEntry())
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
                text: $coordinator.followUpText,
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
                text: $coordinator.lifeEventsText,
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
            } else if let error = coordinator.errorMessage {
                Text(error)
                    .samFont(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            // "Discard" deletes the draft and closes — destructive, gated
            // by a confirmation dialog because it can't be undone.
            Button("Discard") {
                showDiscardConfirmation = true
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
            .help("Delete this draft and close. Your in-progress notes will be lost.")

            // "Close" preserves the draft on disk. Sarah can resume from
            // the Today restore banner later. ESC also routes here so
            // accidental dismissal never destroys work.
            Button("Close") {
                stopDictation()
                coordinator.flushNow()
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])

            if payload.isQueueWalk {
                Button("Skip for now") {
                    skipAndAdvance()
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isSaving || isPolishing)
                .help("Leave this meeting on the review queue and move to the next one.")
            }

            Button(primaryActionLabel) {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(coordinator.isSaving || isPolishing || !canSave)
        }
        .padding()
    }

    /// Live count of pending reviews remaining. Drives the header badge during a queue walk.
    /// Recomputes on every render so the number drops as Sarah walks through the queue.
    private var remainingReviewCount: Int {
        (try? DailyBriefingCoordinator.shared.pendingMeetingReviews().count) ?? 0
    }

    /// "Skip for now" handler: keep the current evidence in .pending state and advance to the
    /// next unreviewed item. The coordinator tracks which IDs have already been shown this
    /// session so we don't loop back to this one.
    private func skipAndAdvance() {
        stopDictation()
        let currentID = payload.evidenceID
        onSave()
        dismiss()
        Task { @MainActor in
            DailyBriefingCoordinator.shared.advancePendingReviewWalker(skipping: currentID)
        }
    }

    // MARK: - Computed

    /// Primary button label. Switches to "Mark cancelled" / "Mark rescheduled" / "Mark no-show"
    /// when the user has declared the meeting didn't happen normally.
    private var primaryActionLabel: String {
        guard payload.captureKind.isMeeting else { return "Save" }
        return coordinator.occurrenceDecision.primaryButtonLabel
    }

    /// Whether the primary action is available. A non-happened occurrence decision is itself
    /// enough to save — we don't need any note content.
    private var canSave: Bool {
        if payload.captureKind.isMeeting && coordinator.occurrenceDecision != .happened {
            return true
        }
        return hasContent
    }

    private var hasContent: Bool {
        if coordinator.mode == .guided {
            // For unanswered calls, always allow save (status: no answer)
            if !payload.captureKind.isMeeting && !coordinator.callAnswered {
                return true
            }
            return !coordinator.mainOutcomeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !coordinator.guidedActionItemsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !coordinator.guidedFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !coordinator.guidedLifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !coordinator.voicemailNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || coordinator.talkingPointResponses.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                || coordinator.actionItemResponses.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        } else {
            return !coordinator.discussionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || coordinator.actionItemEntries.contains(where: { !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                || !coordinator.followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Mode Switching

    private func mapGuidedToFreeform() {
        // Map guided Q&A answers into freeform section fields
        var discussion: [String] = []

        let outcome = coordinator.mainOutcomeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outcome.isEmpty {
            discussion.append(outcome)
        }

        // Talking point responses
        for point in payload.talkingPoints {
            if let resp = coordinator.talkingPointResponses[point]?.trimmingCharacters(in: .whitespacesAndNewlines), !resp.isEmpty {
                discussion.append("\(point): \(resp)")
            }
        }

        // Action point responses
        for action in payload.openActionItems {
            if let resp = coordinator.actionItemResponses[action]?.trimmingCharacters(in: .whitespacesAndNewlines), !resp.isEmpty {
                discussion.append("\(action): \(resp)")
            }
        }

        if !discussion.isEmpty {
            coordinator.discussionText = discussion.joined(separator: "\n\n")
        }

        // Action items
        let guidedActions = coordinator.guidedActionItemsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidedActions.isEmpty {
            let lines = guidedActions.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            coordinator.actionItemEntries = lines.map { line in
                var entry = ActionItemEntry()
                entry.description = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^[\\-•] ?", with: "", options: .regularExpression)
                return entry
            }
            if coordinator.actionItemEntries.isEmpty { coordinator.actionItemEntries = [ActionItemEntry()] }
        }

        // Follow-up
        let guidedFU = coordinator.guidedFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidedFU.isEmpty { coordinator.followUpText = guidedFU }

        // Life events
        let guidedLE = coordinator.guidedLifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidedLE.isEmpty { coordinator.lifeEventsText = guidedLE }
    }

    // MARK: - Save

    private func save() {
        coordinator.isSaving = true
        coordinator.errorMessage = nil

        // Short-circuit: user declared the meeting didn't occur normally.
        // Mark the evidence so velocity/history consumers skip it, refresh the consolidated
        // review outcome, and close the sheet without creating a note.
        if payload.captureKind.isMeeting && coordinator.occurrenceDecision != .happened {
            markEvidenceReviewStatus(coordinator.occurrenceDecision.evidenceStatus)
            DailyBriefingCoordinator.shared.refreshPendingReviewsOutcome()
            coordinator.isSaving = false
            coordinator.clearDraft()
            onSave()
            dismiss()
            advanceWalkerIfNeeded()
            return
        }

        let content: String
        if coordinator.mode == .guided {
            content = composeGuidedContent()
        } else {
            content = composeFreeformContent()
        }

        // Determine linked people IDs
        let linkedIDs: [UUID]
        if payload.captureKind.isMeeting {
            linkedIDs = Array(coordinator.attendancePresent)
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

            // Normal "happened" path — confirm the evidence occurred and drop it from the review queue.
            if payload.captureKind.isMeeting {
                markEvidenceReviewStatus(.confirmed)
                DailyBriefingCoordinator.shared.refreshPendingReviewsOutcome()
            }

            coordinator.isSaving = false
            // Note succeeded — only now is it safe to discard the draft.
            // A failed save below leaves the draft intact so Sarah can retry.
            coordinator.clearDraft()
            onSave()
            dismiss()
            advanceWalkerIfNeeded()
        } catch {
            coordinator.errorMessage = "Failed to save: \(error.localizedDescription)"
            coordinator.isSaving = false
            // Make sure the latest in-memory edits are durably on disk so
            // a retry from a re-opened sheet still has the work.
            coordinator.flushNow()
            logger.error("Capture note save failed: \(error)")
        }
    }

    /// Advances to the next pending review when this sheet is part of a queue walk.
    /// Saves of any kind (confirmed, cancelled, no-show, rescheduled) resolve this item, so we
    /// don't need to mark it visited — it won't show up again in `pendingMeetingReviews()`.
    private func advanceWalkerIfNeeded() {
        guard payload.isQueueWalk else { return }
        Task { @MainActor in
            DailyBriefingCoordinator.shared.advancePendingReviewWalker(skipping: nil)
        }
    }

    /// Updates the linked evidence item's `reviewStatus` in place. No-op if the payload
    /// carries no evidenceID (e.g., capture was triggered without a calendar event).
    private func markEvidenceReviewStatus(_ status: EvidenceReviewStatus) {
        guard let evidenceID = payload.evidenceID else { return }
        do {
            try EvidenceRepository.shared.updateReviewStatus(id: evidenceID, status: status)
        } catch {
            logger.error("Failed to update evidence review status: \(error.localizedDescription)")
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
            let present = payload.attendees.filter { coordinator.attendancePresent.contains($0.personID) }.map(\.displayName)
            let absent = payload.attendees.filter { !coordinator.attendancePresent.contains($0.personID) }.map(\.displayName)
            let extras = coordinator.extraAttendeeNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if !present.isEmpty || !extras.isEmpty {
                parts.append("Attendees: \((present + extras).joined(separator: ", "))")
            }
            if !absent.isEmpty {
                parts.append("Absent: \(absent.joined(separator: ", "))")
            }
        } else if !coordinator.callAnswered {
            parts.append("Status: No answer")
            let vm = coordinator.voicemailNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !vm.isEmpty {
                parts.append(vm)
            }
            return parts.joined(separator: "\n")
        }

        parts.append("")

        // Discussion
        var discussion: [String] = []
        let outcome = coordinator.mainOutcomeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outcome.isEmpty { discussion.append(outcome) }

        for point in payload.talkingPoints {
            if let resp = coordinator.talkingPointResponses[point]?.trimmingCharacters(in: .whitespacesAndNewlines), !resp.isEmpty {
                discussion.append("\(point): \(resp)")
            }
        }

        for action in payload.openActionItems {
            if let resp = coordinator.actionItemResponses[action]?.trimmingCharacters(in: .whitespacesAndNewlines), !resp.isEmpty {
                discussion.append("[\(action)] \(resp)")
            }
        }

        if !discussion.isEmpty {
            parts.append("Discussion:")
            parts.append(discussion.joined(separator: "\n"))
            parts.append("")
        }

        // Action Items
        let actions = coordinator.guidedActionItemsText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let fu = coordinator.guidedFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fu.isEmpty {
            parts.append("Follow-Up:")
            parts.append(fu)
            parts.append("")
        }

        // Life Events
        let le = coordinator.guidedLifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let present = payload.attendees.filter { coordinator.attendancePresent.contains($0.personID) }.map(\.displayName)
            let absent = payload.attendees.filter { !coordinator.attendancePresent.contains($0.personID) }.map(\.displayName)
            let extras = coordinator.extraAttendeeNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if !present.isEmpty || !extras.isEmpty {
                parts.append("Attendees: \((present + extras).joined(separator: ", "))")
            }
            if !absent.isEmpty {
                parts.append("Absent: \(absent.joined(separator: ", "))")
            }
        }
        parts.append("")

        let discussion = coordinator.discussionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !discussion.isEmpty {
            parts.append("Discussion:")
            parts.append(discussion)
            parts.append("")
        }

        let validActions = coordinator.actionItemEntries.map(\.description).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !validActions.isEmpty {
            parts.append("Action Items:")
            for action in validActions {
                parts.append("- \(action)")
            }
            parts.append("")
        }

        let fu = coordinator.followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fu.isEmpty {
            parts.append("Follow-Up:")
            parts.append(fu)
            parts.append("")
        }

        let le = coordinator.lifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !le.isEmpty {
            parts.append("Life Events:")
            parts.append(le)
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Bindings for Talking Points / Action Points

    private func bindingForTalkingPoint(_ point: String) -> Binding<String> {
        Binding(
            get: { coordinator.talkingPointResponses[point] ?? "" },
            set: { coordinator.talkingPointResponses[point] = $0 }
        )
    }

    private func bindingForActionPoint(_ action: String) -> Binding<String> {
        Binding(
            get: { coordinator.actionItemResponses[action] ?? "" },
            set: { coordinator.actionItemResponses[action] = $0 }
        )
    }

    // MARK: - Dictation

    private func startDictation(for target: DictationTarget) {
        if activeDictationSection != nil {
            stopDictation()
        }

        let availability = dictationService.checkAvailability()
        guard availability == .available else {
            coordinator.errorMessage = "Speech recognition is not available"
            return
        }

        activeDictationSection = target
        dictationAccumulator.reset(initialText: currentText(for: target))

        Task {
            do {
                let stream = try await dictationService.startRecognition()
                for await result in stream {
                    let fullText = dictationAccumulator.process(result)
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
                coordinator.errorMessage = error.localizedDescription
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
        case .discussion: return coordinator.discussionText
        case .followUp: return coordinator.followUpText
        case .lifeEvents: return coordinator.lifeEventsText
        case .mainOutcome: return coordinator.mainOutcomeText
        case .guidedActionItems: return coordinator.guidedActionItemsText
        case .guidedFollowUp: return coordinator.guidedFollowUpText
        case .guidedLifeEvents: return coordinator.guidedLifeEventsText
        case .voicemailNote: return coordinator.voicemailNoteText
        case .talkingPoint(let point): return coordinator.talkingPointResponses[point] ?? ""
        case .actionPoint(let action): return coordinator.actionItemResponses[action] ?? ""
        }
    }

    private func setCurrentText(_ text: String, for target: DictationTarget) {
        switch target {
        case .discussion: coordinator.discussionText = text
        case .followUp: coordinator.followUpText = text
        case .lifeEvents: coordinator.lifeEventsText = text
        case .mainOutcome: coordinator.mainOutcomeText = text
        case .guidedActionItems: coordinator.guidedActionItemsText = text
        case .guidedFollowUp: coordinator.guidedFollowUpText = text
        case .guidedLifeEvents: coordinator.guidedLifeEventsText = text
        case .voicemailNote: coordinator.voicemailNoteText = text
        case .talkingPoint(let point): coordinator.talkingPointResponses[point] = text
        case .actionPoint(let action): coordinator.actionItemResponses[action] = text
        }
    }

}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
