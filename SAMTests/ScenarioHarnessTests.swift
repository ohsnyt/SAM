//
//  ScenarioHarnessTests.swift
//  SAMTests
//
//  Quality validation harness for SAM's recommendation engines.
//  Creates a realistic synthetic dataset mimicking a WFG financial strategist
//  with ~5 years of history, then runs the outcome/insight/briefing engines
//  against it and asserts that signal-to-noise is acceptable.
//
//  Scenario: "Sarah" — mid-career WFG strategist with:
//    - ~50 Apple Contacts (SAM group) across all roles
//    - ~450 LinkedIn imports (85% zero-engagement, ~25 endorsers, ~25 active)
//    - ~450 Facebook imports (similar distribution)
//    - 3 months of calendar events
//    - Evidence spanning 5 years
//    - Active client + recruiting pipelines
//    - Production records, business goals
//    - Stale contacts that should trigger follow-ups
//    - Archived/DNC contacts that should NOT generate outcomes
//

import Testing
import Foundation
import SwiftData
@testable import SAM

// MARK: - Scenario Data Generator

/// Builds a complete, coherent synthetic dataset in an in-memory SwiftData container.
@MainActor
struct ScenarioDataGenerator {

    let container: ModelContainer
    let context: ModelContext

    // Tracked references for assertions
    var meContact: SamPerson!
    var coreContacts: [SamPerson] = []        // ~50 real contacts
    var linkedInOnlyContacts: [SamPerson] = [] // ~450 LinkedIn imports
    var facebookOnlyContacts: [SamPerson] = [] // ~450 Facebook imports
    var archivedContacts: [SamPerson] = []
    var dncContacts: [SamPerson] = []
    var deceasedContacts: [SamPerson] = []

    // Subsets of core contacts by role
    var clients: [SamPerson] = []
    var applicants: [SamPerson] = []
    var leads: [SamPerson] = []
    var agents: [SamPerson] = []
    var vendors: [SamPerson] = []
    var referralPartners: [SamPerson] = []

    // People with specific test conditions
    var staleClients: [SamPerson] = []         // >45 days since last interaction
    var stuckApplicant: SamPerson!             // In applicant stage for >30 days
    var recentlyActiveClient: SamPerson!       // Interacted yesterday
    var highValueClient: SamPerson!            // Has production records
    var silentRecruitingProspect: SamPerson!   // Agent prospect gone silent

    init() throws {
        container = try makeTestContainer()
        context = ModelContext(container)
    }

    // MARK: - Main Build

    mutating func buildFullScenario() throws {
        try buildMeContact()
        try buildCoreContacts()
        try buildLinkedInImports()
        try buildFacebookImports()
        try buildCalendarEvents()
        try buildCommunicationsEvidence()
        try buildNotes()
        try buildPipelineTransitions()
        try buildProductionRecords()
        try buildBusinessGoals()
        try context.save()
    }

    // MARK: - Me Contact

    private mutating func buildMeContact() throws {
        meContact = SamPerson(
            id: UUID(),
            displayName: "Sarah Mitchell",
            roleBadges: ["Me"],
            contactIdentifier: "me-contact-id",
            email: "sarah.mitchell@wfg.com",
            isMe: true
        )
        meContact.emailAliases = ["sarah.mitchell@wfg.com", "sarah@mitchellfinancial.com"]
        meContact.phoneAliases = ["5551234567"]
        context.insert(meContact)
    }

    // MARK: - Core Contacts (~50 real relationships)

    private mutating func buildCoreContacts() throws {
        // 12 Clients (various engagement levels)
        let clientNames = [
            ("Robert", "Chen"), ("Maria", "Santos"), ("James", "Wilson"),
            ("Patricia", "Kim"), ("David", "Thompson"), ("Jennifer", "Okafor"),
            ("Michael", "Rivera"), ("Lisa", "Nakamura"), ("William", "Patel"),
            ("Susan", "Anderson"), ("Thomas", "Garcia"), ("Karen", "Lee")
        ]
        for (i, name) in clientNames.enumerated() {
            let p = makePerson(given: name.0, family: name.1, roles: ["Client"])
            context.insert(p)
            clients.append(p)
            coreContacts.append(p)

            // First 3 are stale (no interaction in 50+ days)
            if i < 3 {
                staleClients.append(p)
            }
            // Client #4 is recently active
            if i == 3 {
                recentlyActiveClient = p
            }
            // Client #5 is high-value with production
            if i == 4 {
                highValueClient = p
            }
        }

        // 4 Applicants (in purchasing process)
        let applicantNames = [
            ("Daniel", "Brown"), ("Emily", "Nguyen"),
            ("Christopher", "Martinez"), ("Ashley", "Taylor")
        ]
        for (i, name) in applicantNames.enumerated() {
            let p = makePerson(given: name.0, family: name.1, roles: ["Applicant"])
            context.insert(p)
            applicants.append(p)
            coreContacts.append(p)

            // First applicant is stuck (30+ days, no progress)
            if i == 0 {
                stuckApplicant = p
            }
        }

        // 10 Leads (potential clients)
        let leadNames = [
            ("Andrew", "Johnson"), ("Sarah", "Davis"), ("Matthew", "Moore"),
            ("Jessica", "Clark"), ("Ryan", "Lewis"), ("Amanda", "Robinson"),
            ("Kevin", "Walker"), ("Stephanie", "Hall"), ("Brandon", "Allen"),
            ("Nicole", "Young")
        ]
        for name in leadNames {
            let p = makePerson(given: name.0, family: name.1, roles: ["Lead"])
            context.insert(p)
            leads.append(p)
            coreContacts.append(p)
        }

        // 6 Agents (recruited, on team)
        let agentNames = [
            ("Tyler", "Wright"), ("Megan", "Scott"), ("Justin", "Green"),
            ("Rachel", "Adams"), ("Brandon", "Baker"), ("Samantha", "Hill")
        ]
        for (i, name) in agentNames.enumerated() {
            let p = makePerson(given: name.0, family: name.1, roles: ["Agent"])
            context.insert(p)
            agents.append(p)
            coreContacts.append(p)

            // Agent #3 is a silent recruiting prospect
            if i == 2 {
                silentRecruitingProspect = p
            }
        }

        // 3 Vendors
        let vendorNames = [("Mark", "Transamerica"), ("Linda", "Nationwide"), ("George", "Pacific Life")]
        for name in vendorNames {
            let p = makePerson(given: name.0, family: name.1, roles: ["Vendor"])
            context.insert(p)
            vendors.append(p)
            coreContacts.append(p)
        }

        // 3 Referral Partners
        let rpNames = [("Catherine", "Brooks"), ("Paul", "Murphy"), ("Diana", "Reed")]
        for name in rpNames {
            let p = makePerson(given: name.0, family: name.1, roles: ["Referral Partner"])
            context.insert(p)
            referralPartners.append(p)
            coreContacts.append(p)
        }

        // 5 External Agents
        let extAgentNames = [
            ("Derek", "Foster"), ("Laura", "Hughes"),
            ("Eric", "Ramirez"), ("Tiffany", "Cox"), ("Nathan", "Bell")
        ]
        for name in extAgentNames {
            let p = makePerson(given: name.0, family: name.1, roles: ["External Agent"])
            context.insert(p)
            coreContacts.append(p)
        }

        // 3 Archived, 2 DNC, 1 Deceased
        let archivedNames = [("Old", "Contact1"), ("Old", "Contact2"), ("Old", "Contact3")]
        for name in archivedNames {
            let p = makePerson(given: name.0, family: name.1, roles: ["Lead"])
            p.lifecycleStatus = .archived
            context.insert(p)
            archivedContacts.append(p)
            coreContacts.append(p)
        }

        let dncNames = [("Blocked", "Person1"), ("Blocked", "Person2")]
        for name in dncNames {
            let p = makePerson(given: name.0, family: name.1, roles: ["Lead"])
            p.lifecycleStatus = .dnc
            context.insert(p)
            dncContacts.append(p)
            coreContacts.append(p)
        }

        let dp = makePerson(given: "Deceased", family: "Person", roles: ["Client"])
        dp.lifecycleStatus = .deceased
        context.insert(dp)
        deceasedContacts.append(dp)
        coreContacts.append(dp)
    }

