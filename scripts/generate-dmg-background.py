#!/usr/bin/env python3
"""Generate a DMG background image with a drag-to-Applications arrow."""

import sys
from PIL import Image, ImageDraw, ImageFont

# DMG window interior dimensions (must match create-dmg --window-size)
WIDTH = 600
HEIGHT = 400

# Icon center positions (must match create-dmg --icon / --app-drop-link)
APP_X = 150
APPS_X = 450
ICON_Y = 200

# Colors
BG_COLOR = (245, 245, 247)
ARROW_COLOR = (170, 170, 178)
TEXT_COLOR = (140, 140, 148)


def draw_arrow(draw, x_start, x_end, y_center):
    """Draw a horizontal arrow with a triangular head."""
    shaft_thickness = 3
    head_length = 16
    head_half_h = 10

    # Shaft
    draw.rectangle(
        [x_start, y_center - shaft_thickness // 2,
         x_end - head_length, y_center + shaft_thickness // 2],
        fill=ARROW_COLOR
    )

    # Arrowhead (triangle)
    draw.polygon([
        (x_end, y_center),
        (x_end - head_length, y_center - head_half_h),
        (x_end - head_length, y_center + head_half_h),
    ], fill=ARROW_COLOR)


def main():
    output_path = sys.argv[1] if len(sys.argv) > 1 else 'dmg-background.png'

    img = Image.new('RGB', (WIDTH, HEIGHT), BG_COLOR)
    draw = ImageDraw.Draw(img)

    # Arrow between icon positions
    arrow_margin = 68
    draw_arrow(draw, APP_X + arrow_margin, APPS_X - arrow_margin, ICON_Y)

    # "Drag to install" text below the arrow
    font_size = 13
    try:
        font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', font_size)
    except OSError:
        font = ImageFont.truetype('/System/Library/Fonts/SFNSText.ttf', font_size)

    text = "Drag to install"
    text_y = ICON_Y + 28
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_x = (WIDTH - text_w) // 2
    draw.text((text_x, text_y), text, fill=TEXT_COLOR, font=font)

    img.save(output_path, 'PNG')
    print(f"Generated DMG background: {output_path} ({WIDTH}x{HEIGHT})")


if __name__ == '__main__':
    main()
