# Now Playing chapter and seeking regression

The report describes the current chapter or slider becoming stale after changing chapters
and scrubbing. Local generated audio reproduced two causes in the real `PlayerEngine`:

- A chapter beginning at 10.000375 seconds was sought at 10.000 seconds because the target
  used a millisecond timescale. The next tick selected the previous chapter; a following
  chapter-relative seek went into that chapter. Four alternating chapter taps reproduced it.
- During playing chapter changes, a queued time callback carried 0.513831869 seconds while
  the native player had already reached the requested 40.0015 seconds. Applying the old
  callback replaced the chosen chapter. Reading the native position alone reduced failures
  but still exposed the native seek's pending window during repeated stress.

The fix retains microsecond seek precision and rounds forward if conversion falls before
the requested boundary. Periodic callbacks read the live item position. While a seek is
pending, the displayed requested position stays authoritative; only its matching completion
can clear the pending state. Item replacement invalidates it. A replacement seek also keeps
the initial autoplay intent, with explicit Pause still taking precedence.

Regression tests were written and failed before their corresponding fixes. The initial
autoplay replacement case also failed by never starting playback. After the fix:

- All 254 ordinary tests passed on iOS 27, including the five new playback regression tests.
- Ten repetitions of the playing test passed (400 chapter-change/seek pairs), plus ten
  repetitions of seeking during initial readiness with autoplay. No temporary tracing was
  present in the final stress run.
- The native Now Playing sheet journey passed on iOS 26.5 (84 seconds); its retained screenshots show the chapter button, chapter count and scrubber agreeing.
- Both focused real SMB cases passed on iOS 27 and iOS 26.5: chapter changes with immediate seeking, and the existing playback/seek/pause/reconnect journey (7 seconds total per runtime).

The existing generated Frankenstein M4B native sheet journey passed before the fix; it is
a UI sanity check, not the failing reproduction. The failing seam uses actual AVPlayer
audio with fractional chapter metadata and rapid public transport commands. The exact
physical-device book/source and timing from the report remain unverified.

Receipts in `/tmp`: `earmark-seek-fractional-red-20261021.xcresult`,
`earmark-seek-playing-20261021.xcresult`, `earmark-seek-callback-trace-20261021.xcresult`,
`earmark-seek-autoplay-red-20261021.xcresult`,
`earmark-seek-latest-request-stress-20261021.xcresult`, and
`earmark-now-playing-full27-20261021.xcresult`. An aborted intermediate stress invocation
is excluded from passing validation. Temporary diagnostic logs were removed from source.