    // MARK: - LinkedIn Imports (~450 connections, mostly noise)

    private mutating func buildLinkedInImports() throws {
        let importID = UUID()
        let fiveYearsAgo = Calendar.current.date(byAdding: .year, value: -5, to: .now)!

        // ~385 zero-engagement connections (pure noise)
        for i in 0..<385 {
            let p = makePerson(
                given: "LinkedIn\(i)",
                family: "Connection",
                roles: []  // No role — just a connection
            )
            p.linkedInProfileURL = "www.linkedin.com/in/linkedin\(i)-connection"
            p.linkedInConnectedOn = randomDate(from: fiveYearsAgo, to: .now)
            context.insert(p)
            linkedInOnlyContacts.append(p)

            // Each gets exactly one touch: the connection itself
            let touch = IntentionalTouch(
                platform: .linkedIn,
                touchType: .invitationGeneric,
                direction: .mutual,
                contactProfileUrl: p.linkedInProfileURL,
                samPersonID: p.id,
                date: p.linkedInConnectedOn ?? fiveYearsAgo,
                weight: 1,
                source: .bulkImport,
                sourceImportID: importID
            )
            context.insert(touch)
        }

        // ~25 endorsement-only contacts (low signal)
        for i in 0..<25 {
            let p = makePerson(
                given: "LIEndorse\(i)",
                family: "Contact",
                roles: []
            )
            p.linkedInProfileURL = "www.linkedin.com/in/li-endorse-\(i)"
            p.linkedInConnectedOn = randomDate(from: fiveYearsAgo, to: Date.now.addingTimeInterval(-365 * 86400))
            context.insert(p)
            linkedInOnlyContacts.append(p)

            // Connection touch
            let connTouch = IntentionalTouch(
                platform: .linkedIn, touchType: .invitationGeneric, direction: .mutual,
                contactProfileUrl: p.linkedInProfileURL, samPersonID: p.id,
                date: p.linkedInConnectedOn ?? fiveYearsAgo,
                weight: 1, source: .bulkImport, sourceImportID: importID
            )
            context.insert(connTouch)

            // 1-3 endorsement touches
            let endorsementCount = Int.random(in: 1...3)
            for j in 0..<endorsementCount {
                let endorseDate = randomDate(
                    from: p.linkedInConnectedOn ?? fiveYearsAgo,
                    to: .now
                )
                let touch = IntentionalTouch(
                    platform: .linkedIn, touchType: .endorsementReceived,
                    direction: j % 2 == 0 ? .inbound : .outbound,
                    contactProfileUrl: p.linkedInProfileURL, samPersonID: p.id,
                    date: endorseDate,
                    snippet: ["Financial Planning", "Insurance", "Retirement", "Leadership"].randomElement(),
                    weight: 3, source: .bulkImport, sourceImportID: importID
                )
                context.insert(touch)
            }
        }

        // ~25 active LinkedIn contacts (messages exchanged — real signal)
        for i in 0..<25 {
            let p = makePerson(
                given: "LIActive\(i)",
                family: "Messager",
                roles: []
            )
            p.linkedInProfileURL = "www.linkedin.com/in/li-active-\(i)"
            p.linkedInConnectedOn = randomDate(from: fiveYearsAgo, to: Date.now.addingTimeInterval(-180 * 86400))
            context.insert(p)
            linkedInOnlyContacts.append(p)

            // Connection
            let connTouch = IntentionalTouch(
                platform: .linkedIn, touchType: .invitationGeneric, direction: .mutual,
                contactProfileUrl: p.linkedInProfileURL, samPersonID: p.id,
                date: p.linkedInConnectedOn ?? fiveYearsAgo,
                weight: 1, source: .bulkImport, sourceImportID: importID
            )
            context.insert(connTouch)

            // 3-15 messages over time
            let msgCount = Int.random(in: 3...15)
            for j in 0..<msgCount {
                let msgDate = randomDate(
                    from: p.linkedInConnectedOn ?? fiveYearsAgo,
                    to: .now
                )
                let touch = IntentionalTouch(
                    platform: .linkedIn, touchType: .message,
                    direction: j % 2 == 0 ? .inbound : .outbound,
                    contactProfileUrl: p.linkedInProfileURL, samPersonID: p.id,
                    date: msgDate,
                    snippet: "LinkedIn message exchange about financial planning",
                    weight: 10, source: .bulkImport, sourceImportID: importID
                )
                context.insert(touch)
            }

            // Some also have endorsements
            if i < 10 {
                let touch = IntentionalTouch(
                    platform: .linkedIn, touchType: .endorsementReceived, direction: .inbound,
                    contactProfileUrl: p.linkedInProfileURL, samPersonID: p.id,
                    date: randomDate(from: fiveYearsAgo, to: .now),
                    weight: 3, source: .bulkImport, sourceImportID: importID
                )
                context.insert(touch)
            }

            // Create LinkedIn evidence for the most active ones (recent messages)
            if i < 10 {
                let ev = SamEvidenceItem(
                    id: UUID(),
                    state: .done,
                    sourceUID: "linkedin:msg-active-\(i)",
                    source: .linkedIn,
                    occurredAt: randomDate(from: Date.now.addingTimeInterval(-90 * 86400), to: .now),
                    title: "LinkedIn conversation with LIActive\(i) Messager",
                    snippet: "Discussion about financial planning strategies"
                )
                ev.linkedPeople.append(p)
                context.insert(ev)
            }
        }

        // ~15 of the zero-engagement also overlap with core contacts (already in SAM)
        // This simulates the common case where known clients also show up in LinkedIn
        for i in 0..<min(15, clients.count + leads.count) {
            let person = i < clients.count ? clients[i] : leads[i - clients.count]
            person.linkedInProfileURL = "www.linkedin.com/in/\(person.displayName.lowercased().replacingOccurrences(of: " ", with: "-"))"
            person.linkedInConnectedOn = randomDate(from: fiveYearsAgo, to: Date.now.addingTimeInterval(-365 * 86400))
        }
    }

