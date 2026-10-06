# Mark which seconds of the footage show the gameplay HUD (green health bar, bottom right).
# Seconds without it, in runs of 4 s or more, are cutscenes. Usage: python -I hud.py <frames dir> <out.json>
import json, os, sys
from PIL import Image
d, out = sys.argv[1], sys.argv[2]
files = sorted(f for f in os.listdir(d) if f.endswith(".jpg"))
hud = []
for f in files:
    im = Image.open(os.path.join(d, f)).convert("RGB")
    w, h = im.size
    box = im.crop((int(w * 0.74), int(h * 0.93), int(w * 0.88), int(h * 0.99)))
    green = sum(1 for r, g, b in box.getdata() if g > 110 and g > r + 40 and g > b + 40)
    hud.append(green >= 4)
spans, start = [], None
for i, v in enumerate(hud + [True]):
    if not v and start is None: start = i
    if v and start is not None:
        if i - start >= 4: spans.append([start, i])   # frame i = second i (1 fps, from 0)
        start = None
json.dump({"hud": hud, "cutscenes": spans}, open(out, "w"))
print(len(hud), "seconds,", sum(hud), "with HUD;", len(spans), "cutscene spans,",
      sum(b - a for a, b in spans), "s of cutscene")
for a, b in spans[:40]: print(f"{a//60}:{a%60:02d}-{b//60}:{b%60:02d} ({b-a}s)")
