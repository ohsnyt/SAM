# SAM – Changelog

A compact history of notable changes, fixes, and phases. For current architecture and guardrails, see context.md.

## 2026-02-07 – Permission Dialog UX Fix
- Fixed unexpected Contacts permission prompts at startup.
- Added authorization guards to ContactValidator and isInSAMGroup.
- Switched ContactPhotoFetcher to use ContactsImportCoordinator.contactStore (shared instance).
- Removed intermediate alerts in Settings; requests go directly to system dialogs.
- Centralized permission flow via PermissionsManager.
- Result: Predictable, user-initiated permission dialogs only.

## 2026-02-07 – Notes-first Evidence Pipeline
- Introduced SamNote and SamAnalysisArtifact (@Model) and added to schema (SAM_v5).
- End-to-end: SamNote → SamAnalysisArtifact → SamEvidenceItem → signals → SamInsight.
- Heuristic NoteLLMAnalyzer extracts people, topics, facts, implications, and sentiment.
- Insights include detailed, context-aware messages; appear on relevant person/context pages.
- Fixed bidirectional inverse relationships (SamPerson.insights ↔ SamInsight.samPerson).
- Developer tooling: improved restore developer fixture; comprehensive debug logging.

## 2026 – Phase 3: Evidence Relationships (Complete)
- Replaced evidenceIDs with @Relationship basedOnEvidence on SamInsight.
- Added inverse supportingInsights to SamEvidenceItem; delete rule .nullify.
- Backup/Restore: BackupInsight DTO preserves evidence links.
- Computed property interactionsCount derives from basedOnEvidence.count.

## 2026 – Concurrency & Model Container
- SAMModelContainer.shared marked nonisolated to avoid MainActor inference.
- newContext() kept nonisolated for background work.
- Seed hook moved to SeedHook.swift and kept @MainActor.

## 2026 – Phase 4: Core UX Refinement (Highlights)
- Search & filtering in People, Contexts, Inbox with persisted filter state.
- Sidebar badges for Awareness and Inbox with timed/triggered refresh.
- Detail view quick actions and keyboard shortcuts across primary views.
- Keyboard Shortcuts Palette (⌘/) and sidebar navigation shortcuts (⌘1–⌘4).

## 2026 – Backup & Restore Improvements
- AES-256-GCM + PBKDF2 encrypted backups with versioned DTOs.
- Relationship re-linking by UUID on restore.

## 2025 – Insight Generation Pipeline (Complete)
- Debounced generation triggered post-import and on app launch (safety net).
- Duplicate prevention (composite uniqueness: person + context + kind).
- Evidence aggregation to single insights; lifecycle logging.

## Earlier (Pre-2025) – Foundations
- Calendar/Contacts single shared stores with macOS per-instance auth cache behavior documented.
- Repository configuration and schema fallback to prevent early-init crashes.
