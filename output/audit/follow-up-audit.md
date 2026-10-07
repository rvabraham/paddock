# Follow-up audit

The October 7 review began at the single `green flag` commit `21473d122eb0d6d76d24cab104c5a828e07c7f25`. Separate Sol 6.1 xhigh agents reviewed core replay behavior, services and storage, and every native app view. An independent agent reviewed the integrated repairs; the main agent reviewed the diffs and owned final verification. The earlier [92-test audit](fresh-audit.md) remains dated evidence.

## Corrections

- Saved tyre ages now use the raw decoder's bounds before playback arithmetic. Reloading extreme ages cannot overflow when a lap advances.
- Invalid measured lap durations and impossible completion times remain unavailable to analysis. Recorded starts remain seekable.
- Integer fields reject fractional values instead of truncating them into driver IDs, seasons, lap counters, gear, or other discrete readings. Native booleans and integral numeric/string values remain supported.
- Calendar, championship, and session catalogs validate their schema and identities. Malformed refreshes retain displayed results. Empty provider arrays remain valid unavailable data, and finite negative championship points remain supported.
- Catalog, calendar, and standings responses validate before replacing a cached response. Failed semantic refreshes preserve the last valid disk response; invalid older cache entries can recover through a fresh request.
- Lap analysis shows a recorded comparison trace when reference telemetry is missing, and labels an absent comparison reading as unavailable. Trace preparation now belongs above the view that owns crosshair state, removing its repeated full-array scans.

The changes use existing model, provider, and view boundaries. The HTTP decoder returns rows and metadata together, replacing separate permissive parsing paths.

## Evidence

Final test, build, source identity, native checks, and publication scan are recorded in [follow-up-validation.json](follow-up-validation.json). The first integrated run passed 99 tests before the shared integer conversion and cache-publication repairs. The final run passed 104 tests across eight suites, covering those additional changes. The release build passed strict concurrency checking, warnings as errors, plist validation, and ad hoc signature verification.

An isolated harness compiled the actual chart helper bodies with Swift 6 complete concurrency checking and warnings treated as errors. Its 56 assertions cover missing segments, empty arrays, exact and out-of-range samples, and continuous/discrete brackets. Source checks place trace preparation outside crosshair state. These establish helper behavior and ownership; they do not measure native drag latency or prove a playback CPU reduction.

Native checks cover the minimum-width Library filter bar and expanded Calendar rows with the widest sidebar, lap selectors and legends at the inspector breakpoint, all telemetry channels, comparison toggling, and replay-lap navigation. The app's original resources and fixtures remain unchanged.

## Publication

The code/privacy checks found no publication blocker. The original code has an MIT license and provider materials retain their separate notices. The repository keeps one `green flag` root commit with no body. Publication remains a reasonable hobby-project choice if the maintainer accepts the provider-data risk described in the [publication assessment](publication.md).

This review cannot establish parity with Zed, VS Code, or React, or flawless behavior across every recording and Mac. Active crosshair rendering with a held pointer, partial-telemetry native cases, every-season provider compatibility, hostile same-user filesystem races, total memory/energy limits, and upstream legal clearance remain outside the established evidence.
