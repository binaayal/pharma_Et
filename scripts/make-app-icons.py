#!/usr/bin/env python3
"""Renders every app, web and store icon from the one brand image.

Source: apps/mobile/assets/brand/icon-source.png — the cross, capsule and leaf on a cream
tile, drawn as a finished 1254 px picture *with its own rounded tile and drop shadow*. That
is right for a picture and wrong for an icon: iOS and Android apply their own mask, and an
icon that already has corners and a shadow ends up with two of each.

So the artwork is lifted off its tile rather than cropped:

  1. The tile's cream is a near-flat gradient. A plane is fitted to it (residual about one
     level in 255), which lets the background be extended to any size without a seam.
  2. The artwork is pasted onto that extended background with a feathered edge. Inside the
     feather the source and the fitted plane agree to within that one level, so the join is
     invisible.
  3. Each platform then gets the framing it expects: full-bleed and opaque for iOS (the store
     rejects alpha), an adaptive foreground inside the 66 dp safe zone for Android 8+, a
     rounded square for older Android, the web console and the in-app logo.

The outputs are committed so a build never depends on this script or on Pillow and numpy.
Re-run it after replacing the source image:

    python3 scripts/make-app-icons.py
"""
import json
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, '..')
MOBILE = os.path.join(REPO, 'apps', 'mobile')
SOURCE = os.path.join(MOBILE, 'assets', 'brand', 'icon-source.png')

src = np.asarray(Image.open(SOURCE).convert('RGB')).astype(np.float64)
H, W, _ = src.shape

# Where the artwork is, in source pixels: found by saturation, then padded so the white
# outline round the capsule is inside the paste. Measured once on the source; a new source
# image means re-measuring these four numbers.
ART = (242, 216, 1011, 1033)  # left, top, right, bottom
ART_CX = (ART[0] + ART[2]) / 2
ART_CY = (ART[1] + ART[3]) / 2
ART_W = ART[2] - ART[0]
# The region of source that is safely inside the tile, clear of its rim and shadow: the
# tile's own rounded square, inset. A plain rectangle cannot reach the cross's arms without
# also reaching the tile's corners.
PASTE = (140, 140, 1115, 1115)
PASTE_RADIUS = 205
PASTE_FEATHER = 24


def fit_background():
    """A plane per channel over the tile's own background, away from the rim and the art."""
    ys, xs = np.mgrid[0:H, 0:W]
    inside = (xs > 170) & (xs < 1085) & (ys > 170) & (ys < 1085)
    near_corner = np.zeros_like(inside)
    for cx, cy in [(345, 345), (910, 345), (345, 910), (910, 910)]:
        quadrant = ((xs < 345) == (cx == 345)) & ((ys < 345) == (cy == 345))
        outer = ((xs < 345) | (xs > 910)) & ((ys < 345) | (ys > 910))
        near_corner |= quadrant & outer & (((xs - cx) ** 2 + (ys - cy) ** 2) > 175 ** 2)
    art = (xs > ART[0] - 40) & (xs < ART[2] + 40) & (ys > ART[1] - 40) & (ys < ART[3] + 40)
    sample = inside & ~near_corner & ~art
    design = np.stack([np.ones(sample.sum()), xs[sample], ys[sample]], 1)
    return [np.linalg.lstsq(design, src[..., c][sample], rcond=None)[0] for c in range(3)]


BACKGROUND = fit_background()


def render(size, art_fraction):
    """The artwork centred on the extended cream, occupying `art_fraction` of the width."""
    scale = ART_W / (art_fraction * size)  # source pixels per output pixel
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float64)
    sx = ART_CX + (xs + 0.5 - size / 2) * scale
    sy = ART_CY + (ys + 0.5 - size / 2) * scale
    bg = np.stack([c[0] + c[1] * sx + c[2] * sy for c in BACKGROUND], -1)
    canvas = Image.fromarray(np.clip(bg, 0, 255).round().astype(np.uint8), 'RGB')

    # Paste the tile's interior, resized to this frame, through its feathered rounded mask.
    left, top, right, bottom = PASTE
    ox = (left - ART_CX) / scale + size / 2
    oy = (top - ART_CY) / scale + size / 2
    pw = round((right - left) / scale)
    ph = round((bottom - top) / scale)
    patch = Image.fromarray(src[top:bottom, left:right].astype(np.uint8), 'RGB').resize(
        (pw, ph), Image.LANCZOS)
    canvas.paste(patch, (round(ox), round(oy)), PASTE_MASK.resize((pw, ph), Image.LANCZOS))
    return canvas


def paste_mask():
    w, h = PASTE[2] - PASTE[0], PASTE[3] - PASTE[1]
    mask = Image.new('L', (w, h), 0)
    f = PASTE_FEATHER
    ImageDraw.Draw(mask).rounded_rectangle((f, f, w - f, h - f), radius=PASTE_RADIUS, fill=255)
    return mask.filter(ImageFilter.GaussianBlur(f / 2))


PASTE_MASK = paste_mask()


def rounded(img, radius_fraction=0.225):
    """The launcher/console tile: the icon on transparency with the platform's corner."""
    size = img.size[0]
    mask = Image.new('L', (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * 4 - 1, size * 4 - 1), radius=round(size * 4 * radius_fraction), fill=255)
    out = img.convert('RGBA')
    out.putalpha(mask.resize((size, size), Image.LANCZOS))
    return out