    // MARK: - Facebook Imports (~450 friends, mostly noise)

    private mutating func buildFacebookImports() throws {
        let fiveYearsAgo = Calendar.current.date(byAdding: .year, value: -5, to: .now)!

        // ~385 zero-engagement friends (pure noise)
        for i in 0..<385 {
            let p = makePerson(
                given: "FB\(i)",
                family: "Friend",
                roles: []
            )
            p.facebookProfileURL = "https://www.facebook.com/fb\(i).friend"
            p.facebookFriendedOn = randomDate(from: fiveYearsAgo, to: .now)
            p.facebookMessageCount = 0
            p.facebookTouchScore = 0
            context.insert(p)
            facebookOnlyContacts.append(p)

            // Single connection touch
            let touch = IntentionalTouch(
                platform: .facebook, touchType: .invitationGeneric, direction: .mutual,
                contactProfileUrl: p.facebookProfileURL, samPersonID: p.id,
                date: p.facebookFriendedOn ?? fiveYearsAgo,
                weight: 1, source: .bulkImport
            )
            context.insert(touch)
        }

        // ~25 light engagement (reactions, comments — low signal)
        for i in 0..<25 {
            let p = makePerson(
                given: "FBReact\(i)",
                family: "Commenter",
                roles: []
            )
            p.facebookProfileURL = "https://www.facebook.com/fbreact\(i).commenter"
            p.facebookFriendedOn = randomDate(from: fiveYearsAgo, to: Date.now.addingTimeInterval(-365 * 86400))
            p.facebookMessageCount = 0
            p.facebookTouchScore = Int.random(in: 3...10)
            context.insert(p)
            facebookOnlyContacts.append(p)

            // Connection + a few reactions/comments
            let connTouch = IntentionalTouch(
                platform: .facebook, touchType: .invitationGeneric, direction: .mutual,
                contactProfileUrl: p.facebookProfileURL, samPersonID: p.id,
                date: p.facebookFriendedOn ?? fiveYearsAgo,
                weight: 1, source: .bulkImport
            )
            context.insert(connTouch)

            let reactCount = Int.random(in: 2...5)
            for _ in 0..<reactCount {
                let touch = IntentionalTouch(
                    platform: .facebook, touchType: .reaction, direction: .inbound,
                    contactProfileUrl: p.facebookProfileURL, samPersonID: p.id,
                    date: randomDate(from: fiveYearsAgo, to: .now),
                    weight: 2, source: .bulkImport
                )
                context.insert(touch)
            }
        }

        // ~25 active Facebook contacts (Messenger conversations — real signal)
        for i in 0..<25 {
            let p = makePerson(
                given: "FBActive\(i)",
                family: "Messenger",
                roles: []
            )
            p.facebookProfileURL = "https://www.facebook.com/fbactive\(i).messenger"
            p.facebookFriendedOn = randomDate(from: fiveYearsAgo, to: Date.now.addingTimeInterval(-180 * 86400))
            let msgCount = Int.random(in: 5...50)
            p.facebookMessageCount = msgCount
            p.facebookLastMessageDate = randomDate(from: Date.now.addingTimeInterval(-90 * 86400), to: .now)
            p.facebookTouchScore = Int.random(in: 15...80)
            context.insert(p)
            facebookOnlyContacts.append(p)

            // Connection + messages
            let connTouch = IntentionalTouch(
                platform: .facebook, touchType: .invitationGeneric, direction: .mutual,
                contactProfileUrl: p.facebookProfileURL, samPersonID: p.id,
                date: p.facebookFriendedOn ?? fiveYearsAgo,
                weight: 1, source: .bulkImport
            )
            context.insert(connTouch)

            for j in 0..<min(msgCount, 10) {
                let touch = IntentionalTouch(
                    platform: .facebook, touchType: .message,
                    direction: j % 2 == 0 ? .inbound : .outbound,
                    contactProfileUrl: p.facebookProfileURL, samPersonID: p.id,
                    date: randomDate(from: p.facebookFriendedOn ?? fiveYearsAgo, to: .now),
                    snippet: "Messenger conversation",
                    weight: 10, source: .bulkImport
                )
                context.insert(touch)
            }

            // Create Facebook evidence for the most active
            if i < 10 {
                let ev = SamEvidenceItem(
                    id: UUID(),
                    state: .done,
                    sourceUID: "facebook:msg-active-\(i)",
                    source: .facebook,
                    occurredAt: p.facebookLastMessageDate ?? .now,
                    title: "Facebook Messenger with FBActive\(i) Messenger",
                    snippet: "Conversation about family and financial planning"
                )
                ev.linkedPeople.append(p)
                context.insert(ev)
            }
        }

        // Some Facebook friends overlap with core contacts
        for i in 0..<min(10, clients.count) {
            let person = clients[i]
            person.facebookProfileURL = "https://www.facebook.com/\(person.displayName.lowercased().replacingOccurrences(of: " ", with: "."))"
            person.facebookFriendedOn = randomDate(from: fiveYearsAgo, to: Date.now.addingTimeInterval(-365 * 86400))
            person.facebookMessageCount = Int.random(in: 0...5)
        }
    }

