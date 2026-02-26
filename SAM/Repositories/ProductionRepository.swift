//
//  ProductionRepository.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase S: Production Tracking
//
//  SwiftData CRUD and metric queries for ProductionRecord.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ProductionRepository")

@MainActor
@Observable
final class ProductionRepository {

    // MARK: - Singleton

    static let shared = ProductionRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    enum RepositoryError: Error {
        case notConfigured
        case notFound
    }

    // MARK: - CRUD

    /// Create a new production record. Re-resolves person in own context (cross-context safety).
    @discardableResult
    func createRecord(
        personID: UUID,
        productType: WFGProductType,
        carrierName: String,
        annualPremium: Double,
        submittedDate: Date = .now,
        notes: String? = nil
    ) throws -> ProductionRecord {
        guard let context else { throw RepositoryError.notConfigured }

        // Re-resolve person in this context
        let descriptor = FetchDescriptor<SamPerson>()
        let allPeople = try context.fetch(descriptor)
        let person = allPeople.first { $0.id == personID }

        let record = ProductionRecord(
            person: person,
            productType: productType,
            carrierName: carrierName,
            annualPremium: annualPremium,
            submittedDate: submittedDate,
            notes: notes
        )
        context.insert(record)
        try context.save()
        logger.info("Created production record for \(person?.displayName ?? "unknown"): \(productType.displayName)")
        return record
    }

    /// Update status and optional fields on an existing production record.
    func updateRecord(
        recordID: UUID,
        status: ProductionStatus? = nil,
        resolvedDate: Date? = nil,
        policyNumber: String? = nil,
        notes: String? = nil
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<ProductionRecord>()
        let all = try context.fetch(descriptor)
        guard let record = all.first(where: { $0.id == recordID }) else {
            throw RepositoryError.notFound
        }

        if let status { record.status = status }
        if let resolvedDate { record.resolvedDate = resolvedDate }
        if let policyNumber { record.policyNumber = policyNumber }
        if let notes { record.notes = notes }
        record.updatedAt = .now

        try context.save()
        logger.info("Updated production record \(recordID): status=\(record.status.displayName)")
    }

    /// Advance a record's status to the next happy-path stage.
    /// Sets resolvedDate on transition to approved/issued.
    func advanceStatus(recordID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<ProductionRecord>()
        let all = try context.fetch(descriptor)
        guard let record = all.first(where: { $0.id == recordID }) else {
            throw RepositoryError.notFound
        }

        guard let nextStatus = record.status.next else { return }
        record.status = nextStatus
        record.updatedAt = .now

        // Set resolvedDate on terminal states
        if nextStatus == .approved || nextStatus == .issued {
            record.resolvedDate = .now
        }

        try context.save()
        logger.info("Advanced production record \(recordID) to \(nextStatus.displayName)")
    }

    /// Delete a production record.
    func deleteRecord(recordID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<ProductionRecord>()
        let all = try context.fetch(descriptor)
        guard let record = all.first(where: { $0.id == recordID }) else {
            throw RepositoryError.notFound
        }

        context.delete(record)
        try context.save()
        logger.info("Deleted production record \(recordID)")
    }

    // MARK: - Fetch

    /// Fetch production records for a specific person, sorted by submittedDate descending.
    func fetchRecords(forPerson personID: UUID) throws -> [ProductionRecord] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<ProductionRecord>(
            sortBy: [SortDescriptor(\.submittedDate, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.person?.id == personID }
    }

    /// Fetch all production records, sorted by submittedDate descending.
    func fetchAllRecords() throws -> [ProductionRecord] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<ProductionRecord>(
            sortBy: [SortDescriptor(\.submittedDate, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetch production records within a date window.
    func fetchRecords(since date: Date) throws -> [ProductionRecord] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<ProductionRecord>(
            sortBy: [SortDescriptor(\.submittedDate, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.submittedDate >= date }
    }

    // MARK: - Metrics

    /// Count of records grouped by status.
    func countByStatus() throws -> [ProductionStatus: Int] {
        let all = try fetchAllRecords()
        var result: [ProductionStatus: Int] = [:]
        for record in all {
            result[record.status, default: 0] += 1
        }
        return result
    }

    /// Count of records grouped by product type.
    func countByProductType() throws -> [WFGProductType: Int] {
        let all = try fetchAllRecords()
        var result: [WFGProductType: Int] = [:]
        for record in all {
            result[record.productType, default: 0] += 1
        }
        return result
    }

    /// Total premium grouped by status.
    func totalPremiumByStatus() throws -> [ProductionStatus: Double] {
        let all = try fetchAllRecords()
        var result: [ProductionStatus: Double] = [:]
        for record in all {
            result[record.status, default: 0] += record.annualPremium
        }
        return result
    }

    /// Submitted records with their pending age in days, sorted oldest first.
    func pendingWithAge() throws -> [(record: ProductionRecord, daysPending: Int)] {
        let all = try fetchAllRecords()
        let now = Date.now
        return all
            .filter { $0.status == .submitted }
            .map { record in
                let days = Int(now.timeIntervalSince(record.submittedDate) / (24 * 60 * 60))
                return (record: record, daysPending: days)
            }
            .sorted { $0.daysPending > $1.daysPending }
    }
}
