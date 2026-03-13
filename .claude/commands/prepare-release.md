# Prepare SAM for Distribution

You are preparing SAM for distribution after a round of enhancements. This is a comprehensive quality, coverage, and marketing asset preparation workflow. Execute ALL phases below. Report progress at each phase boundary. If any phase fails, fix the issue before moving to the next phase.

The target platforms are: macOS (primary, current) and iOS (companion, upcoming). All assets must be platform-aware — label macOS-specific features clearly and note iOS availability where applicable.

---

## Phase 0: Feature Discovery (Required First Step)

Before auditing anything, build a **complete feature inventory** by scanning the actual codebase. This inventory drives all subsequent coverage checks.

### 0a. Sidebar Sections & Major Views
Read `SAM/Views/AppShellView.swift` and catalog every sidebar section and the view it routes to:
- Today → AwarenessView
- People → PeopleListView / RelationshipGraphView
- Business → BusinessDashboardView
- Grow → GrowDashboardView
- Events → EventManagerView
- Search → SearchView

### 0b. Sub-Features Within Each Section
For each major view, read the view file and its coordinator(s) to enumerate sub-features. Key places to check:
- **Today**: AwarenessView sections (briefing, outcome queue, hero card, coaching chat)
- **People**: PersonDetailView tabs/sections (notes, evidence, outcomes, insurance, recruiting, production, time, coaching, family)
- **Business**: BusinessDashboardView sections (goals, client pipeline, recruiting pipeline, production, strategic insights, time analysis)
- **Grow**: GrowDashboardView sections (lead acquisition, content drafts, social promotion, referral analysis)
- **Events**: EventManagerView sections (events list, event detail, presentations, presentation detail)
- **Search**: SearchView capabilities
- **Cross-cutting**: Dictation, clipboard capture, keyboard shortcuts, settings/permissions, onboarding, security (lock screen, backup encryption), undo system, compliance scanning

### 0c. Build the Coverage Matrix
Create a working table with columns: **Feature** | **Has Tip?** | **Has Guide Article?** | **Has Screenshot?** | **In Screenshot Runner?**

Populate it by cross-referencing:
- Tips: `SAM/Views/Shared/SAMTips.swift` (all tip structs)
- Tip→Guide mapping: `SAMTipGuideMapping` in the same file
- Guide articles: `SAM/Resources/Guide/GuideManifest.json`
- Guide screenshots: `SAM/Resources/Guide/*/images/*.png` (glob for actual files)
- Screenshot runner specs: `SAM/Debug/GuideScreenshotRunner.swift` → `buildManifest()` + `manualScreenshotList()`

Report the matrix. Flag any feature that is missing coverage in ANY column.

---

## Phase 1: Tooltip Coverage & Accuracy Audit

Using the coverage matrix from Phase 0:

### 1a. Verify Existing Tips
For EVERY tip defined in `SAMTips.swift`:
1. Verify the tip title, message, and SF Symbol are accurate for the current feature state
2. Verify the tip's "Learn more" action links to an existing guide article (check `SAMTipGuideMapping`)
3. Cross-reference the tip text with the actual view code to ensure descriptions match current UI
4. If a feature has changed since the tip was written, update the tip text

### 1b. Identify Missing Tips
Check the coverage matrix for features that should have a tip but don't. A tip is warranted for:
- Every sidebar section's primary view
- Major sub-features a user might not discover on their own (e.g., dictation, clipboard capture, relationship graph, compliance scanning)
- New features added since the last release prep

For each missing tip:
- Create the tip struct in `SAMTips.swift` following the existing pattern (title, message, SF Symbol, `SAMTip` protocol conformance)
- Add its guide mapping in `SAMTipGuideMapping`
- Wire it into the appropriate view

### 1c. Verify Tip Placement
For each tip, confirm it appears in the correct view at the right location. Read the view file and search for the tip type name to verify it's used.

Report: tips verified, tips updated, tips created, any that need user approval.

---

## Phase 2: Guide Coverage & Accuracy Audit

Using the coverage matrix from Phase 0:

