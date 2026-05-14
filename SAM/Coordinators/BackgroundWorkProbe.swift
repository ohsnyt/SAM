//
//  BackgroundWorkProbe.swift
//  SAM
//
//  Shared probe for "is any background coordinator still doing work that
//  would be unsafe to interrupt?" Used by both BackupCoordinator (restore
//  settle phase) and ShutdownCoordinator (graceful quit). Centralizes the
//  list of coordinators we care about so it only has to be maintained in
//  one place.
//

import Foundation

@MainActor
enum BackgroundWorkProbe {

    /// Human-readable names of coordinators currently busy. Empty when idle.
    ///
    /// AI-only coordinators (DailyBriefingCoordinator, NoteAnalysisCoordinator,
    /// StrategicCoordinator, PresentationAnalysisCoordinator, EventCoordinator
    /// drafts, PromptLabCoordinator) used to be listed here. They were removed
    /// once every AI call site started registering with `InferenceRegistry`
    /// and `ShutdownCoordinator.settle()` started awaiting
    /// `AIService.shared.isFullyIdle` — their busy state is now covered by
    /// the inference counter and would just produce duplicate blocker entries.
    /// Coordinators that wrap rule-based work (or mix rule-based with AI)
    /// stay listed.
    static func currentBlockers() -> [String] {
        var blockers: [String] = []
        if CommunicationsImportCoordinator.shared.importStatus == .importing {
            blockers.append("communications import")
        }
        if MailImportCoordinator.shared.importStatus == .importing {
            blockers.append("mail import")
        }
        if CalendarImportCoordinator.shared.importStatus == .importing {
            blockers.append("calendar import")
        }
        if ContactsImportCoordinator.isImportingContacts {
            blockers.append("contacts import")
        }
        if OutcomeEngine.shared.generationStatus == .generating {
            blockers.append("outcome generation")
        }
        if RoleDeductionEngine.shared.deductionStatus == .running {
            blockers.append("role deduction")
        }
        if InsightGenerator.shared.generationStatus == .generating {
            blockers.append("insight generation")
        }
        return blockers
    }

    static var isAnyBusy: Bool {
        !currentBlockers().isEmpty
    }
}
