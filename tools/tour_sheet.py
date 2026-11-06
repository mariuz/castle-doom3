"""Contact sheets of tools/tour_maps.ps1's screenshots: one image per map
(<map>_sheet.jpg in the tour's directory), the shots in order, numbered,
4 a row, each 400 x 225.

    python tools/tour_sheet.py [tour_output]
"""
import glob
import os
import re
import sys

from PIL import Image, ImageDraw

out_dir = sys.argv[1] if len(sys.argv) > 1 else 'tour_output'
W, H, COLS = 400, 225, 4
for log in sorted(glob.glob(os.path.join(out_dir, '*.log'))):
    name = os.path.splitext(os.path.basename(log))[0]
    shots = glob.glob(os.path.join(out_dir, name + '_*.png'))
    shots = sorted(shots, key=lambda p: int(re.search(r'_(\d+)\.png$', p).group(1)))
    if not shots:
        continue
    rows = (len(shots) + COLS - 1) // COLS
    sheet = Image.new('RGB', (W * COLS, H * rows))
    draw = ImageDraw.Draw(sheet)
    for i, shot in enumerate(shots):
        im = Image.open(shot).convert('RGB').resize((W, H))
        x, y = (i % COLS) * W, (i // COLS) * H
        sheet.paste(im, (x, y))
        draw.rectangle([x, y, x + 26, y + 16], fill=(0, 0, 0))
        draw.text((x + 3, y + 2), str(i + 1), fill=(255, 255, 0))
    sheet.save(os.path.join(out_dir, name + '_sheet.jpg'), quality=85)
    print(name, len(shots))
