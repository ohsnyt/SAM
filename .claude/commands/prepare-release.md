# Prepare SAM for Distribution

You are preparing SAM for distribution after a round of enhancements. This is a comprehensive quality, coverage, and marketing asset preparation workflow. Execute ALL phases below. Report progress at each phase boundary. If any phase fails, fix the issue before moving to the next phase.

The target platforms are **macOS** (SAM, primary) and **iOS** (SAMField, companion). Both ship together. Every phase must address both platforms unless explicitly scoped otherwise. When auditing, label findings with the platform they apply to. Cross-platform features (e.g., recordings synced from phone to Mac) must be verified end-to-end on both ends.

---

## Phase 0: Feature Discovery (Required First Step)
Before auditing anything, build a **complete feature inventory** by scanning the actual codebase. This inventory drives all subsequent coverage checks.

### 0a. macOS — Sidebar Sections & Major Views
Read `SAM/Views/AppShellView.swift` and catalog every sidebar section and the view it routes to.

### 0b. macOS — Sub-Features Within Each Section
For each major view, read the view file and its coordinator(s) to enumerate sub-features.

### 0c. iOS — Tabs, Settings, and Major Views
Read `SAMField/Views/FieldTabView.swift` and catalog every tab and its root view. Then walk each tab's view files and coordinators (`SAMField/Coordinators/`) and the Settings hierarchy (`SAMField/Views/Settings/`) to enumerate sub-features. Pay special attention to:
- **Today**: briefing surfaces, sync state, day plan
- **Record**: live-transcription pairing flow, offline recording, pending uploads, saved note review
- **Trips**: auto-detected trips, manual entry, address pickers, mileage export, vehicle config
- **Settings**: pairing, permissions, trip preferences, account/identity
- **Cross-cutting**: CloudKit pairing/handshake, location/motion permissions, microphone permissions, background tasks, offline queue

### 0d. Build the Coverage Matrix
Create a working table with columns: **Platform** | **Feature** | **Has Tip?** | **Has Guide Article?** | **Has Screenshot?** | **In Screenshot Runner?**

The Platform column is one of `macOS`, `iOS`, or `Both` (for features that exist or are described on both — e.g., recordings, briefing).

Populate it by cross-referencing:
- macOS tips: `SAM/Views/Shared/SAMTips.swift` (all tip structs)
- macOS tip→guide mapping: `SAMTipGuideMapping` in the same file
- iOS tips: SAMField TipKit catalog (see Phase 1b — create `SAMField/Views/Shared/FieldTips.swift` if not present)
- Guide articles: `SAM/Resources/GuideManifest.json` — a single guide system serves both platforms; iOS articles should carry a `platform: "iOS"` tag (see Phase 2). Article markdown lives under `SAM/Resources/Guide/<section>/`.
- Guide screenshots: `SAM/Resources/Guide/*/images/*.png` (glob for actual files; iOS screenshots should be named `<feature>-ios.png` to distinguish)
- macOS screenshot runner specs: `SAM/Debug/GuideScreenshotRunner.swift` → `buildManifest()` + `manualScreenshotList()`
- iOS screenshot runner specs: `SAMField/Debug/FieldScreenshotRunner.swift` if present (otherwise note iOS screenshots as manual capture for v1)

Report the matrix. Flag any feature that is missing coverage in ANY column.

---

## Phase 1: Tooltip Coverage & Accuracy Audit

