# Crash Recovery & Database Integrity

SAM defends against partial-write corruption and bad migrations with three layers: startup hardening (every launch), crash report capture (next launch after a crash), and Safe Mode (Option-key launch).

## Startup Hardening (Every Launch)

Runs automatically in `SAMModelContainer` before opening the store:

- `checkpointStoreIfNeeded()` — WAL checkpoint
- `backupStoreBeforeOpen()` — timestamped backup of store files before migration (keeps last 3)
- `cleanupOrphanedReferences()` — raw SQL nullification of dangling FK references (4 known FK mappings)
- **Crash loop guard** — if app crashed within 10s of last launch, reset sidebar to "today" to avoid re-loading the offending view

## Crash Report Auto-Detection

`CrashReportService` runs on every launch:

- `sam.cleanShutdown` flag set `false` at launch, `true` in `applicationShouldTerminate`
- `sam.debuggerAttached` records whether the previous session was running under Xcode/lldb (`sysctl` + `kinfo_proc.p_flag & P_TRACED`)
- On next launch, if cleanShutdown is `false` and `sam.lastLaunchTimestamp > 0`, scan `~/Library/Logs/DiagnosticReports/` (and `/Library/...` and `/Retired`) for `SAM_*.ips` / `SAM-*.ips` / `sam.SAM*.ips` files created after the previous launch
- If a `.ips` is found, wrap it with SAM context (version, schema, hardware, mac model) and show the red `CrashReportBanner` at the top of Today view
- "Send Report" emails to `sam@stillwaiting.org` with `[CRASH REPORT]` subject via `NSSharingService(.composeEmail)` (fallback: mailto URL)
- Dismiss records the crash timestamp in `sam.crashReport.dismissedTimestamp` to prevent re-showing
- **Debugger suppression** — if the previous session had a debugger attached AND no `.ips` was found, treat it as a clean dev termination and skip the banner. Real crashes still surface because a `.ips` is still written even when debugged.

## Safe Mode (Option Key During Launch)

Skips all normal startup: no `SAMModelContainer.shared`, no coordinators, no imports, no AI.

`SafeModeService` operates on raw SQLite directly with seven check categories:

1. **WAL checkpoint** — flush pending writes
2. **`PRAGMA integrity_check`**
3. **Table inventory** with row counts
4. **Full FK repair** — 12 known mappings + heuristic discovery of unknown FK columns
5. **Many-to-many join table cleanup** — orphaned rows
6. **Duplicate UUID detection**
7. **Schema metadata report**

`SafeModeView` shows a streaming log with color-coded severity icons. "Email Report" sends to `sam@stillwaiting.org` with `[DATABASE REBUILD]` subject. "Restart SAM" relaunches in normal mode (`sam.safeMode.justCompleted` flag prevents re-entry).

`AppDelegate.applicationDidFinishLaunching` and `applicationShouldTerminate` are guarded to skip data layer access in safe mode.
