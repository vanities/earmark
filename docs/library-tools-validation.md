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

## Endurance follow-up and SMB timeout regression

Generated audio continued in the simulator background: 54 seconds of playback advancement
across 57 seconds on the Home screen (`/tmp/earmark-background-result.json`). This is a
simulator result, not physical-device background evidence.

Pausing the disposable SMB fixture server during playback, then restoring it, crashed the
old dependency in `SMB2Client.generic_handler`. A focused macOS test reproduced the crash
before the fix. AMSMB2 retained a callback pointer beyond the lifetime of the Swift stack
storage after a timeout. The maintenance fork keeps the pointer valid throughout the wait
and destroys failed contexts before that storage expires. Both echo and file-open timeout
regressions pass in Debug and Release, with reconnect, directory listing and ranged-read
checks (`/tmp/amsmb2-timeout-red.log`, `/tmp/amsmb2-timeout-green4.log`,
`/tmp/amsmb2-timeout-release.log`). Both apps pin this shared fix. ShelfKit's full 78-test suite also passed against the
460.8 MB SMB fixture with the patched dependency (`/tmp/shelfkit-timeout-fix-tests.log`).

Dependency patch and repeatable Docker test instructions:
https://github.com/vanities/AMSMB2/blob/4.0.4/PATCHES.md

The original simulator streaming interruption was repeated with AMSMB2 4.0.4: pause
server, skip forward, leave it unavailable beyond the 15-second timeout, restore server.
The app stayed alive and playback advanced after restoration (`/tmp/earmark-network-fixed-ui.txt`).
Full app reruns with the dependency patch passed: Earmark 202 and Mango 293 tests
(`/tmp/earmark-timeout-fix-tests.log`, `/tmp/mango-timeout-fix-tests.log`). The subsequent
capture-only cleanup built without compiler warnings (`/tmp/earmark-capture-fix-build.log`).

## Download recovery and release preparation

Force-quit recovery passed in both simulator apps: Earmark resumed a 460,800,044-byte
WAV and Mango a 367,061,310-byte CBZ from persisted running jobs and partial files.
Both completed files matched the source SHA-256 hashes. Evidence:
`/tmp/earmark-download-relaunch-result.json`, `/tmp/mango-download-relaunch-result.json`.

The physical Earmark lifecycle harness could not activate its audio session. A follow-up
native UI test was blocked at runner initialization by "Authentication canceled. Canceled
by user." Physical background playback and real OS interruptions therefore remain unverified;
the isolated device QA app and runner were removed.

Mango build 71 (`bc88b30`) was confirmed VALID and IN_BETA_TESTING for internal and external
testers, with notes attached. Earmark cloud builds 51 and 52 compiled/exported but failed
App Store Connect preparation. Direct upload of cloud-signed build 52 exposed the actual
validation error: approved version 0.1.0's pre-release train is closed (90062/90186). The
feature release now uses marketing version 0.2.0 for both app and widget.
