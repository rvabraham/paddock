# Paddock

A native macOS app for replaying Formula 1 sessions. Browse recorded races and qualifying, follow every car on the track, inspect telemetry, and compare laps. Paddock requires no account, API key, subscription, Python installation, or external package. Its original code is [MIT licensed](LICENSE); provider data has [separate terms](THIRD_PARTY_NOTICES.md).

## Run

Requirements: macOS 26 or newer and Swift 6.2 or newer. Apple's Command Line Tools are sufficient; a full Xcode installation is not required. Install missing tools with `xcode-select --install`.

From the project directory:

```sh
./scripts/run-app.sh
```

This builds a release version, assembles and locally signs `build/Paddock.app`, then opens it. To build without launching:

```sh
./scripts/build-app.sh
```

Open an existing build with `open build/Paddock.app`. Use `./scripts/run-app.sh debug` for a debug build. Builds use the current Mac's architecture and keep compiler caches in `.build/`. The app bundle includes its resources and can be moved out of the checkout. Its ad hoc signature is not a Developer ID signature or notarization for public distribution.

## Replays

Open Library, choose a season and session, then download the replay. Progress shows the recorded data being acquired. Cancel to stop; Resume download keeps validated pieces and requests the missing ones. A completed download opens without a network connection after restarting the app. Use the session's context menu to redownload or delete it.

On startup, Paddock opens the last used readable downloaded recording, paused. If it is unavailable, the app tries another saved recording. With no readable recording on this Mac, Replay offers a direct link to Library. No race data is bundled, and the app never substitutes demo data for a recording.

Playback supports pause, speed changes, scrubbing, lap jumps, ten-second steps, restart, and seeking to recorded events. The track view uses recorded car coordinates. Inspect a driver for speed, gear, throttle, brake, DRS, lap timing, and tyre history. Laps compares speed, throttle, brake, gear, and time delta over shared recorded distance. Qualifying shows Q1, Q2, and Q3 results with direct lap analysis. Pace compares up to six drivers' completed laps; Strategy shows recorded stints. Calendar and Championship use locally cached schedules and standings.

Download a replay to obtain the provider's available coordinates and telemetry for that session. Older timing-only downloads are identified separately and can be upgraded. Calendar and Championship load provider responses through the local cache; a fresh install has no saved schedule or standings.

| Shortcut | Action |
| --- | --- |
| Command–1 through Command–4 | Replay, calendar, library, championship |
| Space | Play or pause |
| Command–Left / Command–Right | Previous or next lap |
| Command–Option–Left / Command–Option–Right | Back or forward ten seconds |
| Command–Shift–R | Restart replay |
| Command–F | Search the library or calendar |
| Command–, | Settings |
| Escape | Cancel a library download |

## Sources and availability

