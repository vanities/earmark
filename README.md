# Earmark

An open-source iOS audiobook player for people with folders full of MP3s and M4Bs.
It plays your files **where they are**, keeps them organized, works great in the car, and
never asks you for money.

**[Join the TestFlight beta →](https://testflight.apple.com/join/E65Y3akv)**

> Bundle ID `com.vanities.earmark`. GPL-3.0. Website: https://am2.biz/earmark · [Support](https://am2.biz/earmark/support) · [Privacy](https://am2.biz/earmark/privacy)

## Why

Existing players want you to import files one at a time, quietly duplicate them into their
own sandbox, and interrupt you with donation screens. Earmark does none of that:

- **Pick a whole folder.** iCloud Drive, On My iPhone, another app's folder, or a NAS share
  connected in the Files app. Earmark keeps a security-scoped bookmark and reads in place.
  Nothing is copied or moved unless you ask.
- **Auto-organized.** A folder of MP3s is a book, each `.m4b` is a book, `Disc 1/Disc 2`
  folders merge, and `Author / Series / Book` trees (or tags) fill in author and series.
  Group by author, series, or folder; search everything.
- **Consolidate.** "Move into Earmark" copies books from any folder you picked (another
  player's folder, Downloads) into On My iPhone › Earmark, checks every file arrived whole, and
  only then deletes the originals — a different file already there is never overwritten. Your
  place, bookmarks and corrected details come along, so everything ends up in one place.
- **Find covers.** One tap searches Apple's audiobook catalog and Open Library for artwork and saves
  your pick (as `cover.jpg` next to the files for local books).
- **Find duplicates.** Fingerprints every file (size + content hash) and shows identical
  books or stray copies so you can reclaim space — deletion always asks first.
- **A player that just works.** Big skip back/forward (configurable), 0.5–3× speed with
  natural pitch, chapters, sleep timer (including "end of chapter"), smart rewind after a
  pause, per-book speed memory, lock screen and Control Center controls.
- **NAS support.** Add an SMB share (Unraid, Synology, any file server) as a library folder.
  Remote books show a **Remote** badge, stream while you're on the NAS's network, and can be
  downloaded to the phone with one tap; the local copy then takes over automatically.
- **Stats.** Books finished, a yearly goal, and time listening: this week, this month, your
  streak, a calendar of the last four months, when in the day you listen, and the books that
  took the most time. Only time audio actually plays counts. Day totals sync through your own
  iCloud, the same way Mango counts reading.
- **CarPlay.** A real CarPlay app with *Continue* and *Library* tabs plus Now Playing with
  speed, bookmark, undo-jump and chapter buttons — and even without the CarPlay entitlement,
  full control from the car's Now Playing screen.
- **No tip jar.** Free, open source, done.

## Requirements

- iOS 26 or later (uses the iOS 26 tab-bar accessory mini player and Liquid Glass).
- Xcode 26 to build. `brew install xcodegen` if you want to regenerate the project.
- One Swift package: [AMSMB2](https://github.com/amosavian/AMSMB2) for SMB.

## Build

```bash
git clone https://github.com/vanities/earmark && cd earmark
make gen              # regenerate Earmark.xcodeproj from project.yml (optional, it's committed)
open Earmark.xcodeproj
```

Run on the simulator from Xcode, or:

```bash
make run              # via xcodebuildmcp
make test             # unit tests
make fixtures && make install-fixtures   # sample audiobooks with real narration → simulator
```

To run on your iPhone, copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig`
and put your Apple Developer team ID in it (or pick a team in Xcode's Signing tab).

## Browsing

The default view is **Authors → Series → Book**: open an author to see their sets of work in
chronological order (years come from tags or `[Y=1998]`-style folder names), with standalone books
after. Series, Folders, and a flat "All Books" grid are one tap away in the view menu, and search
always shows a flat result list.

An author's, series' or folder's page opens the way Mango's series page does: the covers, how
many books and hours, and one button — **Resume** the book you were on there, or **Play** the first
one you haven't finished. Its ••• menu downloads everything that's only on the NAS, or removes
the downloads (they play from the NAS again).

**Edit Details › Look Up Book** finds a book in Apple Books and Open Library and fills its title,
author, narrator (split from Apple's "Author & Narrator"), series and year from the match you
pick — only when you tap it, and nothing is saved until you do.

**Lists** (the list button in the Library's top bar) are your own: "Up next", "Road trip". Add a
book from its menu (Add to List…), drag to reorder, swipe to remove. A listed book stays listed
through downloads and rescans — lists hold books by their path.

## Getting your books in

1. **Add Folder…** in Library's ••• menu or in Sources, and pick the folder — you get read access to the
   whole tree. Add as many as you like.
2. Or, in the Files app, move audiobooks into **On My iPhone › Earmark**. That folder is
   scanned automatically.
3. Any other app's exposed folder (e.g. another player's "On My iPhone" folder) can be
   added the same way, so you can adopt an existing library without moving it.

Recommended layout, all optional because tags are read too:

```
Audiobooks/
  Jane Austen/
    Pride and Prejudice/            ← folder of chapters = one book
      01 - Chapter 1.mp3
      02 - Chapter 2.mp3
      cover.jpg
  Mary Shelley/
    Frankenstein.m4b                ← single file with embedded chapters = one book
  Herman Melville/
    Moby-Dick/
      Disc 1/ ...                   ← disc folders merge into the parent book
      Disc 2/ ...
  Lewis Carroll/
    Alice/                          ← Author / Series / Book
      1 - Alice's Adventures in Wonderland/
      2 - Through the Looking-Glass/
```

Supported: MP3, M4A/M4B/AAC, WAV, AIFF, CAF, FLAC. Files iOS can't decode (OGG/Opus/WMA)
are listed under the folder so you know why they're missing.

## CarPlay

The `com.apple.developer.carplay-audio` entitlement is in the project and works in the
simulator (Simulator → I/O → External Displays → CarPlay). To use the CarPlay app in a real
car, request the entitlement for your App ID at https://developer.apple.com/contact/carplay/
(it's free; audio apps are routinely approved). Until then, playback controls, artwork,
and skip buttons still appear in the car's built-in Now Playing screen.

## NAS / SMB

Sources › **Add NAS Share…** asks for host, share, folder, and login (the password is stored in the
Keychain). Earmark indexes the folder listing over SMB, reads tags the same way it does for
local files, and shows the books on the shelf with a Remote badge. Playback streams through
AVFoundation's resource loader, so nothing is written to disk unless you tap **Download to
iPhone** on a book, which copies its folder into On My iPhone › Earmark. Once a downloaded copy
exists, the remote entry hides and the download picks up everything you did to it: your place,
bookmarks, corrected details, even hidden. **Download Everything** (Sources › Sync, the ••• menu
on the NAS's page, or swipe its row) queues every book that isn't on the phone yet and skips
files you already have. If the NAS can't be reached, the player says so instead of failing silently.

A source's page shows it the way Mango shows its sources: how much is in both places (on a NAS,
how much is on this iPhone; on this iPhone, how much is safe on the NAS), and a compact row per
book under its author with a ring for what it can do — download, upload, remove a download, or
move a book in from a folder you picked.

Indexing a share is cheap on bandwidth: MP3 tags and durations are read from the first few
hundred KB of each file (`QuickTagReader`), so a 16 GB library indexes in a few minutes without
downloading it.

Two useful patterns: keep the NAS as the master library and download only what you're about
to listen to, or point the phone's NAS folder at the same tree you already curate.

**Done with a download? Give the space back.** A downloaded book's menu has **Remove Download**:
it deletes the copy in On My iPhone › Earmark and the book plays from the NAS again, with its
place and bookmarks intact. **Select** on a source's page picks several books at once — on the
NAS to download them or remove their downloads, on this iPhone to upload them to the NAS or
remove downloads — with the count and size on each button. Only ever a download whose book is
still on the NAS: a book that exists only on the phone, or in a folder you picked, is never
deleted this way.

Transfers run one at a time and keep going while Earmark is open or a book is playing (the screen
stays awake). If iOS suspends the app they pause, survive termination, and resume from partial
files on the next launch; a background processing task also picks them up while the phone is idle.

## TestFlight / App Store Connect

One-time: create the app in [App Store Connect](https://appstoreconnect.apple.com/apps) (iOS, name
Earmark, bundle ID `com.vanities.earmark`, any SKU) and be signed into Xcode with the team in
`Config/Signing.xcconfig`. Then:

```bash
make archive      # Release archive (build/Earmark.xcarchive)
make upload       # re-sign for App Store Connect and upload; ASC assigns the build number
make testflight   # both
```

`ExportOptions.plist` uses automatic signing and lets App Store Connect manage build numbers,
so every upload is unique without touching the project. To drive TestFlight from the terminal,
copy `.env.appstore-connect.example` to `.env.appstore-connect`, point it at an App Store Connect
API key, and use `scripts/testflight.py` (`status`, `ensure-group`, `wait`, `notes`). Internal
testers in a group with "all builds" access get each upload automatically.

## Roadmap

- Bonjour discovery of SMB servers and per-server "download everything new".
- Per-folder overrides ("treat as one book" / "split by album") for messy folders.
- iCloud Drive download management for not-yet-downloaded books.
- Bookmarks and notes within a book.
- Import listening progress from other players.

## Architecture in one paragraph

`LibraryModel` (main actor) owns the list of sources and books and persists them as JSON.
`LibraryScanner` walks each source off-main, reads tags with AVFoundation (cached by
size + mtime), hands the flat file list to `BookGrouper` — pure, unit-tested logic that
decides what is a book — and resolves cover art into small cached thumbnails.
`PlayerEngine` wraps a single `AVPlayer`, advances through multi-file books, and reports to
`NowPlayingController`, which mirrors state to the lock screen and CarPlay.
`CarPlayInterface` builds CarPlay templates from the same shared `AppEnvironment`.

## License

GPL-3.0. See `LICENSE`.
