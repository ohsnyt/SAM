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
        if StrategicCoordinator.shared.generationStatus == .generating {
            blockers.append("strategic digest")
        }
        if RoleDeductionEngine.shared.deductionStatus == .running {
            blockers.append("role deduction")
        }
        return blockers
    }

    static var isAnyBusy: Bool {
        !currentBlockers().isEmpty
    }
}