| Source | Use | Availability |
| --- | --- | --- |
| [OpenF1](https://openf1.org/docs/) | Race and practice timing, coordinates, car telemetry, stints, pit records, weather, and race control | Sessions from 2023 onward. Free historical access normally begins 30 minutes after a session ends. |
| Formula 1 completed-session archives | Recorded timing and telemetry, including qualifying phases, through Paddock's native archive reader | Sessions from 2018 through 2022, plus qualifying and sprint qualifying from 2023 onward, subject to upstream archive availability. The format is also used by [FastF1](https://github.com/theOehrly/Fast-F1). |
| [Jolpica F1](https://github.com/jolpica/jolpica-f1) | Calendar and championship standings | Free noncommercial API with local caching. |

Paddock has no live timing connection. Historical archive access does not require a Python runtime or a FastF1 installation. No paid endpoint, account, or authentication bypass is used.

Downloads preserve available coordinate and car-data samples at their recorded rate. Playback interpolates continuous values only across short gaps; discrete gear, brake, and DRS values come from past samples. Missing or stale measurements remain unavailable. Coordinates are approximate, and recorded channels can contain gaps or upstream errors. A complete download means all required archive pieces were acquired and verified, not that the provider recorded every measurement. Replay contains no race video or radio.

OpenF1 coordinate and car-data downloads use bounded time windows based on the session's recorded start and finish. Archives identify their source, encoding version, channels, and saved-piece checksums; OpenF1 sample pieces also record their exact acquisition ranges. An archive becomes ready only after its data validates. A failed redownload preserves the previous completed archive. The app respects provider rate limits, retries rate limits and transient failures, and reports denied access without attempting to bypass it.

Replay archives are kept in `~/Library/Application Support/Paddock/Replays/`. Storage is bounded to 4 GiB, 512 MiB per session folder, and 64 session folders, including partial downloads and a preserved prior recording during refresh. Recorded sample arrays have a 256 MiB estimated payload budget; exceptionally large sessions can exceed the supported limit. This budget does not measure the app's total memory use. Completed archives are not automatically evicted; delete recordings in Library or Settings when storage is full. Migration considers up to 65 recent eligible legacy caches and stops when the library is full; it keeps the legacy files until explicitly deleted. Temporary response caching under `~/Library/Caches/Paddock/Responses/` is limited to 100 MiB. Calendar, championship, and library refresh actions request new provider data and retain available results if a refresh fails. Their provider responses validate before replacing saved responses, so a malformed refresh preserves the last valid cache entry.

## Data rights

Paddock is an independent, noncommercial fan project, unaffiliated with Formula 1, the FIA, any team, or the data providers. Its icon is drawn by the project's own script. No Formula 1 logo is included.

The MIT license covers Paddock's original code, including commercial reuse. It does not cover downloaded provider data or grant permission to access services. OpenF1 and Jolpica publish noncommercial data terms. [Third-party notices](THIRD_PARTY_NOTICES.md) identify the sources and licensing limits.

Formula 1's [guidelines](https://www.formula1.com/en/information/guidelines.4EOKE9RRqevL4niTK9kWyt) assert timing-data and database rights. Provider licenses and historical endpoint access do not establish clearance from every upstream rights holder. Numerical facts, original code, protected expression, service terms, and database rights are separate questions. The [publication assessment](output/audit/publication.md) explains the remaining risk. The [audit index](output/audit/README.md) links code reviews and dated validation evidence. [Background research](research/README.md) preserves earlier design proposals and source investigations.

## Development

```sh
./scripts/check.sh
./scripts/test.sh
./scripts/build-app.sh debug
```

`PaddockCore` contains models, provider clients, durable archive storage, recorded-data indexes, and the replay clock. `PaddockApp` contains the SwiftUI interface. Tests cover archive integrity, cancellation and resume, offline restart, provider-response validation, integer boundaries, response and storage limits, replay chronology, interpolation, telemetry, session events, historical parsing, and lifecycle behavior using synthetic data and mocked transport.

The build uses Swift 6 with complete concurrency checking and warnings treated as errors. It invokes Apple's compiler directly, embeds `PaddockCore`, copies resources and license notices, validates `Info.plist`, and verifies the ad hoc signature. This avoids SwiftPM's manifest runtime on incompatible upgraded Command Line Tools installations. A local virtual-file overlay hides a duplicate legacy Swift bridging module map when detected; installed toolchain files are unchanged.

`scripts/check.sh` validates shell scripts and the property list. `scripts/test.sh` uses Apple's Swift Testing framework in an isolated workspace, removes successful outputs, and preserves a failed workspace for diagnosis. Its synthetic inputs are test code and are never included in the app. The build replaces the previous app only after the new bundle validates.

To regenerate the original icon:

```sh
./scripts/generate-icon.sh
```

`scripts/benchmark-core.sh` runs a separate command-line benchmark with generated synthetic inputs. Those inputs are not compiled or copied into Paddock, and its measurements should not be treated as results from an actual race recording.
