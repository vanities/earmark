# SMB simulator audit

Use a dedicated iOS simulator with generated content. These tests use the app's real
SMB client, reader/player, and transfer manager. They download only generated fixtures
into the simulator's own Documents folder and remove those generated downloads afterward.
They reject pre-existing destination/partial files. Do not run both apps' suites at once
against this fixture share.

Run the WAV streaming cases on iOS 27 as well as iOS 26.5. Approximate timing failed WAV
startup only on iOS 27; the app now requests precise timing for WAV while retaining ranged
reads. The service-loss cases must use the controlled server's normal read delay: a fully
buffered file cannot establish the intended unavailable-source precondition.

Start a localhost-only SMB2 server (port 1445, share AUDIT) in one terminal:

```sh
uv run --with impacket python scripts/nas-audit/smb_fixture.py
```

In another terminal, build the separate integration target and run it:

```sh
uv run --with pyyaml python scripts/nas-audit/run.py --udid <DEDICATED_SIMULATOR_UDID> --result /tmp/smb-audit.xcresult
```

The runner creates a temporary generated Xcode project; the committed project and ordinary
unit suite stay unchanged. Results and a sibling `.log` are retained. `--only <testMethod>`
selects a case and can be repeated. Stop the fixture server with Ctrl-C afterward.
The fixture credentials are deliberately public and only used on loopback. The server refuses
to populate a nonempty directory that lacks its fixture marker. Small test-state directories
remain in the simulator's temporary folder until cleanup; this lets background cover work finish.

Mango can additionally replay an original EPUB without copying or modifying it: pass the
same `--original-epub /absolute/path/to/book.epub` to both commands. The server exports its
parent directory as a second share, ORIGINAL, with writes disabled. This optional test
is skipped when no book is specified. Only use an original that the user asked to investigate.
The volume-16 replay expects 18 spine documents; adapt that assertion for other books.

Coverage includes actual SMB chapter transitions or AVPlayer playback, bounded reads,
partial-download cancellation and retry, offline local playback/removal, and manual
client reconnect. Both apps test a fixture truncated during transfer; Mango also checks unavailable and empty folders. This suite does not establish the cause of an unrecorded device crash, and a
manual disconnect/reconnect is not an OS network-outage simulation.

Three additional cases drive the actual transfer manager with injectable background execution
callbacks while downloading over SMB: expiry then a new execution, expiry then foreground,
and foreground before expiry. They verify retained partials, exact final bytes, pending jobs,
explicit cancellation, and stale callback rejection. They exercise lifecycle handling, not
the OS scheduler's decision to grant background time. Select them with repeated `--only`
arguments using the method names in `Tests.swift`.

For actual service-loss cases, start the controlled server instead of `smb_fixture.py`:

```sh
uv run --with impacket python scripts/nas-audit/service_control.py
```

The controller owns its child process on loopback port 1445. Tests send nonce-tagged requests
through the generated fixture directory to stop that child (closing its live SMB connections)
and start a fresh server. Restarts reuse the existing files, preserving ZIP headers and modification
times. They assert the server generation changed and retry with the same
app client. Default read delay is 0.03 seconds to keep enough data in flight. Ctrl-C stops the
owned child and removes its control session. It refuses an existing port listener and does not
export original books. This tests service loss; a device network-interface outage or physical
NAS/VPN failure remains separate.

Replacement-source cases cancel a real download, replace only a generated fixture, and retry.
They cover equal-sized, growing and preserved-timestamp changes, compare every final byte,
and reject detected changes during an active transfer before retrying. Earmark additionally
changes only a retained middle range while preserving size, timestamp and sampled ends.
Both apps verify the complete retained prefix through bounded reads before resuming;
unchanged-source cancellation, service restart and background cases guard that path too.
Source snapshots do not provide atomic reads of a concurrently edited NAS file. The hidden
`.versions` fixtures are generated test data and are never registered as library sources.