### 2a. Verify Existing Articles
Read the guide manifest (`SAM/Resources/Guide/GuideManifest.json`) and then read EVERY guide article markdown file in `SAM/Resources/Guide/`.

For EACH article:
1. Verify the content accurately describes the current feature (cross-reference with the actual view/coordinator code)
2. Verify screenshots referenced in the article exist in the images subdirectory
3. Verify keyboard shortcuts mentioned are correct
4. Check for stale references to removed features or outdated UI descriptions
5. Update any inaccurate content

### 2b. Identify Missing Articles
Check the coverage matrix for features that have no guide article. Every user-facing feature should have guide coverage. For each gap:
- Create the markdown article in the appropriate section directory under `SAM/Resources/Guide/`
- Add the article entry to `GuideManifest.json` with appropriate `searchKeywords` and `relatedTipID`
- Follow the existing article format (heading, description, screenshot references, step-by-step usage, tips)

### 2c. Screenshot Coverage
For each guide article that references screenshots:
1. Verify the referenced image files exist
2. If missing, check whether the screenshot runner already captures it
3. If the runner doesn't cover it, add it (see Phase 2d)
4. Note screenshots that must be captured manually (sheets, alerts, settings panels)

### 2d. Update Screenshot Runner
Read `SAM/Debug/GuideScreenshotRunner.swift`. Compare `buildManifest()` specs and `manualScreenshotList()` against the full set of screenshots needed by all guide articles.

For each missing automated screenshot:
- Add a `ScreenshotSpec` to `buildManifest()` with the correct section, filename, description, and navigation closure
- Use existing navigation helpers (`navigateToSection`, `navigateToGraph`, `selectFirstPerson`) or add new ones following the same `NotificationCenter` pattern

For each missing manual screenshot:
- Add it to `manualScreenshotList()` with the section, filename, and description

Report: articles verified, articles updated, articles created, screenshots present, screenshots missing (automated vs manual), runner specs added.

---

## Phase 3: Test Suite

Run the full test suite:
```
xcodebuild test -scheme SAM -destination 'platform=macOS' -quiet
```

- If tests pass, report the count.
- If tests fail, diagnose and fix each failure. Re-run until green.
- If tests are outdated (testing removed features), update or remove them.

Report: test results summary.

---

## Phase 4: Build Warnings

Run a clean build and capture all warnings:
```
xcodebuild clean build -scheme SAM -destination 'platform=macOS' 2>&1 | grep -E "warning:|error:"
```

- Fix all errors (obviously).
- For warnings: fix any that indicate real problems (unused variables, deprecated API usage, type-check issues). Ignore warnings from third-party packages.

Report: warnings found, warnings fixed, any remaining (with justification for keeping).

---

## Phase 5: Overview Document (500 words max)

Generate or update `SAM/1_Documentation/NotebookLM/sam-overview.md`.

This document will be fed to NotebookLM (or similar) to generate a "podcast-style" audio presentation. Write it as a compelling narrative, NOT as a feature list. Structure:

1. **The problem** (2-3 sentences): What independent financial strategists struggle with
2. **The solution** (2-3 sentences): What SAM is and how it's different
3. **Key value pillars** (3-4 short paragraphs): Relationship intelligence, business strategy, zero-friction capture, privacy-first design
4. **The result** (2-3 sentences): What life looks like WITH SAM

Tone: Conversational but professional. Written for the target user (independent financial strategist at WFG), not for developers. Should make the listener think "I need this."

Constraints:
- 500 words maximum
- No technical jargon (no "SwiftData", "CoreML", "LLM")
- Platform mention: "Available on Mac, with iPhone companion coming soon"
- Must reflect the CURRENT feature set accurately — use the feature inventory from Phase 0

---

## Phase 6: Topic-Specific Deep Dive Documents (250 words each)

Generate or update individual documents in `SAM/1_Documentation/NotebookLM/topics/`. Each is a standalone NotebookLM source for a focused "podcast episode."

Create one document for EACH of the following topics. Each document should:
- Open with a relatable problem statement (1-2 sentences)
- Describe how SAM specifically solves it (with concrete examples)
- Close with the outcome/benefit
- Be 250 words or less
- Use conversational, non-technical language
- Note platform availability (macOS now, iOS companion where relevant)

