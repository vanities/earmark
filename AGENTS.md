# Earmark — agent guide

> `CLAUDE.md` is a symlink to this file.

Earmark is an open-source iOS audiobook player (SwiftUI, iOS 26; the only dependency is
AMSMB2 for SMB). Its whole reason to exist: play the files you already have, where they
are, with great organization and CarPlay — and never nag.

## Non-negotiables

- **Never copy or move the user's audio.** Sources are security-scoped bookmarks
  (`BookmarkStore`) or the app's own Documents folder. The only files Earmark writes about
  a book are cover thumbnails in Caches (`ArtworkStore`), JSON in Application Support, and —
  when the user picks a cover for a book on this device — one image beside its audio
  (`cover.jpg` in a book folder, `<file>.jpg` next to a single file) so other apps see it.
  Earmark only ever replaces or deletes an image it wrote itself (hash in
  `LibraryState.writtenCovers`), never one the user put there.
- **Move into Earmark** (a book in a folder the user picked → On My iPhone › Earmark) is the one
  move, and only when asked: ShelfKit's `LocalMove` copies, checks every file arrived whole, and
  only then removes the originals. A file already there counts as moved only if every byte
  matches; a different one is never overwritten. Folders it empties go, up to the picked folder.
- **What the listener did follows the book between copies** (`CopyState`, tested): a move or a
  removed download hands everything to the copy that stays (`handOverState`); a download fills
  what it lacks from the NAS copy it came from (`adoptStateFromRemoteTwins`). Place, bookmarks,
  corrections, hidden, last played — never just the position.
- **No donation / tip / rating prompts. Ever.**
- Remote (SMB) books are real library sources: `LibraryScanner.scanRemote` walks the share,
  `MetadataReader.read(asset:)` reads tags through `SMBResourceLoader`, and `LibraryModel.visibleBooks`
  hides a remote book once a downloaded twin (same relative path) exists locally.
- Library contents are *derived* by scanning; user state (progress, hidden, speed) lives
  in `LibraryState.progress` keyed by the stable `Book.id` and must survive rescans.

## Layout

```
Earmark/
  App/            EarmarkApp (SwiftUI @main), AppEnvironment (composition root, shared with CarPlay)
  Models/         Book, Track, Chapter, LibrarySource, PlaybackProgress, LibraryState, AppSettings
  Services/
    Library/      BookmarkStore, LibraryStore (JSON), MetadataReader (AVFoundation tags/chapters),
                  MetadataCache (actor), ArtworkStore, NameParser (real-world file/folder name patterns),
                  QuickTagReader (ID3/MPEG header parser for remote MP3s — avoids whole-file downloads),
                  BookGrouper (pure logic), LibraryScanner, DuplicateFinder, CopyState (what follows a
                  book between copies), Catalogs (the iTunes + Open Library client Find Cover and
                  Look Up share), LibraryModel (@MainActor @Observable source of truth; its feature
                  files +Covers/+Downloads/+Duplicates/+History/+Lists/+NAS/+Cloud/+Queries)
    Playback/     PlayerEngine (AVPlayer), AudioSessionManager, NowPlayingController (lock screen/CarPlay)
    Network/      NASClient (AMSMB2 wrapper; bounded range reads only — never abort a stream mid-callback),
                  SMBResourceLoader (AVAssetResourceLoaderDelegate streaming), DownloadManager (downloads,
                  Move-into-Earmark via ShelfKit's LocalMove, persisted queue, BGProcessingTask), KeychainStore
    Library/      also CoverSearch (iTunes + Open Library lookups), CoverSync (pure cover-choice merge
                  and per-device plan; newest choice wins across devices) and QuickTagReader
  CarPlay/        CarPlaySceneDelegate (from Info.plist), CarPlayInterface (templates)
  Views/          Root (TabView + bottom-accessory mini player), Library, Player, Sources (SourcesView,
                  SourceBrowserView — laid out as Mango's, drawn with ShelfKit's shared views), Stats,
                  Settings, Components
  Resources/      Info.plist (background audio, Files integration, CarPlay scene), assets, entitlements
EarmarkTests/     XCTest: grouping heuristics, positions, formatting, duplicates, real-file scanner test
scripts/          make-fixtures.sh (sample audiobooks with real speech), install-fixtures.sh, render-icon.swift
```

## Build / run / test

