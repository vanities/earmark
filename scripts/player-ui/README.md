# Native player audit

Generate the public-domain narration with `scripts/make-fixtures.sh`, then use a dedicated
simulator whose name contains `Audit`:

```sh
uv run --with pyyaml python scripts/player-ui/run.py --udid <UDID> --orientation landscape --result /tmp/earmark-player-ui.xcresult
```

The runner builds a temporary Xcode project with a separate QA bundle identifier, installs
only that QA app, and copies only the generated fixtures into its Documents folder. It rejects
unmarked, nonempty QA Documents. It leaves the simulator, generated state, build logs and result
bundle for inspection; it does not change the committed project or the normal app's library.
Use `--only <method>` to select a journey. Tests assert native window geometry, bookmark seeking,
paused preset application and queue autoplay, and retain screenshots in the result bundle.
`testBookmarkNoteCancelSaveDeleteAndRelaunch` covers note cancellation, persistence, deletion,
and relaunch. `testBookmarkNoteStaysWithItsBookWhenQueueAdvancesDuringEditing` enters a real
draft, waits for actual audio completion and queue autoplay, saves it, and verifies the original
book owns the note while the new book remains untouched. Player title/chapter identifiers and
sheet/cell-scoped queries distinguish these controls from the covered book-detail screen.
`testQueueReorderAndRemovalSurviveRelaunch` adds three generated books, checks duplicate
prevention in the actual Add sheet, drags a native reorder handle, relaunches, removes a book,
and relaunches again. It checks visible title positions and uniqueness in `ListeningQueueList`;
`QueueBookPickerList` scopes Add-sheet checks away from the covered queue.
`testCustomizedPresetPersistsAndAppliesWithoutStartingPlayback` edits every Driving field,
relaunches, applies it while paused, checks speed/timer plus the Audio settings, then restores
the generated QA app's Driving defaults. Boolean preferences use native controls; string
launch arguments do not override this app's typed Bool reads. The normal restore-to-player
behavior is handled explicitly, and the minimized Settings tab bar is reached through the
visible mini player.

The runner holds a per-device lock and reuses a per-device DerivedData directory. Wait for its
authoritative exit before starting another run on that simulator, including ordinary test runs
or manual native-app control. A result path and test screenshots remain available after failure.
No physical-device, CarPlay, NAS or hosted-release behavior is established by this suite.

`testChapterChangesAndScrubbingKeepCurrentChapter` selects chapters in the generated M4B,
pauses, drags the real slider to the start and then into the chapter, and verifies the current
chapter button and slider update together. The existing sample passed before the fix too;
the failing fractional-boundary and rapid-playback repros are in `PlayerLifecycleTests`.