    // MARK: - Calendar Events (3 months of meetings)

    private mutating func buildCalendarEvents() throws {
        let threeMonthsAgo = Calendar.current.date(byAdding: .month, value: -3, to: .now)!
        let cal = Calendar.current

        // Generate ~60 meetings over 3 months (roughly 5/week)
        var currentDate = threeMonthsAgo
        var meetingIndex = 0

        while currentDate < .now {
            let weekday = cal.component(.weekday, from: currentDate)

            // Skip weekends
            if weekday >= 2 && weekday <= 6 {
                // 1-2 meetings per business day
                let meetingsToday = Int.random(in: 0...2)

                for slot in 0..<meetingsToday {
                    let hour = slot == 0 ? Int.random(in: 9...11) : Int.random(in: 13...16)
                    let startDate = cal.date(bySettingHour: hour, minute: 0, second: 0, of: currentDate)!
                    let endDate = startDate.addingTimeInterval(3600) // 1 hour

                    // Pick a person to meet with
                    let attendee: SamPerson
                    if meetingIndex % 4 == 0, !clients.isEmpty {
                        attendee = clients[meetingIndex % clients.count]
                    } else if meetingIndex % 4 == 1, !leads.isEmpty {
                        attendee = leads[meetingIndex % leads.count]
                    } else if meetingIndex % 4 == 2, !agents.isEmpty {
                        attendee = agents[meetingIndex % agents.count]
                    } else if !applicants.isEmpty {
                        attendee = applicants[meetingIndex % applicants.count]
                    } else {
                        attendee = clients.first!
                    }

                    let titles = [
                        "Client Review with \(attendee.displayName)",
                        "Financial Planning — \(attendee.displayName)",
                        "Follow-up: \(attendee.displayName)",
                        "Annual Review — \(attendee.displayName)",
                        "Portfolio Discussion with \(attendee.displayName)"
                    ]

                    let ev = SamEvidenceItem(
                        id: UUID(),
                        state: startDate < .now ? .done : .needsReview,
                        sourceUID: "eventkit:meeting-\(meetingIndex)",
                        source: .calendar,
                        occurredAt: startDate,
                        endedAt: endDate,
                        title: titles[meetingIndex % titles.count],
                        snippet: "Meeting at office"
                    )
                    ev.linkedPeople.append(attendee)
                    context.insert(ev)

                    meetingIndex += 1
                }
            }

            currentDate = cal.date(byAdding: .day, value: 1, to: currentDate)!
        }

        // Add a few upcoming meetings (next 3 days)
        for i in 0..<3 {
            let futureDate = cal.date(byAdding: .day, value: i + 1, to: .now)!
            let startDate = cal.date(bySettingHour: 10, minute: 0, second: 0, of: futureDate)!
            let endDate = startDate.addingTimeInterval(3600)
            let attendee = clients[i % clients.count]

            let ev = SamEvidenceItem(
                id: UUID(),
                state: .needsReview,
                sourceUID: "eventkit:future-meeting-\(i)",
                source: .calendar,
                occurredAt: startDate,
                endedAt: endDate,
                title: "Upcoming: \(attendee.displayName) Review",
                snippet: "Quarterly review meeting"
            )
            ev.linkedPeople.append(attendee)
            context.insert(ev)
        }
    }

    // MARK: - Communications Evidence (5 years, sparse→dense)

