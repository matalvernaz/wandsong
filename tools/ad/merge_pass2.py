"""Merge second-pass descriptions with the first pass into the slot files build_descriptions.py
reads, in story order (key_lines.py aligns descriptions to the game's lines monotonically).

    python -I merge_pass2.py <work dir> <pass2 dir> <out desc dir> <out batches dir>

Second-pass files (<pass2 dir>/span<NN>_<k>.json) hold {"items": [{"line": <transcript index>,
"delay": seconds after that line ends, "text": "...", "replaces": "<first-pass text>"?}]}. Every
first-pass slot (desc2/batches2) is kept; a new item joins the slot triggered by the same
transcript line, else starts a new slot. An item with "replaces" swaps out that first-pass
description (a vaguer or wrong one); other items that mostly repeat a description already on
that line are dropped. An item with "removes" (and no text) deletes that first-pass description.
"""
import glob
import json
import os
import re
import sys

work, pass2, out_desc, out_batches = sys.argv[1:5]
tr = json.load(open(os.path.join(work, "transcript_timed.json" if os.path.exists(os.path.join(work, "transcript_timed.json")) else "transcript.json"), encoding="utf-8"))
speech = json.load(open(os.path.join(work, "speech.json")))


def line_index_before(t):
    """The transcript line that started last before t: slots.py's trigger rule."""
    best = None
    for i, x in enumerate(tr):
        if x["start"] <= t - 0.3:
            best = i
    return best


def words(s):
    return set(re.sub(r"[^\w\s]", " ", s.lower()).split())


def repeats(text, others):
    w = words(text)
    for o in others:
        ow = words(o)
        if w and ow and len(w & ow) / min(len(w), len(ow)) >= 0.6:
            return True
    return False


# Lines whose descriptions wait for the next scene to start (subtitles.lua CORRECTIONS, hold).
HOLD = {"I'm going to have to fight my way out of here."}
slots = {}          # transcript line index -> slot dict (first pass)
batches = {}        # transcript line index -> batch dict
for f in glob.glob(os.path.join(work, "batches2", "batch_*.json")):
    for b in json.load(open(f, encoding="utf-8")):
        li = line_index_before(b["t0"]) if b.get("after") else None
        if li is None:
            continue
        batches.setdefault(li, b)
by_slot_id = {}
for f in glob.glob(os.path.join(work, "desc2", "batch_*.json")):
    for s in json.load(open(f, encoding="utf-8")):
        by_slot_id[s["slot"]] = s
batch_list = []
for f in glob.glob(os.path.join(work, "batches2", "batch_*.json")):
    batch_list.extend(json.load(open(f, encoding="utf-8")))
for b in sorted(batch_list, key=lambda b: b["t0"]):
    li = line_index_before(b["t0"]) if b.get("after") else None
    s = by_slot_id.get(b["id"])
    if li is None or not s:
        continue
    items = [i for i in s.get("items", []) if (i.get("text") or "").strip()]
    # In game a delay counts from the end of its line; the first pass counted from the start of
    # the silence, which the voice detector often put later (it ran the next lines in): 24
    # descriptions played early, some by tens of seconds (Oct 8). Count from the line's end
    # instead, so they play when the frames showed them and the second pass's delays agree.
    # Held lines count from the next scene's start, and a silence inside a long transcript line
    # can only follow the whole line: both keep the first pass's timing.
    if li in slots:
        base = slots[li]["t0"]   # a second silence after the same line, timed from the first
    elif tr[li]["text"].strip() in HOLD or b["t0"] < tr[li]["end"]:
        base = b["t0"]
    else:
        base = tr[li]["end"]
    shift = b["t0"] - base
    items = [{"offset": round(float(i["offset"]) + shift, 1), "text": i["text"]} for i in items]
    if li in slots:
        slots[li]["items"].extend(items)
    else:
        slots[li] = {"after": tr[li]["text"], "items": items, "t0": base, "span": b.get("span")}

added, dropped, replaced, removed = 0, 0, 0, 0
for f in sorted(glob.glob(os.path.join(pass2, "span*_*.json"))):
    data = json.load(open(f, encoding="utf-8"))
    for it in data.get("items", []):
        li, text = it.get("line"), (it.get("text") or "").strip()
        gone = (it.get("removes") or "").strip()
        if gone and li is not None and li in slots:
            # A first-pass description that only repeats the dialogue or talks over a line.
            match = [i for i in slots[li]["items"] if i["text"].strip() == gone]
            if match:
                slots[li]["items"].remove(match[0])
                removed += 1
        if li is None or not text or li < 0 or li >= len(tr):
            continue
        delay = max(0.0, float(it.get("delay", 0.5)))
        slot = slots.get(li)
        if slot is None:
            end = tr[li]["end"]
            slot = {"after": tr[li]["text"], "items": [], "t0": end, "span": None}
            slots[li] = slot
            nxt = [s for s in speech if s[0] > end + 0.2]
            batches[li] = {"id": None, "t0": end, "t1": nxt[0][0] if nxt else end + 10,
                           "after": tr[li]["text"],
                           "context_before": [x["text"] for x in tr[max(0, li - 2):li + 1]]}
        old = (it.get("replaces") or "").strip()
        if old:
            match = [i for i in slot["items"] if i["text"].strip() == old]
            if match:
                slot["items"].remove(match[0])
                replaced += 1
        if repeats(text, [i["text"] for i in slot["items"]]):
            dropped += 1
            continue
        slot["items"].append({"offset": round(max(0.0, delay - 0.4), 1), "text": text})
        added += 1

order = sorted(slots, key=lambda li: slots[li]["t0"])
out_s, out_b = [], []
for new_id, li in enumerate(order):
    s, b = slots[li], batches[li]
    s["items"].sort(key=lambda i: i["offset"])
    out_s.append({"slot": new_id, "line": li, "after": s["after"], "items": s["items"],
                  "hold": tr[li]["text"].strip() in HOLD})
    bb = dict(b)
    bb["id"] = new_id
    bb.setdefault("context_before", [x["text"] for x in tr[max(0, li - 2):li + 1]])
    out_b.append(bb)
os.makedirs(out_desc, exist_ok=True)
os.makedirs(out_batches, exist_ok=True)
for old in glob.glob(os.path.join(out_desc, "batch_*.json")) + glob.glob(os.path.join(out_batches, "batch_*.json")):
    os.remove(old)
json.dump(out_s, open(os.path.join(out_desc, "batch_0.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
json.dump(out_b, open(os.path.join(out_batches, "batch_0.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print("%d slots, %d second-pass descriptions added (%d replacing first-pass ones), %d first-pass ones removed, %d dropped as repeats, "
      "%d descriptions in all" % (len(out_s), added, replaced, removed, dropped, sum(len(s["items"]) for s in out_s)))
