# Replay audit and corrections

This report records the preceding 92-test release and initial October 7 publication checks. The [follow-up audit](follow-up-audit.md) and [validation record](follow-up-validation.json) cover the later repairs.

The preceding release's replay and storage fixes passed 92 Swift tests, the offline developer checks, and a release build under Swift 6 complete concurrency checking with warnings as errors. The review began at the former private commit `bbd11d2d150b1dd4f4ad1ccd3a7b4ef4401287d7`. The [validation record](fresh-validation.json) identifies the tested source and the October 7 publication checks. Main was squashed into one `green flag` root commit, with application source unchanged at that initial publication check.

## What changed

Replay navigation now reads the advancing cursor before selecting a lap or event, including at 256× playback. Duration includes every retained dated channel, so late weather, status, pit, validity, and race-control observations remain reachable. Initial lap validity keeps its dated history through later reinstatement. Invalid timestamps, extreme coordinates, and impossible completion chronology are rejected or excluded from indexes. Startup restores the last successfully opened completed recording, paused, with a fallback if its files become unreadable.

Two real-data findings changed the review's initial assumptions. Monaco's bundled intervals contain 59 null leader gaps for drivers who were not first. A null is now labelled LEADER only when that driver's latest recorded position at the observation is P1. Equal qualifying times use recorded completion order, fixing the Russell/Verstappen Canada 2024 tie. Missing telemetry fields break chart lines and interior crosshair readings; a nearby endpoint can no longer fill an unrecorded bracket. The [independent review](fresh-independent.md) records these cases and the extracted production-helper harness.

Malformed archive lengths and row counts are checked before aggregation, preventing integer-overflow crashes. Cancellation is checked during final verification and before installation. Failed deletion reports an error and refreshes the recordings that remain on disk. Legacy migration selects recent eligible files, limits conversion work, stops at library capacity, and can retry after cancellation. It retains original legacy files until explicit deletion. [Services review](fresh-services.md) records the boundaries and regressions.

The UI keeps the map, timing list, and playback controls central. Stint history and conditions use native disclosures. Sessions without telemetry show one concise state instead of empty metrics and pedal rows. Crosshair state stays inside the chart subtree. Static circuit bounds, colors, and outline drawing sit outside the moving-car update path. An unused observable position mirror was removed. The map remains at 30 Hz and selected telemetry at 15 Hz. [UI review](fresh-ui.md) records the changes and their limits.

## Performance evidence

The optimized fixture contains 20 drivers and two hours of recorded data, with 576,020 coordinate samples and 576,020 telemetry samples. Both runs used Apple Swift 6.2.4 on arm64 macOS 26.6.2 and produced identical checksums.

| Operation | Previous source | Audited source |
| --- | ---: | ---: |
| Dataset preparation | 0.141230 s | 0.130519 s |
| 10,000 map and selected-driver queries | 0.101441 s | 0.065574 s |
| 10,000 full timing snapshots | 0.090323 s | 0.073944 s |

These are single runs of CPU work without drawing or networking. They show no regression in this fixture and do not establish sustained frame rate, energy use, a memory ceiling, or the same improvement across recordings. The release bundle contains 10,616,455 regular-file bytes, about 10.1 MiB, with no external app package dependencies. Its executable and core-library string scans found no owner-home, source-checkout, or diagnostic temporary paths.

Short process measurements of the final release used Australia 2019 race playback with Hamilton's inspector visible. The three usable playback samples were 31.7%, 42.2%, and 40.5% CPU. The preceding release's samples were 34%, 35%, and 39%, so these measurements establish no playback CPU improvement. Five usable minimized samples were 0.1%, 0%, 0%, 0%, and 0%; three paused samples were 0%. The host was under heavy CPU and memory pressure. These short observations are not a frame-rate, energy, or peak-memory benchmark.

A four-second final playback stack sample showed substantial AppKit and SwiftUI layout work without identifying an app layout cycle. Circuit drawing was the largest named app rendering branch, with 33 sampling observations out of 2,575 main-thread observations. The source review confirmed separate 30 Hz map, 15 Hz telemetry, and 4 Hz timing updates. This bounded review found no further rendering defect supported by the sample.

## Native acceptance

The final release was checked against already-downloaded Australia 2019 race and qualifying recordings. The race displayed 20 cars, synchronized Hamilton and Vettel detail, and opened Ricciardo's inspector when his car was selected on the map. The compact inspector used a popover; the wide window used the side inspector. Stint history and conditions opened through native disclosures. The included Monaco sample also showed concise unavailable telemetry, lap, and tyre states. The Library used the corrected singular footer, "1 session".

At about 981 × 702 points, the native timing table clipped its State column and needed a horizontal scrollbar. Increasing its fixed width from 300 to 360 points resolved that defect. All five columns and the playback controls fit in the rebuilt release at the compact size, at the 980-point minimum width with the widest sidebar, and at the 1,300-point inspector breakpoint. The 1,470 × 924-point wide window retained room for the map and driver detail. The flexible map and existing split layout remain intact.

Qualifying comparison rendered speed, throttle, brake, and gear traces. Hamilton's Q3 lap 17 and Bottas's lap 15 showed a whole-lap difference of +0.112 seconds. Q1 and Q3 filtering kept the lap pickers within the selected phase. Replay lap sought Hamilton's selected lap and started playback. Closing and reopening the app restored the last completed race recording, paused. Minimizing retained the play intent; on restore, the cursor stayed near its previous position rather than jumping by the hidden wall-clock interval. Settings showed the three data sources and download storage without changing or deleting recordings.

The Mac lock interrupted an earlier attempt; the checks above were completed after it was unlocked. Active chart hover annotations were not observed because the automation released the selection gesture. Missing-field and distance-boundary behavior is covered by the extracted production-helper harness. No download deletion was performed in native QA; filesystem failure and cancellation cases are covered by the core tests. Earlier native acceptance remains in [replay overhaul](replay-overhaul.md).

## Publication and remaining limits

The source and provenance review found no exposed credentials or private-content issues. Original code has the selected MIT license. Provider fixtures are unchanged and excluded from MIT. On October 7, the five private commits were squashed into one `green flag` root commit with no body. Earlier live-feed implementations are no longer reachable from main. The final tracked-file and binary-metadata checks passed. No user recordings were deleted.

Publishing the source is a reasonable hobby-project choice if the maintainer accepts the unresolved provider-data risk. Replay-only access does not establish upstream permission. The [publication assessment](publication.md) explains why this audit cannot promise only a takedown or zero account/legal consequences.

The audit is not a claim of flawless rendering, every-season data fidelity, or code quality equal to Zed, VS Code, or React. The app is locally signed, not Developer ID signed or notarized. Missing provider measurements remain missing, and very large recordings can exceed the supported payload budget.

The review used the requested [code-smell catalogue](https://refactoring.guru/refactoring/smells), [Code Smells](https://www.codesmells.org), and [Cursor review reference](https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md). Fixes target observed behavior and repeated work. User-facing documentation was edited with `$unslop`.