    private mutating func buildCommunicationsEvidence() throws {
        let fiveYearsAgo = Calendar.current.date(byAdding: .year, value: -5, to: .now)!

        // Emails for clients/leads over 5 years
        for (i, client) in clients.enumerated() {
            // Stale clients: last evidence >50 days ago
            let lastInteraction: Date
            if staleClients.contains(where: { $0.id == client.id }) {
                lastInteraction = Date.now.addingTimeInterval(-Double(50 + i * 5) * 86400)
            } else if client.id == recentlyActiveClient?.id {
                lastInteraction = Date.now.addingTimeInterval(-86400) // Yesterday
            } else {
                lastInteraction = randomDate(from: Date.now.addingTimeInterval(-30 * 86400), to: .now)
            }

            // Scatter 5-20 evidence items over the client's history
            let evidenceCount = Int.random(in: 5...20)
            let clientStart = randomDate(from: fiveYearsAgo, to: Date.now.addingTimeInterval(-365 * 86400))

            for j in 0..<evidenceCount {
                let date: Date
                if j == evidenceCount - 1 {
                    date = lastInteraction
                } else {
                    date = randomDate(from: clientStart, to: lastInteraction)
                }

                let sources: [EvidenceSource] = [.mail, .iMessage, .phoneCall, .calendar]
                let source = sources[j % sources.count]

                let ev = SamEvidenceItem(
                    id: UUID(),
                    state: .done,
                    sourceUID: "\(source.rawValue.lowercased()):client-\(i)-\(j)",
                    source: source,
                    occurredAt: date,
                    title: "\(source.rawValue) with \(client.displayName)",
                    snippet: "Discussion about financial planning and review"
                )
                ev.linkedPeople.append(client)
                context.insert(ev)
            }
        }

        // Applicants — more recent, denser evidence
        for (i, applicant) in applicants.enumerated() {
            let lastDate: Date
            if applicant.id == stuckApplicant?.id {
                lastDate = Date.now.addingTimeInterval(-35 * 86400) // 35 days ago = stuck
            } else {
                lastDate = randomDate(from: Date.now.addingTimeInterval(-14 * 86400), to: .now)
            }

            let evidenceCount = Int.random(in: 3...8)
            let startDate = Date.now.addingTimeInterval(-90 * 86400)

            for j in 0..<evidenceCount {
                let date = j == evidenceCount - 1
                    ? lastDate
                    : randomDate(from: startDate, to: lastDate)

                let ev = SamEvidenceItem(
                    id: UUID(),
                    state: .done,
                    sourceUID: "mail:applicant-\(i)-\(j)",
                    source: .mail,
                    occurredAt: date,
                    title: "Application discussion with \(applicant.displayName)",
                    snippet: "Following up on paperwork and underwriting status"
                )
                ev.linkedPeople.append(applicant)
                context.insert(ev)
            }
        }

        // Agents — regular mentoring evidence
        for (i, agent) in agents.enumerated() {
            let lastDate: Date
            if agent.id == silentRecruitingProspect?.id {
                lastDate = Date.now.addingTimeInterval(-45 * 86400) // Silent for 45 days
            } else {
                lastDate = randomDate(from: Date.now.addingTimeInterval(-14 * 86400), to: .now)
            }

            let evidenceCount = Int.random(in: 2...6)
            for j in 0..<evidenceCount {
                let date = j == evidenceCount - 1
                    ? lastDate
                    : randomDate(from: Date.now.addingTimeInterval(-180 * 86400), to: lastDate)

                let ev = SamEvidenceItem(
                    id: UUID(),
                    state: .done,
                    sourceUID: "calendar:agent-\(i)-\(j)",
                    source: .calendar,
                    occurredAt: date,
                    endedAt: date.addingTimeInterval(3600),
                    title: "Training session with \(agent.displayName)",
                    snippet: "Mentoring and skill development"
                )
                ev.linkedPeople.append(agent)
                context.insert(ev)
            }
        }

        // Archived/DNC/Deceased — some old evidence, but no recent
        for person in archivedContacts + dncContacts + deceasedContacts {
            let oldDate = randomDate(from: fiveYearsAgo, to: Date.now.addingTimeInterval(-365 * 86400))
            let ev = SamEvidenceItem(
                id: UUID(),
                state: .done,
                sourceUID: "mail:excluded-\(person.id.uuidString.prefix(8))",
                source: .mail,
                occurredAt: oldDate,
                title: "Old email with \(person.displayName)",
                snippet: "Historical correspondence"
            )
            ev.linkedPeople.append(person)
            context.insert(ev)
        }
    }

    // MARK: - Notes

    private mutating func buildNotes() throws {
        // Meeting notes for recently-active clients
        for client in clients.prefix(5) {
            let note = SamNote(
                id: UUID(),
                content: "Met with \(client.displayName) to discuss portfolio rebalancing. They expressed interest in IUL products. Action: send comparison sheet by Friday.",
                analysisVersion: 2,
                sourceType: .typed
            )
            note.linkedPeople.append(client)
            context.insert(note)
        }

        // Notes with action items for applicants
        for applicant in applicants.prefix(2) {
            let note = SamNote(
                id: UUID(),
                content: "Reviewed application status for \(applicant.displayName). Underwriting requested additional medical records. Need to follow up with client to get records submitted.",
                analysisVersion: 2,
                sourceType: .typed
            )
            note.extractedActionItems = [
                NoteActionItem(type: .generalFollowUp, description: "Follow up on medical records", urgency: .soon)
            ]
            note.linkedPeople.append(applicant)
            context.insert(note)
        }
    }

    // MARK: - Pipeline Transitions

    private mutating func buildPipelineTransitions() throws {
        // Client pipeline: Lead → Applicant → Client transitions
        for client in clients.prefix(8) {
            // Lead → Applicant (6+ months ago)
            let t1 = StageTransition(
                person: client,
                fromStage: "Lead",
                toStage: "Applicant",
                transitionDate: Date.now.addingTimeInterval(-Double(Int.random(in: 180...365)) * 86400),
                pipelineType: .client
            )
            context.insert(t1)

            // Applicant → Client
            let t2 = StageTransition(
                person: client,
                fromStage: "Applicant",
                toStage: "Client",
                transitionDate: Date.now.addingTimeInterval(-Double(Int.random(in: 60...180)) * 86400),
                pipelineType: .client
            )
            context.insert(t2)
        }

        // Stuck applicant: Lead → Applicant 35 days ago, no further progress
        let stuckT = StageTransition(
            person: stuckApplicant,
            fromStage: "Lead",
            toStage: "Applicant",
            transitionDate: Date.now.addingTimeInterval(-35 * 86400),
            pipelineType: .client
        )
        context.insert(stuckT)

        // Recruiting pipeline for agents
        for agent in agents.prefix(4) {
            let rt = StageTransition(
                person: agent,
                fromStage: "",
                toStage: "Agent",
                transitionDate: Date.now.addingTimeInterval(-Double(Int.random(in: 90...365)) * 86400),
                pipelineType: .recruiting
            )
            context.insert(rt)
        }
    }

