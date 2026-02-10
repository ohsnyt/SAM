//
//  ContactDTO.swift
//  SAM
//
//  Created on February 9, 2026.
//  Phase B: Services Layer - Data Transfer Object for CNContact
//

import Foundation
import Contacts

/// Sendable wrapper for CNContact data that can cross actor boundaries
/// This is what Views receive instead of raw CNContact objects
struct ContactDTO: Sendable, Identifiable {
    let id: String
    let identifier: String
    let givenName: String
    let familyName: String
    let nickname: String
    let organizationName: String
    let departmentName: String
    let jobTitle: String
    let phoneNumbers: [PhoneNumberDTO]
    let emailAddresses: [String]
    let postalAddresses: [PostalAddressDTO]
    let birthday: DateComponents?
    let note: String
    let imageData: Data?
    let thumbnailImageData: Data?
    let contactRelations: [RelationDTO]
    let socialProfiles: [SocialProfileDTO]
    let instantMessageAddresses: [InstantMessageDTO]
    let urlAddresses: [String]
    
    var displayName: String {
        let components = PersonNameComponents(
            givenName: givenName.isEmpty ? nil : givenName,
            familyName: familyName.isEmpty ? nil : familyName
        )
        let formatted = components.formatted(.name(style: .long))
        
        if formatted.isEmpty {
            return organizationName.isEmpty ? "Unknown" : organizationName
        }
        return formatted
    }
    
    var initials: String {
        let first = givenName.first.map(String.init) ?? ""
        let last = familyName.first.map(String.init) ?? ""
        let combined = first + last
        return combined.isEmpty ? "?" : combined
    }
}

// MARK: - Nested DTOs

extension ContactDTO {
    struct PhoneNumberDTO: Sendable, Identifiable {
        let id = UUID()
        let label: String?
        let number: String
    }
    
    struct PostalAddressDTO: Sendable, Identifiable {
        let id = UUID()
        let label: String?
        let street: String
        let city: String
        let state: String
        let postalCode: String
        let country: String
        
        var formattedAddress: String {
            [street, city, state, postalCode, country]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
    }
    
    struct RelationDTO: Sendable, Identifiable {
        let id = UUID()
        let label: String?
        let name: String
    }
    
    struct SocialProfileDTO: Sendable, Identifiable {
        let id = UUID()
        let service: String
        let username: String
        let urlString: String?
    }
    
    struct InstantMessageDTO: Sendable, Identifiable {
        let id = UUID()
        let service: String
        let username: String
    }
}

// MARK: - CNContact Conversion

extension ContactDTO {
    /// Creates a DTO from a CNContact
    /// This is the ONLY place in the codebase where we read CNContact properties
    init(from contact: CNContact) {
        self.id = contact.identifier
        self.identifier = contact.identifier
        self.givenName = contact.givenName
        self.familyName = contact.familyName
        self.nickname = contact.nickname
        self.organizationName = contact.organizationName
        self.departmentName = contact.departmentName
        self.jobTitle = contact.jobTitle
        
        self.phoneNumbers = contact.phoneNumbers.map { phone in
            PhoneNumberDTO(
                label: phone.label.flatMap { CNLabeledValue<NSString>.localizedString(forLabel: $0) },
                number: phone.value.stringValue
            )
        }
        
        self.emailAddresses = contact.emailAddresses.map { $0.value as String }
        
        self.postalAddresses = contact.postalAddresses.map { address in
            let postal = address.value
            return PostalAddressDTO(
                label: address.label.flatMap { CNLabeledValue<NSString>.localizedString(forLabel: $0) },
                street: postal.street,
                city: postal.city,
                state: postal.state,
                postalCode: postal.postalCode,
                country: postal.country
            )
        }
        
        self.birthday = contact.birthday
        self.note = contact.note
        self.imageData = contact.imageData
        self.thumbnailImageData = contact.thumbnailImageData
        
        self.contactRelations = contact.contactRelations.map { relation in
            RelationDTO(
                label: relation.label.flatMap { CNLabeledValue<NSString>.localizedString(forLabel: $0) },
                name: relation.value.name
            )
        }
        
        self.socialProfiles = contact.socialProfiles.map { profile in
            let social = profile.value
            return SocialProfileDTO(
                service: social.service,
                username: social.username,
                urlString: social.urlString
            )
        }
        
        self.instantMessageAddresses = contact.instantMessageAddresses.map { im in
            InstantMessageDTO(
                service: im.value.service,
                username: im.value.username
            )
        }
        
        self.urlAddresses = contact.urlAddresses.map { $0.value as String }
    }
}

// MARK: - CNContact Key Sets

extension ContactDTO {
    /// Predefined sets of CNContact keys for different use cases
    /// This ensures we always fetch exactly what we need
    enum KeySet {
        case minimal    // For lists: name, image thumbnail
        case detail     // For detail view: everything except relations
        case full       // Everything including relations
        
        var keys: [CNKeyDescriptor] {
            switch self {
            case .minimal:
                return [
                    CNContactIdentifierKey,
                    CNContactGivenNameKey,
                    CNContactFamilyNameKey,
                    CNContactNicknameKey,
                    CNContactOrganizationNameKey,
                    CNContactThumbnailImageDataKey
                ] as [CNKeyDescriptor]
                
            case .detail:
                return [
                    CNContactIdentifierKey,
                    CNContactGivenNameKey,
                    CNContactFamilyNameKey,
                    CNContactNicknameKey,
                    CNContactOrganizationNameKey,
                    CNContactDepartmentNameKey,
                    CNContactJobTitleKey,
                    CNContactPhoneNumbersKey,
                    CNContactEmailAddressesKey,
                    CNContactPostalAddressesKey,
                    CNContactBirthdayKey,
                    CNContactNoteKey,
                    CNContactImageDataKey,
                    CNContactThumbnailImageDataKey,
                    CNContactSocialProfilesKey,
                    CNContactInstantMessageAddressesKey,
                    CNContactUrlAddressesKey
                ] as [CNKeyDescriptor]
                
            case .full:
                return [
                    CNContactIdentifierKey,
                    CNContactGivenNameKey,
                    CNContactFamilyNameKey,
                    CNContactNicknameKey,
                    CNContactOrganizationNameKey,
                    CNContactDepartmentNameKey,
                    CNContactJobTitleKey,
                    CNContactPhoneNumbersKey,
                    CNContactEmailAddressesKey,
                    CNContactPostalAddressesKey,
                    CNContactBirthdayKey,
                    CNContactNoteKey,
                    CNContactImageDataKey,
                    CNContactThumbnailImageDataKey,
                    CNContactContactRelationsKey,
                    CNContactSocialProfilesKey,
                    CNContactInstantMessageAddressesKey,
                    CNContactUrlAddressesKey
                ] as [CNKeyDescriptor]
            }
        }
    }
}
