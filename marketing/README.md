# Earmark App Store presentation

The en-US listing copy lives in `scripts/appstore.py` (`COPY`). The three iPhone
frames in `iphone/` use real simulator captures in `raw/iphone/`, with an original
cover and generated demo audio. The screenshot design follows SwiftBible's bold
headlines, warm gradients, rounded captures and subtle shadows.

The final frames show the player, chapters and sleep timer. These are Earmark
0.2.0 features, captured from the build-53 source line. No production library,
personal server address, or user audio was used. The demo book's long-duration
silent tracks are screenshot fixtures, not a recording included with the app.

Regenerate the marketing frames on macOS:

```sh
uv run --script scripts/render-store-screenshots.py
```

`screenshots.json` defines copy, color and ordering. The renderer uses SwiftBible's
layout primitives, preserves the actual app UI, checks headline widths, and exports
opaque RGB PNGs at 1320 x 2868. Original captures are retained without retouching.

## Original artwork

`assets/secret-garden-cover.png` was generated with the built-in image generation
tool. Prompt:

> Square original illustrated audiobook cover for THE SECRET GARDEN by FRANCES HODGSON BURNETT, a public-domain novel. A small weathered garden gate framed by lush blue-green leaves, climbing roses, golden morning light through branches. Refined botanical screenprint style with teal, cream and coral accents, tasteful large serif typography, exceptionally readable as a thumbnail. Flat finished artwork only, no mockup, no app UI.

The original novel is public domain; this is newly generated cover artwork, not a
publisher's edition cover. No book or audiobook is bundled with Earmark.

## Listing verification

The subtitle, promotional text, description, keywords and What's New were read
back from ASC after updating. All fit Apple's character/byte limits. Marketing,
support and privacy URLs returned HTTP 200; contact information is present on the
support page. The upload checked all new assets were COMPLETE before replacing
the old screenshots and verified their final order.

Apple blocks screenshot creation while waiting for review, so the existing
submission was removed and resubmitted with the same 0.2.0 build 53. Automatic
release after approval was preserved. See `asc-verification.json` for the final
readback; Waiting for Review is not approval or public availability.