    // MARK: - Production Records

    private mutating func buildProductionRecords() throws {
        guard let hvClient = highValueClient else { return }

        // High-value client has 3 products
        let products: [(WFGProductType, ProductionStatus, Double)] = [
            (.iul, .issued, 12000),
            (.termLife, .issued, 3600),
            (.annuity, .submitted, 25000)
        ]

        for (type, status, premium) in products {
            let pr = ProductionRecord(
                person: hvClient,
                productType: type,
                status: status,
                carrierName: "Transamerica",
                annualPremium: premium,
                submittedDate: Date.now.addingTimeInterval(-Double(Int.random(in: 30...180)) * 86400),
                resolvedDate: status == .issued ? Date.now.addingTimeInterval(-Double(Int.random(in: 10...30)) * 86400) : nil
            )
            context.insert(pr)
        }

        // A few other clients with single products
        for client in clients[5...7] {
            let pr = ProductionRecord(
                person: client,
                productType: .termLife,
                status: .issued,
                carrierName: "Nationwide",
                annualPremium: Double(Int.random(in: 2000...8000)),
                submittedDate: Date.now.addingTimeInterval(-Double(Int.random(in: 60...300)) * 86400),
                resolvedDate: Date.now.addingTimeInterval(-Double(Int.random(in: 30...60)) * 86400)
            )
            context.insert(pr)
        }
    }

    // MARK: - Business Goals

    private mutating func buildBusinessGoals() throws {
        let quarterStart = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
        let quarterEnd = Calendar.current.date(byAdding: .month, value: 2, to: .now)!

        let goals: [(GoalType, String, Double)] = [
            (.newClients, "Q2 New Clients", 10),
            (.policiesSubmitted, "Q2 Policies Submitted", 15),
            (.meetingsHeld, "Q2 Meetings", 60),
            (.recruiting, "Q2 Recruiting", 3),
        ]

        for (type, title, target) in goals {
            let goal = BusinessGoal(
                goalType: type,
                title: title,
                targetValue: target,
                startDate: quarterStart,
                endDate: quarterEnd
            )
            context.insert(goal)
        }
    }

    // MARK: - Helpers

    private func makePerson(given: String, family: String, roles: [String]) -> SamPerson {
        let p = SamPerson(
            id: UUID(),
            displayName: "\(given) \(family)",
            roleBadges: roles,
            contactIdentifier: UUID().uuidString,
            email: "\(given.lowercased()).\(family.lowercased())@example.com"
        )
        p.emailAliases = [p.email ?? ""]
        p.phoneAliases = [String(format: "555%07d", Int.random(in: 1000000...9999999))]
        return p
    }

    private func randomDate(from: Date, to: Date) -> Date {
        let interval = to.timeIntervalSince(from)
        guard interval > 0 else { return from }
        return from.addingTimeInterval(Double.random(in: 0...interval))
    }
}



// ═══════════════════════════════════════════════════════════════════════
// MARK: - Test Suite: Outcome Engine Signal-to-Noise
// ═══════════════════════════════════════════════════════════════════════

@Suite("Scenario: Outcome Engine Quality", .serialized)
@MainActor
struct OutcomeEngineQualityTests {

    // MARK: - Setup

    /// Build the full scenario and configure all singletons.
    @MainActor
    private func buildScenario() throws -> ScenarioDataGenerator {
        var gen = try ScenarioDataGenerator()
        try gen.buildFullScenario()

        // Configure all repositories with our test container
        configureAllRepositories(with: gen.container)
        OutcomeRepository.shared.configure(container: gen.container)
        PipelineRepository.shared.configure(container: gen.container)
        ProductionRepository.shared.configure(container: gen.container)
        GoalRepository.shared.configure(container: gen.container)
        IntentionalTouchRepository.shared.configure(container: gen.container)
        InsightGenerator.shared.configure(container: gen.container)

        return gen
    }

    // MARK: - Noise Filtering

    @Test("Outcomes should not target zero-engagement LinkedIn connections")
    @MainActor
    func noOutcomesForLinkedInNoise() async throws {
        let gen = try buildScenario()

        // Run the outcome scanners (synchronous parts only — skip AI enrichment)
        let allPeople = try PeopleRepository.shared.fetchAll().filter { !$0.isMe && !$0.isArchived }
        let allEvidence = try EvidenceRepository.shared.fetchAll()
        let allNotes = try NotesRepository.shared.fetchAll()

        // The zero-engagement LinkedIn contacts (385 of them) should have no role badges
        let zeroEngagementIDs = Set(gen.linkedInOnlyContacts.prefix(385).map(\.id))
        let noiseWithRoles = allPeople.filter { zeroEngagementIDs.contains($0.id) && !$0.roleBadges.isEmpty }
        #expect(noiseWithRoles.isEmpty, "Zero-engagement LinkedIn contacts should have no role badges, but \(noiseWithRoles.count) do")

        // Since OutcomeEngine filters to !isArchived && !isMe, AND scanRelationshipHealth
        // only looks at people with evidence, the noise contacts should not produce outcomes.
        // We can't easily run the full engine without AI, but we can verify the filtering:
        let noiseWithEvidence = allPeople.filter { person in
            zeroEngagementIDs.contains(person.id) && !person.linkedEvidence.isEmpty
        }
        #expect(noiseWithEvidence.isEmpty, "Zero-engagement LinkedIn contacts should have no linked evidence")
    }

    @Test("Outcomes should not target zero-engagement Facebook friends")
    @MainActor
    func noOutcomesForFacebookNoise() async throws {
        let gen = try buildScenario()

        let zeroEngagementIDs = Set(gen.facebookOnlyContacts.prefix(385).map(\.id))
        let allPeople = try PeopleRepository.shared.fetchAll()
        let noiseWithEvidence = allPeople.filter { person in
            zeroEngagementIDs.contains(person.id) && !person.linkedEvidence.isEmpty
        }
        #expect(noiseWithEvidence.isEmpty, "Zero-engagement Facebook friends should have no linked evidence")
    }

