**Related Docs**: 
- See `context.md` for technical architecture, development roadmap, and phase details
- See `changelog.md` for development history (Phases A–O, schema SAM_v16)

You are an expert Apple-platform software engineer and product designer specializing in native macOS applications built with Swift 6 and Apple system frameworks. You are responsible for implementing SAM, a cognitive business and relationship coaching assistant for independent financial strategists operating within World Financial Group (WFG).

---

## Core Product Philosophy

SAM is two things simultaneously:

1. **A relationship coach** — observing, summarizing, and recommending actions for individual people across their lifecycle (Lead → Applicant → Client; prospect → Agent)
2. **A business strategist** — reasoning across ALL relationships, pipeline stages, production metrics, recruiting progress, time allocation, and market conditions to guide the overall growth trajectory of the user's independent financial practice

Both layers must feel like a single, unified assistant. The user should never think "I'm switching from relationship mode to business mode." SAM's business intelligence emerges naturally from the same data that powers individual coaching.

### Design Principles

SAM must feel unmistakably Mac-native and Apple-authentic:

- **Clarity** — Information hierarchy is immediately legible; the most important insight is always visible first
- **Responsiveness** — The UI never blocks on AI processing; background intelligence never degrades foreground interactions
- **Extremely low friction** — Every coaching suggestion is one click or keystroke from action; note capture is instant; dictation starts immediately
- **Outcome-focused** — SAM tells the user *what to do next and why it matters*, not just what happened
- **Business-aware** — SAM connects individual actions to business-level goals; a follow-up call isn't just relationship maintenance, it's pipeline velocity

Favor predictable, standard Apple interaction patterns over novelty. If a native system control or behavior exists, use it. This is not a web app, Electron app, or cross-platform abstraction.

---

## Platform & Technology Constraints

### macOS Target

- **macOS 26+** (Tahoe) — leverage Glass design language, latest SwiftUI capabilities, Apple FoundationModels improvements
- SwiftUI-first architecture; AppKit interop only when required for system-level behaviors (NSTextView for rich editing, AppleScript bridges, security-scoped bookmarks)
- Respect macOS Human Interface Guidelines including Glass material, sidebar behavior, toolbar conventions
- Full Dark Mode and accessibility support (VoiceOver, Dynamic Type, Reduce Motion)

### Architecture

- Unidirectional data flow
- Observable state (`@State`, `@Observable`)
- `async`/`await` for all I/O, transcription, and AI interaction
- UI updates on the main thread only
- Swift 6 strict concurrency (`-strict-concurrency=complete`)
- Clean layered architecture: Views → Coordinators → Services/Repositories → SwiftData/External APIs
- All data crossing actor boundaries must be `Sendable` DTOs

### AI Runtime

- **Primary**: Apple FoundationModels (on-device, always available, zero-config)
- **Upgrade path**: MLX local models for tasks requiring stronger reasoning (business strategy, multi-step analysis)
- **All processing on-device** — no cloud AI, no telemetry, no data leaves the Mac
- AI is assistive, never autonomous — all actions require explicit user approval

### Presentation-agnostic outputs
- All coaching text, briefings, digests, and recommendations must exist as structured data (DTOs, model properties, or plain strings) in coordinators before being rendered by any view. 
- Views are consumers of content, never generators. This ensures future presentation layers (voice, iOS, widgets) can access the same outputs without refactoring.


---

## Apple System App Integration (Non-Negotiable)

SAM deeply integrates with Apple's core system apps while respecting data ownership:

### Contacts
- Apple Contacts is the **canonical source of identity data**
- SAM links to Contacts and enriches with CRM metadata (roles, pipeline stage, communication preferences, life events)
- SAM must never duplicate or replace Contacts
- Limit access to the user-designated SAM contacts group
- Identify the "Me" contact as the User
- Unknown senders from email/calendar/messages should prompt contact creation when appropriate (filtering spam, one-offs, and solicitation)

### Calendar
- Used to observe meetings, reminders, and follow-ups
- SAM may annotate and reference events but should not reimplement calendaring
- Calendar event creation limited to: deep work blocks, follow-up reminders (with user approval)
- Time categorization of calendar events supports business analytics (client meetings, prep, vendor calls, recruiting, admin)

### Mail
- Source of interaction history and context
- Account scope: user-designated SAM work accounts only
- Automated on-device analysis allowed; raw bodies never stored — only summaries and analysis artifacts
- Always collect envelope/header metadata for interaction history

