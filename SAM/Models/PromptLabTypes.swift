//
//  PromptLabTypes.swift
//  SAM
//
//  Created on March 9, 2026.
//  Prompt Lab — Types for prompt variant testing and comparison.
//

import Foundation

// MARK: - Prompt Site

/// Identifies a specific AI prompt location in the codebase.
enum PromptSite: String, CaseIterable, Identifiable, Codable {
    case noteAnalysis       = "Note Analysis"
    case emailAnalysis      = "Email Analysis"
    case messageAnalysis    = "Message Analysis"
    case pipelineAnalyst    = "Pipeline Analyst"
    case timeAnalyst        = "Time Analyst"
    case patternDetector    = "Pattern Detector"
    case contentTopics      = "Content Topics"
    case contentDraft       = "Content Draft"
    case morningBriefing    = "Morning Briefing"
    case eveningBriefing    = "Evening Briefing"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .noteAnalysis:     return "note.text"
        case .emailAnalysis:    return "envelope"
        case .messageAnalysis:  return "message"
        case .pipelineAnalyst:  return "chart.bar"
        case .timeAnalyst:      return "clock"
        case .patternDetector:  return "waveform.path.ecg"
        case .contentTopics:    return "lightbulb"
        case .contentDraft:     return "doc.richtext"
        case .morningBriefing:  return "sunrise"
        case .eveningBriefing:  return "sunset"
        }
    }

    /// Description of what this prompt does.
    var siteDescription: String {
        switch self {
        case .noteAnalysis:     return "Extracts structured data (people, topics, action items, life events) from advisor notes."
        case .emailAnalysis:    return "Extracts intelligence (entities, topics, sentiment) from professional emails."
        case .messageAnalysis:  return "Extracts structured data from iMessage conversation threads."
        case .pipelineAnalyst:  return "Analyzes pipeline health and generates strategic recommendations."
        case .timeAnalyst:      return "Analyzes time allocation and suggests work-life balance improvements."
        case .patternDetector:  return "Identifies behavioral patterns and correlations in relationship data."
        case .contentTopics:    return "Suggests educational content topics for social media based on recent interactions."
        case .contentDraft:     return "Generates platform-aware social media drafts with compliance scanning."
        case .morningBriefing:  return "Generates a concise morning briefing narrative from today's schedule and actions."
        case .eveningBriefing:  return "Generates an end-of-day summary narrative from accomplishments and metrics."
        }
    }

    /// The expected output format for this prompt site.
    var outputFormat: String {
        switch self {
        case .noteAnalysis, .emailAnalysis, .messageAnalysis,
             .pipelineAnalyst, .timeAnalyst, .patternDetector,
             .contentTopics, .contentDraft:
            return "JSON"
        case .morningBriefing, .eveningBriefing:
            return "Narrative text"
        }
    }

    /// UserDefaults key for custom prompt override.
    var userDefaultsKey: String {
        switch self {
        case .noteAnalysis:     return "sam.ai.notePrompt"
        case .emailAnalysis:    return "sam.ai.emailPrompt"
        case .messageAnalysis:  return "sam.ai.messagePrompt"
        default:                return "sam.promptLab.\(rawValue)"
        }
    }

    /// Sample input data for testing this prompt site.
    var sampleInput: String {
        switch self {
        case .noteAnalysis:
            return """
                Met with John and Sarah Martinez today at their home. They're interested in \
                reviewing their life insurance coverage since Sarah just got promoted to VP \
                at Meridian Tech. John mentioned his mother (Gloria Martinez) is moving in \
                with them next month — they may need to look at long-term care options for her. \
                Sarah's birthday is March 15. Need to send updated quotes by Friday. \
                John also referred me to his colleague Mike Chen who's looking for a financial advisor.
                """

        case .emailAnalysis:
            return """
                Subject: Re: Annual Review Meeting Follow-Up
                From: David Thompson

                Hi there,

                Thanks for meeting with me last week. I've been thinking about what you said regarding \
                the IUL policy and I think it makes sense for our situation. My wife Linda and I would \
                like to move forward with the $500K coverage.

                One question — can we schedule the medical exam for sometime next week? Also, Linda's \
                sister Rachel is interested in talking to you about retirement planning. She just turned 55 \
                and is thinking about her options. I'll send you her contact info.

                Best regards,
                David
                """

        case .messageAnalysis:
            return """
                [2026-03-08 10:15] Me: Hey Tom, just wanted to follow up on our conversation about the annuity
                [2026-03-08 10:22] Tom Wilson: Hey! Yeah I've been thinking about it. The guaranteed income part is really appealing
                [2026-03-08 10:23] Tom Wilson: My wife and I talked it over this weekend
                [2026-03-08 10:25] Me: That's great to hear. Would you and Maria like to come in this week to go over the specifics?
                [2026-03-08 10:28] Tom Wilson: How about Thursday afternoon?
                [2026-03-08 10:30] Me: Perfect, I'll send a calendar invite for 2pm
                [2026-03-08 10:31] Tom Wilson: Sounds good. Oh btw we're having a baby in July! Might need to revisit life insurance too
                """

        case .pipelineAnalyst:
            return """
                PIPELINE SNAPSHOT:
                Clients: 45 (32 active policies)
                Applicants: 8 (3 submitted, 5 in underwriting)
                Leads: 22 (7 new this month, 4 from referrals)

                STUCK PROSPECTS:
                - Tom Lee: Lead for 52 days, no meeting scheduled
                - Sarah Kim: Applicant for 38 days, medical exam pending
                - Mike Chen: Lead for 45 days, initial call completed but no follow-up

                CONVERSION RATES (90 days):
                Lead → Applicant: 18% (below 25% target)
                Applicant → Client: 62%

                PRODUCTION:
                - 3 IUL applications pending (Jane Doe, Robert Park, Amy Liu)
                - 2 term life policies submitted this week
                - Jane Doe's IUL: submitted 21 days ago, awaiting carrier response

                RECRUITING:
                - 2 prospects in licensing phase
                - 1 agent (Kim Nguyen) has first client meeting next week
                """

        case .timeAnalyst:
            return """
                TIME ALLOCATION — Last 7 Days:
                Client Meetings: 8.5 hrs (24%)
                Prospecting: 2.0 hrs (6%)
                Policy Review: 3.0 hrs (9%)
                Recruiting: 4.5 hrs (13%)
                Training/Mentoring: 3.0 hrs (9%)
                Admin: 9.0 hrs (26%)
                Deep Work: 2.0 hrs (6%)
                Personal Development: 1.0 hr (3%)
                Travel: 2.0 hrs (6%)

                TIME ALLOCATION — Last 30 Days:
                Client Meetings: 38 hrs (28%)
                Prospecting: 12 hrs (9%)
                Policy Review: 14 hrs (10%)
                Recruiting: 16 hrs (12%)
                Training/Mentoring: 10 hrs (7%)
                Admin: 28 hrs (21%)
                Deep Work: 8 hrs (6%)
                Personal Development: 6 hrs (4%)
                Travel: 4 hrs (3%)

                CONTACTS BY ROLE:
                Clients: 45, Leads: 22, Applicants: 8, Agents: 5, Vendors: 3
                """

        case .patternDetector:
            return """
                ENGAGEMENT METRICS (90 days):
                Total interactions: 342
                Average per contact: 4.2
                Contacts with 0 interactions: 12 (5 Leads, 4 Clients, 3 External Agents)

                REFERRAL NETWORK:
                Active referral partners: 4
                - Partner A: 6 referrals, 3 interactions this month
                - Partner B: 4 referrals, 0 interactions this month
                - Partner C: 2 referrals, 1 interaction this month
                - Partner D: 1 referral, 0 interactions this month

                MEETING QUALITY (last 20 meetings):
                Average quality score: 7.2/10
                Follow-up completion rate: 68%
                Notes captured: 16/20 (80%)

                ROLE TRANSITIONS (90 days):
                Lead → Applicant: 4 people
                Applicant → Client: 5 people
                Lead → Archived: 3 people

                RESPONSE PATTERNS:
                Average response time to client messages: 2.4 hours
                Average response time to lead messages: 8.1 hours
                Fastest follow-ups: Tuesday afternoons (avg 1.2 hrs)
                Slowest follow-ups: Friday afternoons (avg 14.3 hrs)
                """

        case .contentTopics:
            return """
                RECENT MEETING TOPICS (last 14 days):
                - Retirement planning with David Thompson (age 58)
                - Life insurance review with Martinez family (VP promotion, new baby)
                - Annuity discussion with Tom Wilson (interested in guaranteed income)
                - College savings 529 plan with Lisa Park (daughter starting high school)
                - Long-term care options inquiry from Gloria Martinez (age 78)

                SEASONAL CONTEXT: March 2026 — tax season, open enrollment reminders

                CLIENT CONCERNS MENTIONED:
                - Market volatility and retirement timing
                - Rising cost of long-term care
                - College affordability
                - Estate planning after life changes
                """

        case .contentDraft:
            return """
                Topic: The Hidden Cost of Waiting: Why Starting Your Retirement Plan at 55 Isn't Too Late
                Key Points: Many people feel behind; small consistent steps matter; the power of catch-up contributions; common misconceptions about "too late"
                Platform: LinkedIn
                Tone: educational
                """

        case .morningBriefing:
            return """
                CURRENT TIME: 8:30 AM

                TODAY'S CALENDAR:
                - 9:00 AM — Team standup (30 min)
                - 10:30 AM — Client meeting with David & Linda Thompson (IUL review, 60 min)
                - 12:00 PM — Lunch
                - 1:30 PM — Follow-up call with Tom Wilson (annuity discussion, 30 min)
                - 3:00 PM — Training session with Kim Nguyen (new agent, 60 min)

                PRIORITY ACTIONS:
                - Send updated life insurance quotes to John Martinez (deadline: Friday)
                - Call Sarah Kim about medical exam scheduling
                - Review Mike Chen's financial assessment before outreach

                FOLLOW-UPS:
                - Lisa Park: 529 plan proposal sent 3 days ago, no response
                - Robert Park: IUL application status check with carrier

                GOAL PROGRESS:
                - New Clients: 3/8 this quarter (38%, on track)
                - Policies Submitted: 12/20 this quarter (60%, ahead of pace)
                """

        case .eveningBriefing:
            return """
                ACCOMPLISHMENTS TODAY:
                - Completed client meeting with David & Linda Thompson — moving forward with $500K IUL
                - Training session with Kim Nguyen — reviewed product knowledge, scheduled her first solo meeting
                - Sent 3 follow-up messages (Lisa Park, Robert Park, Sarah Kim)

                METRICS:
                - Appointments completed: 3
                - Messages sent: 7
                - Tasks completed: 5

                STREAKS:
                - LinkedIn posting: 4 days
                - Note capture: 12 days

                TOMORROW HIGHLIGHTS:
                - 9:00 AM — Needs analysis with Mike Chen (referred by John Martinez)
                - 2:00 PM — Quarterly review with Partner A (referral partner)
                """
        }
    }
}