Tooltips are audited as two parallel tracks:
- **macOS track**: the existing `SAMTips` system in `SAM/Views/Shared/SAMTips.swift`
- **iOS track**: a TipKit catalog in `SAMField/Views/Shared/FieldTips.swift` (Apple's official iOS feature-discovery framework, iOS 17+)

Both tracks share the same audit shape: verify, identify gaps, fill them, and confirm placement.

### 1a. macOS — Verify Existing Tips
For EVERY tip defined in `SAMTips.swift`:
1. Verify the tip title, message, and SF Symbol are accurate for the current feature state
2. Verify the tip's "Learn more" action links to an existing guide article (check `SAMTipGuideMapping`)
3. Cross-reference the tip text with the actual view code to ensure descriptions match current UI
4. If a feature has changed since the tip was written, update the tip text

### 1b. iOS — TipKit Setup & Existing Tip Audit
SAMField uses Apple's **TipKit** framework (`import TipKit`) for feature discovery. This is the recommended Apple pattern for iOS 17+ apps and handles persistence, frequency, and eligibility rules automatically.

If TipKit is not yet configured:
1. Verify `Tips.configure(...)` is called once at app launch in `SAMFieldApp.swift` (e.g., `.task { try? Tips.configure([.displayFrequency(.daily), .datastoreLocation(.applicationDefault)]) }`).
2. Create `SAMField/Views/Shared/FieldTips.swift` containing one `Tip`-conforming struct per discoverable feature, each with `title: Text`, `message: Text?`, `image: Image?`, and optional `Rule`s for eligibility (e.g., "show after first manual trip" via `Tip.Event` donations).
3. Each tip is rendered either inline via `TipView(_:)` or anchored via `.popoverTip(_:)` in the relevant view.
4. Mirror the macOS pattern: maintain a `FieldTipGuideMapping` that maps tip IDs to guide article IDs so the tip's "Learn more" action opens the corresponding guide entry (web link or in-app help section — see Phase 2).

For EVERY existing tip in `FieldTips.swift`:
1. Verify title, message, and SF Symbol are accurate against current SAMField UI
2. Verify the eligibility `Rule`s still match how the feature is reached (e.g., a tip gated on `firstTripCompletedEvent` is correct only if that event is actually donated)
3. Verify the "Learn more" target article exists in the guide manifest
4. Update any stale text

### 1c. macOS — Identify Missing Tips
Check the coverage matrix for macOS features that should have a tip but don't. A tip is warranted for:
- Every sidebar section's primary view
- Major sub-features a user might not discover on their own (dictation, clipboard capture, relationship graph, compliance scanning, etc.)
- New features added since the last release prep

For each missing tip:
- Create the tip struct in `SAMTips.swift` following the existing pattern (title, message, SF Symbol, `SAMTip` protocol conformance)
- Add its guide mapping in `SAMTipGuideMapping`
- Wire it into the appropriate view

### 1d. iOS — Identify Missing Tips
Check the coverage matrix for iOS features that should have a tip but don't. A TipKit tip is warranted for:
- Each tab's primary affordance the first time the user lands there (e.g., "Pull to sync briefing" on Today, "Tap to start recording" on Record, "Trips auto-save when you stop driving" on Trips)
- Non-obvious gestures: swipe-to-delete on recordings/trips, "Looks Good" approval, pull-to-refresh
- Pairing/handoff: CloudKit pairing in Settings, the live-vs-offline recording mode indicator
- Permissions priming: tips that explain WHY a permission is needed, shown before the system prompt

For each missing tip:
- Add a `Tip`-conforming struct in `FieldTips.swift` with title, message, SF Symbol, and an eligibility `Rule` (e.g., `#Rule(Self.$tabVisitCount) { $0 == 1 }`)
- Add its guide mapping in `FieldTipGuideMapping`
- Wire it into the appropriate view via `TipView(_:)` or `.popoverTip(_:)`
- Donate the relevant `Tip.Event` from the code paths that should trigger eligibility

### 1e. Verify Tip Placement (Both Platforms)
For each tip on each platform, confirm it appears in the correct view at the right location. Read the view file and search for the tip type name to verify it's used. For TipKit tips, also verify that any required `Tip.Event.donate()` calls happen on the relevant user actions.

Report (per platform): tips verified, tips updated, tips created, any that need user approval.

---

## Phase 2: Guide Coverage & Accuracy Audit

A single guide system (manifest at `SAM/Resources/GuideManifest.json`, article markdown under `SAM/Resources/Guide/<section>/`) serves both platforms. Each article carries a `platform` field of `macOS`, `iOS`, or `both`. The Mac guide window filters by platform; iOS surfaces relevant articles via in-Settings help links and from TipKit "Learn more" actions.

If the manifest does not yet have a `platform` field, add it during this phase and default existing articles to `macOS`.

### 2a. Verify Existing Articles
Read `GuideManifest.json` and EVERY guide article markdown file in `SAM/Resources/Guide/`.

For EACH article:
1. Verify the content accurately describes the current feature on the platform(s) it claims to cover (cross-reference with the actual view/coordinator code)
2. Verify screenshots referenced in the article exist in the images subdirectory
3. Verify keyboard shortcuts (macOS) or gestures (iOS) mentioned are correct
4. Check for stale references to removed features or outdated UI descriptions
5. Confirm the `platform` field accurately reflects where the feature lives
6. Update any inaccurate content

### 2b. Identify Missing Articles — macOS
Check the coverage matrix for macOS features with no guide article. Every user-facing macOS feature should have guide coverage. For each gap, create the markdown article in the appropriate section directory under `SAM/Resources/Guide/`, add an entry to `GuideManifest.json` with `platform: "macOS"`, appropriate `searchKeywords`, and `relatedTipID`.

### 2c. Identify Missing Articles — iOS
Check the coverage matrix for iOS features with no guide article. SAMField features that warrant articles include (but are not limited to):
- CloudKit pairing with the Mac (Settings → Pairing)
- Live transcription mode vs. offline recording mode (and how the app picks)
- Pending uploads and how recordings sync back to the Mac
- Trip auto-detection, manual trip entry, and IRS-compliant mileage export
- Address pickers (map and contacts), saved addresses, vehicle setup
- "Looks Good" approval and swipe-to-delete on recordings
- Today tab briefing sync and pull-to-refresh
- Permissions: location (Always vs. While Using), motion, microphone, contacts

For each gap:
- Create the markdown article in a platform-appropriate section under `SAM/Resources/Guide/` (an `iOS/` section directory is acceptable)
- Add it to `GuideManifest.json` with `platform: "iOS"`, `searchKeywords`, and `relatedTipID` referencing the corresponding TipKit tip
- Follow the existing article format (heading, description, screenshot references, step-by-step usage, tips), adapted for iOS (gestures, system sheets, permission prompts)

### 2d. Identify Missing Articles — Cross-Platform
Some features span both platforms (recording sync, briefing sync, identity/pairing). For these, prefer a single article with `platform: "both"` that has clearly labeled "On Mac" and "On iPhone" subsections, each with its own screenshot. Avoid duplicating the same content in two articles.

### 2e. Screenshot Coverage
For each guide article that references screenshots:
1. Verify the referenced image files exist
2. If missing, check whether the appropriate platform's screenshot runner already captures it
3. If the runner doesn't cover it, add it (see Phase 2f)
4. Note screenshots that must be captured manually (sheets, alerts, settings panels, system permission prompts)

iOS screenshots should be named `<feature>-ios.png` (or live in an `images/ios/` subdirectory) so they don't collide with macOS screenshots of the same feature.

### 2f. Update Screenshot Runners
**macOS runner** — Read `SAM/Debug/GuideScreenshotRunner.swift`. Compare `buildManifest()` specs and `manualScreenshotList()` against the full set of macOS screenshots needed by all guide articles. For each missing automated screenshot, add a `ScreenshotSpec` to `buildManifest()` with the correct section, filename, description, and navigation closure (use existing helpers `navigateToSection`, `navigateToGraph`, `selectFirstPerson` or add new ones following the same `NotificationCenter` pattern). For each missing manual screenshot, add it to `manualScreenshotList()`.

**iOS runner** — Check for `SAMField/Debug/FieldScreenshotRunner.swift`. If it exists, do the same audit against iOS screenshots needed by guide articles. If it does not exist, list iOS screenshots in a `manualScreenshotList()` equivalent file (or in this report) so they can be captured by hand on a device or simulator before release. Building an automated iOS runner is not required for v1, but document what would need to be captured manually.

Report (per platform): articles verified, articles updated, articles created, screenshots present, screenshots missing (automated vs manual), runner specs added.

---

## Phase 3: Test Suite (Both Platforms)

Run the full test suites on both platforms in parallel.

**macOS:**
```
xcodebuild test -scheme SAM -destination 'platform=macOS' -quiet
```

**iOS:**
```
xcodebuild test -scheme SAMField -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -quiet
```

For each suite:
- If tests pass, report the count.
- If tests fail, diagnose and fix each failure. Re-run until green.
- If tests are outdated (testing removed features), update or remove them.

If the iOS scheme or test target is missing or misnamed, report it — do not silently skip. SAMField has a test target at `SAMFieldTests/`.

Report (per platform): test results summary.

---

## Phase 4: Build Warnings (Both Platforms)

Run a clean build on each platform and capture all warnings.

**macOS:**
```
xcodebuild clean build -scheme SAM -destination 'platform=macOS' 2>&1 | grep -E "warning:|error:"
```

**iOS:**
```
xcodebuild clean build -scheme SAMField -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 | grep -E "warning:|error:"
```

For each build:
- Fix all errors (obviously).
- For warnings: fix any that indicate real problems (unused variables, deprecated API usage, type-check issues, Swift 6 concurrency warnings, missing `Sendable` conformances). Ignore warnings from third-party packages.

Report (per platform): warnings found, warnings fixed, any remaining (with justification for keeping).

---

## Phase 5: Overview Document (500 words max)

Generate or update `SAM/1_Documentation/NotebookLM/sam-overview.md`.

This document will be fed to NotebookLM (or similar) to generate a "podcast-style" audio presentation. Write it as a compelling narrative, NOT as a feature list. Structure:

1. **The problem** (2–3 sentences): What independent financial strategists struggle with
2. **The solution** (2–3 sentences): What SAM is and how it's different
3. **Key value pillars** (3–4 short paragraphs): Relationship intelligence, business strategy, zero-friction capture (including the iPhone companion for in-the-field capture and trip tracking), privacy-first design
4. **The result** (2–3 sentences): What life looks like WITH SAM on Mac and iPhone together

Tone: Conversational but professional. Written for the target user (independent financial strategist at WFG), not for developers. Should make the listener think "I need this."

Constraints:
- 500 words maximum
- No technical jargon (no "SwiftData", "CoreML", "LLM", "TipKit", "CloudKit")
- Platform mention: SAM is a Mac-first coaching assistant with **SAM Field**, the iPhone companion that captures meetings and tracks trips on the go and syncs everything back to the Mac. Frame iOS as shipping with v1, not as "coming soon."
- Must reflect the CURRENT feature set on BOTH platforms accurately — use the feature inventory from Phase 0

---

## Phase 6: Topic-Specific Deep Dive Documents (250 words each)

Generate or update individual documents in `SAM/1_Documentation/NotebookLM/topics/`. Each is a standalone NotebookLM source for a focused "podcast episode."

Create one document for EACH of the following topics. Each document should:
- Open with a relatable problem statement (1–2 sentences)
- Describe how SAM specifically solves it (with concrete examples)
- Close with the outcome/benefit
- Be 250 words or less
- Use conversational, non-technical language
- State platform availability explicitly at the top: "Available on: Mac", "Available on: iPhone (SAM Field)", or "Available on: Mac and iPhone"

**IMPORTANT**: Before writing each document, read the actual coordinator/view/service code for that feature area on the platform(s) it covers to ensure accuracy. Do not write from memory — verify against the current implementation.

### Required Topics — macOS or Cross-Platform:

1. **`relationship-coaching.md`** — How SAM observes interactions and tells you who needs attention, what to say, and why
2. **`meeting-intelligence.md`** — Pre-briefs, post-meeting capture, automatic follow-up generation, and how phone-recorded meetings flow into the same intelligence pipeline
3. **`business-dashboard.md`** — Pipeline health, production tracking, goal decomposition, strategic insights
4. **`event-management.md`** — Workshop planning, RSVP tracking, presentation library, post-event follow-up
5. **`content-and-growth.md`** — Content topic suggestions, draft generation, social promotion, lead acquisition
6. **`recruiting-pipeline.md`** — Agent recruiting stages, mentoring cadence, licensing tracking
7. **`time-and-productivity.md`** — Time categorization, calendar analysis, deep work protection
8. **`privacy-and-security.md`** — On-device AI, no cloud, mandatory authentication, encrypted backups (cover both platforms — same posture on iPhone)
9. **`social-imports.md`** — LinkedIn, Facebook, Substack data import and contact enrichment
10. **`daily-briefing.md`** — Morning briefing, outcome queue, adaptive coaching that learns your preferences (cover Mac generation + iPhone sync)

### Required Topics — iOS (SAM Field):

11. **`mileage-tracking.md`** — Trips tab. IRS-compliant automatic trip detection, manual entry, address pickers, vehicle setup, mileage export. Why a financial strategist needs reliable mileage logs without thinking about it.
12. **`mobile-capture.md`** — The Record tab on iPhone. Capturing meetings in the field whether or not the Mac is reachable: live-paired transcription when on the same network, offline recording with automatic sync when back in range, "Looks Good" approval, swipe-to-delete.
13. **`mac-iphone-handoff.md`** — How the two apps work as one practice. CloudKit-based pairing, briefing sync to Today tab, recordings flowing from phone to Mac for full intelligence processing, action items showing up on whichever device you're holding.

### Dynamic Topic Discovery
After completing the required topics, check the feature inventory from Phase 0 for any major feature area NOT covered by the topics above. If found, create an additional topic document for it and add it to the list. Common candidates:
- Relationship graph / family discovery
- Compliance and audit trail
- Undo system
- Note-taking and dictation (as a standalone topic)
- Voice capture on iPhone (if distinct from meeting recording)

---

## Phase 7: Onboarding & Help Showcase Documents

Generate or update TWO showcase documents — one per platform — for use with NotebookLM to create short videos of each app's onboarding and help systems.

### 7a. macOS Onboarding Showcase
File: `SAM/1_Documentation/NotebookLM/sam-onboarding-showcase.md`

Structure:
1. **Introduction** (2–3 sentences): SAM's philosophy on getting started — guided, not overwhelming
2. **First Launch Experience**: Describe the onboarding flow step by step (permissions, contact group selection, calendar setup, mail accounts, "Me" contact identification). Reference actual onboarding steps from `OnboardingView.swift`.
3. **Security on First Launch**: Authentication is required immediately — Touch ID or system password. Describe the lock screen experience.
4. **Tooltip System**: Describe how contextual tips appear as users explore features, with "Learn more" links to the built-in guide. List 3–4 example tips with their exact titles from `SAMTips.swift`.
5. **Built-in Guide**: Describe the guide window (sections, article count, searchable, with screenshots). List the section names from `GuideManifest.json`.
6. **Adaptive Learning**: How SAM learns which suggestions you value and adjusts over time. Reference the CalibrationLedger system.

### 7b. iOS (SAM Field) Onboarding Showcase
File: `SAM/1_Documentation/NotebookLM/samfield-onboarding-showcase.md`

Structure:
1. **Introduction** (2–3 sentences): SAM Field's philosophy — "your Mac in your pocket" without re-doing everything you set up on the Mac
2. **First Launch Experience**: Describe the SAMField onboarding flow step by step. Reference actual onboarding steps from the SAMField app entry (`SAMFieldApp.swift`) and any first-launch sheets. Cover: welcome, CloudKit pairing with the Mac (the trust handshake), permissions priming for location/motion/microphone/contacts, vehicle setup for trip tracking.
3. **Pairing With the Mac**: Describe the CloudKit-based pairing experience — same iCloud account = automatic trust, no PIN entry needed. Reference `DevicePairingService.swift`.
4. **TipKit Discovery**: Describe how TipKit tips appear as users land on each tab for the first time. List 3–4 example tips with their exact titles from `FieldTips.swift`.
5. **In-App Help**: Describe how Help is reached from Settings, and how TipKit "Learn more" links open the matching guide article.
6. **Working Offline**: Briefly describe what happens when the Mac isn't reachable — recordings queue, trips keep tracking, briefing shows last-synced state.

For EACH section in BOTH documents, specify a screenshot that should accompany it. Use existing screenshots from `SAM/Resources/Guide/` where they exist. For any that don't exist, note them as "SCREENSHOT NEEDED: [description]" so they can be captured manually.

Tone: Warm, welcoming, emphasizing that SAM meets you where you are.
Length: 400–600 words each.

---

## Phase 8: Asset Inventory & Final Report

After all phases complete, produce a summary.

### Coverage Matrix (Final)
Reproduce the coverage matrix from Phase 0 with updated status after all fixes:
**Platform** | **Feature** | **Has Tip?** | **Has Guide Article?** | **Has Screenshot?** | **In Screenshot Runner?**

### Status Summary
1. **Feature inventory**: X macOS features across Y sidebar sections; A iOS features across B tabs
2. **Tooltip status**:
   - macOS (`SAMTips`): X tips verified, Y updated, Z created, W gaps remaining
   - iOS (TipKit / `FieldTips`): X tips verified, Y updated, Z created, W gaps remaining
3. **Guide status**: X articles verified, Y updated, Z created (broken down by `platform: macOS` / `iOS` / `both`); W screenshots missing
4. **Screenshot runners**:
   - macOS: X automated specs, Y manual specs, Z added this run
   - iOS: X automated specs (or "manual-only for v1"), Y manual specs, Z added this run
5. **Test status**:
   - macOS: X tests passing, Y fixed
   - iOS: X tests passing, Y fixed
6. **Warning status**:
   - macOS: X warnings resolved, Y remaining
   - iOS: X warnings resolved, Y remaining
7. **Marketing assets generated**:
   - Overview document: path, word count
   - Topic documents: list with paths and word counts (flag iOS-specific topics)
   - macOS onboarding showcase: path, word count, screenshots needed
   - iOS onboarding showcase: path, word count, screenshots needed
8. **Platform readiness**:
   - macOS: ready / blockers
   - iOS (SAM Field): ready / blockers
9. **Recommended manual steps**: Any items that require human action (iOS screenshot capture on a device, NotebookLM upload, guide screenshot runner execution, App Store Connect metadata, TestFlight build, etc.)
