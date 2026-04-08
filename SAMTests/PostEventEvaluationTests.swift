//
//  PostEventEvaluationTests.swift
//  SAMTests
//
//  Unit tests for the Post-Event Evaluation feature:
//  - ZoomChatParserService: parsing chat transcripts
//  - FeedbackFormParserService: parsing CSV exports
//  - EventEvaluation model: CRUD and relationships
//  - PostEventEvaluationCoordinator: name matching and orchestration
//

import Testing
import Foundation
import SwiftData
@testable import SAM

// MARK: - ZoomChatParserService Tests

@Suite("ZoomChatParserService", .serialized)
struct ZoomChatParserTests {

    @Test("Parses basic Zoom chat format")
    func parseBasicFormat() async throws {
        let chatText = """
        18:33:33\t From Brad Keim : Hello from cloudy Kansas
        18:33:41\t From Sueann Casey : Spokane, WA
        18:34:17\t From Brad Keim : Reacted to "Hello from cloudy Ka..." with 😆
        """

        let (participants, messages) = await ZoomChatParserService.shared.parse(text: chatText)

        #expect(messages.count == 3)
        #expect(participants.count == 2)

        let brad = participants.first { $0.displayName == "Brad Keim" }
        #expect(brad != nil)
        #expect(brad?.messageCount == 1) // reactions don't count as messages
        #expect(brad?.reactionCount == 1)
    }

    @Test("Cleans host marker from names")
    func cleanHostMarker() async {
        let chatText = """
        18:33:33\t From ! Sarah Snyder, sarah-snyder.com : Hello everyone!
        """

        let (participants, _) = await ZoomChatParserService.shared.parse(text: chatText)

        #expect(participants.count == 1)
        #expect(participants.first?.displayName == "Sarah Snyder")
    }

    @Test("Handles multi-line messages")
    func multiLineMessages() async {
        let chatText = """
        18:34:36\t From ! Sarah Snyder : Replying to "Hello from cloudy Ka..."

        Cloudy is the best!
        18:34:49\t From Brad Keim : Next message
        """

        let (_, messages) = await ZoomChatParserService.shared.parse(text: chatText)

        #expect(messages.count == 2)
        let firstMsg = messages.first { $0.participantName == "Sarah Snyder" }
        #expect(firstMsg?.text.contains("Cloudy is the best!") == true)
        #expect(firstMsg?.isReply == true)
    }

    @Test("Detects reactions correctly")
    func detectReactions() async {
        let chatText = """
        18:33:33\t From Kim Okerman : Reacted to "Hello from Sunny Ari..." with 💜
        """

        let (_, messages) = await ZoomChatParserService.shared.parse(text: chatText)

        #expect(messages.count == 1)
        #expect(messages.first?.isReaction == true)
    }

    @Test("Detects questions correctly")
    func detectQuestions() async {
        let chatText = """
        19:04:29\t From Erin Tibbetts : Can you build all those six things, and pay off debt?
        19:14:38\t From Erin Tibbetts : Can I get a life insurance policy now?
        19:22:26\t From Brad Keim : Great seeing you everyone
        """

        let (participants, _) = await ZoomChatParserService.shared.parse(text: chatText)

        let erin = participants.first { $0.displayName == "Erin Tibbetts" }
        #expect(erin?.questionCount == 2)
        #expect(erin?.questions.count == 2)

        let brad = participants.first { $0.displayName == "Brad Keim" }
        #expect(brad?.questionCount == 0)
    }

    @Test("Sorts participants by message count")
    func sortsByMessageCount() async {
        let chatText = """
        18:33:33\t From Alice : Message 1
        18:33:34\t From Alice : Message 2
        18:33:35\t From Alice : Message 3
        18:33:36\t From Bob : Message 1
        """

        let (participants, _) = await ZoomChatParserService.shared.parse(text: chatText)

        #expect(participants.first?.displayName == "Alice")
        #expect(participants.first?.messageCount == 3)
        #expect(participants.last?.displayName == "Bob")
        #expect(participants.last?.messageCount == 1)
    }

    @Test("Handles empty input")
    func emptyInput() async {
        let (participants, messages) = await ZoomChatParserService.shared.parse(text: "")

        #expect(participants.isEmpty)
        #expect(messages.isEmpty)
    }

