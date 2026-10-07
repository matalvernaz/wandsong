# Turn the written descriptions (work/desc/batch_*.json) into the mod's descriptions.lua.
# Each slot becomes { after = "<line it follows>", items = { { delay = s, text = "..." }, ... } };
# the delay is the frame's offset into the silence plus a short pause, counted from the end of
# that line. Slots with no line before them (the very start of the video) can't be triggered and
# are left out.
# Usage: python -I build_descriptions.py <desc dir> <out descriptions.lua> [batches dir]
import glob, json, os, sys

desc_dir, out = sys.argv[1], sys.argv[2]
slots = []
for f in sorted(glob.glob(os.path.join(desc_dir, "batch_*.json")), key=lambda p: int(p.rsplit("_", 1)[1].split(".")[0])):
    slots.extend(json.load(open(f, encoding="utf-8")))
# The line before each trigger line, from the batches' context, so short trigger lines ("Ah.")
# can be told apart in game.
batch_dir = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(desc_dir)), "batches")
prev_of = {}
for f in glob.glob(os.path.join(batch_dir, "batch_*.json")):
    for b in json.load(open(f, encoding="utf-8")):
        ctx = b.get("context_before") or []
        if len(ctx) >= 2: prev_of[b["id"]] = ctx[-2]
slots.sort(key=lambda s: s["slot"])

def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'

seen, kept, n_items = set(), [], 0
lines = ["-- Audio descriptions for cutscenes, generated from a playthrough recording with the",
         "-- tools/ad pipeline (see tools/ad/README.md). Each entry: the subtitle line it follows,",
         "-- then descriptions spoken that many seconds after the line ends.",
         "return {"]
for s in slots:
    after = (s.get("after") or "").strip()
    items = [i for i in s.get("items", []) if (i.get("text") or "").strip()]
    key = after + "|" + str(prev_of.get(s["slot"]))
    if not after or not items or key in seen:
        continue
    seen.add(key)
    kept.append(s)
    prev = prev_of.get(s["slot"])
    if len(after.split()) < 4 and prev:
        lines.append("    { after = %s, prev = %s, items = {" % (lua_str(after), lua_str(prev)))
    else:
        lines.append("    { after = %s, items = {" % lua_str(after))
    for i in items:
        lines.append("        { delay = %.1f, text = %s }," % (float(i["offset"]) + 0.4, lua_str(i["text"].strip())))
        n_items += 1
    lines.append("    } },")
lines.append("}")
open(out, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
print(len(kept), "lines with descriptions,", n_items, "descriptions")