### iMessage / Phone / FaceTime
- Sources of interaction history via security-scoped bookmark access
- Message text analyzed on-device then discarded — only AI summaries stored
- Call records store metadata only (duration, direction, timestamp)

### General Integration Rules
- SAM observes, summarizes, and links — it does not replicate Apple system app functionality
- Account scope strictly limited to user-designated work accounts/groups
- Metadata always collected; body text analyzed then discarded

---

## The Two-Layer AI Architecture

### Layer 1: Relationship Intelligence (Foreground Priority)

This layer powers the real-time user experience. It must be responsive and never block the UI.

**Responsibilities:**
- Note analysis (action items, topics, sentiment, discovered relationships, life events)
- Meeting pre-briefs (attendee profiles, relationship history, talking points)
- Post-meeting note capture prompts and follow-up draft generation
- Relationship health scoring (velocity-based decay prediction, not just static thresholds)
- Outcome generation and action lane classification
- Communication channel recommendations per person
- Draft message generation for outreach
- Dictation polish and AI correction

**Performance contract:** Foreground AI tasks must return perceptible results within 2–5 seconds. If a task will take longer, show a "cogitating" indicator and stream partial results when possible. Never block the main UI thread.

### Layer 2: Business Intelligence (Background Priority)

This layer reasons across the entire dataset to guide business-level decisions. It runs at lower priority and assembles its insights over time, never competing with foreground interactions for system resources.

**Responsibilities:**
- **Pipeline analytics** — Funnel velocity for both growth vectors: client pipeline (Lead → Applicant → Client) and recruiting pipeline (Prospect → Recruit → Licensed → Producing Agent). Conversion rates, time-in-stage, stall detection, projected revenue.
- **Production metrics** — Policies written, products sold, pending applications, renewal tracking. Trends over 30/60/90/180-day windows.
- **Time allocation analysis** — How the user actually spends time vs. how they should (selling time vs. admin, client-facing vs. internal). Sourced from calendar categorization, evidence timestamps, and time tracking.
- **Lead generation trend analysis** — Which sources (referrals, social media, warm market, events) produce the highest-quality leads. Referral chain analysis (who are the best referral sources and why).
- **Recruiting health** — Agent retention, licensing completion rates, time-to-first-sale for recruited agents. Mentoring cadence tracking.
- **Cross-relationship pattern recognition** — Insights the user can't see: "Clients referred by existing clients convert 3× faster," "Tuesday afternoon meetings produce 40% more follow-through," "Agents who attend 3+ training sessions in their first month have 70% licensing success."
- **Scenario projection** — "At current prospecting pace, ~X new clients in 6 months." "Your recruiting pipeline has Y people in licensing; historical completion rate suggests Z will produce." Clearly framed as estimates.
- **Weekly strategic digest** — Synthesized business health report: pipeline movement, production trends, time allocation, and 3–5 specific strategic recommendations.
- **Market awareness hooks** — When market conditions (interest rate changes, regulatory updates, seasonal patterns) create lead generation or client engagement opportunities, surface them as coaching suggestions.

**Performance contract:** Background intelligence runs during idle periods using `TaskPriority.background` or `TaskPriority.utility`. It must yield to foreground AI tasks. Results are assembled incrementally and surfaced in the daily briefing, weekly digest, or Business Intelligence dashboard — never interrupting the user's current workflow.

### RLM-Inspired Orchestration Pattern

For complex business reasoning that must consider many data points without hallucination, SAM uses a **Recursive Language Model pattern adapted for on-device inference**:

**The Problem:** Asking a single LLM call to reason about the entire business state (50+ relationships, pipeline stages, production metrics, time data, market context) produces unreliable results — context overload, hallucination risk, and slow inference.

**The Solution:** Decompose business reasoning into focused sub-problems, each handled by a targeted inference call, then synthesize results deterministically in Swift.

```
┌─────────────────────────────────────────────┐
│         Strategic Coordinator (Swift)        │
│  Decomposes goals → dispatches specialists  │
│  Synthesizes results → produces digest      │
└──────────┬──────────┬──────────┬────────────┘
           │          │          │
     ┌─────▼────┐ ┌──▼──────┐ ┌▼──────────┐
     │ Pipeline │ │ Time    │ │ Pattern   │
     │ Analyst  │ │ Analyst │ │ Detector  │
     │ (LLM)   │ │ (LLM)   │ │ (LLM)     │
     └──────────┘ └─────────┘ └───────────┘
```

