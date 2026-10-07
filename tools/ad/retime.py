"""Re-time the transcript's lines from word timestamps (word_times.py).

Keeps transcript.json's lines and their order (descriptions refer to them by index) and gives
each line the start of its first spoken word and the end of its last, found by aligning the
two word sequences. Lines with no matched words sit between their neighbours.

    python -I retime.py <transcript.json> <words.json> <out transcript_timed.json>
"""
import difflib
import json
import re
import sys

tr = json.load(open(sys.argv[1], encoding="utf-8"))
timed = json.load(open(sys.argv[2], encoding="utf-8"))


def norm(w):
    return re.sub(r"[^\w]", "", w.lower().replace("’", "'").replace("'", ""))


tw, t_of = [], []
for i, x in enumerate(tr):
    for w in x["text"].split():
        n = norm(w)
        if n:
            tw.append(n)
            t_of.append(i)
ww = [norm(w[2]) for w in timed]
sm = difflib.SequenceMatcher(None, tw, ww, autojunk=False)
spans = {}
for a, b, size in sm.get_matching_blocks():
    for d in range(size):
        i = t_of[a + d]
        s, e = timed[b + d][0], timed[b + d][1]
        lo, hi = spans.get(i, (s, e))
        spans[i] = (min(lo, s), max(hi, e))

out, matched = [], 0
for i, x in enumerate(tr):
    y = dict(x)
    y["orig_start"], y["orig_end"] = x["start"], x["end"]
    if i in spans:
        y["start"], y["end"] = spans[i]
        matched += 1
    out.append(y)
# Unmatched lines: between the neighbours that were matched, in their original order.
for i, y in enumerate(out):
    if i in spans:
        continue
    prev_end = max([out[j]["end"] for j in range(i) if j in spans] or [y["orig_start"]])
    nxt = [out[j]["start"] for j in range(i + 1, len(out)) if j in spans]
    next_start = nxt[0] if nxt else y["orig_end"]
    y["start"] = max(prev_end, min(y["orig_start"], next_start))
    y["end"] = max(y["start"], min(y["orig_end"], next_start))
json.dump(out, open(sys.argv[3], "w", encoding="utf-8"), indent=1, ensure_ascii=False)
moved = sum(1 for y in out if abs(y["end"] - y["orig_end"]) > 2)
print("%d of %d lines timed from words; %d line ends moved by more than 2 s" % (matched, len(out), moved))
