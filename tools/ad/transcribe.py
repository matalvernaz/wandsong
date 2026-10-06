# Transcribe a video's dialogue with timestamps (faster-whisper on the GPU).
# Usage: python -I transcribe.py <video> <out.json>
import json, sys, os, site
# The CUDA libraries pip installed live in nvidia/*/bin: put them on the DLL path.
for sp in site.getsitepackages():
    for sub in ("cublas", "cudnn"):
        d = os.path.join(sp, "nvidia", sub, "bin")
        if os.path.isdir(d):
            os.add_dll_directory(d)
            os.environ["PATH"] = d + os.pathsep + os.environ["PATH"]
import subprocess
import numpy as np
from faster_whisper import WhisperModel
video, out = sys.argv[1], sys.argv[2]
# Decode with ffmpeg ourselves (16 kHz mono): faster-whisper's own decoder clashes with the
# installed PyAV.
raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", video, "-ac", "1", "-ar", "16000",
                      "-f", "s16le", "-"], capture_output=True, check=True).stdout
audio = np.frombuffer(raw, np.int16).astype(np.float32) / 32768.0
print("audio", round(len(audio) / 16000), "s", flush=True)
model = WhisperModel("large-v3", device="cuda", compute_type="float16")
segments, info = model.transcribe(audio, language="en", vad_filter=True, word_timestamps=False)
rows = []
for s in segments:
    rows.append({"start": round(s.start, 2), "end": round(s.end, 2), "text": s.text.strip()})
    if len(rows) % 50 == 0:
        print(len(rows), "segments, at", round(s.end), "s", flush=True)
json.dump(rows, open(out, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print("done", len(rows), "segments")