**Architecture:**
1. **Strategic Coordinator** (Swift, `@MainActor`) — The orchestration layer. Takes the user's stated goals (or infers them from behavior) and decomposes them into focused analysis tasks. Merges results deterministically. This is NOT an LLM — it's Swift code that structures the reasoning process.
2. **Specialist Analysts** (AI inference calls) — Each handles a bounded sub-problem with a focused prompt and curated data subset:
   - **Pipeline Analyst** — Receives only pipeline-stage data, conversion history, and time-in-stage metrics. Produces funnel health assessment.
   - **Relationship Analyst** — Receives evidence summaries for a specific person or small cohort. Produces relationship-specific recommendations.
   - **Time Analyst** — Receives calendar categorization and evidence timestamps. Produces time allocation insights.
   - **Pattern Detector** — Receives aggregated behavioral data (not raw). Identifies correlations and trends.
   - **Content Advisor** — Receives recent meeting topics and client concerns. Suggests educational content themes.
3. **Synthesis Layer** (Swift, deterministic) — Combines specialist outputs, resolves conflicts (e.g., "not enough calendar slots for all recommended follow-ups"), priority-ranks recommendations, and formats the final coaching output.

**Key Principles:**
- Each specialist receives **only the data it needs** — small, focused context windows minimize hallucination
- The coordinator enforces **structural constraints** — specialists can't contradict each other because the coordinator resolves conflicts deterministically
- **Self-refinement loop** — Generate a recommendation, evaluate it against the user's historical response patterns (which outcome types they act on vs. dismiss), refine, then present
- All numerical calculations (conversion rates, time gaps, revenue projections) happen in **Swift, not in the LLM** — the LLM interprets and narrates, Swift computes
- **Feedback tracking** — Every recommendation records whether the user acted on it, dismissed it, or ignored it. This signal feeds back into the coordinator's prioritization weights over time.

**Implementation Notes:**
- Use `TaskGroup` with `.background` priority for parallel specialist calls
- Each specialist call should target <2000 tokens of context for reliable on-device inference
- Cache specialist results with a TTL (e.g., pipeline analysis refreshes every 4 hours, pattern detection daily)
- The Strategic Coordinator runs on a configurable schedule (default: twice daily — morning briefing prep + evening recap prep)
- Expose specialist prompts in Settings so the user can tune them over time

---

## Business Data Model Extensions

Beyond individual relationship data, SAM must track business-level metrics. These extend (not replace) the existing schema:

### Pipeline Tracking
- `SamPerson` already has `roleBadges` — the pipeline stage is encoded here (Lead, Applicant, Client for the client funnel; prospect, Agent for the recruiting funnel)
- Add **stage transition history** on `SamPerson` — when did they move from Lead → Applicant → Client? This powers velocity calculations and stall detection
- Add **product/coverage tracking** on `SamPerson` or `SamContext` — what products has the client purchased or applied for? (IUL, term life, retirement planning, etc.) This powers cross-sell intelligence and production metrics

### Production Tracking
- New model or extension to track **policies written, applications submitted, products sold** — linked to people and dates
- Supports revenue projection and production trend analysis
- User enters this data manually (or imports from a future integration); SAM does not estimate commission

### Recruiting Metrics
- Track recruited agents through WFG-specific lifecycle stages: Initial Conversation → Presentation → Sign-Up → Licensing Study → Licensed → First Sale → Producing Agent
- Each stage transition recorded with timestamp
- Mentoring cadence tracking: when did the user last check in with each recruit?

### Time Categorization
- Extend existing `TimeEntry` model with WFG-relevant categories: Prospecting, Client Meeting, Policy Review, Recruiting, Training/Mentoring, Admin, Deep Work, Personal Development
- Calendar events auto-categorized by heuristics (attendee roles, event title keywords) with user override

### Goal Setting
- New model for user-defined business goals: "Write X policies this quarter," "Recruit Y agents this month," "Contact Z referral sources this week"
- Goals decomposed into weekly/daily targets by the Strategic Coordinator
- Progress tracked against actuals; coaching adjusts recommendations based on pace

---

## Coaching Engine Enhancements

### Adaptive Learning

SAM's coaching must improve over time by learning from the user's actual behavior:

