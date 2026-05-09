# SAM Architecture Diagrams

A starter set of Mermaid diagrams for navigating SAM's architecture, models, and key flows. All diagrams render natively on GitHub and most Markdown viewers — no build step.

## Index

| # | Diagram | Use it when… |
|---|---|---|
| 01 | [System Context](01-system-context.md) | Onboarding someone to "what is SAM and what does it touch?" |
| 02 | [Containers & Components](02-container-components.md) | Deciding *where* a new feature belongs (View / Coordinator / Service / Repo) |
| 03 | [Data Models (ER)](03-data-models.md) | Modifying schema, adding a new model, understanding relationships |
| 04 | [Recording → Summary Flow](04-flows-recording.md) | Working on transcription, polish, summary, retention |
| 05 | [Note → Outcome Flow](05-flows-note-to-outcome.md) | Working on note analysis, outcomes, calibration, gap prompts |
| 06 | [RLM Orchestration](06-flows-rlm-orchestration.md) | Working on `StrategicCoordinator`, specialists, briefing/digest content |
| 07 | [Briefing + Phone Sync](07-flows-briefing-sync.md) | Working on Today view, daily briefing, CloudKit sync |
| 08 | [Social Import (Auto-Detect)](08-flows-social-import.md) | Adding a platform, debugging email/file watchers |
| 09 | [State Machines](09-states-pipeline.md) | Working on pipeline, recruiting, lifecycle, recording, events, outcomes |

## How these are organized

Three lenses, each answering a different question:

- **Structure** (01–03) — *what exists*. System boundaries, layers, data shape.
- **Behavior** (04–08) — *how things move*. Sequence diagrams of the key flows that span multiple layers.
- **State** (09) — *what each thing is doing right now*. State machines for the discrete lifecycles SAM tracks.

A pure mind map wasn't right for SAM: too much of the complexity is *flow* (recording lifecycle, RLM dispatch) and *relationships* (SwiftData models), which mind maps can't express. The mix above covers each kind of complexity with the diagram type best suited to it.

## Maintenance

These diagrams are hand-maintained — they live next to `context.md` and follow the same update cadence: update them when an architectural change ships, not before. Keep them at the same level of abstraction as `context.md` (no per-class detail; aim for "a senior engineer can orient in 60 seconds").

**Quick rules**:
- One diagram per concern. If a flow needs a 30-step sequence, it's two flows.
- Reference the source-of-truth file (`SAMModels-*.swift`, `*Coordinator.swift`, `*Service.swift`) instead of duplicating field lists.
- When `context.md §6` (data models) or §8 (schema versions) changes, update [03-data-models.md](03-data-models.md).
- When the layered architecture changes (`context.md §2`), update [02-container-components.md](02-container-components.md).
- When a new RLM specialist is added, update [06-flows-rlm-orchestration.md](06-flows-rlm-orchestration.md).

## Rendering

Mermaid renders inline on GitHub, in VS Code with the Markdown Preview extension, and in any Mermaid Live Editor (`mermaid.live`). No build step required.

If a diagram outgrows readability, split it (e.g., separate "Pipeline ER" from "Time/Content/Compliance ER" inside [03](03-data-models.md)) rather than cramming detail in.

## Not yet covered (deliberately)

- **Permissions / entitlements flow** — could become #10 if useful.
- **Backup/restore + crash recovery** — covered in `context.md §7`; could become #11 if visual aid helps.
- **Compliance scanning + audit trail** — covered in `context.md §7.1`; could become #12.
- **Per-coordinator sequence diagrams** for less-trafficked flows (event evaluation, presentation library, mileage). Add only when someone is actively working in that area.

If you find yourself answering the same architectural question twice, that's a signal it's worth a diagram here.
