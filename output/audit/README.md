# Paddock audit

The latest change removes bundled provider datasets and the included-sample fallback. Start with the [real-data-only change](real-data-only.md), [current validation record](real-data-validation.json), and [publication assessment](publication.md). The preceding [follow-up audit](follow-up-audit.md) passed 104 Swift tests and a release build, with native acceptance for actual race and qualifying recordings. Those results describe the version before bundled-data removal. The [integrated audit](fresh-audit.md) records the earlier 92-test release.

| Review evidence | Scope |
| --- | --- |
| [Real-data-only change](real-data-only.md) | Empty first launch, saved replay restoration, test-only inputs, and removal of bundled datasets |
| [Follow-up audit](follow-up-audit.md) | Archive bounds, integer fields, provider validation, cache publication, and chart preparation |
| [Core review](fresh-core.md) | Replay duration, validity history, cursor navigation, startup restoration, indexes, and missing data |
| [UI review](fresh-ui.md) | Chart selection, rendering work, compact missing-data states, native disclosures, and source attribution |
| [Services and repository review](fresh-services.md) | Acquisition, cancellation, archive validation, storage errors, migration, privacy, and provenance |
| [Independent review](fresh-independent.md) | Missing-field crosshair values, qualifying ties, and null leader gaps |
| [Publication assessment](publication.md) | MIT code, the squashed history, downloaded data, and unresolved provider rights |

The October 7 publication check covered the single `green flag` root commit. It found no exposed credentials, private-content issues, unintended files, or private binary metadata. MIT and third-party notices are present. That finding does not settle provider-data rights or guarantee that publication has no account or legal consequences.

## Earlier evidence

On October 7, 2026, main was squashed into one `green flag` commit. Commit IDs and history counts in earlier reports refer to the private history before that squash.

The [replay overhaul](replay-overhaul.md) records the preceding 73-test implementation and validation against actual Australia 2019 race and qualifying recordings and Monaco 2024 qualifying. Its measurements describe that version.

The earlier [core](core.md) and [UI](ui.md) notes describe the 73-test replay overhaul. The [services](services-security.md), [build](infra.md), [performance](performance.json), [native lifecycle](native-window-lifecycle.json), and [51-test validation](validation.json) files retain results from earlier passes. Some include live-transport work or bundled provider fixtures that were subsequently removed. References to those files describe earlier versions. Their visibility and uncommitted-state fields are historical snapshots. The [research export checks](../../research/linear-apple/pdf-verification.json) cover the dated design study's prose, citations, PDF layout, and privacy scan.
