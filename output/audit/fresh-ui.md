# Fresh UI audit

This report records the preceding 92-test release and initial October 7 publication checks. The [follow-up audit](follow-up-audit.md) and [validation record](follow-up-validation.json) cover the later repairs.

Reviewed the native app starting at `bbd11d2` on October 4, 2026. Changes are limited to SwiftUI app sources and this note. The replay workspace remains primary. The flexible map, explicit viewport, window lifecycle handling, and native keyboard routing are preserved.

## Corrections

- Lap crosshair state belonged to the whole analysis screen. Moving the crosshair therefore rebuilt lap pickers and qualifying-result filtering as well as the charts. That state now belongs to the chart subtree. The selected trace stays local too; changing chart position no longer invalidates the surrounding selection controls.
- Crosshair labels used an unbounded nearest-point scan. A selection beyond the shorter lap's recorded distance still displayed that lap's endpoint reading. Lookup now checks coverage before a binary search. Gear and brake use the preceding recorded sample. Missing readings show "No data", and missing channel values split the plotted line instead of joining across them.
- Lap requests are validated against the current recording before becoming the reference selection. The inspector's Analyze laps action is enabled only when a measured, completed lap exists, matching the action's actual requirements.
- The inspector rendered an entire telemetry grid and pedal rows when the recording had no telemetry. An absent channel now has one missing-data line and creates no telemetry timer. Missing measurements at a particular cursor position also have one state. Available readings remain visible. Empty lap and tyre fields are compact; stint history and conditions use native disclosures.
- The map rebuilt its static outline and parsed team colors inside its 30 Hz rendering path. Outline bounds and driver colors are now prepared outside that path. A separate outline Canvas has an equality boundary, while moving cars, labels, hover, and selection retain the same behavior. The map remains at 30 Hz and selected telemetry at 15 Hz.
- Settings and Help omitted Formula 1's historical timing feeds even though the provider uses them for earlier seasons and qualifying. Both now identify Formula 1 as a data source alongside OpenF1. Settings retains Jolpica attribution for calendar and standings.
- Settings now captures and displays a failed Clear downloads result through the core's `sessionsError`. Core and provider changes handle retained metadata and filesystem failures. No user download was deleted to test this path.
- Calendar now uses the core's semantic session-name matcher. This handles Sprint qualifying/Sprint Shootout aliases without confusing sprint races with qualifying. The existing date and season checks remain.
- The Library footer uses the singular "1 session" where appropriate.

## Evidence and limits

The initial app-source review passed Swift syntax parsing against the macOS 26.2 SDK and the whitespace check. The final release build includes the core session-name matcher. Integrated native acceptance is recorded below.

The inspected four-second baseline stack sample was `/private/tmp/paddock-audit-baseline.sample.txt`, from the release at `bbd11d2` during Australia 2019 race playback with the map and Hamilton inspector visible. Most active sampled work was SwiftUI/AppKit layout. Circuit Canvas drawing appeared in eight sampled call paths, including color conversion and sorting; the whole inspector body appeared in two. The 15 Hz telemetry Timeline was already confined to its own view, so it was not a whole-inspector rebuild defect. These observations support reducing repeated static rendering work, but do not establish a CPU improvement.

No new explanatory blocks or status badges were added to the main replay workspace.

## Integrated native acceptance

The rebuilt release was checked against actual Australia 2019 race and qualifying recordings. Map car selection, timing selection, synchronized telemetry, the compact inspector popover, the wide side inspector, and the stint and conditions disclosures worked. Qualifying phase filters, all four chart channels, whole-lap comparison, and Replay lap were exercised. Restart restored the last completed recording paused. Settings source attribution and download storage were inspected without clearing recordings.

The compact native table exposed one additional layout defect: its 300-point frame clipped the State column and required horizontal scrolling. The final frame is 360 points. All five columns fit at about 981 × 702 points, at the 980-point minimum width with a 270-point sidebar, and at the 1,300-point inspector breakpoint. The existing HStack and flexible map remain unchanged. The wide layout was checked at 1,470 × 924 points.

Short final playback CPU samples were 31.7%, 42.2%, and 40.5%; preceding-release samples were 34%, 35%, and 39%. They do not establish a playback CPU improvement. Minimized samples stayed near zero. Host load and memory pressure limit these short comparisons. Active crosshair hover annotations could not be observed with the automation's released gesture; the production-helper harness covers missing brackets, exact samples, and distance boundaries. The [integrated audit](fresh-audit.md) and [validation record](fresh-validation.json) give the final scope and measurements.
