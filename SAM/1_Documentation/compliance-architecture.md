# Compliance Architecture

SAM provides industry-specific compliance scanning of meeting transcripts, draft communications, and coaching outputs. Compliance rules are driven by the user's selected `PracticeType` in Settings.

## Compliance Profiles

| Practice Type | Compliance Source | User-Editable | Can Be Disabled |
|---|---|---|---|
| WFG Financial Advisor | WFGIA Agent Insurance Guide | No (SAM-maintained) | No |
| General | None (custom keywords only) | Yes (custom keywords) | N/A |

## Maintenance Rules (Non-Negotiable)

1. **Version tracking** — Every compliance profile MUST state the source document and version it is based on. The WFG profile currently references the "U.S. Agent Agreement Packet, April 2025." When the source document is updated and SAM's rules change, the version reference in both the code (`complianceSectionFinancialAdvisor` in `MeetingSummaryService.swift`) and the Settings disclaimer (`ComplianceSettingsContent.swift`) MUST be updated to match.

2. **Disclaimer required** — Every regulated practice type MUST display a disclaimer in Settings stating: (a) what the compliance checking is based on, (b) the version/date of the source document, and (c) that the user remains fully responsible for all compliance matters — SAM is an assistive tool, not a compliance guarantee.

3. **New industry profiles** — When adding compliance standards for a new business type (e.g., real estate, health/wellness), follow the same pattern: create a SAM-maintained profile referencing the authoritative source document, make it non-editable and non-disableable, and include the appropriate disclaimer.

4. **Custom keywords** — Available for ALL practice types (including regulated ones) as additive-only supplements. Custom keywords never replace or weaken SAM-maintained rules.

## Where Compliance Rules Live

- **AI prompt rules** (LLM-based detection): `MeetingSummaryService.complianceSectionFinancialAdvisor` — injected into the summary system instruction. Detects nuanced violations in context (e.g., "this fund has outperformed the S&P 500").
- **Keyword scanner** (deterministic): `ComplianceScanner.phrasePatterns` — pattern-matched against draft text. Catches literal phrases (e.g., "guaranteed return", "risk-free").
- **Settings UI**: `ComplianceSettingsContent` — displays profile info and disclaimer per practice type.
- **Content advisor**: `ContentAdvisorService` — conditionally includes compliance instructions based on `isFinancial`.

Both the AI prompt rules and the keyword scanner must be updated together when compliance requirements change.

## Recording-Context Tracking

Client-meeting-shaped recordings (`.clientMeeting`, `.prospectingCall`, `.recruitingInterview`, `.annualReview`) are compliance-tracked through the meeting summary. `.trainingLecture` and `.boardMeeting` are not.
