"""Where the audio description is thin: silent stretches in cutscenes with no description.

Reads the work folder's transcript, speech map, cutscene spans and the written descriptions
(desc dir + batches dir for slot times) and lists, per cutscene, every run of QUIET seconds or
more in which nobody speaks and no description is spoken (a description is taken to last
2.5 words a second). Also prints a one-line density summary per cutscene.

    python -I gaps.py <work dir> [desc dir name] [batches dir name] [quiet seconds]
"""
import glob
import json
import os
import sys

work = sys.argv[1]
desc_dir = os.path.join(work, sys.argv[2] if len(sys.argv) > 2 else "desc2")
batch_dir = os.path.join(work, sys.argv[3] if len(sys.argv) > 3 else "batches2")
QUIET = float(sys.argv[4]) if len(sys.argv) > 4 else 4.0

tr = json.load(open(os.path.join(work, "transcript_timed.json" if os.path.exists(os.path.join(work, "transcript_timed.json")) else "transcript.json"), encoding="utf-8"))
spans = json.load(open(os.path.join(work, "hud.json")))["cutscenes"]
speech = json.load(open(os.path.join(work, "speech.json")))

slot_t0 = {}
for f in glob.glob(os.path.join(batch_dir, "batch_*.json")):
    for b in json.load(open(f, encoding="utf-8")):
        slot_t0[b["id"]] = b["t0"]
events = []
for f in glob.glob(os.path.join(desc_dir, "batch_*.json")):
    for s in json.load(open(f, encoding="utf-8")):
        if s["slot"] not in slot_t0:
            continue
        for it in s.get("items", []):
            text = (it.get("text") or "").strip()
            if text:
                start = slot_t0[s["slot"]] + float(it["offset"])
                events.append((start, start + max(1.0, len(text.split()) / 2.5), text))
events.sort()


def line_before(t):
    prev = [x for x in tr if x["start"] <= t]
    return prev[-1]["text"] if prev else "(start)"


def hms(t):
    return "%d:%02d" % (t // 60, t % 60)


total_quiet = 0.0
for si, (a, b) in enumerate(spans):
    step = 0.5
    n = int((b - a) / step)
    covered = [False] * (n + 1)
    for s0, s1 in speech:
        for i in range(n + 1):
            x = a + i * step
            if s0 <= x <= s1:
                covered[i] = True
    for e0, e1, _ in events:
        for i in range(n + 1):
            x = a + i * step
            if e0 <= x <= e1:
                covered[i] = True
    runs, start = [], None
    for i in range(n + 1):
        if not covered[i] and start is None:
            start = i
        if (covered[i] or i == n) and start is not None:
            length = (i - start) * step
            if length >= QUIET:
                runs.append((a + start * step, length))
            start = None
    described = [e for e in events if a <= e[0] <= b]
    words = sum(len(e[2].split()) for e in described)
    quiet = sum(l for _, l in runs)
    total_quiet += quiet
    print("cutscene %2d  %s-%s  %4.0f s  %3d descriptions, %4d words, %5.1f s of undescribed quiet"
          % (si, hms(a), hms(b), b - a, len(described), words, quiet))
    for t0, length in runs:
        print("    quiet %5.1f s at %s  after: %s" % (length, hms(t0), line_before(t0)[:70]))
print("total undescribed quiet inside cutscenes: %.0f s" % total_quiet)
