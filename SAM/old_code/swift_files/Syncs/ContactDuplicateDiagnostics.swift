//
//  ContactDuplicateDiagnostics.swift
//  SAM_crm
//
//  Diagnostic tool to identify and report duplicate SamPerson records
//  that share the same contactIdentifier.
//

import Foundation
import SwiftData
import Contacts

@MainActor
struct ContactDuplicateDiagnostics {
    
    let modelContext: ModelContext
    
    // MARK: - Duplicate Detection
    
    /// Find all SamPerson records that share the same contactIdentifier.
    ///
    /// Returns a dictionary where:
    ///   - Key: The shared contactIdentifier
    ///   - Value: Array of SamPerson records with that identifier
    ///
    /// Only includes identifiers that have 2+ people.
    func findDuplicatesByContactIdentifier() throws -> [String: [SamPerson]] {
        // Fetch all people with a contactIdentifier
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )
        
        let linkedPeople = try modelContext.fetch(descriptor)
        
        // Group by contactIdentifier
        var groups: [String: [SamPerson]] = [:]
        
        for person in linkedPeople {
            guard let identifier = person.contactIdentifier else { continue }
            groups[identifier, default: []].append(person)
        }
        
        // Filter to only groups with 2+ people (duplicates)
        return groups.filter { $0.value.count > 1 }
    }
    
    /// Generate a detailed report of all duplicates.
    func generateReport() throws -> DuplicateReport {
        let duplicates = try findDuplicatesByContactIdentifier()
        
        var groups: [DuplicateGroup] = []
        
        for (identifier, people) in duplicates {
            let group = DuplicateGroup(
                contactIdentifier: identifier,
                people: people.map { person in
                    PersonInfo(
                        id: person.id,
                        displayName: person.displayName,
                        email: person.email,
                        roleBadges: person.roleBadges,
                        participationCount: person.participations.count,
                        coverageCount: person.coverages.count,
                        consentCount: person.consentRequirements.count,
                        contextChipCount: person.contextChips.count
                    )
                }
            )
            groups.append(group)
        }
        
        return DuplicateReport(
            totalDuplicates: groups.count,
            totalAffectedPeople: groups.reduce(0) { $0 + $1.people.count },
            groups: groups.sorted { $0.people.count > $1.people.count }
        )
    }
    
    /// Print a human-readable duplicate report to the console.
    func printReport() throws {
        let report = try generateReport()
        
        print("\n" + String(repeating: "=", count: 70))
        print("📊 DUPLICATE CONTACT IDENTIFIER REPORT")
        print(String(repeating: "=", count: 70))
        
        if report.groups.isEmpty {
            print("\n✅ No duplicates found! All contactIdentifiers are unique.\n")
            return
        }
        
        print("\n⚠️  Found \(report.totalDuplicates) duplicate contactIdentifier(s)")
        print("    Affecting \(report.totalAffectedPeople) SamPerson record(s)\n")
        
        for (index, group) in report.groups.enumerated() {
            print(String(repeating: "-", count: 70))
            print("Duplicate #\(index + 1): contactIdentifier = \(group.contactIdentifier)")
            print("\(group.people.count) people share this identifier:")
            print()
            
            for person in group.people {
                print("  • \(person.displayName)")
                print("    ID: \(person.id)")
                if let email = person.email {
                    print("    Email: \(email)")
                }
                if !person.roleBadges.isEmpty {
                    print("    Roles: \(person.roleBadges.joined(separator: ", "))")
                }
                print("    Relationships:")
                print("      - \(person.participationCount) participation(s)")
                print("      - \(person.coverageCount) coverage(s)")
                print("      - \(person.consentCount) consent requirement(s)")
                print("      - \(person.contextChipCount) context chip(s)")
                print()
            }
        }
        
        print(String(repeating: "=", count: 70))
        print("\n💡 To fix these duplicates, run:")
        print("   let cleaner = DuplicatePersonCleaner(modelContext: modelContext)")
        print("   try cleaner.cleanAllDuplicates()")
        print("\n   Or use the DeduplicatePeopleView in your UI.\n")
    }
    
    // MARK: - Permission Flow Analysis
    
    /// Check if the duplicate problem is caused by the permission race condition.
    ///
    /// Returns `true` if Contacts permission was already granted before
    /// ContactsSyncManager started (indicating a potential race condition).
    func checkPermissionRaceCondition() -> PermissionRaceConditionReport {
        #if canImport(Contacts)
        
        let status = CNContactStore.authorizationStatus(for: .contacts)
        
        let report = PermissionRaceConditionReport(
            currentStatus: status,
            deduplicateOnEveryLaunch: ContactSyncConfiguration.deduplicateOnEveryLaunch,
            deduplicateAfterPermissionGrant: ContactSyncConfiguration.deduplicateAfterPermissionGrant
        )
        
        return report
        #else
        return PermissionRaceConditionReport(
            currentStatus: nil,
            deduplicateOnEveryLaunch: ContactSyncConfiguration.deduplicateOnEveryLaunch,
            deduplicateAfterPermissionGrant: ContactSyncConfiguration.deduplicateAfterPermissionGrant
        )
        #endif
    }
    
    /// Print a diagnosis of the permission race condition issue.
    func printPermissionDiagnosis() {
        let report = checkPermissionRaceCondition()
        
        print("\n" + String(repeating: "=", count: 70))
        print("🔍 PERMISSION RACE CONDITION DIAGNOSIS")
        print(String(repeating: "=", count: 70))
        print()
        
        #if canImport(Contacts)
        if let status = report.currentStatus {
            print("Current Contacts permission status: \(status.description)")
            print()
            
            if status == .authorized {
                print("⚠️  Permission is already granted.")
                print("   This means if your app requests permission elsewhere")
                print("   (e.g. combined Calendar+Contacts request), the deduplication")
                print("   in ContactsSyncManager might be bypassed.")
                print()
            }
        }
        #endif
        
        print("Configuration:")
        print("  • deduplicateOnEveryLaunch: \(report.deduplicateOnEveryLaunch ? "✅ ENABLED" : "❌ DISABLED")")
        print("  • deduplicateAfterPermissionGrant: \(report.deduplicateAfterPermissionGrant ? "✅ ENABLED" : "❌ DISABLED")")
        print()
        
        if !report.deduplicateOnEveryLaunch {
            print("🔧 RECOMMENDED ACTION:")
            print("   Enable 'deduplicateOnEveryLaunch' in ContactSyncConfiguration")
            print("   to catch duplicates created by permission race conditions.")
            print()
            print("   In ContactSyncConfiguration.swift:")
            print("   static let deduplicateOnEveryLaunch: Bool = true")
            print()
        } else {
            print("✅ Configuration is correct for handling permission race conditions.")
            print()
        }
        
        print(String(repeating: "=", count: 70) + "\n")
    }
}