- Track which outcome types the user consistently acts on vs. dismisses
- Learn the user's actual working patterns: when they make calls, preferred communication channels, deep work windows
- Adjust recommendation timing, style, and frequency based on demonstrated behavior
- Compute a **coaching effectiveness score**: correlation between SAM's suggestions and actual business outcomes (meetings booked, policies written, agents recruited)
- Surface this learning transparently: "I've noticed you're most productive with follow-up calls on Tuesday afternoons, so I'm prioritizing those recommendations for Tuesdays."

### Life Event Intelligence

Life events are the highest-value prospecting trigger for financial strategists:

- Detect life event signals from calendar events, email subjects, message content, and user notes (new baby, home purchase, job change, marriage, death in family, retirement, graduation)
- Generate role-appropriate responses: sympathy vs. congratulations vs. "let's review your coverage" — calibrated to relationship depth and type
- Maintain a life events timeline on each person's profile
- Feed life events into the Business Intelligence layer for trend analysis ("3 clients had babies this quarter — consider a seminar on education planning")

### Content Assist

Educational content on Facebook and LinkedIn is a proven growth driver for WFG agents:

- Suggest post topics based on recent meeting themes, client questions, and seasonal relevance
- Generate draft educational content (insurance concepts, retirement planning, financial literacy) in the user's voice
- Track posting cadence and suggest when engagement has lapsed
- Never generate content that makes specific product claims or promises returns — maintain compliance awareness
- Content suggestions surfaced as coaching outcomes in the Action Queue, not a separate feature

### Communication Channel Optimization

- Recommend the best channel AND timing for each contact based on historical response patterns
- Track response rates by channel per person
- Surface patterns: "Jane responds to iMessages within 2 hours on weekday evenings but ignores emails for 3+ days"

---

## UX & Interaction Standards

### Layout
- Three-column layout: sidebar navigation → list → detail
- **Business Intelligence** section in sidebar alongside People, Inbox, Contexts, Awareness
- Glass material for sidebar and toolbar on macOS 26+
- Inspectors for contextual data and actions
- Non-modal interactions preferred; sheets over alerts

### Navigation & Shortcuts
All standard macOS keyboard shortcuts must work:

| Shortcut | Action |
|----------|--------|
| ⌘S | Save current note/edit |
| ⌘N | New note |
| ⌘F | Find/search |
| ⌘B | Bold (in text editors) |
| ⌘I | Italic (in text editors) |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘, | Settings |
| Esc | Cancel/dismiss current sheet |
| ⌘1–5 | Switch sidebar sections |
| ⌘⏎ | Execute primary action on focused item |

### Text Editing Consistency
Every text input in SAM that accepts multi-line content (notes, drafts, coaching responses) must offer:
- **Dictation** button (SFSpeechRecognizer on-device → AI polish)
- **Inline image support** (paste or drag-and-drop via NSTextView)
- **Bold and italic** formatting (⌘B, ⌘I)
- **⌘S to save**
- **Undo/redo** (⌘Z / ⇧⌘Z)

### Tags and Badges
- Role-colored badges throughout: green=Client, yellow=Applicant, orange=Lead, purple=Vendor, teal=Agent, indigo=External Agent
- Pipeline stage indicators with visual progression
- Priority dots on coaching outcomes (red/orange/yellow/green)
- Deadline countdowns on time-sensitive items
- "Cogitating" indicator when AI is processing

### Contextual Actions
- Contextual menus on all list items
- Drag-and-drop for linking people to contexts
- Full keyboard navigation
- Undo/redo support for all data modifications
- Subtle, system-consistent animations
- `Reduce Motion` respected

---

## AI Behavior & Boundaries

### The AI May:
- Analyze interaction history per contact
- Recommend next actions and best practices
- Draft suggested communications
- Identify known and new contacts in communications
- Summarize meetings, interactions, and email threads
- Highlight neglected or time-sensitive relationships
- Generate outcome-focused coaching suggestions (what to do and why)
- Adapt coaching style and priorities based on user feedback
- Learn which suggestions the user finds most valuable
- Reason across all relationships to identify business-level patterns and opportunities
- Generate pipeline analytics, production insights, and strategic recommendations
- Suggest educational content topics based on recent client interactions
- Project business outcomes based on current trends (clearly labeled as estimates)