// MARK: - Prompt Variant

/// A named version of a prompt for a specific site.
struct PromptVariant: Identifiable, Codable {
    let id: UUID
    var name: String
    var systemInstruction: String
    var isDefault: Bool
    var createdAt: Date
    var rating: VariantRating

    init(
        id: UUID = UUID(),
        name: String,
        systemInstruction: String,
        isDefault: Bool = false,
        createdAt: Date = Date(),
        rating: VariantRating = .unrated
    ) {
        self.id = id
        self.name = name
        self.systemInstruction = systemInstruction
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.rating = rating
    }
}

// MARK: - Variant Rating

enum VariantRating: String, Codable, CaseIterable {
    case unrated
    case winner
    case good
    case neutral
    case poor
    case rejected

    var label: String {
        switch self {
        case .unrated:  return "Unrated"
        case .winner:   return "Winner"
        case .good:     return "Good"
        case .neutral:  return "Neutral"
        case .poor:     return "Poor"
        case .rejected: return "Rejected"
        }
    }

    var icon: String {
        switch self {
        case .unrated:  return "circle"
        case .winner:   return "trophy.fill"
        case .good:     return "hand.thumbsup.fill"
        case .neutral:  return "minus.circle"
        case .poor:     return "hand.thumbsdown"
        case .rejected: return "xmark.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .unrated:  return "secondary"
        case .winner:   return "yellow"
        case .good:     return "green"
        case .neutral:  return "gray"
        case .poor:     return "orange"
        case .rejected: return "red"
        }
    }
}

// MARK: - Test Run

/// The result of running a prompt variant against sample data.
struct PromptTestRun: Identifiable, Codable {
    let id: UUID
    let variantID: UUID
    let site: PromptSite
    let input: String
    let output: String
    let durationSeconds: Double
    let timestamp: Date
    let backend: String

    init(
        id: UUID = UUID(),
        variantID: UUID,
        site: PromptSite,
        input: String,
        output: String,
        durationSeconds: Double,
        timestamp: Date = Date(),
        backend: String = "unknown"
    ) {
        self.id = id
        self.variantID = variantID
        self.site = site
        self.input = input
        self.output = output
        self.durationSeconds = durationSeconds
        self.timestamp = timestamp
        self.backend = backend
    }
}

// MARK: - Prompt Lab Store

/// Persistent storage for prompt variants and test runs.
struct PromptLabStore: Codable {
    var variants: [PromptSite: [PromptVariant]]
    var testRuns: [PromptTestRun]

    init() {
        variants = [:]
        testRuns = []
    }
}