**IMPORTANT**: Before writing each document, read the actual coordinator/view/service code for that feature area to ensure accuracy. Do not write from memory — verify against the current implementation.

### Required Topics:

1. **`relationship-coaching.md`** — How SAM observes interactions and tells you who needs attention, what to say, and why
2. **`meeting-intelligence.md`** — Pre-briefs, post-meeting capture, and automatic follow-up generation
3. **`business-dashboard.md`** — Pipeline health, production tracking, goal decomposition, strategic insights
4. **`event-management.md`** — Workshop planning, RSVP tracking, presentation library, post-event follow-up
5. **`content-and-growth.md`** — Content topic suggestions, draft generation, social promotion, lead acquisition
6. **`recruiting-pipeline.md`** — Agent recruiting stages, mentoring cadence, licensing tracking
7. **`time-and-productivity.md`** — Time categorization, calendar analysis, deep work protection
8. **`privacy-and-security.md`** — On-device AI, no cloud, mandatory authentication, encrypted backups
9. **`social-imports.md`** — LinkedIn, Facebook, Substack data import and contact enrichment
10. **`daily-briefing.md`** — Morning briefing, outcome queue, adaptive coaching that learns your preferences

### Dynamic Topic Discovery
After completing the required topics, check the feature inventory from Phase 0 for any major feature area NOT covered by the topics above. If found, create an additional topic document for it and add it to the list. Common candidates:
- Relationship graph / family discovery
- Compliance and audit trail
- Undo system
- Note-taking and dictation (as a standalone topic)

---

## Phase 7: Onboarding & Help Showcase Document

Generate or update `SAM/1_Documentation/NotebookLM/sam-onboarding-showcase.md`.

This document will be used with NotebookLM to create a short video showing SAM's onboarding and help systems. Structure:

1. **Introduction** (2-3 sentences): SAM's philosophy on getting started — guided, not overwhelming
2. **First Launch Experience**: Describe the onboarding flow step by step (permissions, contact group selection, calendar setup, mail accounts, "Me" contact identification). Reference actual onboarding steps from `OnboardingView.swift`.
3. **Security on First Launch**: Authentication is required immediately — Touch ID or system password. Describe the lock screen experience.
4. **Tooltip System**: Describe how contextual tips appear as users explore features, with "Learn more" links to the built-in guide. List 3-4 example tips with their exact titles from `SAMTips.swift`.
5. **Built-in Guide**: Describe the guide window (sections, article count, searchable, with screenshots). List the section names from `GuideManifest.json`.
6. **Adaptive Learning**: How SAM learns which suggestions you value and adjusts over time. Reference the CalibrationLedger system.

For EACH section above, specify a screenshot that should accompany it. Use existing screenshots from `SAM/Resources/Guide/` where they exist. For any that don't exist, note them as "SCREENSHOT NEEDED: [description]" so they can be captured manually.

Tone: Warm, welcoming, emphasizing that SAM meets you where you are.
Length: 400-600 words.

---

## Phase 8: Asset Inventory & Final Report

After all phases complete, produce a summary:

### Coverage Matrix (Final)
Reproduce the coverage matrix from Phase 0 with updated status after all fixes:
**Feature** | **Has Tip?** | **Has Guide Article?** | **Has Screenshot?** | **In Screenshot Runner?**

### Status Summary
1. **Feature inventory**: X features cataloged across Y sidebar sections
2. **Tooltip status**: X tips verified, Y updated, Z created, W gaps remaining
3. **Guide status**: X articles verified, Y updated, Z created, W screenshots missing
4. **Screenshot runner**: X automated specs, Y manual specs, Z added this run
5. **Test status**: X tests passing, Y fixed
6. **Warning status**: X warnings resolved, Y remaining
7. **Marketing assets generated**:
   - Overview document: path, word count
   - Topic documents: list with paths and word counts
   - Onboarding showcase: path, word count, screenshots needed
8. **Platform readiness**: macOS ready / iOS items to address when companion ships
9. **Recommended manual steps**: Any items that require human action (screenshot capture, NotebookLM upload, guide screenshot runner execution, etc.)
