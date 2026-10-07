"""Frames from the footage for every cutscene span: one every STEP seconds, WIDTH px wide.

    python -I extract_frames.py <video> <hud.json> <out dir> [step seconds] [width]

Writes span<NN>_<seconds>.jpg, the seconds being the time into the video (one decimal), so a
frame can be matched to the transcript and the speech map directly.
"""
import glob
import json
import os
import subprocess
import sys

video, hud_path, out = sys.argv[1:4]
step = float(sys.argv[4]) if len(sys.argv) > 4 else 2.0
width = int(sys.argv[5]) if len(sys.argv) > 5 else 640
spans = json.load(open(hud_path))["cutscenes"]
os.makedirs(out, exist_ok=True)
total = 0
for si, (a, b) in enumerate(spans):
    pattern = os.path.join(out, "tmp%02d_%%05d.jpg" % si)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", "%.2f" % a, "-t", "%.2f" % (b - a),
                    "-i", video, "-vf", "fps=1/%g,scale=%d:-1" % (step, width), "-q:v", "4", "-y", pattern],
                   check=True)
    made = sorted(glob.glob(os.path.join(out, "tmp%02d_*.jpg" % si)))
    for k, p in enumerate(made):
        t = a + k * step
        os.replace(p, os.path.join(out, "span%02d_%07.1f.jpg" % (si, t)))
    total += len(made)
    print("span %2d  %7.1f-%7.1f  %3d frames" % (si, a, b, len(made)), flush=True)
print(total, "frames")