    @Test("Parses real-world Sarah Snyder chat format")
    func realWorldChat() async {
        let chatText = """
        18:33:33\t From ! Sarah Snyder, sarah-snyder.com : Reacted to "You Ladies always ha..." with 💜
        18:33:41\t From Loretta Omland / Lorettaomland.com : Hello from Sunny Arizona
        18:44:36\t From Sueann Casey : 2
        18:44:43\t From Erin Tibbetts : 2
        18:44:50\t From Kim Okerman : 3
        18:44:51\t From !Alicia Lang : ensuring I never run out of $ in retirement
        19:22:26\t From Erin Tibbetts : Can I get a life insurance policy now?
        19:23:30\t From ! Sarah Snyder, sarah-snyder.com : https://forms.gle/1QHpgXe9qhY6k7Mj6
        19:24:26\t From Loretta Omland / Lorettaomland.com : Super helpful info!!!
        19:29:00\t From Erin Tibbetts : Replying to "Can I get a life ins…"
        Yes please
        """

        let (participants, messages) = await ZoomChatParserService.shared.parse(text: chatText)

        // Should find all unique participants
        let names = Set(participants.map(\.displayName))
        #expect(names.contains("Sarah Snyder"))
        #expect(names.contains("Erin Tibbetts"))
        #expect(names.contains("Alicia Lang"))
        #expect(names.contains("Kim Okerman"))
        // Loretta with URL should be cleaned
        let loretta = participants.first { $0.displayName.contains("Loretta") }
        #expect(loretta != nil)

        // Erin asked at least 1 question
        let erin = participants.first { $0.displayName == "Erin Tibbetts" }
        #expect(erin != nil)
        #expect(erin!.questionCount >= 1)

        // Should have parsed all messages
        #expect(messages.count == 10)
    }
}

// MARK: - FeedbackFormParserService Tests

@Suite("FeedbackFormParserService", .serialized)
struct FeedbackFormParserTests {

    @Test("Parses basic CSV format")
    func parseBasicCSV() async {
        let csv = """
        Timestamp,Name,Email,Rating
        2026-03-31,John Doe,john@test.com,Helpful
        2026-03-31,Jane Smith,jane@test.com,Extremely valuable
        """

        let (headers, rows) = await FeedbackFormParserService.shared.parse(text: csv)

        #expect(headers.count == 4)
        #expect(headers.contains("Name"))
        #expect(rows.count == 2)
        #expect(rows[0].values["Name"] == "John Doe")
        #expect(rows[1].values["Email"] == "jane@test.com")
    }

    @Test("Handles quoted fields with commas")
    func quotedFields() async {
        let csv = """
        Name,Response
        "Smith, John","I liked it, very much"
        """

        let (_, rows) = await FeedbackFormParserService.shared.parse(text: csv)

        #expect(rows.count == 1)
        // The CSV parser should handle quoted fields
        #expect(rows[0].values.values.contains(where: { $0.contains("liked") }))
    }

    @Test("Maps responses with column mapping")
    func mapResponses() async {
        let csv = """
        Name,Email,Overall,Continue
        Erin Tibbetts,erin@test.com,Extremely valuable,Yes — I'd like to schedule a conversation
        Brad Keim,brad@test.com,Helpful,Not right now
        """

        let (_, rows) = await FeedbackFormParserService.shared.parse(text: csv)

        var mapping = FeedbackColumnMapping()
        mapping.nameColumn = "Name"
        mapping.emailColumn = "Email"
        mapping.overallRatingColumn = "Overall"
        mapping.wouldContinueColumn = "Continue"

        let responses = await FeedbackFormParserService.shared.mapResponses(rows: rows, mapping: mapping)

        #expect(responses.count == 2)

        let erin = responses.first { $0.respondentName == "Erin Tibbetts" }
        #expect(erin != nil)
        #expect(erin?.overallRating == .extremelyValuable)
        #expect(erin?.wouldContinue == .yes)

        let brad = responses.first { $0.respondentName == "Brad Keim" }
        #expect(brad != nil)
        #expect(brad?.overallRating == .helpful)
        #expect(brad?.wouldContinue == .notNow)
    }

    @Test("Handles empty CSV")
    func emptyCSV() async {
        let (headers, rows) = await FeedbackFormParserService.shared.parse(text: "")
        #expect(headers.isEmpty)
        #expect(rows.isEmpty)
    }

    @Test("Handles areas to strengthen multi-select")
    func areasToStrengthen() async {
        let csv = """
        Name,Areas
        John,Cash flow & monthly stability;Debt management;Building wealth
        """

        let (_, rows) = await FeedbackFormParserService.shared.parse(text: csv)

        var mapping = FeedbackColumnMapping()
        mapping.nameColumn = "Name"
        mapping.areasToStrengthenColumn = "Areas"

        let responses = await FeedbackFormParserService.shared.mapResponses(rows: rows, mapping: mapping)

        #expect(responses.count == 1)
        #expect(responses.first?.areasToStrengthen.count == 3)
        #expect(responses.first?.areasToStrengthen.contains("Cash flow & monthly stability") == true)
    }

