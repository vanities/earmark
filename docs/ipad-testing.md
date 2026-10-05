# iPad layout and simulator review

Read Apple's complete [Designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) guidance and [Supporting multiple windows on iPad](https://developer.apple.com/documentation/uikit/supporting-multiple-windows-on-ipad) before changing the layout. Design for the available window, size class, safe areas, and text size, rather than treating device orientation as the layout model. Check portrait, landscape, and narrow windows. These apps have not gained new multiple-window support in this pass.

## Native simulator capture

The review uses iPad mini (A17 Pro) portrait (744 x 1133 pt) and iPad Pro 13-inch (M5) landscape (1376 x 1032 pt), on iPadOS 27.0. Standard iPad uses main display 1. Verify the device with `xcrun simctl list devices` and its displays with `xcrun simctl io <UDID> enumerate`; do not reuse Duo inner display 3.

An XCTest preparation sets `XCUIDevice.shared.orientation` to `.portrait` or `.landscapeLeft`, launches the app, and waits until the actual app window has the requested aspect ratio before starting recordVideo. Then the walkthrough navigates the real app. Native screenshots must have the same requested orientation: mini portrait 1488 x 2266 pixels, Pro landscape 2752 x 2064 pixels. Do not rotate a PNG/video to claim a native orientation passed.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl io <UDID> recordVideo --codec=h264 --display=1 review.mp4
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl io <UDID> screenshot --display=1 review.png
```

Use a scoped DEVELOPER_DIR; do not change global xcode-select. Native Duo APIs require the 27.1/27.2 toolchain described in [iphone-duo-testing.md](iphone-duo-testing.md). The iPad walkthroughs may use that same built binary but run on an ordinary iPad simulator. A passing CLI orientation command alone does not prove app geometry.

Python capture/package helpers run with `uv run --with pillow python`. Run one UI walkthrough per simulator at a time. Package only actual nonempty passing test cases and passing selected suites; reject assertions, empty test restarts, missing/black screenshots, or incomplete videos. Keep original pixels for PNGs. A review MP4 can be scaled for size, without rotating, cropping, or recreating the UI. Verify videos with a full FFmpeg decode and native AVFoundation playback/frame decode.

## App behavior and validation

The app and widget now target both iPhone and iPad (device family 1,2). Keep all four iPad orientations in Info.plist. The expanded player uses a full-screen presentation in regular-width windows; compact windows keep the sheet fallback. In a wide player, bounded artwork sits alongside title, progress, playback controls, and chapters. Compact layouts remain vertically arranged. Native Duo Tabletop keeps artwork above the fold and controls below it. Build 0.3.0 (3) matches app and widget.

Local metadata loading requests precise duration. On iPadOS 27.0 the generated valid WAVs failed AVFoundation duration loading with approximate timing (-11800 / underlying -17770), while precise timing returned the correct duration. Existing real-file scanner tests cover single-file sources, folder grouping, and metadata cache reuse; fixtures explicitly close AVAudioFile before scanning. The full 202-test suite passes on iPad Pro 27.0, and the three scanner tests also pass on iPhone Air 26.5.

Use generated public-domain/sample fixtures in the app's own simulator folder. Check library, stats, sources/settings, book detail, expanded/mini player, chapters, bookmarks, presets, speed, sleep timer, and listening queue.

## Review artifacts

The shared workspace review is `../iphone-duo-review/2026-10-04-current/review/`, with per-app `*-ipad-mini` and `*-ipad-pro` MP4/JSON/PNG packets. `validation.json` records passing cases and source provenance; use it to distinguish historical Duo footage from the current build. The local gallery is http://127.0.0.1:8179/ when its server is running. These artifacts do not indicate an App Store Connect or TestFlight submission.
