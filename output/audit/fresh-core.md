# Fresh core audit

This report records the preceding 92-test release and initial October 7 publication checks. The [follow-up audit](follow-up-audit.md) and [validation record](follow-up-validation.json) cover the later repairs.

The October 4, 2026 review fixed replay chronology, cancellation, fast-playback navigation, and startup restoration. Its initial focused verification passed 45 tests across ReplayEngineTests, ReplayIndexTests, RaceLifecycleTests, and TimingTests with Swift 6, complete concurrency checking, and warnings treated as errors. A subsequent independent review corrected the null-gap regression described below. [Integrated validation](fresh-validation.json) records 92 passing tests, the release build, and the listed native checks.

At the initial October 7 publication check, `main` contained one `green flag` root commit with an empty body. The application source and resources were unchanged from the validated release at that point. The earlier commit IDs identify pre-squash history and are not ancestors of the publication commit. The focused fingerprints below identify the inputs reviewed then.

Five new regressions failed against the original core at `bbd11d2d150b1dd4f4ad1ccd3a7b4ef4401287d7` before the fixes:

| Trigger | Original failure | Repair |
| --- | --- | --- |
| A retained position, interval, weather, pit, driver-status, source-best, lap-boundary, unmeasured completion, or validity observation follows the nominal end | The replay stopped at 100 seconds instead of reaching the 150-second observation; final retirement and pit events could be unreachable | Duration includes every retained dated channel. Historical high-rate clipping remains in its decoder. |
| An explicitly invalid 60-second lap is reinstated at 140 seconds | Before reinstatement, the best became 60 seconds instead of the valid 65-second lap; the initial false validity was lost on reload | Store explicit initial validity at completion before applying later control messages. Preserve and sort dated changes. |
| A malformed lap completes before it starts | Best-lap history published its time even though completed-lap history rejected it | Apply the same completion chronology requirement to both histories. |
| Next lap is pressed at 256× between timing ticks | The command sought 13:44:07 even though playback had passed that boundary; the next boundary was 13:47:05 | Synchronize the active clock before querying lap or event navigation. |
| Dataset initialization runs in an already cancelled task | It returned a complete dataset | Check cancellation before decoding and between index-construction stages. |

Session opening now owns one cancellable task for disk lookup, sample selection, and provider acquisition. Request identity still prevents an older result from installing, and progress callbacks also require an active load. The native renderer already queries coordinates directly from the dataset. Removing RaceStore's unread positions mirror avoids a second map query and observable array assignment on every timing tick. The unused last-update mirror was also removed. Lap-validity attribution selects the closest past matching lap in one scan, without sorting a temporary candidate array.

Startup remembers only successfully installed session keys. It restores a remembered key only when completed archive metadata identifies it as replayable, installs once, and remains paused at the start. A missing or unreadable recording falls back to the saved Monaco recording or included sample. Isolated preference tests cover opening a recording and restarting, a missing key, invalid logical archive data, and retention of the failed archive's files. Production uses the existing UserDefaults store; injected test providers default to no preference writes.

Clear downloads now exposes provider deletion failures and reloads disk metadata instead of reporting unconditional success. An isolated test made a saved session folder unwritable, confirmed the failure was reported, and verified that its replayable archive metadata remained present. The test restored permissions before cleanup. No user replay files were deleted during this audit.

Additional regressions cover simultaneous lap records after reload, nonfinite dates, and coordinates near ±1e308. Date filters protect binary-search ordering, and coordinates use the same ±1e9 bound as the historical decoder to prevent interpolation and track-span overflow. Scheduled session matching recognizes Sprint Shootout and Sprint qualifying as aliases while keeping Race, Sprint, Qualifying, and practice numbers distinct.

The first null-gap change followed the [OpenF1 interval documentation](https://openf1.org/docs/#intervals) too literally and labelled every explicit null as LEADER. Independent review checked the recording and found 59 null gaps across 12 nonleader drivers. Tsunoda's 13:05:01.049 observation has a null gap, a 2.830-second interval, and recorded position 7. The corrected decoder labels a null gap LEADER only when the latest recorded position at that observation is first. It builds each driver's position index once and uses binary search for the null observations. Unknown position, a known nonleader, and an absent gap field stay unavailable. The added bundled-data regression checks all 59 null records and preserves the recorded intervals for Tsunoda, Ricciardo, and Norris. The synthetic regression checks that future positions cannot supply the leader context.

The October 4 source-rate fixture benchmark used Apple Swift 6.2.4 on arm64 macOS 26.6.2, optimized compilation, 576,020 coordinate samples, and 576,020 telemetry samples. [Integrated validation](fresh-validation.json) records both single-run measurements:

| Operation | Baseline duration | Audited duration | Checksum |
| --- | ---: | ---: | ---: |
| Dataset preparation | 0.141230 seconds | 0.130519 seconds | 1152040 |
| 10,000 map and selected-driver queries | 0.101441 seconds | 0.065574 seconds | 2440000 |
| 10,000 full timing snapshots | 0.090323 seconds | 0.073944 seconds | 200000 |

These figures exclude drawing, networking, process memory, and energy use. They are single optimized runs and do not establish a sustained whole-app improvement.

The October 4 focused command was `bash scripts/test.sh --filter 'ReplayEngineTests|ReplayIndexTests|RaceLifecycleTests|TimingTests'`. Its source and test fingerprint was `cae77f4eb6803957b129574df8e9d0559267d27fb2761bf4987a037d1852a24d`. After the null-gap correction, the fingerprint was `ce02b4abc4adee85f1955f90071cde3d604c6e7b5429e221ca94387619f76415`. Each fingerprint hashes the ordered per-file SHA-256 output for RaceStore.swift, ReplayDataset.swift, Models.swift, LapValidity.swift, ReplayEngineTests.swift, ReplayIndexTests.swift, RaceLifecycleTests.swift, and TimingTests.swift. These identify the core inputs at those review stages, not the app bundle or the full integrated tree. [Integrated validation](fresh-validation.json) supplies the final fingerprints and native scope, including restored saved playback, real race telemetry, and qualifying comparison. Active chart hover and destructive native deletion were not exercised. Existing audit documents are preserved as dated evidence.
