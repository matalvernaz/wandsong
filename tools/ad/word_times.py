"""Word-level timestamps for the footage, to re-time the transcript's lines (retime.py).

The transcript's segment times run together (Whisper stretched "Just a moment." over 31 s of
a scene), which put descriptions under the wrong line. Word timestamps are far tighter. A small
model is enough here (only the timing is used) and leaves the GPU to a running game.

    python -I word_times.py <video> <out words.json> [model]
"""
import json
import os
import site
import subprocess
import sys

for sp in site.getsitepackages():
    for sub in ("cublas", "cudnn"):
        d = os.path.join(sp, "nvidia", sub, "bin")
        if os.path.isdir(d):
            os.add_dll_directory(d)
            os.environ["PATH"] = d + os.pathsep + os.environ["PATH"]
import numpy as np
from faster_whisper import WhisperModel

video, out = sys.argv[1], sys.argv[2]
name = sys.argv[3] if len(sys.argv) > 3 else "small.en"
raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", video, "-ac", "1", "-ar", "16000",
                      "-f", "s16le", "-"], capture_output=True, check=True).stdout
audio = np.frombuffer(raw, np.int16).astype(np.float32) / 32768.0
print("audio", round(len(audio) / 16000), "s", flush=True)
model = WhisperModel(name, device="cuda", compute_type="int8_float16")
segments, _ = model.transcribe(audio, language="en", vad_filter=True, word_timestamps=True)
words = []
for s in segments:
    for w in s.words or []:
        words.append([round(w.start, 2), round(w.end, 2), w.word.strip()])
    if len(words) and len(words) % 500 < len(s.words or []):
        print(len(words), "words, at", round(s.end), "s", flush=True)
json.dump(words, open(out, "w", encoding="utf-8"), ensure_ascii=False)
print("done", len(words), "words")
