# Independent review

Historical review from before the final replay audit and October 7 history squash. See the [latest audit](fresh-audit.md) and [validation record](fresh-validation.json) for the release prepared for publication.

Reviewed the then-uncommitted changes against `ea04371cb563d1548950e03aab649aa010508894` on October 4, 2026. This review found three specific edge cases and sent them to the implementation owners before final validation. No other confirmed defect requiring a release block was identified in the inspected code. This is an independent source review, not a claim that the application or its data is cleared for public release. Its commit and publication statements describe the review period.

## Findings sent for correction

| Priority | Location at discovery | Evidence and consequence | Required correction |
| --- | --- | --- | --- |
| P2 | `Sources/PaddockCore/ProviderHTTP.swift:66` | Shared `Retry-After` handling was conditional on `attempt < 2`. After the third 429, another queued request could start after ordinary host spacing, 0.3 seconds for Jolpica, even when that response requested a longer pause. The pure rate-limit test did not exercise this integration boundary. | Install shared backoff for every 429. Only the decision to retry the current request should depend on the attempt count. Verify the first subsequent request waits after the final throttled response. |
| P2 | `Sources/PaddockCore/RaceStore.swift:537` and `:611` | A heartbeat returned without recomputing source freshness, while hidden/inactive coverage stopped its ticker. Timing updates could cease while transport heartbeats continued, preserving a stale “Live timing connected” sidebar label until Coverage was reopened. The reducer's freshness tests do not alone cover the store's scheduling behavior. | Recompute source health on heartbeat while coverage is hidden, without decoding/publishing timing arrays or advancing replay playback. Verify a fresh state becomes stale after 30 seconds despite continued heartbeats. |
| P2 | `Sources/PaddockApp/SettingsView.swift:33` | The initial Settings body converted the persisted delay with `Int(preferredLiveDelay)` before `.onAppear` clamped it. A persisted NaN, infinity, or out-of-range finite number could trap while opening Settings. `RaceStore`'s separate validation did not protect this independent AppStorage read. | Use a finite, clamped value for the first render and the slider binding. Continue persisting normalized preferences. |

These line numbers identify the code as discovered and may move during correction. The first two findings follow directly from the control flow. The preference finding follows from the unsafe conversion being evaluated before the appearance callback; a native Settings crash was not induced on the user's persisted preferences. The services owner confirmed the 429 issue and planned a mock-transport test. The root agent accepted the hidden-status issue for correction. Final correction status and integrated results belong in the completed implementation reports.

## Review coverage

Read the replay index, live event buffer and reducer, RaceStore lifecycle and cancellation paths, HTTP rate gate and response transport, replay/response caches and metadata index, provider decoders, native view responsibilities and focused keyboard routing, build/test/benchmark scripts, fixture validation, current tests, and audit/release documents.

The indexed replay uses chronological per-driver arrays, binary searches, and prefix best-lap state. The regression tests compare reconstructed state with a scan at forward/backward seeks and exact completion boundaries. The benchmark retains a scan reference and matching checksums. The claimed roughly 193× improvement is explicitly limited to this lookup operation; it should not be presented as a whole-app speedup. Process CPU/RSS samples use short observations and differ in scenario/state, so they do not establish an energy or memory regression or improvement.

The inspected cancellation paths use request generations, local transport cancellation, and guards before installation/publication. Cache generation changes prevent earlier requests from restoring cleared files. Response bodies and disk storage have explicit limits. The original live buffer bounded retention by time and checkpointed derived lap history. The subsequent focused review checked a 64 MiB retained-event estimate limit, a 50,000-frame ceiling, and a separate 32 MiB merged-topic estimate limit. Rejection preserves accepted state and pauses the connection before publishing the rejected patch. These estimates do not establish a process-RSS ceiling or a measured memory improvement.

The focused playback routing addresses the prior cross-section shortcuts. Calendar/Library owned opening tasks check cancellation before navigation. Timing and chart subviews form observation/equality boundaries, and the UI retains missing-measurement and partial-coordinate descriptions. Native focus, resizing, minimized-window behavior, and visual polish still depend on root's runtime checks. Root separately reported that minimized replay had continued advancing and assigned a visibility correction; that was not independently reproduced by this reviewer.

## Release claims and verification limits

The README and notices distinguish original MIT code from bundled provider data, third-party material, and direct feed access. They preserve the unresolved upstream rights question and describe the local signature as ad hoc rather than notarized distribution. This review did not perform a fresh legal assessment or independently rescan the full Git history. It checked the claims against the written services audit and the inspected code/package contents.

No sustained changing feed during an active race was independently observed. Negotiation, a completed-session snapshot, and synthetic protocol/reducer tests cannot establish that behavior. Final native UI results, Swift 6 build/signing results, and the complete final test count are owned by the root agent and must be reported after all corrections land. No production source was edited by this reviewer, and no commit, push, publication, or external message was performed.

## Implementation follow-up

All three P2 findings were corrected on October 4, 2026. Every 429 now installs shared backoff, including the final failed attempt. Hidden or inactive coverage refreshes source health on heartbeat without rebuilding displayed timing arrays. Settings uses a finite, clamped delay for its first render and slider binding before the appearance callback persists normalization.

The actual mock-transport backoff regression and store callback/freshness regression passed in the final integrated 51-test run, across eight suites in 4.678 seconds, with Swift 6 complete concurrency checking and warnings treated as errors. The seven budget regressions and queued-ticker cancellation regression also passed. Root's [native lifecycle evidence](native-window-lifecycle.json) verifies exact cursor preservation while minimized and restoration without a hidden-time jump. Reopening the main window while Settings remained open also passed. The final clean release passed plist and deep/strict signature verification, matching bundled license notices, and launch checks. Sustained changing timing during an active race remains unverified.

The maintainer subsequently chose source publication as a noncommercial hobby project and accepted ordinary project risk. That decision preserves the original MIT code license, separate provider-data terms, experimental feed limitations, and unresolved upstream rights. It does not change this review into a claim of permission or clearance.