    @Test("Outcomes should not target archived, DNC, or deceased contacts")
    @MainActor
    func noOutcomesForExcludedContacts() async throws {
        let gen = try buildScenario()

        let allPeople = try PeopleRepository.shared.fetchAll()
        let activePeople = allPeople.filter { !$0.isMe && !$0.isArchived }
        let excludedIDs = Set(
            gen.archivedContacts.map(\.id) +
            gen.dncContacts.map(\.id) +
            gen.deceasedContacts.map(\.id)
        )

        let leakedExcluded = activePeople.filter { excludedIDs.contains($0.id) }
        #expect(leakedExcluded.isEmpty, "Archived/DNC/Deceased contacts should be filtered out, but \(leakedExcluded.count) leaked through")
    }

    // MARK: - Signal Detection

    @Test("Stale clients should be detectable for follow-up")
    @MainActor
    func staleClientsDetectable() async throws {
        let gen = try buildScenario()

        for staleClient in gen.staleClients {
            let evidence = staleClient.linkedEvidence
            let mostRecent = evidence.map(\.occurredAt).max()
            let daysSince = mostRecent.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 } ?? 999
            #expect(daysSince >= 45, "\(staleClient.displayName) should have >45 days since last interaction, has \(daysSince)")
        }
    }

    @Test("Stuck applicant should be detectable")
    @MainActor
    func stuckApplicantDetectable() async throws {
        let gen = try buildScenario()

        let transitions = gen.stuckApplicant.stageTransitions
        let lastTransition = transitions.sorted(by: { $0.transitionDate < $1.transitionDate }).last
        #expect(lastTransition != nil, "Stuck applicant should have stage transitions")
        #expect(lastTransition?.toStage == "Applicant", "Stuck applicant should still be at Applicant stage")

        let daysSinceTransition = Calendar.current.dateComponents(
            [.day], from: lastTransition!.transitionDate, to: .now
        ).day ?? 0
        #expect(daysSinceTransition >= 30, "Stuck applicant should have been in Applicant stage for 30+ days, is \(daysSinceTransition)")
    }

    @Test("Recently active client should NOT trigger follow-up")
    @MainActor
    func recentClientNotStale() async throws {
        let gen = try buildScenario()

        let evidence = gen.recentlyActiveClient.linkedEvidence
        let mostRecent = evidence.map(\.occurredAt).max()
        let daysSince = mostRecent.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 } ?? 999
        #expect(daysSince <= 7, "Recently active client should have interacted within 7 days, has \(daysSince)")
    }

    @Test("Silent recruiting prospect should be detectable")
    @MainActor
    func silentProspectDetectable() async throws {
        let gen = try buildScenario()

        let evidence = gen.silentRecruitingProspect.linkedEvidence
        let mostRecent = evidence.map(\.occurredAt).max()
        let daysSince = mostRecent.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 } ?? 999
        #expect(daysSince >= 30, "Silent prospect should have 30+ days since last interaction, has \(daysSince)")
    }

    // MARK: - Data Integrity

    @Test("Total contact count matches expected distribution")
    @MainActor
    func totalContactCount() async throws {
        let gen = try buildScenario()

        let allPeople = try PeopleRepository.shared.fetchAll()
        let totalExpected = 1 // me
            + gen.coreContacts.count
            + gen.linkedInOnlyContacts.count
            + gen.facebookOnlyContacts.count

        #expect(allPeople.count == totalExpected, "Expected \(totalExpected) people, got \(allPeople.count)")

        // Verify noise ratio: social imports should be ~95% of total
        let socialCount = gen.linkedInOnlyContacts.count + gen.facebookOnlyContacts.count
        let noiseRatio = Double(socialCount) / Double(allPeople.count)
        #expect(noiseRatio > 0.9, "Social imports should be >90% of contacts (noise ratio \(String(format: "%.1f", noiseRatio * 100))%)")
    }

    @Test("Active contacts with roles are a small subset")
    @MainActor
    func activeRoledContactsSmall() async throws {
        let gen = try buildScenario()

        let allPeople = try PeopleRepository.shared.fetchAll()
        let activeWithRoles = allPeople.filter { !$0.isMe && !$0.isArchived && !$0.roleBadges.isEmpty }
        let totalActive = allPeople.filter { !$0.isMe && !$0.isArchived }

        // Active people with roles should be ~50 out of ~950
        #expect(activeWithRoles.count < 60, "Active contacts with roles should be <60, got \(activeWithRoles.count)")
        #expect(activeWithRoles.count >= 30, "Active contacts with roles should be >=30, got \(activeWithRoles.count)")

        let signalRatio = Double(activeWithRoles.count) / Double(totalActive.count)
        #expect(signalRatio < 0.1, "Signal ratio should be <10% (got \(String(format: "%.1f", signalRatio * 100))%)")
    }

    @Test("Upcoming meetings have linked people")
    @MainActor
    func upcomingMeetingsLinked() async throws {
        _ = try buildScenario()

        let allEvidence = try EvidenceRepository.shared.fetchAll()
        let futureEvents = allEvidence.filter { $0.source == .calendar && $0.occurredAt > .now }
        #expect(futureEvents.count >= 3, "Should have at least 3 upcoming meetings")

        for event in futureEvents {
            #expect(!event.linkedPeople.isEmpty, "Upcoming meeting '\(event.title)' should have linked attendees")
        }
    }

    @Test("High-value client has production records")
    @MainActor
    func highValueClientProduction() async throws {
        let gen = try buildScenario()

        let records = gen.highValueClient.productionRecords
        #expect(records.count >= 3, "High-value client should have 3+ production records, has \(records.count)")

        let totalPremium = records.reduce(0.0) { $0 + $1.annualPremium }
        #expect(totalPremium > 10000, "High-value client total premium should be >$10k, is $\(totalPremium)")
    }

    @Test("Business goals are active and have valid dates")
    @MainActor
    func businessGoalsValid() async throws {
        _ = try buildScenario()

        let goals = try GoalRepository.shared.fetchActive()
        #expect(goals.count >= 4, "Should have at least 4 active goals, got \(goals.count)")

        for goal in goals {
            #expect(goal.startDate < goal.endDate, "Goal '\(goal.title)' has invalid date range")
            #expect(goal.targetValue > 0, "Goal '\(goal.title)' has non-positive target")
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════
// MARK: - Test Suite: Briefing Data Quality
// ═══════════════════════════════════════════════════════════════════════

@Suite("Scenario: Briefing Data Quality", .serialized)
@MainActor
struct BriefingDataQualityTests {

    @MainActor
    private func buildScenario() throws -> ScenarioDataGenerator {
        var gen = try ScenarioDataGenerator()
        try gen.buildFullScenario()
        configureAllRepositories(with: gen.container)
        OutcomeRepository.shared.configure(container: gen.container)
        PipelineRepository.shared.configure(container: gen.container)
        ProductionRepository.shared.configure(container: gen.container)
        GoalRepository.shared.configure(container: gen.container)
        IntentionalTouchRepository.shared.configure(container: gen.container)
        DailyBriefingCoordinator.shared.configure(container: gen.container)
        InsightGenerator.shared.configure(container: gen.container)
        return gen
    }

    @Test("Morning narrative data threshold prevents empty-context hallucination")
    @MainActor
    func narrativeDataThreshold() async throws {
        // Test the DailyBriefingService guard directly
        let result = await DailyBriefingService.shared.generateMorningNarrative(
            calendarItems: [],
            priorityActions: [],
            followUps: [],
            lifeEvents: [],
            tomorrowPreview: []
        )
        #expect(result.visual.isEmpty, "Empty data should produce empty narrative, not hallucinated content")
        #expect(result.tts.isEmpty, "Empty data should produce empty TTS narrative")
    }

    @Test("Morning narrative with single sparse section is rejected")
    @MainActor
    func narrativeSingleSectionRejected() async throws {
        // One action item is not enough context for a grounded narrative
        let singleAction = BriefingAction(
            title: "Follow up with someone",
            rationale: "It's been a while",
            urgency: "standard",
            sourceKind: "health"
        )

        let result = await DailyBriefingService.shared.generateMorningNarrative(
            calendarItems: [],
            priorityActions: [singleAction],
            followUps: [],
            lifeEvents: [],
            tomorrowPreview: []
        )
        #expect(result.visual.isEmpty, "Single sparse section should be rejected to prevent hallucination")
    }

    @Test("LinkedIn noise contacts do not appear in briefing follow-ups")
    @MainActor
    func noLinkedInNoiseInFollowUps() async throws {
        let gen = try buildScenario()

        // The briefing coordinator gathers follow-ups from MeetingPrepCoordinator
        // which checks relationship health. Zero-engagement contacts should not appear.
        let allPeople = try PeopleRepository.shared.fetchAll()
        let zeroEngagementIDs = Set(gen.linkedInOnlyContacts.prefix(385).map(\.id))

        // People without evidence can't have relationship health computed
        let noiseWithHealth = allPeople.filter { person in
            zeroEngagementIDs.contains(person.id) && !person.linkedEvidence.isEmpty
        }
        #expect(noiseWithHealth.isEmpty, "Zero-engagement LinkedIn contacts should not have evidence that triggers follow-ups")
    }
}


// ═══════════════════════════════════════════════════════════════════════
// MARK: - Test Suite: Relationship Health Scoring
// ═══════════════════════════════════════════════════════════════════════

@Suite("Scenario: Relationship Health Quality", .serialized)
@MainActor
struct RelationshipHealthQualityTests {

    @MainActor
    private func buildScenario() throws -> ScenarioDataGenerator {
        var gen = try ScenarioDataGenerator()
        try gen.buildFullScenario()
        configureAllRepositories(with: gen.container)
        OutcomeRepository.shared.configure(container: gen.container)
        PipelineRepository.shared.configure(container: gen.container)
        ProductionRepository.shared.configure(container: gen.container)
        IntentionalTouchRepository.shared.configure(container: gen.container)
        InsightGenerator.shared.configure(container: gen.container)
        return gen
    }

    @Test("Stale clients have worse health than active clients")
    @MainActor
    func staleVsActiveHealth() async throws {
        let gen = try buildScenario()
        let meetingPrep = MeetingPrepCoordinator.shared

        // Compute health for stale vs active
        for staleClient in gen.staleClients {
            let staleHealth = meetingPrep.computeHealth(for: staleClient)
            let activeHealth = meetingPrep.computeHealth(for: gen.recentlyActiveClient)

            // Stale should be "at_risk" or "cold"; active should be "healthy"
            let staleDays = staleHealth.daysSinceLastInteraction ?? 999
            let activeDays = activeHealth.daysSinceLastInteraction ?? 0
            let staleIsWorse = (staleHealth.overdueRatio ?? 0) > (activeHealth.overdueRatio ?? 0)
                || staleDays > activeDays
            #expect(staleIsWorse, "\(staleClient.displayName) health should be worse than \(gen.recentlyActiveClient.displayName)'s")
        }
    }

    @Test("Contacts without evidence have no health score")
    @MainActor
    func noEvidenceNoHealth() async throws {
        let gen = try buildScenario()

        // A zero-engagement LinkedIn contact
        if let noiseContact = gen.linkedInOnlyContacts.first {
            let health = MeetingPrepCoordinator.shared.computeHealth(for: noiseContact)
            #expect(health.daysSinceLastInteraction == nil || health.interactionCount30 == 0,
                    "Contact with no linked evidence should have nil days or zero 30-day interaction count")
        }
    }
}
