# /// script
# dependencies = ["Pillow>=11"]
# ///
"""Render App Store frames from unretouched simulator captures.

Layout primitives adapted from SwiftBible's appstore/generate_marketing_screenshots.py.
Run: uv run --script scripts/render-store-screenshots.py
The app UI is never redrawn; marketing typography sits outside each capture.
"""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

def create_gradient(width, height, top_color, bottom_color):
    """Create a vertical gradient image."""
    img = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(img)
    for y in range(height):
        ratio = y / height
        r = int(top_color[0] + (bottom_color[0] - top_color[0]) * ratio)
        g = int(top_color[1] + (bottom_color[1] - top_color[1]) * ratio)
        b = int(top_color[2] + (bottom_color[2] - top_color[2]) * ratio)
        draw.line([(0, y), (width, y)], fill=(r, g, b))
    return img

def add_ambient_orbs(canvas, orbs_config, canvas_w, canvas_h):
    """Add soft glowing orbs for glassmorphism depth effect."""
    overlay = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    for (cx_pct, cy_pct, r_pct, color, alpha) in orbs_config:
        cx = int(canvas_w * cx_pct)
        cy = int(canvas_h * cy_pct)
        radius = int(min(canvas_w, canvas_h) * r_pct)
        draw.ellipse(
            [cx - radius, cy - radius, cx + radius, cy + radius],
            fill=(*color, alpha),
        )

    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=130))
    return Image.alpha_composite(canvas, overlay)

def round_corners(img, radius):
    """Apply rounded corners to an image."""
    mask = Image.new("L", img.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([(0, 0), img.size], radius=radius, fill=255)
    result = img.copy()
    result.putalpha(mask)
    return result

def create_shadow(size, radius, blur_radius=30, offset=(0, 15), opacity=100):
    """Create a drop shadow."""
    pad = blur_radius * 3
    shadow_size = (size[0] + pad * 2, size[1] + pad * 2)
    shadow = Image.new("RGBA", shadow_size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    draw.rounded_rectangle(
        [pad, pad, pad + size[0], pad + size[1]],
        radius=radius,
        fill=(0, 0, 0, opacity),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur_radius))
    return shadow, (pad - offset[0], pad - offset[1])

def load_font(size, bold=False):
    """Load SF Pro Display font."""
    if bold:
        paths = [
            "/Library/Fonts/SF-Pro-Display-Bold.otf",
            "/Library/Fonts/SF-Pro-Display-Semibold.otf",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        ]
    else:
        paths = [
            "/Library/Fonts/SF-Pro-Display-Medium.otf",
            "/Library/Fonts/SF-Pro-Display-Regular.otf",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
        ]
    for p in paths:
        try:
            return ImageFont.truetype(p, size)
        except (OSError, IOError):
            continue
    return ImageFont.load_default()

def draw_gradient_text(canvas, text, y, font, color_top, color_bottom, canvas_w, glow_color=None):
    """Draw headline text with a vertical gradient fill and optional glow."""
    # Get text dimensions
    tmp_draw = ImageDraw.Draw(canvas)
    bbox = tmp_draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    x = (canvas_w - text_w) // 2

    # Optional glow: soft colored bloom behind the text
    if glow_color:
        glow_pad = 60
        glow_layer = Image.new("RGBA", (canvas_w, text_h + glow_pad * 2), (0, 0, 0, 0))
        glow_draw = ImageDraw.Draw(glow_layer)
        glow_draw.text((x, glow_pad - bbox[1]), text, font=font,
                        fill=(*glow_color, 120))
        glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(radius=35))
        canvas.paste(glow_layer, (0, y - glow_pad), glow_layer)

    # Create gradient strip for the text area
    grad = Image.new("RGBA", (canvas_w, text_h + 40), (0, 0, 0, 0))
    for row in range(text_h + 40):
        ratio = row / (text_h + 40)
        r = int(color_top[0] + (color_bottom[0] - color_top[0]) * ratio)
        g = int(color_top[1] + (color_bottom[1] - color_top[1]) * ratio)
        b = int(color_top[2] + (color_bottom[2] - color_top[2]) * ratio)
        ImageDraw.Draw(grad).line([(0, row), (canvas_w, row)], fill=(r, g, b, 255))

    # Create text mask
    text_mask = Image.new("L", (canvas_w, text_h + 40), 0)
    mask_draw = ImageDraw.Draw(text_mask)
    mask_draw.text((x, -bbox[1]), text, font=font, fill=255)

    # Apply mask to gradient
    grad.putalpha(text_mask)

    # Composite onto canvas at y position
    canvas.paste(grad, (0, y), grad)
    return text_h

def scale_screenshot(raw, canvas_w, scale):
    """Scale a raw screenshot proportionally."""
    scaled_w = int(canvas_w * scale)
    scaled_h = int(raw.size[1] * (scaled_w / raw.size[0]))
    return raw.resize((scaled_w, scaled_h), Image.LANCZOS)

