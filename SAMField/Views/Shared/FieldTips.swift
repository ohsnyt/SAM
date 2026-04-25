//
//  FieldTips.swift
//  SAM Field
//
//  TipKit catalog for SAMField. Mirrors the macOS SAMTips pattern:
//  one Tip-conforming struct per discoverable feature, a guide-article
//  mapping for "Learn more" actions, a global enable/disable toggle, and
//  a custom view style for in-app rendering.
//
//  Apple-recommended pattern for iOS 17+ feature discovery.
//

import TipKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "FieldTips")

// MARK: - Guide Article ID Mapping

/// Maps each FieldTip type to its corresponding guide article ID.
/// Reserved for a future in-app iOS guide reader; tips currently display
/// without a "Learn more" action because SAMField has no guide UI yet.
enum FieldTipGuideMapping {
    static func articleID(for tip: any Tip) -> String? {
        switch tip {
        case is TodayBriefingSyncTip:    return "ios.today-briefing-sync"
        case is TodayQuickStatsTip:      return "ios.today-overview"
        case is RecordTapToStartTip:     return "ios.recording-overview"
        case is RecordModeIndicatorTip:  return "ios.recording-modes"
        case is RecordParticipantsTip:   return "ios.recording-participants"
        case is RecordReclassifyTip:     return "ios.recording-reclassify"
        case is RecordSwipeDeleteTip:    return "ios.recording-overview"
        case is RecordLooksGoodTip:      return "ios.recording-approve"
        case is RecordPendingUploadsTip: return "ios.pending-uploads"
        case is TripStartTip:            return "ios.trips-overview"
        case is TripStopDetectionTip:    return "ios.trips-stops"
        case is TripCloseAtHomeTip:      return "ios.trips-close-at-home"
        case is TripSwipeDeleteTip:      return "ios.trips-overview"
        case is TripExportTip:           return "ios.mileage-export"
        case is TripPeriodFilterTip:     return "ios.trips-overview"
        case is SettingsPairingTip:      return "ios.pairing"
        default:                         return nil
        }
    }
}

// MARK: - Tip Events (donate from user actions to control eligibility)

/// Events donated from the app to drive TipKit `Rule` evaluation.
/// e.g. show RecordReclassifyTip only after the first recording completes.
enum FieldTipEvents {
    static let firstRecordingCompleted = Tips.Event(id: "field.firstRecordingCompleted")
    static let firstTripCompleted      = Tips.Event(id: "field.firstTripCompleted")
    static let firstPendingUpload      = Tips.Event(id: "field.firstPendingUpload")
    static let openedRecordTab         = Tips.Event(id: "field.openedRecordTab")
    static let openedTripsTab          = Tips.Event(id: "field.openedTripsTab")
    static let openedTodayTab          = Tips.Event(id: "field.openedTodayTab")
    static let openedSettings          = Tips.Event(id: "field.openedSettings")
}

// MARK: - Global Guidance Toggle

/// Manages the TipKit guidance system on/off state and lifecycle.
/// Persisted via UserDefaults; mirrors SAMTipState on macOS.
enum FieldTipState {

    private static let enabledKey = "samfield.tips.guidanceEnabled"

    /// Whether tips are currently enabled. Defaults to true on first launch.
    static var guidanceEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// All tip types in the iOS app, used for batch reset/disable.
    static let allTipTypes: [any Tip.Type] = [
        TodayBriefingSyncTip.self,
        TodayQuickStatsTip.self,
        RecordTapToStartTip.self,
        RecordModeIndicatorTip.self,
        RecordParticipantsTip.self,
        RecordReclassifyTip.self,
        RecordSwipeDeleteTip.self,
        RecordLooksGoodTip.self,
        RecordPendingUploadsTip.self,
        TripStartTip.self,
        TripStopDetectionTip.self,
        TripCloseAtHomeTip.self,
        TripSwipeDeleteTip.self,
        TripExportTip.self,
        TripPeriodFilterTip.self,
        SettingsPairingTip.self,
    ]

