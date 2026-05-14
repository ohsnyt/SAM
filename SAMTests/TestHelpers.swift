//
//  TestHelpers.swift
//  SAMTests
//
//  Shared test infrastructure for repository unit tests.
//

import Foundation
import SwiftData
@testable import SAM

// MARK: - In-Memory Container

/// Creates an in-memory SwiftData ModelContainer for test isolation.
/// `cloudKitDatabase: .none` matches the production app — without it,
/// SwiftData/CoreData defaults to CloudKit integration which demands
/// every relationship have an explicit inverse, exploding the load with
/// a long list of cross-model warnings (`SwiftDataError.loadIssueModelContainer`).
func makeTestContainer() throws -> ModelContainer {
    let schema = Schema(SAMSchema.allModels)
    let config = ModelConfiguration(
        "TestStore",
        schema: schema,
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: config)
}

/// Configures all repository singletons with the given container.
@MainActor
func configureAllRepositories(with container: ModelContainer) {
    PeopleRepository.shared.configure(container: container)
    EvidenceRepository.shared.configure(container: container)
    ContextsRepository.shared.configure(container: container)
    NotesRepository.shared.configure(container: container)
    OutcomeRepository.shared.configure(container: container)
    PipelineRepository.shared.configure(container: container)
    ProductionRepository.shared.configure(container: container)
    GoalRepository.shared.configure(container: container)
    IntentionalTouchRepository.shared.configure(container: container)
    InsightGenerator.shared.configure(container: container)
    DailyBriefingCoordinator.shared.configure(container: container)
    UndoRepository.shared.configure(container: container)
    ContentPostRepository.shared.configure(container: container)
    DeducedRelationRepository.shared.configure(container: container)
    ComplianceAuditRepository.shared.configure(container: container)
    EventRepository.shared.configure(container: container)
    RoleRecruitingRepository.shared.configure(container: container)
    SphereRepository.shared.configure(container: container)
}

// MARK: - DTO Factories

/// Creates a ContactDTO with sensible defaults.
func makeContactDTO(
    identifier: String = UUID().uuidString,
    givenName: String = "Test",
    familyName: String = "Person",
    emailAddresses: [String] = [],
    phoneNumbers: [ContactDTO.PhoneNumberDTO] = [],
    nickname: String = "",
    organizationName: String = "",
    departmentName: String = "",
    jobTitle: String = "",
    postalAddresses: [ContactDTO.PostalAddressDTO] = [],
    birthday: DateComponents? = nil,
    dates: [ContactDTO.DateDTO] = [],
    imageData: Data? = nil,
    thumbnailImageData: Data? = nil,
    contactRelations: [ContactDTO.RelationDTO] = [],
    socialProfiles: [ContactDTO.SocialProfileDTO] = [],
    instantMessageAddresses: [ContactDTO.InstantMessageDTO] = [],
    urlAddresses: [String] = []
) -> ContactDTO {
    ContactDTO(
        id: identifier,
        identifier: identifier,
        givenName: givenName,
        familyName: familyName,
        nickname: nickname,
        organizationName: organizationName,
        departmentName: departmentName,
        jobTitle: jobTitle,
        phoneNumbers: phoneNumbers,
        emailAddresses: emailAddresses,
        postalAddresses: postalAddresses,
        birthday: birthday,
        imageData: imageData,
        thumbnailImageData: thumbnailImageData,
        dates: dates,
        contactRelations: contactRelations,
        socialProfiles: socialProfiles,
        instantMessageAddresses: instantMessageAddresses,
        urlAddresses: urlAddresses
    )
}

/// Creates an EventDTO with sensible defaults for testing.
func makeEventDTO(
    identifier: String = UUID().uuidString,
    calendarIdentifier: String = "test-calendar",
    title: String = "Test Meeting",
    location: String? = nil,
    notes: String? = nil,
    startDate: Date = Date(),
    endDate: Date = Date().addingTimeInterval(3600),
    isAllDay: Bool = false,
    status: EventDTO.EventStatus = .confirmed,
    availability: EventDTO.EventAvailability = .busy,
    attendees: [EventDTO.AttendeeDTO] = [],
    organizer: EventDTO.AttendeeDTO? = nil,
    hasRecurrenceRules: Bool = false,
    isDetached: Bool = false,
    creationDate: Date? = nil,
    lastModifiedDate: Date? = nil,
    url: URL? = nil
) -> EventDTO {
    EventDTO(
        identifier: identifier,
        calendarIdentifier: calendarIdentifier,
        title: title,
        location: location,
        notes: notes,
        startDate: startDate,
        endDate: endDate,
        isAllDay: isAllDay,
        status: status,
        availability: availability,
        attendees: attendees,
        organizer: organizer,
        hasRecurrenceRules: hasRecurrenceRules,
        isDetached: isDetached,
        creationDate: creationDate,
        lastModifiedDate: lastModifiedDate,
        url: url
    )
}

/// Creates an AttendeeDTO with sensible defaults for testing.
func makeAttendeeDTO(
    name: String? = "Test Attendee",
    email: String? = "attendee@test.com",
    isCurrentUser: Bool = false,
    participantStatus: EventDTO.AttendeeDTO.ParticipantStatus = .accepted,
    participantRole: EventDTO.AttendeeDTO.ParticipantRole = .required,
    participantType: EventDTO.AttendeeDTO.ParticipantType = .person
) -> EventDTO.AttendeeDTO {
    EventDTO.AttendeeDTO(
        name: name,
        emailAddress: email,
        participantStatus: participantStatus,
        participantRole: participantRole,
        participantType: participantType,
        isCurrentUser: isCurrentUser
    )
}