The project file is generated: edit `project.yml`, then `xcodegen generate` (`make gen`).
`Earmark.xcodeproj` is committed so `open Earmark.xcodeproj` works without xcodegen.

Preferred tooling in agent sessions is the `xcodebuildmcp` CLI:

```bash
xcodebuildmcp simulator build-and-run --project-path Earmark.xcodeproj --scheme Earmark --simulator-name "iPhone Air"
xcodebuildmcp simulator test          --project-path Earmark.xcodeproj --scheme Earmark --simulator-name "iPhone Air"
xcodebuildmcp simulator screenshot    --simulator-name "iPhone Air" --output /tmp/shot.png
xcodebuildmcp simulator snapshot-ui   ...   # semantic UI snapshot with elementRefs, then ui-automation tap
```

Plain `xcodebuild` equivalents are in the `Makefile` (`make build`, `make test`).

Sample content: `make fixtures && make install-fixtures` drops a tagged MP3 book, an M4B
with chapters, Disc 1/2 folders, an Author/Series tree, loose files, and a duplicate into
the simulator's "On My iPhone › Earmark". The app scans it on launch.

Device builds need a team: copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig`.

## Conventions

- Swift 5 language mode with `SWIFT_STRICT_CONCURRENCY = complete`. Observable models are
  `@MainActor`; scanning/IO is `Sendable` structs + actors off-main. Fix concurrency warnings,
  don't silence them.
- Logging: `os.Logger` via `Logger.<category>` (`Logger+Earmark.swift`), `[scope]`-prefixed
  messages, timings via `Stopwatch`. Log boundaries, decisions, and every error with its
  inputs. Never log secrets or PII (paths and titles are fine for this personal app).
- Persisted types (`LibraryState` and everything inside it) must keep decoding files written by
  older builds: give new fields a default *and* decode them with `decodeIfPresent` (see
  `LibraryState.init(from:)`), then add a case to `LibraryStateCompatTests`. `LibraryStore` moves an
  undecodable library aside and restores it once a build can read it again.
- **iCloud sync never plain-unions anything that can be deleted** — the other device still has
  it, so the next merge brings it back (Mango's deleted bookmarks did). Bookmarks sync as
  `bookmarks.v1` minus `LibraryState.deletedBookmarks` (tombstones, synced as
  `bookmarks.deleted.v1`, pruned at 180 days); the rules are `BookmarkSync` on ShelfKit's
  `UnionSync`/`Tombstones`. Plumbing shared with Mango lives in ShelfKit
  (github.com/vanities/shelfkit), pinned with `exactVersion` in `project.yml`.
- Heuristics live in `BookGrouper` and are unit-tested. When changing grouping rules, add a
  case to `BookGrouperTests` first.
- **Keep the UI like Mango's.** Both apps share a look (Sources, a source's page, the Library's
  toolbar and Continue row, Stats); the pieces drawn identically are ShelfKit views. A change
  to one app's version of those screens goes to the other's too, and nothing either app can do
  is dropped to make them match.
- UI is native iOS 26 (Liquid Glass): `tabViewBottomAccessory` mini player,
  `glassProminent` primary buttons, SF Symbols. Keep hit targets ≥ 44pt — this is used in cars.
- SwiftLint config in `.swiftlint.yml`; run `swiftlint` before committing.

## Stress testing

`python3 scripts/monkey.py --udid <sim>` runs scripted NAS scenarios (stream, skip, speed, sleep,
switch books, download/cancel/resume, background/foreground, kill mid-scan) and then random taps
that avoid destructive actions. It reports simulator crash reports and whether the app stayed up.
Run it against a simulator that already has the NAS source configured.

## Releasing

`make archive && make upload` (see README). `ExportOptions.plist` = automatic signing,
`manageAppVersionAndBuildNumber`, team 8Q3RG3ULSU. `scripts/testflight.py` wraps the ASC API for
status/groups/notes and reads `.env.appstore-connect` (gitignored, never commit the .p8).
The App Store Connect app record must exist before the first upload (`missingApp` error otherwise).

## Testing CarPlay

Simulator → I/O → External Displays → CarPlay. The entitlement in `Earmark.entitlements`
works in the simulator; a physical car needs Apple to grant `com.apple.developer.carplay-audio`
for the App ID (https://developer.apple.com/contact/carplay/). Without it, Earmark still
controls from the car's "Now Playing" screen via `MPNowPlayingInfoCenter`.