    /// Configure TipKit at app launch. Call once from `SAMFieldApp.init()` or `.task`.
    @MainActor
    static func configure() {
        do {
            try Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault)
            ])
            logger.debug("TipKit configured for SAMField")
        } catch {
            logger.error("TipKit configure failed: \(error.localizedDescription)")
        }
    }

    /// Re-enable all tips so they reappear after being globally disabled.
    @MainActor
    static func enableTips() {
        guidanceEnabled = true
        Task {
            await TodayBriefingSyncTip().resetEligibility()
            await TodayQuickStatsTip().resetEligibility()
            await RecordTapToStartTip().resetEligibility()
            await RecordModeIndicatorTip().resetEligibility()
            await RecordParticipantsTip().resetEligibility()
            await RecordReclassifyTip().resetEligibility()
            await RecordSwipeDeleteTip().resetEligibility()
            await RecordLooksGoodTip().resetEligibility()
            await RecordPendingUploadsTip().resetEligibility()
            await TripStartTip().resetEligibility()
            await TripStopDetectionTip().resetEligibility()
            await TripCloseAtHomeTip().resetEligibility()
            await TripSwipeDeleteTip().resetEligibility()
            await TripExportTip().resetEligibility()
            await TripPeriodFilterTip().resetEligibility()
            await SettingsPairingTip().resetEligibility()
            logger.debug("All FieldTips re-enabled via resetEligibility")
        }
    }

    /// Hide all tips immediately.
    @MainActor
    static func disableTips() {
        guidanceEnabled = false
        TodayBriefingSyncTip().invalidate(reason: .tipClosed)
        TodayQuickStatsTip().invalidate(reason: .tipClosed)
        RecordTapToStartTip().invalidate(reason: .tipClosed)
        RecordModeIndicatorTip().invalidate(reason: .tipClosed)
        RecordParticipantsTip().invalidate(reason: .tipClosed)
        RecordReclassifyTip().invalidate(reason: .tipClosed)
        RecordSwipeDeleteTip().invalidate(reason: .tipClosed)
        RecordLooksGoodTip().invalidate(reason: .tipClosed)
        RecordPendingUploadsTip().invalidate(reason: .tipClosed)
        TripStartTip().invalidate(reason: .tipClosed)
        TripStopDetectionTip().invalidate(reason: .tipClosed)
        TripCloseAtHomeTip().invalidate(reason: .tipClosed)
        TripSwipeDeleteTip().invalidate(reason: .tipClosed)
        TripExportTip().invalidate(reason: .tipClosed)
        TripPeriodFilterTip().invalidate(reason: .tipClosed)
        SettingsPairingTip().invalidate(reason: .tipClosed)
        logger.debug("All FieldTips disabled via invalidate")
    }

    /// Wipe TipKit datastore. Use for "Reset All Tips" in Settings.
    @MainActor
    static func resetAllTips() {
        do {
            try Tips.resetDatastore()
            try Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault)
            ])
            guidanceEnabled = true
            logger.debug("TipKit datastore reset for SAMField")
        } catch {
            logger.error("TipKit reset failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Custom Tip View Style

/// SAMField tip rendering: prominent symbol, title, message, "Learn more"
/// action, and a close button. Designed for iOS list/section embedding.
struct FieldTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            configuration.image?
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.orange, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                configuration.title?
                    .font(.headline)

                configuration.message?
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    ForEach(configuration.actions) { action in
                        Button(action: action.handler) {
                            action.label()
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)

            Button {
                configuration.tip.invalidate(reason: .tipClosed)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        }
    }
}

// MARK: - Today Tab Tips

struct TodayBriefingSyncTip: Tip {
    var title: Text { Text("Daily Briefing") }
    var message: Text? {
        Text("Pull down to refresh today's briefing from your Mac. The briefing is generated on the Mac and synced via iCloud.")
    }
    var image: Image? { Image(systemName: "arrow.down.circle") }
    var rules: [Rule] {
        [#Rule(FieldTipEvents.openedTodayTab) { $0.donations.count >= 1 }]
    }
}

struct TodayQuickStatsTip: Tip {
    var title: Text { Text("Your Day at a Glance") }
    var message: Text? {
        Text("These cards show meetings today, pending actions, captures this week, and your monthly business mileage.")
    }
    var image: Image? { Image(systemName: "chart.bar.fill") }
}

// MARK: - Record Tab Tips

struct RecordTapToStartTip: Tip {
    var title: Text { Text("Capture a Meeting") }
    var message: Text? {
        Text("Tap the record button to capture audio. If your Mac is reachable you'll get live transcription; otherwise the recording queues and syncs later.")
    }
    var image: Image? { Image(systemName: "waveform.and.mic") }
}

struct RecordModeIndicatorTip: Tip {
    var title: Text { Text("Live or Offline") }
    var message: Text? {
        Text("This badge shows whether your Mac is connected. Live mode streams audio to your Mac in real time. Offline mode records locally and syncs later.")
    }
    var image: Image? { Image(systemName: "antenna.radiowaves.left.and.right") }
}

struct RecordParticipantsTip: Tip {
    var title: Text { Text("Who's in the Room") }
    var message: Text? {
        Text("Set participant count and names before starting. SAM uses these to label speakers in the transcript on your Mac.")
    }
    var image: Image? { Image(systemName: "person.2.fill") }
}

struct RecordReclassifyTip: Tip {
    var title: Text { Text("Wrong Recording Type?") }
    var message: Text? {
        Text("Tap the menu to reclassify a recording (Client, Internal, Board, Training). Your Mac will regenerate the summary with the right structure.")
    }
    var image: Image? { Image(systemName: "arrow.triangle.2.circlepath") }
    var rules: [Rule] {
        [#Rule(FieldTipEvents.firstRecordingCompleted) { $0.donations.count >= 1 }]
    }
}

struct RecordSwipeDeleteTip: Tip {
    var title: Text { Text("Swipe to Delete") }
    var message: Text? {
        Text("Swipe left on any recording to delete it. Useful for cleaning up false starts or test recordings.")
    }
    var image: Image? { Image(systemName: "hand.draw") }
    var rules: [Rule] {
        [#Rule(FieldTipEvents.firstRecordingCompleted) { $0.donations.count >= 1 }]
    }
}

struct RecordLooksGoodTip: Tip {
    var title: Text { Text("Approve in One Tap") }
    var message: Text? {
        Text("Once you've reviewed the summary, tap \"Looks Good\" to approve it without opening the Mac. Your Mac runs the deeper coaching analysis afterwards.")
    }
    var image: Image? { Image(systemName: "checkmark.seal.fill") }
    var rules: [Rule] {
        [#Rule(FieldTipEvents.firstRecordingCompleted) { $0.donations.count >= 1 }]
    }
}

struct RecordPendingUploadsTip: Tip {
    var title: Text { Text("Pending Uploads") }
    var message: Text? {
        Text("Recordings made offline appear here. They upload automatically when your Mac is reachable on the same network.")
    }
    var image: Image? { Image(systemName: "icloud.and.arrow.up") }
    var rules: [Rule] {
        [#Rule(FieldTipEvents.firstPendingUpload) { $0.donations.count >= 1 }]
    }
}

// MARK: - Trips Tab Tips

struct TripStartTip: Tip {
    var title: Text { Text("Start a Trip") }
    var message: Text? {
        Text("Tap Start Trip when you head out. SAM detects stops automatically using GPS and dwell time. No manual logging needed.")
    }
    var image: Image? { Image(systemName: "car.fill") }
}

struct TripStopDetectionTip: Tip {
    var title: Text { Text("Stops Are Automatic") }
    var message: Text? {
        Text("SAM creates a stop when you've been still for a couple minutes. Tap a stop chip to label its purpose (business or personal).")
    }
    var image: Image? { Image(systemName: "mappin.circle.fill") }
    var rules: [Rule] {
        [#Rule(FieldTipEvents.openedTripsTab) { $0.donations.count >= 1 }]
    }
}

struct TripCloseAtHomeTip: Tip {
    var title: Text { Text("Close at Home") }
    var message: Text? {
        Text("Heading home? Tap Close at Home to snap the final stop to your home address — useful for round trips.")
    }
    var image: Image? { Image(systemName: "house.fill") }
}

struct TripSwipeDeleteTip: Tip {
    var title: Text { Text("Swipe to Delete a Trip") }
    var message: Text? {
        Text("Swipe left on any trip in the history to delete it.")
    }
    var image: Image? { Image(systemName: "hand.draw") }
    var rules: [Rule] {
        [#Rule(FieldTipEvents.firstTripCompleted) { $0.donations.count >= 1 }]
    }
}

struct TripExportTip: Tip {
    var title: Text { Text("Export for Taxes") }
    var message: Text? {
        Text("Export your business miles as IRS-compliant CSV or PDF. Includes date, addresses, purpose, and the IRS rate you set at export time.")
    }
    var image: Image? { Image(systemName: "square.and.arrow.up") }
    var rules: [Rule] {
        [#Rule(FieldTipEvents.firstTripCompleted) { $0.donations.count >= 1 }]
    }
}

struct TripPeriodFilterTip: Tip {
    var title: Text { Text("Filter by Period") }
    var message: Text? {
        Text("Switch between Day, Week, Month, Year, and All to see trips for any range. Year and All group results by month.")
    }
    var image: Image? { Image(systemName: "calendar") }
}

// MARK: - Settings Tips

struct SettingsPairingTip: Tip {
    var title: Text { Text("Automatic Mac Pairing") }
    var message: Text? {
        Text("Macs signed in to your Apple ID are paired automatically through iCloud — no PIN required. Tap a Mac to remove it.")
    }
    var image: Image? { Image(systemName: "checkmark.icloud.fill") }
    var rules: [Rule] {
        [#Rule(FieldTipEvents.openedSettings) { $0.donations.count >= 1 }]
    }
}
