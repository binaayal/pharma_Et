#!/usr/bin/env python3
"""Renders the app icon from the prototype's mark (docs/prototype/index.html `.pin-logo`):
a gold ℞ on the brand's green gradient. Re-run after changing the mark; the outputs are
committed so a build never depends on this script."""
import json, os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(__file__), '..', 'apps', 'mobile')
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
GREEN_FROM, GREEN_TO, GOLD = (0x23, 0x80, 0x67), (0x15, 0x5A, 0x49), (0xEB, 0xB8, 0x4B)


def gradient(size):
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(GREEN_FROM, GREEN_TO))
    return img


def glyph(img, scale):
    size = img.size[0]
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT, round(size * scale))
    box = draw.textbbox((0, 0), '℞', font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    draw.text(((size - w) / 2 - box[0], (size - h) / 2 - box[1]), '℞', font=font, fill=GOLD)
    return img


master = glyph(gradient(1024), 0.62)

# iOS: full-bleed, opaque — iOS applies its own corner mask, and the store rejects alpha.
ios = os.path.join(ROOT, 'ios/Runner/Assets.xcassets/AppIcon.appiconset')
for image in json.load(open(os.path.join(ios, 'Contents.json')))['images']:
    points = float(image['size'].split('x')[0])
    scale = int(image['scale'].rstrip('x'))
    px = round(points * scale)
    master.resize((px, px), Image.LANCZOS).save(os.path.join(ios, image['filename']))

# Android legacy launcher icon: the rounded square of the prototype, on transparency.
mask = Image.new('L', (1024, 1024), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 1023, 1023), radius=230, fill=255)
rounded = master.convert('RGBA')
rounded.putalpha(mask)
densities = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
for name, px in densities.items():
    d = os.path.join(ROOT, f'android/app/src/main/res/mipmap-{name}')
    rounded.resize((px, px), Image.LANCZOS).save(os.path.join(d, 'ic_launcher.png'))

# Android adaptive icon (API 26+): the launcher masks it to its own shape, so the glyph sits
# in the central safe zone and the gradient fills the background layer.
fg = Image.new('RGBA', (432, 432), (0, 0, 0, 0))
glyph(fg, 0.40)
bg = gradient(432)
for name, px in densities.items():
    d = os.path.join(ROOT, f'android/app/src/main/res/mipmap-{name}')
    s = round(px * 108 / 48)
    fg.resize((s, s), Image.LANCZOS).save(os.path.join(d, 'ic_launcher_foreground.png'))
    bg.resize((s, s), Image.LANCZOS).save(os.path.join(d, 'ic_launcher_background.png'))
anydpi = os.path.join(ROOT, 'android/app/src/main/res/mipmap-anydpi-v26')
os.makedirs(anydpi, exist_ok=True)
open(os.path.join(anydpi, 'ic_launcher.xml'), 'w').write(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    '</adaptive-icon>\n')
master.save(os.path.join(ROOT, '..', '..', 'docs', 'prototype', 'app-icon-1024.png'))
print('icons written')