def paste_with_shadow(canvas, img, x, y, corner_r, shadow_blur=28, shadow_opacity=110):
    """Paste a rounded screenshot with drop shadow onto canvas."""
    rounded = round_corners(img, corner_r)
    shadow, s_offset = create_shadow(
        img.size, corner_r, blur_radius=shadow_blur, offset=(0, 14), opacity=shadow_opacity
    )
    canvas.paste(shadow, (x - s_offset[0], y - s_offset[1]), shadow)
    canvas.paste(rounded, (x, y), rounded)

def layout_straight(canvas, raw, config, canvas_w, canvas_h, corner_r, text_bottom):
    """Standard centered screenshot below text."""
    scale = config["screenshot_scale"]
    scaled = scale_screenshot(raw, canvas_w, scale)
    screenshot_y = text_bottom + int(canvas_h * 0.025)
    screenshot_x = (canvas_w - scaled.size[0]) // 2
    paste_with_shadow(canvas, scaled, screenshot_x, screenshot_y, corner_r)

def layout_tilted(canvas, raw, config, canvas_w, canvas_h, corner_r, text_bottom, angle):
    """Tilted/angled screenshot presentation."""
    scale = config["screenshot_scale"] * 0.92  # slightly smaller to fit rotation
    scaled = scale_screenshot(raw, canvas_w, scale)
    rounded = round_corners(scaled, corner_r)

    # Rotate with transparent background
    rotated = rounded.rotate(angle, expand=True, resample=Image.BICUBIC, fillcolor=(0, 0, 0, 0))

    # Create shadow for rotated version
    shadow_base = Image.new("RGBA", scaled.size, (0, 0, 0, 110))
    shadow_base = round_corners(shadow_base, corner_r)
    shadow_rotated = shadow_base.rotate(angle, expand=True, resample=Image.BICUBIC, fillcolor=(0, 0, 0, 0))
    pad = 100
    padded = Image.new("RGBA", (shadow_rotated.width + pad * 2, shadow_rotated.height + pad * 2))
    padded.paste(shadow_rotated, (pad, pad))
    shadow_rotated = padded.filter(ImageFilter.GaussianBlur(30))

    screenshot_y = text_bottom + int(canvas_h * 0.02)
    screenshot_x = (canvas_w - rotated.size[0]) // 2

    canvas.paste(shadow_rotated, (screenshot_x + 8 - pad, screenshot_y + 16 - pad), shadow_rotated)
    canvas.paste(rotated, (screenshot_x, screenshot_y), rotated)

def main():
    root = Path(__file__).resolve().parent.parent / "marketing"
    manifest = json.loads((root / "screenshots.json").read_text())
    for family, shots in manifest["sets"].items():
        width, height = ((1320, 2868) if family == "iphone" else (2064, 2752))
        for index, shot in enumerate(shots, 1):
            canvas = create_gradient(width, height, tuple(shot["top"]), tuple(shot["bottom"])).convert("RGBA")
            accent = tuple(shot["accent"])
            canvas = add_ambient_orbs(canvas, [(0.8, 0.4, 0.7, accent, 50), (0.1, 0.85, 0.5, accent, 22)], width, height)
            draw = ImageDraw.Draw(canvas)
            margin = int(width * .075)
            brandfont = load_font(int(width * .026), True)
            draw.text((margin, int(height * .045)), manifest["brand"].upper(), font=brandfont, fill=(*accent, 255))
            y = int(height * .086)
            font = load_font(int(width * .077), True)
            for line in shot["headline"]:
                assert draw.textlength(line, font=font) < width - margin * 2, line
                h = draw_gradient_text(canvas, line, y, font, (255, 253, 246), accent, width)
                y += h + int(height * .012)
            subtitle = load_font(int(width * .034))
            for line in shot["subtitle"]:
                assert draw.textlength(line, font=subtitle) < width - margin * 2, line
                draw.text((width // 2, y), line, font=subtitle, fill=(223, 220, 214, 255), anchor="mt")
                y += int(height * .022)
            raw = Image.open(root / "raw" / family / shot["raw"]).convert("RGBA")
            # Fit the entire actual capture below the headline with a small bottom margin.
            available = height - y - int(height * .07)
            ratio = min((width * .84) / raw.width, available / raw.height)
            config = {"screenshot_scale": raw.width * ratio / width}
            if shot.get("tilt"):
                layout_tilted(canvas, raw, config, width, height, 48, y, shot["tilt"])
            else:
                layout_straight(canvas, raw, config, width, height, 48, y)
            output = root / family / f"{index:02}-{shot['raw']}"
            output.parent.mkdir(parents=True, exist_ok=True)
            canvas.convert("RGB").save(output, "PNG", optimize=True)
            print(output)


if __name__ == "__main__":
    main()
