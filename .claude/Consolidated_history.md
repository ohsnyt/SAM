# SAM – Consolidated Engineering History and Lessons

_Last updated: 2026-02-07_

This document consolidates key lessons, major historical changes, and high-signal references from engineering notes. It supersedes numerous scattered documents while retaining links for deep dives.

See also:
- Project context and guardrails: ../context.md
- Chronological updates: ../changelog.md

## Table of Contents
- [Guiding Guardrails (Always Apply)](#guardrails)
- [Major Themes & Fixes](#themes)
  - [Permissions & Dialog Control](#permissions)
  - [Contacts Sync, Linking, and Validation](#contacts)
  - [Swift 6 Concurrency & Build Stability](#concurrency)
  - [Insight Promotion: Phases 1–3](#insights)
  - [Data Model & SwiftData Patterns](#data-model)
  - [Keyboard, Toolbar, and UX Polish](#ux)
  - [Compilation & Predicate Fixes](#compile)
  - [Foundation Models Plan](#foundation-models)
  - [Liquid Glass Design (SwiftUI)](#liquid-glass)
- [Superseded Files Index](#superseded)

## <a id="guardrails"></a>Guiding Guardrails (Always Apply)
- Single shared stores: EKEventStore and CNContactStore are singletons owned by their coordinators. Never create ad-hoc instances in views or helpers.
- Permission prompts: Only originate from Settings → Permissions. Always guard any data access with authorization checks.
- SwiftData enums: Store raw values + @Transient computed properties; never store enums directly.
- Relationships: Use non-optional inverse arrays; delete order is Evidence → Contexts → People.
- Concurrency: Prefer async/await and keep SAMModelContainer.shared and newContext() nonisolated for background usage.
- UX: Stick to native macOS patterns. Keyboard shortcuts are first-class and discoverable via ⌘/.

## <a id="themes"></a>Major Themes & Fixes

### <a id="permissions"></a>Permissions & Dialog Control
- Problem: Unexpected CNContactStore/EKEventStore dialogs appeared during startup or background operations.
- Fix: Guard all reads; centralize requests in Settings; remove intermediate app alerts; use shared store instances.
- Why it matters: Predictable, user-initiated consent; prevents surprise dialogs and improves trust.
- Related: PERMISSION_DIALOG_STARTUP_FIX.md, PERMISSION_DIALOG_POSITIONING_FIX.md, PERMISSIONS_CHECKLIST.md, PERMISSIONS_REFACTOR.md, PERMISSION_REQUEST_AUDIT.md.

### <a id="contacts"></a>Contacts Sync, Linking, and Validation
- Problems: Duplicate contactIdentifier values, stale links, merge edge cases, unlinked contact flows.
- Fixes: Group-based import, validation with authorization guards, duplicate detection and merge workflows, consistent SAM group sync.
- Why it matters: Accurate person identity and stable relationships across Evidence and Insights.
- Related: CONTACT_SYNC_FIX.md, CONTACT_SYNC_LINKING_FIXES.md, CONTACT_VALIDATION_README.md, DUPLICATE_CONTACTIDENTIFIER_FIX.md, DUPLICATE_CONTACTS_FIX.md, LINK_CONTACT_MERGE_FIX.md, LINK_CONTACT_SEARCH_FIX.md, LINK_CONTACT_PICKER_REDESIGN.md, MERGE_NAME_RESOLUTION.md, SAM_GROUP_SYNC_FIX.md, SAM_GROUP_SYNC_TRACE.md, DEBUGGING_UNLINKED_CONTACTS.md, QUICK_START_CONTACT_VALIDATION.md, CONTACTS_COORDINATOR_ACTOR_FIX.md.

### <a id="concurrency"></a>Swift 6 Concurrency & Build Stability
- Actions: Migrated to Swift 6 strategies; marked SAMModelContainer.shared nonisolated; resolved actor isolation issues.
- Results: Clean builds, reduced warnings, predictable background work.
- Related: SWIFT6_CONCURRENCY_FIX_SUMMARY.md, SWIFT6_CONCURRENCY_WARNINGS_FIXED.md, OBSERVABLE_BUILD_FIX.md, PHASE_3_COMPILE_FIXES.md, COMPILATION_FIX.md.

### <a id="insights"></a>Insight Promotion: Phases 1–3
- Phase 1: Promote insights to first-class @Model (SamInsight) with relationships to people/contexts.
- Phase 2: Generation pipeline with duplicate prevention, aggregation, debounced runner, and logging.
- Phase 3: Replace evidenceIDs with relationships (basedOnEvidence ↔ supportingInsights); .nullify delete rule; backup/restore preserves links.
- Why it matters: Explainability, deduplication, and durable relationships across backups.
- Related: INSIGHT_PROMOTION_PLAN.md, INSIGHT_PROMOTION_SUMMARY.md, README_INSIGHT_PROMOTION.md, PHASE_2_* files, PHASE_3_* files, IMPLEMENTATION_SUMMARY.md, COMPLETE.md, COMPLETE_FIX_SUMMARY.md.

### <a id="data-model"></a>Data Model & SwiftData Patterns
- Patterns: Enum raw values + @Transient; predicates on raw values; relationship inverses non-optional; DTO boundary for backups only.
- Backup/Restore: AES-256-GCM + PBKDF2; DTOs with UUID re-link; reverse-dependency delete order.
- Related: data-model.md, PREDICATE_ENUM_FIX.md, PHASE_3_BUILD_CHECKLIST.md.

### <a id="ux"></a>Keyboard, Toolbar, and UX Polish
- Keyboard: Sidebar nav (⌘1–⌘4), command palette (⌘/), action shortcuts per view.
- Toolbar: Primary actions, tooltips, conditional visibility; consistent placements.
- Related: KEYBOARD_SHORTCUTS_FIX.md, VISUAL_OVERVIEW.md.

### <a id="compile"></a>Compilation & Predicate Fixes
- Avoid dynamic #Predicate in SwiftUI init; use unfiltered @Query and filter in-memory.
- Place .searchable on HSplitView/NavigationStack, not List (avoid padding flicker).
- Related: PHASE_3_COMPILE_FIXES.md, OBSERVABLE_BUILD_FIX.md.

### <a id="foundation-models"></a>Foundation Models Plan
- Status: Guided generation is planned; currently using heuristic extraction for notes.
- Actions: Re-enable #if canImport(FoundationModels) in NoteLLMAnalyzer when API surface is confirmed.
- Reference: FOUNDATION_MODELS_IMPLEMENTATION.md, FoundationModels-Using-on-device-LLM-in-your-app.md.

### <a id="liquid-glass"></a>Liquid Glass Design (SwiftUI)
- Use native materials and animations sparingly; align with Apple HIG.
- Reference: SwiftUI-Implementing-Liquid-Glass-Design.md.

## <a id="superseded"></a>Superseded Files Index
The following files are consolidated here. Keep for historical detail until removed; future updates should edit this document and changelog instead.

- ADDITIONAL_FIXES_NEEDED.md, BUG_FIX_SUMMARY.md, CLEANUP_TASKS.md, COMPILATION_FIX.md, COMPLETE_FIX_SUMMARY.md, COMPLETE.md
- CONTACT_SYNC_FIX.md, CONTACT_SYNC_LINKING_FIXES.md, CONTACT_VALIDATION_README.md, CONTACTS_COORDINATOR_ACTOR_FIX.md
- data-model.md, DEBUGGING_UNLINKED_CONTACTS.md, DUPLICATE_CONTACTIDENTIFIER_FIX.md, DUPLICATE_CONTACTS_FIX.md
- FOUNDATION_MODELS_IMPLEMENTATION.md, FoundationModels-Using-on-device-LLM-in-your-app.md
- IMPLEMENTATION_SUMMARY.md
- INSIGHT_PROMOTION_PLAN.md, INSIGHT_PROMOTION_PLAN 2.md, INSIGHT_PROMOTION_SUMMARY.md, INSIGHT_PROMOTION_SUMMARY 2.md, README_INSIGHT_PROMOTION.md, README_INSIGHT_PROMOTION 2.md
- KEYBOARD_SHORTCUTS_FIX.md, LINK_CONTACT_MERGE_FIX.md, LINK_CONTACT_PICKER_REDESIGN.md, LINK_CONTACT_SEARCH_FIX.md, LINK_CONTACT_SEARCH_FIX 2.md, MERGE_NAME_RESOLUTION.md
- OBSERVABLE_BUILD_FIX.md, OPTION_A_FIX_COMPLETE.md
- PERMISSION_DIALOG_POSITIONING_FIX.md, PERMISSION_DIALOG_STARTUP_FIX.md, PERMISSION_REQUEST_AUDIT.md, PERMISSIONS_CHECKLIST.md, PERMISSIONS_REFACTOR.md
- PHASE_1_IMPLEMENTATION_GUIDE.md, PHASE_1_IMPLEMENTATION_GUIDE 2.md
- PHASE_2_COMPLETE.md, PHASE_2_COMPLETION_PLAN.md, PHASE_2_FINAL_SUMMARY.md, PHASE_2_PROGRESS_SUMMARY.md, PHASE_2_STATUS.md
- PHASE_3_BUILD_CHECKLIST.md, PHASE_3_COMPILE_FIXES.md, PHASE_3_SUMMARY.md
- PREDICATE_ENUM_FIX.md, QUICK_START_CONTACT_VALIDATION.md
- SAM_GROUP_SYNC_FIX.md, SAM_GROUP_SYNC_TRACE.md
- SWIFT6_CONCURRENCY_FIX_SUMMARY.md, SWIFT6_CONCURRENCY_WARNINGS_FIXED.md, SWIFT6_QUICK_REFERENCE.md
- SwiftUI-Implementing-Liquid-Glass-Design.md, VISUAL_OVERVIEW.md

Notes:
- Update ../context.md and ../changelog.md first, then summarize high-signal lessons here.
- Avoid duplicating detailed logs; link to the original file if necessary until it’s removed.
