# Find the silences inside cutscenes that can hold a description, and pull frames for each.
# A slot is a gap of at least MIN_GAP seconds between spoken lines inside a cutscene span
# (from hud.py), plus the stretch before a cutscene's first line. Each slot records the line it
# follows (the in-game trigger), the line after it, and three frames.
# Usage: python -I slots.py <video> <transcript.json> <hud.json> <out dir> <speech.json>
import json, os, subprocess, sys

MIN_GAP = 1.2      # professional description uses even very short gaps ("Fig frowns.")
STEP = 5.0         # in a long silence, a description about every this many seconds
WIDTH = 480
video, tr_path, hud_path, out = sys.argv[1:5]
tr = json.load(open(tr_path, encoding="utf-8"))
spans = json.load(open(hud_path))["cutscenes"]
os.makedirs(out, exist_ok=True)

def grab(t, p):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", f"{t:.2f}", "-i", video,
                    "-frames:v", "1", "-vf", f"scale={WIDTH}:-1", "-q:v", "5", "-y", p], check=True)

def frames(t0, t1, tag):
    """Frames to describe: one just before the silence (what happened during the last line),
    then the middle of a short silence, or one about every STEP s in a long one (each becomes its
    own description, spoken at that point)."""
    if t1 - t0 < STEP + 1:
        times = [t0 + min(0.5, (t1 - t0) / 2)]
    else:
        times, t = [], t0 + 0.5
        while t < t1 - 1.5 and len(times) < 16:
            times.append(t)
            t += STEP
    before = os.path.join(out, f"{tag}_before.jpg")
    grab(max(0, t0 - 1.5), before)
    out_frames = []
    for k, t in enumerate(times):
        p = os.path.join(out, f"{tag}_{k}.jpg")
        grab(t, p)
        out_frames.append({"t": round(t, 2), "offset": round(t - t0, 2), "path": p})
    return {"before": before, "during": out_frames}

speech = json.load(open(sys.argv[5])) if len(sys.argv) > 5 else None

def line_before(t):
    """The transcript line that started last before time t (the in-game trigger)."""
    prev = [x for x in tr if x["start"] <= t - 0.3]
    return prev[-1]["text"] if prev else None

def line_after(t):
    nxt = [x for x in tr if x["start"] >= t - 0.5]
    return nxt[0]["text"] if nxt else None

slots = []
for si, (a, b) in enumerate(spans):
    # Silences inside the cutscene, from the speech map (real speech, not Whisper's run-together
    # timestamps): the stretches between speech regions.
    inside = [sp for sp in speech if sp[1] > a and sp[0] < b]
    edges = [a] + [x for sp in inside for x in (max(sp[0], a), min(sp[1], b))] + [b]
    for k in range(0, len(edges), 2):
        g0, g1 = edges[k], edges[k + 1]
        if g1 - g0 >= MIN_GAP:
            tag = f"slot{len(slots):04d}"
            slots.append({"id": len(slots), "span": si, "t0": round(g0, 2), "t1": round(g1, 2),
                          "after": line_before(g0), "next": line_after(g1),
                          **dict(zip(("before_frame", "frames"), (lambda f: (f["before"], f["during"]))(frames(g0, g1, tag))))})
json.dump(slots, open(os.path.join(out, "slots.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print(len(slots), "slots,", round(sum(x["t1"] - x["t0"] for x in slots)), "s of silence to describe")
