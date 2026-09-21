#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "pillow"]
# ///
"""Generate Earmark's app icon with OpenAI's image API.

Family style shared with Mango (../mango): one bold flat charcoal glyph on a gradient, soft
drop shadow, no text. Earmark's glyph is a pair of headphones cradling an open book.

Amber moved to Mango, where orange means the fruit; Earmark takes a colour of its own.

Auth: OPENAI_OAUTH_TOKEN is tried first, then OPENAI_API_KEY. Both are read from the
environment, then from `.env` next to this repo, then from ../game/.env (where the existing
art pipeline keeps them). Nothing is ever printed.

    uv run --script scripts/generate-icon.py
    uv run --script scripts/generate-icon.py --model gpt-image-2.5-flare --quality high
    uv run --script scripts/generate-icon.py --dry-run
"""

from __future__ import annotations

import argparse
import base64
import io
import os
import sys
from pathlib import Path

import requests
from PIL import Image, ImageEnhance

REPO = Path(__file__).resolve().parent.parent
ICONSET = REPO / "Earmark/Resources/Assets.xcassets/AppIcon.appiconset"
API_URL = "https://api.openai.com/v1/images/generations"

# gpt-image-2.5, released 2026-09-08. "flare" is the fast high-quality generation variant;
# "sunburst" is tuned for multi-turn editing, which an icon generated from a prompt doesn't need.
DEFAULT_MODEL = "gpt-image-2.5-flare"

SHARED = (
    "App icon for iOS, square, 1024x1024, no text, no letters, no words anywhere. "
    "A single bold flat vector glyph centred in the frame, filling about 70% of it, "
    "with a soft subtle drop shadow beneath it. The glyph is a pair of over-ear headphones "
    "seen from the front — a thick curved headband with a rounded earcup on each side — "
    "cradling an open book whose two pages fan up between the earcups, the page edges "
    "curving outward at the bottom. Headphones and book resolve as one clean symmetrical "
    "shape. Flat modern iconography, generous even margins, crisp edges, perfectly centred, "
    "no outline stroke, no gloss, no 3D render, no photorealism, no rounded-rectangle frame "
    "or border drawn inside the image. The background is a smooth two-colour diagonal "
    "gradient, completely plain with no pattern or texture."
)

# Amber went to Mango with the fruit, so Earmark needs a colour of its own. Each palette is
# (light-glyph, light-background, dark-glyph, dark-background).
PALETTES = {
    "green": (
        "very dark charcoal, almost black",
        "fresh unripe-mango green in the top-left to deep leaf green in the bottom-right",
        "bright fresh mango green fading to lime",
        "very dark green-black in the top-left to near-black in the bottom-right",
    ),
    "teal": (
        "very dark charcoal, almost black",
        "bright turquoise in the top-left to deep teal in the bottom-right",
        "bright turquoise fading to aqua",
        "very dark teal-black in the top-left to near-black in the bottom-right",
    ),
    "berry": (
        "very dark charcoal, almost black",
        "vivid raspberry pink in the top-left to deep plum purple in the bottom-right",
        "vivid raspberry pink fading to warm magenta",
        "very dark plum-black in the top-left to near-black in the bottom-right",
    ),
    "indigo": (
        "very dark charcoal, almost black",
        # Kept deliberately light: a deep-navy end made the whole icon read as a dark slab
        # next to Mango's bright orange.
        "light periwinkle blue in the top-left to a medium vivid royal blue in the "
        "bottom-right, bright and luminous rather than dark",
        "light periwinkle blue fading to soft cornflower",
        "deep indigo in the top-left to very dark navy in the bottom-right",
    ),
}


def variants(palette: str) -> dict[str, str]:
    light_glyph, light_bg, dark_glyph, dark_bg = PALETTES[palette]
    return {
        "AppIcon.png": SHARED + f" The glyph is {light_glyph}. The background gradient runs from {light_bg}.",
        "AppIcon-Dark.png": SHARED + f" The glyph is {dark_glyph}. The background gradient runs from {dark_bg}.",
    }


def load_env(path: Path) -> None:
    """Minimal .env reader. Sets vars that aren't already in the environment."""
    if not path.is_file():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        line = line.removeprefix("export ").lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key.strip(), value)


def bearer_token() -> tuple[str, str]:
    """Returns (token, which) — OAuth first, then API key, per Adam's instruction."""
    for path in (REPO / ".env", REPO.parent / "game" / ".env"):
        load_env(path)
    for name in ("OPENAI_OAUTH_TOKEN", "OPENAI_API_KEY"):
        token = os.environ.get(name)
        if token:
            return token, name
    sys.exit(
        "No credential found. Set OPENAI_OAUTH_TOKEN or OPENAI_API_KEY in the environment, "
        "in ./.env, or in ../game/.env."
    )


def generate(prompt: str, token: str, model: str, quality: str, size: str) -> bytes:
    payload = {"model": model, "prompt": prompt, "n": 1, "size": size, "quality": quality}
    response = requests.post(
        API_URL,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
        timeout=900,
    )
    if not response.ok:
        raise SystemExit(f"image API error {response.status_code}: {response.text[:400]}")
    item = response.json()["data"][0]
    if "b64_json" in item:
        return base64.b64decode(item["b64_json"])
    return requests.get(item["url"], timeout=120).content


def derive_tinted(dark_png: bytes) -> bytes:
    """iOS tinted icons are greyscale masks the system colours itself, so this is derived
    from the dark variant rather than generated — a second generation would drift."""
    image = Image.open(io.BytesIO(dark_png)).convert("RGB")
    grey = image.convert("L")
    grey = ImageEnhance.Contrast(grey).enhance(1.15)
    out = io.BytesIO()
    grey.convert("RGB").save(out, format="PNG")
    return out.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--quality", default="high")
    parser.add_argument("--size", default="1024x1024")
    parser.add_argument("--palette", default="green", choices=sorted(PALETTES))
    parser.add_argument("--only-light", action="store_true", help="just the light variant, for comparing palettes")
    parser.add_argument("--out", type=Path, default=None, help="write here instead of the iconset")
    parser.add_argument("--dry-run", action="store_true", help="print the prompts and stop")
    args = parser.parse_args()

    chosen = variants(args.palette)
    if args.only_light:
        chosen = {"AppIcon.png": chosen["AppIcon.png"]}
    destination = args.out or ICONSET

    if args.dry_run:
        for name, prompt in chosen.items():
            print(f"--- {name} ---\n{prompt}\n")
        return

    token, source = bearer_token()
    print(f"Using {source} · model {args.model} · quality {args.quality} · palette {args.palette}")
    destination.mkdir(parents=True, exist_ok=True)

    dark_png = b""
    for name, prompt in chosen.items():
        print(f"Generating {name}…", flush=True)
        data = generate(prompt, token, args.model, args.quality, args.size)
        (destination / name).write_bytes(data)
        print(f"  wrote {name} ({len(data) // 1024} KB)")
        if name == "AppIcon-Dark.png":
            dark_png = data

    if dark_png:
        tinted = derive_tinted(dark_png)
        (destination / "AppIcon-Tinted.png").write_bytes(tinted)
        print(f"  wrote AppIcon-Tinted.png ({len(tinted) // 1024} KB, derived greyscale)")


if __name__ == "__main__":
    main()
