# Real-data-only startup

Checked October 7, 2026. Paddock now includes no provider dataset or demonstration recording. The app displays only data acquired from providers or restored from the user's saved downloads. Synthetic test and benchmark inputs are never compiled or copied into the app.

The 12 OpenF1 and Jolpica JSON samples, bundled-data loaders, hardcoded Monaco Library entry, and sample fallback were removed. First launch stays empty with one Open Library action. Startup restores the remembered readable downloaded recording, paused, or tries another saved recording. Missing channels remain unavailable. Calendar and Championship load provider responses through their existing cache.

The resource bundle and fixture-maintenance scripts were removed. The README and third-party notices describe the download-only behavior. Earlier audit reports retain their dated findings about the former bundled samples. Main retains one `green flag` root commit with no body; private backups and old server objects are not represented as securely erased.

## Verification

All 107 Swift tests in eight suites pass with complete Swift 6 concurrency checking and warnings treated as errors. Startup checks cover empty storage, missing and invalid remembered recordings, readable saved fallback, cancellation, a competing selection, and restoration after an interrupted refresh. Synthetic provider-shaped inputs preserve decoder and replay-index checks without redistributing recordings.

The release build, shell and property-list checks, and deep strict ad hoc signature verification pass. The app contains no JSON dataset or core resource bundle. The separate synthetic benchmark runs successfully, with matching scan and indexed snapshot checksums. Its changed inputs prevent comparison with earlier measurements from the bundled recording.

Native verification reopened the actual Australia 2019 qualifying recording in the release app, paused at zero, with its recorded lap times. A temporary native build using the production views and isolated empty storage showed the empty prompt, and Open Library navigated to provider session discovery. The user's existing recordings and preferences were preserved. This change did not repeat a full network recording download or native acquisition-cancellation trial.

The [validation record](real-data-validation.json) identifies the source inputs and release files. The [publication assessment](publication.md) retains the separate question of upstream data rights. Removing bundled recordings reduces redistribution; it does not establish permission to access or use every provider archive.
