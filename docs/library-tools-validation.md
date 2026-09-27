# Library tools validation — 2026-09-27

Tested the current Earmark, Mango and ShelfKit changes with generated media, local SMB
servers and an iPhone 17 Pro. The physical-device tests used `com.vanities.mangoqa`,
leaving the installed Mango app and its library separate.

| Check | Result |
| --- | --- |
| Earmark full simulator suite | 202 tests passed, no failures or skips |
| Mango full simulator suite after the search fix | 293 tests passed, no failures or skips |
| ShelfKit full suite with an authenticated SMB server | 78 tests passed, no failures or skips |
| Both existing SMB fixture servers | Listing, ranged reads and downloaded-byte comparisons passed |
| SMB reconnect rejection | Missing paths and changed file sizes were rejected |
| Earmark and Mango reconnect UI | Preview and apply passed, including changing the NAS root folder |
| State after NAS relocation | Source IDs, book IDs, progress, bookmarks, overrides, custom-cover references and lists stayed unchanged |
| Mango backup UI | Export, browse to the JSON, preview matches and restore completed in a fresh simulator |
| Mango smart lists and trip preparation | Saved an unfinished-books list; selected a novel and verified its files as ready offline |
| Physical-device Live Text | Recognized a generated text page, attached the text-selection interaction, and rejected a blank page |
| Physical-device novel highlights | Selection anchoring, painting, typography changes and ambiguous repeated quotes passed |
| SwiftLint and whitespace checks | Both apps passed |

## Bug found and fixed

The novel reader's **Find in this chapter** button initially closed its sheet without
leaving a search bar visible. Instrumentation confirmed that WebKit received the request
and presented its find navigator while the sheet was dismissing. UIKit then dismissed
the navigator with the sheet.

`NovelReaderView` now sends the request from the sheet's `onDismiss` callback. The same
UI test failed before this change and passed afterwards. Temporary instrumentation was
removed.

## Repeatable coverage

Mango's `scripts/test-library-ui.py` generates an isolated project and simulator, seeds
the invented demo library, and runs backup and chapter-search UI regressions. It preserves
logs and xcresults in the printed temporary directory and removes its simulator unless
`--keep-simulator` is supplied.

`MangoTests/LiveTextTests.swift` contains the device-capable recognition/selection test.
`ShelfKitTests/NASClientIntegrationTests.swift` now includes reconnect validation against
real directory listings; its environment variables are documented in that file.

## Evidence from this run

- Full suites: `/tmp/earmark-release-tests.log`, `/tmp/mango-post-find-tests.log`,
  `/tmp/shelfkit-final-live-tests.log`.
- Authenticated SMB checks: `/tmp/mango-smb-integration.log`, `/tmp/earmark-smb-integration.log`.
- Physical-device tests: `/tmp/mango-device-live-tests.log`.
- Both apps' NAS relocation UI: `/tmp/library-nas-relocation-ui-tests.log`.
- Search regression before/after: `/tmp/mango-find-probe-ui.log`, `/tmp/mango-find-fix-ui.log`.
- Search entry assertion, including first-use keyboard onboarding: `/tmp/mango-ui-query-final.log`.
- Fresh simulator backup/search run: `/tmp/mango-isolated-ui-run2.log`, which prints the
  retained results directory.

The older simulator's Files provider repeatedly returned `NSFileProviderErrorDomain -1002`.
The backup round trip passed in a fresh simulator; no app workaround was added for that
environment failure. Temporary SMB shares were read-only mounts of generated fixtures.

## Upgrade and playback follow-through

Installed isolated copies of the previous committed builds (Earmark `07aef3b`, Mango
`23d05aa`), scanned generated media, and saved progress, bookmarks, corrections, hidden
books, a custom cover and a list through each old build. Installed the new builds over
them without uninstalling and relaunched twice. Both passed: five Earmark books and eleven
Mango books retained their IDs and user state; cover bytes and media hashes matched.
Evidence: `/tmp/library-upgrade-results.json`, `/tmp/library-upgrade-validation.log`.

`PlayerLifecycleTests` exercises a real AVPlayer with generated audio: applying a preset
without autoplay, playback at 1.5x, interruption/resume and route-loss handlers, sleep-timer
expiry and recording three listening sessions. Passed in `/tmp/earmark-lifecycle-tests3.log`.
Notifications are injected; this does not establish behavior during an actual phone call.

The paired phone required its passcode during this follow-through. Physical background
audio, actual OS interruptions, network-loss streaming and force-quit download recovery
remain unverified in this run. Earlier physical Live Text/highlight results above remain
valid. This limitation does not block preparing beta builds for further testing.
