# Replay overhaul validation

Historical review from before the final replay audit and October 7 history squash. See the [latest audit](fresh-audit.md) and [validation record](fresh-validation.json) for the release prepared for publication.

Validated October 4, 2026 on macOS 26.6.2 with Apple Swift 6.2.4. The repository was private. No repository visibility change was made.

## Scope

Direct live transport, buffering, reduction, connection controls, and live-specific tests are removed. Replay is the primary workspace. Completed-session archives provide recorded coordinates, car telemetry, timing, tyres, weather, race control, and qualifying phases where the source includes them. The app requires no account, paid endpoint, Python runtime, or external package.

The functional reference was IAmTomShaw/f1-race-replay at commit `3a3aa1ad23e6b7442e73e07a47917a2b08c7f180`. Paddock supports its central replay capabilities: historical discovery from 2018, recorded car movement and telemetry, slow motion through 256×, lap and event seeking, pit and retirement state, flags, qualifying results, and lap comparisons over distance. Paddock adds a native macOS workspace, durable verified downloads, cancellation and resume, offline restart, and preservation of an existing recording during refresh. Source gaps remain unavailable; no race video or simulated safety-car coordinates are added.

## Integrated checks

- 73 Swift tests across eight suites passed in Swift 6 mode with complete concurrency checking and warnings treated as errors.
- Fifteen mocked fixture-maintenance tests, all 12 bundled response schemas, shell syntax, and the property list passed `scripts/check.sh`.
- The optimized release app passed plist validation and deep, strict ad hoc signature verification. Its bundle occupies approximately 10 MiB. This is a local build, without Developer ID signing or notarization.
- Whitespace and credential-pattern scans passed. Downloaded validation streams stayed outside the repository. Existing bundled provider fixtures were unchanged.

Independent review identified inaccurate historical stint starts, lost qualifying gaps, best laps crossing qualifying phases, and an open pit interval overriding retirement. Regression tests and actual archive checks verify the corrections. Empty initial race gaps also remain unknown for nonleaders.

## Actual recordings

All required static topics were acquired, decoded natively, committed to the checksummed archive store, and reopened by a fresh disk-only provider. Each recording includes 20 drivers.

| Recording | Session key | Recorded laps | Coordinates | Car telemetry |
| --- | --- | --- | --- | --- |
| Australia 2019 qualifying | 5398 | 253 | 257,880 | 316,340 |
| Australia 2019 race | 5394 | 1,038 | 355,230 | 464,900 |
| Monaco 2024 qualifying | 9519 | 405 | 286,907 | 286,640 |

The Australia race uses the recorded finalization time, with a replay duration of 5,499.594 seconds. Its initially missing first-lap time does not erase the first lap. Ricciardo remains retired after his final open pit entry. Monaco's final Gasly best is his Q3 time of 71.311 seconds, rather than his faster Q2 time. Leclerc's first stint starts at lap 1 even though the source's stint best-lap field changes later.

## Native verification

The full Australia race opened from the local library and rendered 20 recorded cars. Lap entry, 0.1× and 256× playback, pause, table selection, ten-second controls, and a named session-start event seek updated replay state. Selected-driver speed, gear, pedals, lap times, and tyre age stayed synchronized with the cursor. Missing initial car positions and the included sample's missing telemetry were explicit.

Native testing exposed an AppKit constraint cycle when a nested split view opened the full map. The final workspace uses a flexible map beside a fixed-width timing table, within the measured viewport. Compact and expanded window checks confirmed visible headers, playback controls, timing columns, and native driver detail. Inspector collapse and restoration preserved driver text and selection. Compact windows use a driver popover.

Monaco qualifying opened in lap analysis. Q1/Q2/Q3 results showed separate recorded times, including Gasly's Q2 1:10.896 and Q3 1:11.311. Phase selection and comparison showed Leclerc lap 25 against Piastri lap 23, a recorded whole-lap difference of +0.154 seconds, and distinct speed and brake traces. The distance chart uses shared recorded metres; its endpoint delta can differ from the recorded whole-lap difference. This distinction is stated in the interface.

Space from the timing list started playback. Minimizing preserved play intent and cursor 1,074.792 seconds. Native restoration showed 1,075.555 seconds after the observation's activation delay, rather than adding the hidden interval. Three two-second `top` samples while minimized reported 0.0% CPU. Visible playback with the map and inspector reported 24.9% and 33.3% CPU, with `top` MEM around 346M. A paused `ps` sample reported 144,352 KiB RSS. These short samples were taken on a loaded development machine; they do not establish energy use, sustained frame rate, or a memory ceiling.

Core query measurements and their narrower scope remain in [performance.json](performance.json). The latest source-rate fixture measured approximately 14.9 microseconds for 20 car lookups and one selected telemetry lookup. Native drawing is excluded from that measurement.

Provider availability and data rights remain separate from code licensing. This validation establishes implementation behavior for the tested recordings, not complete upstream coverage or legal clearance.