// MARK: - Report Types

struct DuplicateReport {
    let totalDuplicates: Int
    let totalAffectedPeople: Int
    let groups: [DuplicateGroup]
}

struct DuplicateGroup {
    let contactIdentifier: String
    let people: [PersonInfo]
}

struct PersonInfo {
    let id: UUID
    let displayName: String
    let email: String?
    let roleBadges: [String]
    let participationCount: Int
    let coverageCount: Int
    let consentCount: Int
    let contextChipCount: Int
}

struct PermissionRaceConditionReport {
    #if canImport(Contacts)
    let currentStatus: CNAuthorizationStatus?
    #else
    let currentStatus: Int? = nil
    #endif
    
    let deduplicateOnEveryLaunch: Bool
    let deduplicateAfterPermissionGrant: Bool
    
    var hasRaceConditionRisk: Bool {
        // If permission is already granted but we don't deduplicate on every launch,
        // there's a risk of duplicates from the race condition
        #if canImport(Contacts)
        if currentStatus == .authorized && !deduplicateOnEveryLaunch {
            return true
        }
        #endif
        return false
    }
}

#if canImport(Contacts)
import Contacts

extension CNAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined:
            return ".notDetermined (not yet requested)"
        case .restricted:
            return ".restricted (system-level restriction)"
        case .denied:
            return ".denied (user declined)"
        case .authorized:
            return ".authorized (user granted)"
        @unknown default:
            return ".unknown (\(self.rawValue))"
        }
    }
}
#endif