    @Test("Fuzzy matches rating values")
    func fuzzyRatingMatch() async {
        let csv = """
        Name,Rating
        A,Extremely valuable
        B,Helpful
        C,Neutral
        D,Not helpful
        """

        let (_, rows) = await FeedbackFormParserService.shared.parse(text: csv)

        var mapping = FeedbackColumnMapping()
        mapping.nameColumn = "Name"
        mapping.overallRatingColumn = "Rating"

        let responses = await FeedbackFormParserService.shared.mapResponses(rows: rows, mapping: mapping)

        #expect(responses[0].overallRating == .extremelyValuable)
        #expect(responses[1].overallRating == .helpful)
        #expect(responses[2].overallRating == .neutral)
        #expect(responses[3].overallRating == .notHelpful)
    }
}

// MARK: - EventEvaluation Model Tests

@Suite("EventEvaluation Model", .serialized)
@MainActor
struct EventEvaluationModelTests {

    @Test("Create evaluation linked to event")
    func createEvaluation() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let context = ModelContext(container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop Test",
            format: .virtual,
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600)
        )

        let evaluation = EventEvaluation(event: event)
        context.insert(evaluation)
        try context.save()

        #expect(evaluation.status == .pending)
        #expect(evaluation.totalAttendeeCount == 0)
        #expect(evaluation.participantAnalyses.isEmpty)
        #expect(evaluation.feedbackResponses.isEmpty)
    }

    @Test("ChatParticipantAnalysis Codable round-trip")
    func participantAnalysisCodable() throws {
        let analysis = ChatParticipantAnalysis(
            displayName: "Erin Tibbetts",
            matchedPersonID: UUID(),
            messageCount: 8,
            reactionCount: 3,
            engagementLevel: .high,
            questionsAsked: ["Can I get life insurance?", "Can we build all six?"],
            topicInterests: ["life insurance", "debt management"],
            sentiment: "positive",
            conversionSignals: ["requested life insurance help"],
            inferredRole: .attendee
        )

        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(ChatParticipantAnalysis.self, from: data)

        #expect(decoded.displayName == "Erin Tibbetts")
        #expect(decoded.messageCount == 8)
        #expect(decoded.engagementLevel == .high)
        #expect(decoded.questionsAsked.count == 2)
        #expect(decoded.conversionSignals.first == "requested life insurance help")
        #expect(decoded.inferredRole == .attendee)
    }

    @Test("FeedbackResponse Codable round-trip")
    func feedbackResponseCodable() throws {
        let response = FeedbackResponse(
            respondentName: "Maureen Desmond",
            respondentEmail: "maureen@test.com",
            mostHelpful: "Compound interest explanation",
            areasToStrengthen: ["Retirement planning", "Debt management"],
            overallRating: .extremelyValuable,
            wouldContinue: .yes,
            currentSituation: "Primarily employed"
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(FeedbackResponse.self, from: data)

        #expect(decoded.respondentName == "Maureen Desmond")
        #expect(decoded.overallRating == .extremelyValuable)
        #expect(decoded.wouldContinue == .yes)
        #expect(decoded.wouldContinue?.isWarmLead == true)
        #expect(decoded.areasToStrengthen.count == 2)
    }

    @Test("FeedbackColumnMapping Codable round-trip")
    func columnMappingCodable() throws {
        var mapping = FeedbackColumnMapping()
        mapping.nameColumn = "Full Name"
        mapping.emailColumn = "Email Address"
        mapping.overallRatingColumn = "How did this workshop feel?"
        mapping.wouldContinueColumn = "Would you like to continue?"

        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(FeedbackColumnMapping.self, from: data)

        #expect(decoded.nameColumn == "Full Name")
        #expect(decoded.emailColumn == "Email Address")
        #expect(decoded.overallRatingColumn == "How did this workshop feel?")
        #expect(decoded.phoneColumn == nil)
    }

    @Test("Evaluation stores participant analyses as JSON array")
    func storeParticipantAnalyses() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let context = ModelContext(container)

        let event = try EventRepository.shared.createEvent(
            title: "Storage Test",
            format: .virtual,
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600)
        )

        let evaluation = EventEvaluation(event: event)
        evaluation.participantAnalyses = [
            ChatParticipantAnalysis(displayName: "Alice", messageCount: 5, engagementLevel: .high),
            ChatParticipantAnalysis(displayName: "Bob", messageCount: 2, engagementLevel: .low),
        ]
        evaluation.chatParticipantCount = 2
        context.insert(evaluation)
        try context.save()

        // Re-fetch
        let descriptor = FetchDescriptor<EventEvaluation>()
        let fetched = try context.fetch(descriptor)
        #expect(fetched.count == 1)
        #expect(fetched.first?.participantAnalyses.count == 2)
        #expect(fetched.first?.participantAnalyses.first?.displayName == "Alice")
        #expect(fetched.first?.chatParticipantCount == 2)
    }
}

