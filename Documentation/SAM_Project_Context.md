
SAM Project Context Summary

🎯 Purpose

SAM is a native macOS / iOS SwiftUI application acting as a cognitive assistant for relationship management for independent financial strategists (insurance agents under World Financial Group).

Its goal:

> “A native Mac assistant that quietly helps me steward relationships well.”

It observes interactions (Calendar, later Contacts, Mail, Zoom), turns them into Evidence, and then produces Evidence-backed Insights that recommend next steps.

AI is assistive, never autonomous:
* Suggests
* Explains why
* Never acts without approval

---

🧠 Core Design Principles
* SwiftUI-first, macOS Human Interface Guidelines
* NavigationSplitView (no nested NavigationStacks)
* Sidebar navigation: Awareness, People, Contexts, Inbox
* Inspectors and sheets, not alerts
* Local-first processing where possible
* Trust, transparency, and reversibility

---

🗂 Architecture Overview

Key Concepts

EvidenceItem
* Represents imported data (Calendar events currently)
* Fields include:
    * id
    * state (needsReview / done)
    * sourceUID (stable: eventkit:<calendarItemIdentifier>)
    * source (.calendar)
    * occurredAt, title, snippet, bodyText
    * signals: [EvidenceSignal]
    * proposedLinks
    * linkedPeople, linkedContexts

EvidenceSignal
* Deterministic, explainable triggers (not AI yet)
* Examples:
    * unlinkedEvidence
    * divorce
    * comingOfAge
    * partnerLeft
    * productOpportunity
    * complianceRisk

EvidenceBackedInsight (in AwarenessHost)
* Built by grouping EvidenceSignals
* Displayed in AwarenessView
* Shows:
    * message
    * confidence
    * evidence count
    * drill-in to Evidence

---

🔁 Data Flow

Calendar App
→ CalendarImportCoordinator
→ MockEvidenceRuntimeStore.upsert()
→ EvidenceItem created/updated
→ InsightGeneratorV1 adds signals
→ AwarenessHost derives EvidenceBackedInsights
→ User reviews in Awareness & Inbox

---

📅 Calendar Integration (implemented)
* User selects one Calendar (can create “SAM” calendar)
* Permissions requested in Settings
* Import window: past & future days
* Incremental import
* Pruning implemented:
    * If event is deleted or moved out of SAM calendar → Evidence is removed
* Throttling:
    * Normal import: 5 minutes
    * Calendar-changed import: 10 seconds

Important bug fixed: Duplicate evidence was caused by two import paths. Now only CalendarImportCoordinator imports.

---

📥 Inbox
* Shows EvidenceItems needing review
* User can:
    * Link to People and Contexts
    * Accept or decline proposed links
    * Mark evidence done
    * Reverse link decisions
* EvidenceDrillInSheet shows details and signals

---

🧭 Awareness
* Shows grouped EvidenceBackedInsights:
    * Needs Attention
    * Suggested Follow-Ups
    * Opportunities
* Each Insight shows:
    * message
    * confidence
    * evidence count
    * drill-in to evidence

---

🧑 People & 🏠 Contexts

People
* Individuals, business owners, recruits, vendors, referral partners
* Duplicate detection when creating new people
* Can be added to contexts

Contexts
* Household
* Business
* Recruiting
* Duplicate detection on creation
* ContextDetailView shows participants, products, consent requirements, interactions, insights

---

⚙️ Settings (macOS style)

Accessible via:

SAM → Settings…

Includes:
* Calendar permission status
* Create/select SAM calendar
* Contacts permission status
* Import windows
* Enable/disable calendar import

Usage description strings in Info.plist:
* Calendar access explanation
* Contacts access explanation

Sandbox entitlements enabled.

---

🧠 InsightGenerator v1 (current phase)

Deterministic rule-based generator that produces EvidenceSignals:

Rule A — Unlinked Calendar Event
→ Follow-up insight

Rule B — Keyword triggers
* Divorce / separation
* Coming of age
* Partner left
* Product terms (annuity, LTC, college savings, trusts)
* Compliance terms (beneficiary, consent, underwriting)

Signals include:
* kind
* confidence
* reason (plain English)

Signals feed directly into AwarenessHost’s EvidenceBackedInsight logic.

---

🗃 Key Files
* CalendarImportCoordinator.swift — imports calendar events
* MockEvidenceRuntimeStore.swift — stores EvidenceItems, upsert, prune
* EvidenceModels.swift — EvidenceItem, EvidenceSignal, ProposedLink
* AwarenessHost.swift — EvidenceBackedInsight model & UI
* InboxHost.swift — Inbox UI
* SamSettingsView.swift — Settings UI
* AppShellView.swift — NavigationSplitView layout

---

⚠️ Known Pitfalls
* Do not use nested NavigationStacks inside NavigationSplitView
* Only one Calendar import path allowed
* Always use sourceUID = "eventkit:<calendarItemIdentifier>"
* Prune logic must run when calendar changes
* Long chats break file uploads → use this summary

---


