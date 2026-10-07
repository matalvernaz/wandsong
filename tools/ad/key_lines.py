# Key each description to the game's own subtitle line ID, so it fires on exactly that line.
#
# The descriptions' "after" text comes from a speech-to-text transcript of a recording, which
# differs from the game's subtitles ("Ranrock", "pensive"). Matching that loosely in game
# fired descriptions on the wrong lines and missed others. This aligns the descriptions (in
# story order) with the game's lines as logged in play (in story order) and writes
# id = "<subtitle id>" into each matched entry; subtitles.lua then matches those by ID.
#
# Game lines are collected from the logs into game_lines.json in the work folder, so they
# survive log rotation; run this after each play session that reached new scenes.
# Usage: python -I key_lines.py <descriptions.lua> <work dir> <log file>...
import json, os, re, sys

desc_path, work = sys.argv[1], sys.argv[2]
logs = sys.argv[3:]

# --- Game lines, in first-seen order --------------------------------------------------------
store = os.path.join(work, "game_lines.json")
known = json.load(open(store, encoding="utf-8")) if os.path.exists(store) else []
seen = {l["id"] for l in known}
LINE = re.compile(r"subtitles\] line (\S+) \[[^\]]*\] [\d.]+s: (.*)$")
for path in sorted(logs, key=os.path.getmtime):
    for raw in open(path, encoding="utf-8", errors="replace"):
        m = LINE.search(raw.rstrip())
        if not m or m.group(1) in seen or m.group(1) == "?":
            continue
        text = re.sub(r"^\s*<Name_Text>.*?</>\s*", "", m.group(2))
        text = re.sub(r"<[^>]*>", "", text).strip()
        if re.fullmatch(r"\(.*\)", text):
            continue   # sound-only lines never trigger descriptions
        seen.add(m.group(1))
        known.append({"id": m.group(1), "text": text})
os.makedirs(work, exist_ok=True)
json.dump(known, open(store, "w", encoding="utf-8"), ensure_ascii=False, indent=0)

# --- Descriptions -------------------------------------------------------------------------
src = open(desc_path, encoding="utf-8").read()
Q = r'"((?:[^"\\]|\\.)*)"'
HEAD = re.compile(r'^    \{ (?:id = ' + Q + r', )?after = ' + Q + r'(?:, prev = ' + Q + r')?, items = \{$', re.M)
entries = [(m.start(), m.end(), m.group(2), m.group(3)) for m in HEAD.finditer(src)]

def words(t): return set(re.sub(r"[^\w\s]", " ", t.lower().replace("’", "'")).split())
def sim(a, b):
    sa, sb = words(a), words(b)
    if not sa or not sb: return 0.0
    c = len(sa & sb); lo, hi = min(len(sa), len(sb)), max(len(sa), len(sb))
    return c / hi if lo < 6 else max(c / hi, c / lo if c / hi >= 0.3 else 0)

# Monotonic alignment maximising total similarity: descriptions and game lines both run in
# story order, which tells repeated short lines ("Wait.") apart.
n, m = len(entries), len(known)
MIN = 0.7
best = [[0.0] * (m + 1) for _ in range(n + 1)]
for i in range(n - 1, -1, -1):
    for j in range(m - 1, -1, -1):
        s = sim(entries[i][2], known[j]["text"])
        take = s + best[i + 1][j + 1] if s >= MIN else -1
        best[i][j] = max(best[i + 1][j], best[i][j + 1], take)
pairs, i, j = {}, 0, 0
while i < n and j < m:
    s = sim(entries[i][2], known[j]["text"])
    if s >= MIN and abs(best[i][j] - (s + best[i + 1][j + 1])) < 1e-9:
        pairs[i] = (known[j]["id"], s); i += 1; j += 1
    elif best[i][j] == best[i + 1][j]:
        i += 1
    else:
        j += 1

def lua_str(s): return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
out, last = [], 0
for k, (a, b, after, prev) in enumerate(entries):
    out.append(src[last:a])
    head = "    { "
    if k in pairs: head += "id = %s, " % lua_str(pairs[k][0])
    head += "after = %s, " % lua_str(after)
    if prev is not None: head += "prev = %s, " % lua_str(prev)
    out.append(head + "items = {")
    last = b
out.append(src[last:])
open(desc_path, "w", encoding="utf-8", newline="\n").write("".join(out))
print("%d game lines known, %d of %d descriptions keyed to a line ID" % (m, len(pairs), n))
for k in sorted(pairs):
    if pairs[k][1] < 0.85:
        print("  check: %r -> %s %r (%.2f)" % (entries[k][2], pairs[k][0],
              next(l["text"] for l in known if l["id"] == pairs[k][0]), pairs[k][1]))
