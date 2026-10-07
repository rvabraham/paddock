# Build and fixture audit

Historical review from before the final replay audit and October 7 history squash. See the [latest audit](fresh-audit.md) and [validation record](fresh-validation.json) for the release prepared for publication.

The development workflow still uses Apple's Command Line Tools, the standard library, Swift Testing, and Python's standard library. No package dependency, hosted CI, account, paid service, toolchain installation, or source fixture download was added.

## Changes

- Package.swift and every direct compiler invocation now agree on Swift 6. Complete strict concurrency checking and warnings-as-errors are enabled in the shared compiler flags. UI actor boundaries are explicit, and monitor cleanup uses Swift 6.2's isolated deinitializer. No broad production preconcurrency import was added. The URLSession transport/delegate/transfer use reviewed lock-backed unchecked Sendable boundaries; the mock URLProtocol and live test clock also use explicit lock-backed unchecked boundaries, with locked mock globals marked nonisolated(unsafe). Strict compilation is evidence of checked interfaces, not a claim that these unchecked contracts disappear.
- The release bundle now includes LICENSE and THIRD_PARTY_NOTICES.md alongside its resources. Existing staging, plist checks, embedded library/bundle signing verification, and replacement of the previous app only after successful validation remain in place.
- Test builds use a unique .build workspace. Successful runs remove generated products; failed runs preserve the workspace and print its location for diagnosis. Compiler/test output remains available to the caller rather than being swallowed.
- Icon regeneration builds PNGs and the new icon into its own temporary workspace. Only a successfully converted icns replaces the prior icon. Swift icon drawing is explicitly confined to MainActor.
- The local toolchain VFS overlay JSON is installed atomically, avoiding a reader seeing a half-written overlay during concurrent development commands. Installed Apple module maps remain untouched.
- Fixture refresh reads the actual app version from Info.plist for its User-Agent, accepts JSON, bounds response size, honors bounded Retry-After, retries transient failures at most four times, and closes HTTP error responses before retry/rethrow.
- Responses are validated before writing. Historical arrays must match session 9523; expected driver/lap/date/stint/coordinate fields are checked. Jolpica snapshots must match season 2026, contain real calendar/standings identities, and provide a coherent round within each standings response. Error objects, wrong sessions/seasons, oversized responses, non-finite JSON, and inverted measured ranges cannot replace good fixtures. Missing recorded lap and stint measurements remain allowed rather than becoming zero.
- JSON serialization and replacement use a temporary sibling file, flush/fsync, public resource permissions, and atomic replacement. Serialization or replacement failure preserves the original file and removes the temporary file.
- Existing Monaco files are validated and retained. Calendar/standings refreshes remain explicit source updates. --check validates all included data offline without writes or requests.
- scripts/check.sh checks every shell script's syntax, the app plist, all 12 source fixtures, and 15 mocked Python tests. Checks cover session/season/error payload rejection, missing measurements, failed writes preserving original data, public file permissions, 429/backoff, nonretryable failures, bounded transport retries, oversized responses, and the bundle User-Agent.
- Python bytecode/cache output is ignored, and the developer check command disables bytecode writes. The existing build/source separation and macOS 26 minimum remain intact.

## Evidence

This agent ran scripts/check.sh successfully: Info.plist validation, all 12 included fixtures, and 15 mocked Python tests passed, with no HTTP ResourceWarning after fixing response cleanup. No network requests or fixture writes were made by those checks. The changed VFS shell code passed bash syntax checking separately.

Root reported the final integrated strict Swift 6 run passed all 51 tests in eight suites in 4.678 seconds. The aggregate scripts/check.sh also passed all 12 source fixture validations and 15 mocked Python tests. The final clean strict release compiled, passed plist validation and ad hoc signing, and passed independent codesign deep/strict verification. Root compared bundled MIT license and notices exactly with their repository sources. The app bundle occupies 8.9 MiB on disk and launched successfully. Root owned those integrated build and native checks. The initial direct source parse failed because the host has duplicate SwiftBridging module maps; parsing passed with the existing project-local VFS workaround, including Swift 6 parsing after the lifecycle and command-restoration changes.

The shared source cache is still shared between commands; the generated output workspaces are isolated. The fixture updater installs each validated file atomically, rather than claiming a transaction across independent remote API snapshots. App code handles differing driver/constructor rounds without inventing a matching round.
