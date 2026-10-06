# Where speech actually is in the footage (Silero VAD from faster-whisper), as [start, end]
# seconds. Usage: python -I speech_map.py <video> <out.json>
import json, subprocess, sys
import numpy as np
from faster_whisper.vad import get_speech_timestamps, VadOptions
video, out = sys.argv[1], sys.argv[2]
raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", video, "-ac", "1", "-ar", "16000",
                      "-f", "s16le", "-"], capture_output=True, check=True).stdout
audio = np.frombuffer(raw, np.int16).astype(np.float32) / 32768.0
ts = get_speech_timestamps(audio, VadOptions(min_silence_duration_ms=600, speech_pad_ms=150))
spans = [[round(t["start"] / 16000, 2), round(t["end"] / 16000, 2)] for t in ts]
json.dump(spans, open(out, "w"))
print(len(spans), "speech spans")
