# SAM – Project Context (Concise)
_Last updated: 2026-02-07_

See also: [Changelog](changelog.md)

[TOC]

- [1) Purpose & Principles](#purpose)
- [2) System Architecture (At-a-Glance)](#architecture)
- [3) Critical Gotchas (Must Follow)](#gotchas)
  - [3.1 Permissions (CNContactStore / EKEventStore)](#permissions)
  - [3.2 Store & Singleton Management](#singletons)
  - [3.3 SwiftData Patterns](#swiftdata)
  - [3.4 SwiftUI Notes](#swiftui-notes)
  - [3.5 Insight/Evidence Links](#insight-links)
- [4) Current Capabilities (High Signal)](#capabilities)
- [5) Recent Fixes (Why They Matter)](#recent-fixes)
- [6) Roadmap (Next Steps)](#roadmap)
  - [Phase 5: Communication Integration](#phase-5)
  - [Phase 6: AI Assistant](#phase-6)
  - [Phase 7: Compliance & Data Integrity](#phase-7)
  - [Phase 8: iOS Companion App](#phase-8)
- [7) UX Guardrails (Stay Native)](#ux-guardrails)
- [8) Technical Debt & Polish](#tech-debt)
- [9) Non-Negotiables](#non-negotiables)
- [Changelog](changelog.md)

## <a id="purpose"></a>1) Purpose & Principles
- Native macOS SwiftUI assistant for independent financial strategists.
- Observes Calendar and Contacts to create Evidence and AI-backed Insights for relationship management.
- AI assists, never acts autonomously. All suggestions require explicit user approval.
- Design values: Clarity, Responsiveness, Familiarity, Trust. Prefer standard macOS patterns.

## <a id="architecture"></a>2) System Architecture (At-a-Glance)
- Navigation: NavigationSplitView with sidebar (Awareness, People, Contexts, Inbox). Sidebar selection via @AppStorage.
- Data Models (@Model): SamEvidenceItem, SamPerson, SamContext, SamInsight, SamNote, SamAnalysisArtifact.
- Repositories/Coordinators: EvidenceRepository, PeopleRepository, CalendarImportCoordinator, ContactsImportCoordinator.
- Singletons: EvidenceRepository.shared, PeopleRepository.shared, CalendarImportCoordinator.eventStore, ContactsImportCoordinator.contactStore, SAMModelContainer.shared (nonisolated), PermissionsManager.shared.
- Views (primary): InboxListView/InboxDetailView/AwarenessHost, PeopleListView/PersonDetailHost, ContextListView/ContextDetailRouter.
- Concurrency: Swift 6 async/await; SAMModelContainer.shared and newContext() are nonisolated for background usage.

## <a id="gotchas"></a>3) Critical Gotchas (Must Follow)

### <a id="permissions"></a>3.1 Permissions (CNContactStore / EKEventStore)
- Any data access on CNContactStore/EKEventStore triggers a system dialog if not authorized.
- Safe (no dialog):
```swift
CNContactStore.authorizationStatus(for: .contacts)
EKEventStore.authorizationStatus(for: .event)