// MARK: - Enum Tests

@Suite("Evaluation Enums")
struct EvaluationEnumTests {

    @Test("EngagementLevel has correct display names and colors")
    func engagementLevel() {
        #expect(EngagementLevel.high.displayName == "High")
        #expect(EngagementLevel.observer.displayName == "Observer")
        #expect(EngagementLevel.high.color == "green")
        #expect(EngagementLevel.observer.color == "gray")
    }

    @Test("FeedbackRating numeric scores")
    func feedbackRatingScores() {
        #expect(FeedbackRating.extremelyValuable.numericScore == 4.0)
        #expect(FeedbackRating.helpful.numericScore == 3.0)
        #expect(FeedbackRating.neutral.numericScore == 2.0)
        #expect(FeedbackRating.notHelpful.numericScore == 1.0)
    }

    @Test("FollowUpInterest warm lead detection")
    func followUpInterest() {
        #expect(FollowUpInterest.yes.isWarmLead == true)
        #expect(FollowUpInterest.maybe.isWarmLead == false)
        #expect(FollowUpInterest.notNow.isWarmLead == false)
    }

    @Test("EvaluationStatus display names")
    func evaluationStatus() {
        #expect(EvaluationStatus.pending.displayName == "Pending")
        #expect(EvaluationStatus.complete.displayName == "Complete")
        #expect(EvaluationStatus.failed.icon == "exclamationmark.triangle")
    }

    @Test("InferredEventRole display names")
    func inferredEventRole() {
        #expect(InferredEventRole.host.displayName == "Host")
        #expect(InferredEventRole.cohost.displayName == "Co-host")
        #expect(InferredEventRole.attendee.displayName == "Attendee")
    }

    @Test("EvidenceSource.zoomChat properties")
    func zoomChatEvidenceSource() {
        let source = EvidenceSource.zoomChat
        #expect(source.displayName == "Zoom Chat")
        #expect(source.iconName == "bubble.left.and.text.bubble.right")
        #expect(source.qualityWeight == 1.0)
        #expect(source.isInteraction == true)
        #expect(source.isDirectional == false)
    }
}

// MARK: - EventEvaluationAnalysisService Tests

@Suite("EventEvaluationAnalysisService", .serialized)
struct EventEvaluationAnalysisTests {

    @Test("Deterministic engagement scoring - high engagement")
    func highEngagement() async throws {
        let analysis = ChatParticipantAnalysis(
            displayName: "Erin",
            messageCount: 8,
            reactionCount: 3,
            questionsAsked: ["Can I get life insurance?", "Can we build all six?"]
        )

        let result = try await EventEvaluationAnalysisService.shared.analyzeParticipant(analysis)
        #expect(result.engagementLevel == .high)
    }

    @Test("Deterministic engagement scoring - medium engagement")
    func mediumEngagement() async throws {
        let analysis = ChatParticipantAnalysis(
            displayName: "Brad",
            messageCount: 3,
            reactionCount: 2,
            questionsAsked: ["How does that work?"]
        )

        let result = try await EventEvaluationAnalysisService.shared.analyzeParticipant(analysis)
        #expect(result.engagementLevel == .medium)
    }

    @Test("Deterministic engagement scoring - low engagement")
    func lowEngagement() async throws {
        let analysis = ChatParticipantAnalysis(
            displayName: "Observer",
            messageCount: 1,
            reactionCount: 0
        )

        let result = try await EventEvaluationAnalysisService.shared.analyzeParticipant(analysis)
        #expect(result.engagementLevel == .low)
    }

    @Test("Deterministic engagement scoring - observer (no messages)")
    func observerEngagement() async throws {
        let analysis = ChatParticipantAnalysis(
            displayName: "Silent",
            messageCount: 0,
            reactionCount: 0
        )

        let result = try await EventEvaluationAnalysisService.shared.analyzeParticipant(analysis)
        #expect(result.engagementLevel == .observer)
    }
}
