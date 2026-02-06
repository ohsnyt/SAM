//
//  DuplicatePersonCleaner.swift
//  SAM_crm
//
//  Utility to find and merge duplicate SamPerson records.
//
//  Duplicate scenarios:
//    1. Same contactIdentifier (different UUIDs) — import created duplicate
//    2. Same name, one linked, one unlinked — manual + auto import
//    3. Same name, both unlinked — user created twice
//
//  Strategy:
//    • Keep the person with a contactIdentifier (if any)
//    • Merge relationships from the duplicate into the survivor
//    • Delete the duplicate
//

import Foundation
import SwiftData

@MainActor
struct DuplicatePersonCleaner {
    
    let modelContext: ModelContext
    
    /// Find and merge all duplicate people.
    ///
    /// Returns the number of duplicates merged/deleted.
    @discardableResult
    func cleanAllDuplicates() throws -> Int {
        let people = try modelContext.fetch(FetchDescriptor<SamPerson>())
        
        var mergedCount = 0
        var processedIDs = Set<UUID>()
        
        for person in people {
            // Skip if already processed (as survivor or duplicate)
            guard !processedIDs.contains(person.id) else { continue }
            
            // Find duplicates of this person
            let duplicates = findDuplicates(of: person, in: people)
            
            if !duplicates.isEmpty {
                // Merge all duplicates into this person
                for duplicate in duplicates {
                    guard !processedIDs.contains(duplicate.id) else { continue }
                    
                    mergePerson(duplicate, into: person)
                    modelContext.delete(duplicate)
                    processedIDs.insert(duplicate.id)
                    mergedCount += 1
                }
            }
            
            processedIDs.insert(person.id)
        }
        
        if mergedCount > 0 {
            try modelContext.save()
        }
        
        return mergedCount
    }
    
    // MARK: - Finding Duplicates
    
    /// Find all duplicates of a person.
    ///
    /// Duplicate criteria (in order of priority):
    ///   1. Same contactIdentifier (definite duplicate)
    ///   2. Same canonical name (likely duplicate)
    private func findDuplicates(of person: SamPerson, in allPeople: [SamPerson]) -> [SamPerson] {
        var duplicates: [SamPerson] = []
        
        for candidate in allPeople {
            // Skip self
            guard candidate.id != person.id else { continue }
            
            // 1. Same contactIdentifier = definite duplicate
            if let personCI = person.contactIdentifier,
               let candidateCI = candidate.contactIdentifier,
               personCI == candidateCI {
                duplicates.append(candidate)
                continue
            }
            
            // 2. Same canonical name
            let personCanonical = canonicalName(person.displayName)
            let candidateCanonical = canonicalName(candidate.displayName)
            
            if !personCanonical.isEmpty &&
               personCanonical == candidateCanonical {
                duplicates.append(candidate)
                continue
            }
        }
        
        return duplicates
    }
    
    /// Convert a name to a canonical form for comparison.
    ///
    /// - Lowercase
    /// - Remove punctuation
    /// - Normalize whitespace
    /// - Normalize common name variations (nickname map would go here)
    private func canonicalName(_ name: String) -> String {
        var result = name.lowercased()
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove punctuation
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        result = result.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce("") { $0 + String($1) }
        
        // Collapse multiple spaces
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return result
    }
    
    // MARK: - Merging
    
    /// Merge `source` into `target`.
    ///
    /// Strategy:
    ///   • Keep target's data as primary
    ///   • Adopt source's contactIdentifier if target doesn't have one
    ///   • Move all relationships from source to target
    ///   • Source will be deleted afterward
    private func mergePerson(_ source: SamPerson, into target: SamPerson) {
        // Adopt contactIdentifier if target doesn't have one
        if target.contactIdentifier == nil, let sourceCI = source.contactIdentifier {
            target.contactIdentifier = sourceCI
        }
        
        // Adopt email if target doesn't have one
        if target.email == nil, let sourceEmail = source.email {
            target.email = sourceEmail
        }
        
        // Merge role badges (deduplicate)
        for badge in source.roleBadges {
            if !target.roleBadges.contains(badge) {
                target.roleBadges.append(badge)
            }
        }
        
        // Merge alert counters (additive)
        target.consentAlertsCount += source.consentAlertsCount
        target.reviewAlertsCount += source.reviewAlertsCount
        
        // Move participations
        for participation in source.participations {
            participation.person = target
            if !target.participations.contains(where: { $0.id == participation.id }) {
                target.participations.append(participation)
            }
        }
        
        // Move coverages
        for coverage in source.coverages {
            coverage.person = target
            if !target.coverages.contains(where: { $0.id == coverage.id }) {
                target.coverages.append(coverage)
            }
        }
        
        // Move consent requirements
        for consent in source.consentRequirements {
            consent.person = target
            if !target.consentRequirements.contains(where: { $0.id == consent.id }) {
                target.consentRequirements.append(consent)
            }
        }
        
        // Move responsibilities (as guardian)
        for resp in source.responsibilitiesAsGuardian {
            resp.guardian = target
            if !target.responsibilitiesAsGuardian.contains(where: { $0.id == resp.id }) {
                target.responsibilitiesAsGuardian.append(resp)
            }
        }
        
        // Move responsibilities (as dependent)
        for resp in source.responsibilitiesAsDependent {
            resp.dependent = target
            if !target.responsibilitiesAsDependent.contains(where: { $0.id == resp.id }) {
                target.responsibilitiesAsDependent.append(resp)
            }
        }
        
        // Move joint interests
        for ji in source.jointInterests {
            // Remove source from parties, add target
            if let index = ji.parties.firstIndex(where: { $0.id == source.id }) {
                ji.parties.remove(at: index)
            }
            if !ji.parties.contains(where: { $0.id == target.id }) {
                ji.parties.append(target)
            }
            
            if !target.jointInterests.contains(where: { $0.id == ji.id }) {
                target.jointInterests.append(ji)
            }
        }
        
        // Merge context chips (deduplicate by id)
        for chip in source.contextChips {
            if !target.contextChips.contains(where: { $0.id == chip.id }) {
                target.contextChips.append(chip)
            }
        }
        
        // Merge responsibility notes
        for note in source.responsibilityNotes {
            if !target.responsibilityNotes.contains(note) {
                target.responsibilityNotes.append(note)
            }
        }
        
        // Merge insights (deduplicate by some criteria if needed)
        target.insights.append(contentsOf: source.insights)
        
        // Merge interactions
        target.recentInteractions.append(contentsOf: source.recentInteractions)
    }
    
    // MARK: - Diagnostics
    
    /// Find all potential duplicates without merging.
    ///
    /// Returns groups of duplicates (each group has 2+ people that match).
    func findAllDuplicates() throws -> [[SamPerson]] {
        let people = try modelContext.fetch(FetchDescriptor<SamPerson>())
        var groups: [[SamPerson]] = []
        var processed = Set<UUID>()
        
        for person in people {
            guard !processed.contains(person.id) else { continue }
            
            let duplicates = findDuplicates(of: person, in: people)
            
            if !duplicates.isEmpty {
                var group = [person]
                group.append(contentsOf: duplicates)
                groups.append(group)
                
                processed.insert(person.id)
                for dup in duplicates {
                    processed.insert(dup.id)
                }
            }
        }
        
        return groups
    }
}
