"""Build the mod's descriptions.lua with every description keyed to the game's own line ID.

The descriptions hang off lines of a speech-to-text transcript of a recording. The game's
subtitles split and word the same speech differently ("Wait!" in the transcript is "Wait. We do
not know what -" in the game), so matching text in game missed whole scenes (the dragon attack,
Oct 6). This aligns the transcript with the game lines seen in play, word by word, and keys
each description to the game line its transcript line ends in.

    python -I build_keyed.py <work dir> <merged desc dir> <out descriptions.lua> [log ...]

Game lines come from the mod's logs ("[Wandsong subtitles] line <id> [voice] <s>s: text"),
one session per log file, kept in <work dir>/game_sessions.json so they survive log rotation
(the older game_lines.json joins as one session). Descriptions on transcript lines not yet seen
in game keep their transcript text for the mod's fallback text matching; play further and run
this again to key them.
"""
import difflib
import glob
import json
import os
import re
import sys

work, desc_dir, out = sys.argv[1:4]
logs = sys.argv[4:]

tr = json.load(open(os.path.join(work, "transcript_timed.json" if os.path.exists(os.path.join(work, "transcript_timed.json")) else "transcript.json"), encoding="utf-8"))


def words(text):
    text = text.lower().replace("’", "'").replace("‘", "'")
    return re.sub(r"[^\w\s']", " ", text).replace("'", "").split()


def game_text(raw):
    t = re.sub(r"^\s*<Name_Text>.*?</>\s*", "", raw)
    t = re.sub(r"<[^>]*>", "", t)
    t = t.replace("â€“", "-").replace("â€™", "'").replace("â€œ", '"').replace("â€\x9d", '"')
    t = re.sub(r"\([^)]*\)", " ", t)            # (chuckles), (effort sound)
    return re.sub(r"\s+", " ", t).strip()


# --- Game sessions ----------------------------------------------------------------------------
store = os.path.join(work, "game_sessions.json")
sessions = json.load(open(store, encoding="utf-8")) if os.path.exists(store) else []
known = {tuple(l["id"] for l in s) for s in sessions}
old = os.path.join(work, "game_lines.json")
LINE = re.compile(r"subtitles\] line (\S+) \[([^\]]*)\] [\d.]+s: (.*)$")
candidates = []
if os.path.exists(old):
    candidates.append([{"id": l["id"], "text": l["text"]} for l in json.load(open(old, encoding="utf-8"))])
for path in sorted(logs, key=os.path.getmtime):
    seq, last = [], None
    for raw in open(path, encoding="utf-8", errors="replace"):
        m = LINE.search(raw.rstrip())
        if not m or m.group(1) == "?":
            continue
        text = game_text(m.group(3))
        if not text or m.group(1) == last:
            continue
        last = m.group(1)
        seq.append({"id": m.group(1), "text": text})
    candidates.append(seq)
for seq in candidates:
    key = tuple(l["id"] for l in seq)
    if len(seq) >= 3 and key not in known:
        known.add(key)
        sessions.append(seq)
json.dump(sessions, open(store, "w", encoding="utf-8"), ensure_ascii=False, indent=0)

# --- Alignment ------------------------------------------------------------------------------
tw, t_of = [], []                      # transcript words and their line index
for i, x in enumerate(tr):
    for w in words(x["text"]):
        tw.append(w)
        t_of.append(i)

best = {}                              # transcript line -> (matched words, game id, game text)
for seq in sessions:
    gw, g_of = [], []
    for k, l in enumerate(seq):
        for w in words(l["text"]):
            gw.append(w)
            g_of.append(k)
    sm = difflib.SequenceMatcher(None, tw, gw, autojunk=False)
    hits = {}                          # transcript line -> list of game line indexes, in order
    for a, b, size in sm.get_matching_blocks():
        if size < 2 and len(gw) > 50:
            continue                   # lone common words ("the") are noise in a long session
        for d in range(size):
            hits.setdefault(t_of[a + d], []).append(g_of[b + d])
    for i, gs in hits.items():
        n = len(words(tr[i]["text"]))
        if len(gs) < max(1, (n + 1) // 2):
            continue
        g = gs[-1]
        if n <= 2:
            # A one- or two-word line ("Wait!") needs its neighbours to agree on the place.
            near = [hits.get(j, [None])[-1] for j in (i - 1, i + 1)]
            if not any(x is not None and abs(x - g) <= 3 for x in near):
                continue
        if i not in best or len(gs) > best[i][0]:
            best[i] = (len(gs), seq[g]["id"], seq[g]["text"])

# --- Descriptions ---------------------------------------------------------------------------
slots = []
for f in sorted(glob.glob(os.path.join(desc_dir, "batch_*.json"))):
    slots.extend(json.load(open(f, encoding="utf-8")))
slots.sort(key=lambda s: (s.get("line") if s.get("line") is not None else 10 ** 9, s["slot"]))

ANCHOR_SECONDS = 30.0


def anchor(li):
    """The game line to hang a description on, and seconds to add to its delays. A transcript
    line the game never says as such (speech-to-text heard words in a snore, or split a line
    differently) hangs off the last matched line before it, if that ended recently."""
    if li in best:
        return best[li][1], best[li][2], 0.0
    for j in range(li - 1, max(-1, li - 12), -1):
        if j in best:
            gap = tr[li]["end"] - tr[j]["end"]
            if 0 <= gap <= ANCHOR_SECONDS:
                return best[j][1], best[j][2], gap
            break
    return None, None, 0.0


entries, by_key = [], {}
n_anchored = 0
for s in slots:
    li = s.get("line")
    items = [i for i in s.get("items", []) if (i.get("text") or "").strip()]
    if li is None or not items:
        continue
    gid, gtext, shift = anchor(li)
    if gid and li not in best:
        n_anchored += 1
    key = ("id", gid) if gid else ("line", li)
    e = by_key.get(key)
    if not e:
        e = {"line": li, "id": gid, "after": gtext or tr[li]["text"],
             "prev": tr[li - 1]["text"] if li > 0 else None, "items": []}
        by_key[key] = e
        entries.append(e)
    for it in items:
        e["items"].append((round(float(it["offset"]) + 0.4 + shift, 1), it["text"].strip()))


def lua(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


lines = ["-- Audio descriptions for cutscenes, written from a playthrough recording (tools/ad, see",
         "-- README.md) and keyed to the game's subtitle line IDs by build_keyed.py. Each entry: the",
         "-- line it follows (id, else its text), then descriptions spoken that many seconds after it.",
         "return {"]
n_items = n_keyed = 0
for e in entries:
    e["items"].sort()
    head = "    { "
    if e["id"]:
        head += "id = %s, " % lua(e["id"])
        n_keyed += 1
    head += "after = %s, " % lua(e["after"])
    if not e["id"] and e["prev"] and len(words(e["after"])) < 4:
        head += "prev = %s, " % lua(e["prev"])
    lines.append(head + "items = {")
    for delay, text in e["items"]:
        lines.append("        { delay = %.1f, text = %s }," % (delay, lua(text)))
        n_items += 1
    lines.append("    } },")
lines.append("}")
open(out, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
print("%d game sessions, %d transcript lines matched to game lines" % (len(sessions), len(best)))
print("%d entries (%d keyed to a game line ID; %d slots hung off an earlier matched line), %d descriptions"
      % (len(entries), n_keyed, n_anchored, n_items))
