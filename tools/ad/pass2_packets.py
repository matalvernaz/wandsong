"""Packets for the second description pass: for each cutscene chunk, every spoken line with
the silence that follows it, the descriptions already written for it, and the frames
(extract_frames.py) covering the chunk, for a describer to add to.

    python -I pass2_packets.py <work dir> <frames dir> <out dir> [chunk seconds]

Reads transcript.json, speech.json, hud.json, desc2 + batches2 (the existing descriptions) and
<frames dir>/span<NN>_<seconds>.jpg. Writes <out>/span<NN>_<k>.json, one per chunk of at most
<chunk seconds> (default 90) of a cutscene.
"""
import glob
import json
import os
import re
import sys

work, frames_dir, out = sys.argv[1:4]
CHUNK = float(sys.argv[4]) if len(sys.argv) > 4 else 90.0

tr = json.load(open(os.path.join(work, "transcript.json"), encoding="utf-8"))
spans = json.load(open(os.path.join(work, "hud.json")))["cutscenes"]
speech = json.load(open(os.path.join(work, "speech.json")))

slot_t0 = {}
for f in glob.glob(os.path.join(work, "batches2", "batch_*.json")):
    for b in json.load(open(f, encoding="utf-8")):
        slot_t0[b["id"]] = b["t0"]
existing = []
for f in glob.glob(os.path.join(work, "desc2", "batch_*.json")):
    for s in json.load(open(f, encoding="utf-8")):
        if s["slot"] in slot_t0:
            for it in s.get("items", []):
                if (it.get("text") or "").strip():
                    existing.append((slot_t0[s["slot"]] + float(it["offset"]), it["text"].strip()))
existing.sort()

frames = {}
for p in glob.glob(os.path.join(frames_dir, "span*_*.jpg")):
    m = re.match(r"span(\d+)_(\d+\.\d)\.jpg$", os.path.basename(p))
    if m:
        frames.setdefault(int(m.group(1)), []).append((float(m.group(2)), os.path.abspath(p)))


def next_speech_start(after_t, limit):
    nxt = [s for s in speech if s[0] > after_t + 0.2]
    return nxt[0][0] if nxt else limit


os.makedirs(out, exist_ok=True)
n = 0
for si, (a, b) in enumerate(spans):
    fr = sorted(frames.get(si, []))
    if not fr:
        continue
    t, k = a, 0
    while t < b:
        t1 = min(b, t + CHUNK)
        lines = []
        for i, x in enumerate(tr):
            if x["start"] < t1 and x["end"] > t - 2:
                nxt = next_speech_start(x["end"], b)
                lines.append({
                    "index": i, "start": x["start"], "end": x["end"], "text": x["text"],
                    "silence_after": round(nxt - x["end"], 1),
                    "existing": [{"delay": round(e[0] - x["end"], 1), "text": e[1]}
                                 for e in existing if x["end"] - 0.5 <= e[0] < nxt],
                })
        packet = {
            "span": si, "chunk": k, "start": round(t, 1), "end": round(t1, 1),
            "previous_lines": [x["text"] for x in tr if x["end"] <= t][-3:],
            "lines": lines,
            "frames": [{"t": ft, "path": fp} for ft, fp in fr if t - 1 <= ft <= t1 + 1],
        }
        json.dump(packet, open(os.path.join(out, "span%02d_%d.json" % (si, k)), "w", encoding="utf-8"),
                  indent=1, ensure_ascii=False)
        n += 1
        t, k = t1, k + 1
print(n, "packets in", out)
