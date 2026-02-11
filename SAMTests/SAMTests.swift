//
//  SAMTests.swift
//  SAMTests
//
//  Created by David Snyder on 2/9/26.
//

import XCTest
@testable import SAM

// MARK: - ForEach Pattern Tests

final class ForEachPatternsTests: XCTestCase {
    
    // MARK: - ContactDTO Phone Numbers
    
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
        
        XCTAssertEqual(enumerated.count, 3)
        XCTAssertEqual(enumerated[0].offset, 0)
        XCTAssertEqual(enumerated[0].element.value, "555-1234")
        XCTAssertEqual(enumerated[1].offset, 1)
        XCTAssertEqual(enumerated[1].element.value, "555-5678")
        XCTAssertEqual(enumerated[2].offset, 2)
        XCTAssertEqual(enumerated[2].element.value, "555-9999")
    }
    
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
        
        XCTAssertTrue(enumerated.isEmpty)
    }
    
    // MARK: - ContactDTO Email Addresses
    
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
        
        XCTAssertEqual(enumerated.count, 3)
        XCTAssertEqual(enumerated[0].offset, 0)
        XCTAssertEqual(enumerated[0].element, "john@example.com")
        XCTAssertEqual(enumerated[1].offset, 1)
        XCTAssertEqual(enumerated[1].element, "john.doe@work.com")
    }
    
    // MARK: - Offset Stability
    
    func testOffsetStability() async throws {
        let numbers = [10, 20, 30, 40, 50]
        
        let firstPass = Array(numbers.enumerated())
        let secondPass = Array(numbers.enumerated())
        
        XCTAssertEqual(firstPass.count, secondPass.count)
        
        for (first, second) in zip(firstPass, secondPass) {
            XCTAssertEqual(first.offset, second.offset)
            XCTAssertEqual(first.element, second.element)
        }
    }
    
    func testOffsetSequence() async throws {
        let items = ["A", "B", "C", "D", "E"]
        let enumerated = Array(items.enumerated())
        
        for (index, tuple) in enumerated.enumerated() {
            XCTAssertEqual(tuple.offset, index)
        }
    }
    
    // MARK: - Warning Cases
    
    func testOffsetInstabilityAfterDeletion() async throws {
        // This test documents why offset IDs are problematic for editable lists
        var items = ["A", "B", "C", "D"]
        let original = Array(items.enumerated())
        
        XCTAssertEqual(original[2].offset, 2)
        XCTAssertEqual(original[2].element, "C")
        
        // Simulate deletion (what would happen in mutable list)
        items.remove(at: 1) // Remove "B"
        let afterDeletion = Array(items.enumerated())
        
        // "C" was at offset 2, now at offset 1
        XCTAssertEqual(afterDeletion[1].offset, 1)
        XCTAssertEqual(afterDeletion[1].element, "C")
        
        // SwiftUI would see offset 2 as different identity, causing animation issues
    }
    
    // MARK: - Performance
    
    func testPerformanceSmallCollection() throws {
        let items = Array(repeating: "item", count: 100)
        
        measure {
            _ = Array(items.enumerated())
        }
    }
    
    func testPerformanceLargeCollection() throws {
        let items = Array(repeating: "item", count: 10_000)
        
        measure {
            _ = Array(items.enumerated())
        }
    }
}

// MARK: - Original Placeholder Tests

final class SAMTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }

}