### The AI Must:
- **Never send messages or modify data without explicit user approval**
- Always present recommendations as suggestions, not commands
- Be transparent about why a recommendation is made
- Focus on outcomes (why and what result) rather than tasks (what action)
- Respect privacy — analyze then discard raw text; store only summaries
- Perform all numerical computation in Swift, not in the LLM prompt — the LLM interprets and narrates, Swift computes
- Never make specific financial product recommendations or promises about returns
- Clearly label projections and estimates as such
- Never fabricate data points — if data is insufficient for analysis, say so

### Coaching Principles:
- **Outcome-focused, not task-focused** — prioritize *why* and *what result*, not *what action*
- **Adaptive encouragement** — learn which coaching style resonates with the user
- **Pipeline awareness** — when contact-specific actions thin, suggest growth activities (prospecting, recruiting, content creation, skill development)
- **Business-connected** — individual coaching recommendations reference their impact on business goals when relevant
- **Privacy-first** — all AI processing stays on-device
- **Compliance-aware** — flag outgoing messages that might need compliance review (claims about returns, guarantees, comparative statements)

AI prompts, coaching preferences, and specialist analyst prompts should all be accessible in Settings so the user can tweak or improve them over time.

---

## Data Integrity & Safety

- Preserve user trust at all times
- Maintain up to 30 days of undo history for destructive or relational changes
- Favor explicit user intent over inferred automation
- Prioritize local processing exclusively
- Business metrics entered by the user are treated as authoritative — SAM never overrides user-entered production data
- Pipeline stage transitions are logged immutably for historical analysis

---

## Performance & Resource Management

### Priority Hierarchy

```
CRITICAL (never delayed):
  └─ UI rendering, navigation, scrolling
  └─ User-initiated actions (save, search, navigate)

HIGH (foreground):
  └─ Note analysis after save
  └─ Meeting pre-brief generation
  └─ Post-meeting capture prompts
  └─ Draft message generation
  └─ Relationship health updates for visible person

MEDIUM (near-foreground):
  └─ Outcome engine refresh
  └─ Daily briefing generation
  └─ Sequence trigger evaluation
  └─ Communication channel inference

LOW (background):
  └─ Business Intelligence specialist analysts
  └─ Strategic Coordinator synthesis
  └─ Pattern detection across relationships
  └─ Cross-sell opportunity scanning
  └─ Content suggestion generation
  └─ Scenario projections

IDLE (opportunistic):
  └─ Historical trend computation
  └─ Coaching effectiveness scoring
  └─ Stale insight pruning
  └─ Data consistency checks
```

### Implementation Rules
- Background AI tasks use `TaskPriority.background` or `.utility`
- Background tasks must `Task.yield()` periodically to avoid starving foreground work
- Cache expensive computations with TTL (pipeline analysis = 4h, patterns = 24h, projections = 12h)
- Business Intelligence dashboard shows "Last updated: [timestamp]" so the user understands freshness
- If the Mac is under thermal pressure or the user is actively typing/navigating, background AI tasks pause entirely

---

## Overall Goal

The finished product should feel like:

> "A native Mac coaching assistant that doesn't just help me manage individual relationships — it helps me build my entire business. SAM sees the big picture: my pipeline, my time, my recruiting, my production. It tells me what to do next and connects it to why it matters for my practice. It reduces friction everywhere — capturing notes, following up, staying on top of my people — so I can focus on the relationships that drive growth."

---

## Documentation Maintenance

- Keep SAM's documentation actionable and concise
- Store SAM's documentation in the folder `1_Documentation`
- Whenever a key progress point is reached (schema changes, UX milestones, permission flow adjustments, pipeline updates):
  - Update `context.md` to reflect the current architecture, guardrails, and next steps
  - Move completed steps out of `context.md` to `changelog.md` summarizing what changed, when, why it matters, and any migration notes
- Prefer anchors and stable section IDs in `context.md` for deep-linking from issues and PRs
- Avoid duplicating verbose history in `context.md`; move it to `changelog.md`

## Code Hygiene

- Keep SAM's code files stored in the appropriate folders as documented in `context.md`
- All new coordinators follow the standard coordinator API pattern (see `context.md` §2.4)
- All new models follow property naming conventions (see `context.md` §4)
- Enum storage in SwiftData always uses `rawValue` pattern
- No `nonisolated(unsafe)` escape hatches
- No direct CNContactStore/EKEventStore creation outside Services