# Full-bleed master: the artwork at 76 % of the width reads at 29 pt and does not crowd iOS's
# own corner mask at 1024.
master = render(1024, 0.76)

# ------------------------------------------------------------------------------- iOS
ios = os.path.join(MOBILE, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
for image in json.load(open(os.path.join(ios, 'Contents.json')))['images']:
    points = float(image['size'].split('x')[0])
    px = round(points * int(image['scale'].rstrip('x')))
    # Opaque RGB: App Store Connect rejects an icon with an alpha channel.
    master.resize((px, px), Image.LANCZOS).save(os.path.join(ios, image['filename']))

# --------------------------------------------------------------------------- Android
densities = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
res = os.path.join(MOBILE, 'android', 'app', 'src', 'main', 'res')
legacy = rounded(master)
for name, px in densities.items():
    d = os.path.join(res, f'mipmap-{name}')
    legacy.resize((px, px), Image.LANCZOS).save(os.path.join(d, 'ic_launcher.png'))

# Adaptive (API 26+): 108 dp layers of which the launcher shows the middle 72 dp, and only
# the central 66 dp circle is guaranteed. At 58 % of the layer width the artwork's farthest
# point sits at 0.46 × its width from centre — inside that circle on every launcher shape.
adaptive_fg = render(432, 0.58)
adaptive_bg = render(432, 0.58)
# The background layer is the cream alone; the foreground carries the art on the same
# cream, so the two stay aligned under the launcher's parallax.
bg_only = np.stack(
    [np.full((432, 432), c[0] + c[1] * ART_CX + c[2] * ART_CY) for c in BACKGROUND], -1)
adaptive_bg = Image.fromarray(np.clip(bg_only, 0, 255).round().astype(np.uint8), 'RGB')
for name, px in densities.items():
    d = os.path.join(res, f'mipmap-{name}')
    s = round(px * 108 / 48)
    adaptive_fg.resize((s, s), Image.LANCZOS).save(os.path.join(d, 'ic_launcher_foreground.png'))
    adaptive_bg.resize((s, s), Image.LANCZOS).save(os.path.join(d, 'ic_launcher_background.png'))
anydpi = os.path.join(res, 'mipmap-anydpi-v26')
os.makedirs(anydpi, exist_ok=True)
with open(os.path.join(anydpi, 'ic_launcher.xml'), 'w') as f:
    f.write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n')

# ------------------------------------------------------------------ in-app logo (Flutter)
rounded(master.resize((512, 512), Image.LANCZOS)).save(
    os.path.join(MOBILE, 'assets', 'brand', 'logo.png'))

# ------------------------------------------------------------------- web console
public = os.path.join(REPO, 'apps', 'dashboard', 'public')
os.makedirs(public, exist_ok=True)
for px in (32, 192, 512):
    rounded(master.resize((px, px), Image.LANCZOS)).save(
        os.path.join(public, f'icon-{px}.png'))
# Safari's home-screen icon is masked by iOS like an app icon: opaque, full-bleed.
master.resize((180, 180), Image.LANCZOS).save(os.path.join(public, 'apple-touch-icon.png'))
favicon = rounded(master.resize((256, 256), Image.LANCZOS))
favicon.save(os.path.join(public, 'favicon.ico'), sizes=[(16, 16), (32, 32), (48, 48)])

# ------------------------------------------------------------------ store listings
store = os.path.join(REPO, 'docs', 'store')
os.makedirs(store, exist_ok=True)
# Google Play: 512 × 512, 32-bit PNG; Play applies its own corner radius and shadow.
master.resize((512, 512), Image.LANCZOS).save(os.path.join(store, 'play-icon-512.png'))
# App Store: 1024 × 1024, opaque, no corners — the same file Xcode already carries.
master.save(os.path.join(store, 'app-store-icon-1024.png'))


def feature_graphic():
    """Google Play's 1024 × 500 feature graphic: the icon and the name on the brand green."""
    w, h = 1024, 500
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
    t = ((xs / (w - 1)) + (ys / (h - 1))) / 2
    a, b = np.array([0x23, 0x80, 0x67]), np.array([0x15, 0x5A, 0x49])
    img = Image.fromarray((a + (b - a) * t[..., None]).round().astype(np.uint8), 'RGB')
    icon = rounded(master.resize((300, 300), Image.LANCZOS))
    img.paste(icon, (90, 100), icon)
    draw = ImageDraw.Draw(img)
    bold = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
    regular = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
    draw.text((440, 160), 'PharmaEt', font=ImageFont.truetype(bold, 84), fill='white')
    draw.text((444, 268), 'Pharmacy system for Ethiopia', font=ImageFont.truetype(regular, 34),
              fill=(0xEB, 0xB8, 0x4B))
    draw.text((444, 318), 'Sales · stock · cash-up — works offline', font=ImageFont.truetype(
        regular, 26), fill=(0xE7, 0xF0, 0xEC))
    img.save(os.path.join(store, 'play-feature-graphic-1024x500.png'))


feature_graphic()

master.save(os.path.join(REPO, 'docs', 'prototype', 'app-icon-1024.png'))
print('icons written')
