//
//  ForEachPatternsTests.swift
//  SAMTests
//
//  Created on February 10, 2026.
//  Tests for SwiftUI ForEach patterns with non-Identifiable collections
//

import Testing
import Foundation
@testable import SAM

@Suite("ForEach Pattern Tests - enumerated() with offset ID")
struct ForEachPatternsTests {
    
    // MARK: - ContactDTO Phone Numbers
    
    @Test("Phone numbers can be enumerated for ForEach")
    func testPhoneNumbersEnumerated() async throws {
        let dto = ContactDTO(
            identifier: "test-123",
            givenName: "John",
            familyName: "Doe",
            nickname: "",
            organizationName: "",
            departmentName: "",
            jobTitle: "",
            phoneNumbers: [
                ContactDTO.PhoneNumberDTO(label: "mobile", value: "555-1234"),
                ContactDTO.PhoneNumberDTO(label: "work", value: "555-5678"),
                ContactDTO.PhoneNumberDTO(label: "home", value: "555-9999")
            ],
            emailAddresses: [],
            postalAddresses: [],
            birthday: nil,
            note: "",
            imageData: nil,
            thumbnailImageData: nil,
            contactRelations: [],
            socialProfiles: [],
            instantMessageAddresses: [],
            urlAddresses: []
        )
        
        // Pattern used in PersonDetailView
        let enumerated = Array(dto.phoneNumbers.enumerated())
        
        #expect(enumerated.count == 3)
        #expect(enumerated[0].offset == 0)
        #expect(enumerated[0].element.value == "555-1234")
        #expect(enumerated[1].offset == 1)
        #expect(enumerated[1].element.value == "555-5678")
        #expect(enumerated[2].offset == 2)
        #expect(enumerated[2].element.value == "555-9999")
    }
    
    @Test("Empty phone numbers array enumerates correctly")
    func testEmptyPhoneNumbers() async throws {
        let dto = ContactDTO(
            identifier: "test-123",
            givenName: "John",
            familyName: "Doe",
            nickname: "",
            organizationName: "",
            departmentName: "",
            jobTitle: "",
            phoneNumbers: [],
            emailAddresses: [],
            postalAddresses: [],
            birthday: nil,
            note: "",
            imageData: nil,
            thumbnailImageData: nil,
            contactRelations: [],
            socialProfiles: [],
            instantMessageAddresses: [],
            urlAddresses: []
        )
        
        let enumerated = Array(dto.phoneNumbers.enumerated())
        
        #expect(enumerated.isEmpty)
    }
    
    // MARK: - ContactDTO Email Addresses
    
    @Test("Email addresses can be enumerated for ForEach")
    func testEmailAddressesEnumerated() async throws {
        let dto = ContactDTO(
            identifier: "test-123",
            givenName: "John",
            familyName: "Doe",
            nickname: "",
            organizationName: "",
            departmentName: "",
            jobTitle: "",
            phoneNumbers: [],
            emailAddresses: [
                "john@example.com",
                "john.doe@work.com",
                "jdoe@personal.net"
            ],
            postalAddresses: [],
            birthday: nil,
            note: "",
            imageData: nil,
            thumbnailImageData: nil,
            contactRelations: [],
            socialProfiles: [],
            instantMessageAddresses: [],
            urlAddresses: []
        )
        
        let enumerated = Array(dto.emailAddresses.enumerated())
        
        #expect(enumerated.count == 3)
        #expect(enumerated[0].offset == 0)
        #expect(enumerated[0].element == "john@example.com")
        #expect(enumerated[1].offset == 1)
        #expect(enumerated[1].element == "john.doe@work.com")
    }
    
    // MARK: - Offset Stability
    
    @Test("Offsets remain stable for same collection")
    func testOffsetStability() async throws {
        let numbers = [10, 20, 30, 40, 50]
        
        let firstPass = Array(numbers.enumerated())
        let secondPass = Array(numbers.enumerated())
        
        #expect(firstPass.count == secondPass.count)
        
        for (first, second) in zip(firstPass, secondPass) {
            #expect(first.offset == second.offset)
            #expect(first.element == second.element)
        }
    }
    
    @Test("Offsets are sequential integers starting at 0")
    func testOffsetSequence() async throws {
        let items = ["A", "B", "C", "D", "E"]
        let enumerated = Array(items.enumerated())
        
        for (index, tuple) in enumerated.enumerated() {
            #expect(tuple.offset == index)
        }
    }
    
    // MARK: - Warning Cases
    
    @Test("Offset IDs become unstable after deletion", .tags(.knownIssue))
    func testOffsetInstabilityAfterDeletion() async throws {
        var items = ["A", "B", "C", "D"]
        let original = Array(items.enumerated())
        
        #expect(original[2].offset == 2)
        #expect(original[2].element == "C")
        
        // Simulate deletion (what would happen in mutable list)
        items.remove(at: 1) // Remove "B"
        let afterDeletion = Array(items.enumerated())
        
        // "C" was at offset 2, now at offset 1
        #expect(afterDeletion[1].offset == 1)
        #expect(afterDeletion[1].element == "C")
        
        // This is why offset IDs are problematic for editable lists
        // SwiftUI would see offset 2 as different identity, causing animation issues
    }
    
    // MARK: - Performance
    
    @Test("enumerated() is efficient for small collections")
    func testPerformanceSmallCollection() async throws {
        let items = Array(repeating: "item", count: 100)
        
        let start = Date()
        _ = Array(items.enumerated())
        let elapsed = Date().timeIntervalSince(start)
        
        // Should complete in microseconds
        #expect(elapsed < 0.001) // Less than 1ms
    }
    
    @Test("enumerated() handles large collections acceptably")
    func testPerformanceLargeCollection() async throws {
        let items = Array(repeating: "item", count: 10_000)
        
        let start = Date()
        _ = Array(items.enumerated())
        let elapsed = Date().timeIntervalSince(start)
        
        // Should complete in reasonable time even for 10k items
        #expect(elapsed < 0.1) // Less than 100ms
    }
}

// MARK: - Tag Extension

extension Tag {
    @Tag static var knownIssue: Self
}
