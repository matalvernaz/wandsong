# Audio description pipeline

Pre-generates cutscene descriptions from a playthrough recording, so nobody has to replay a
scene. The mod (subtitles.lua) speaks each description right after the subtitle line it follows.

Work folder (outside the repo, not committed): C:\claudeProjects\wandsong-ad, with
footage\ (downloaded video) and work\ (frames, transcripts, batches, descriptions).

Needs: yt-dlp, ffmpeg, Python with faster-whisper (CUDA), numpy, pillow.

1. Footage: a no-commentary playthrough at 720p, for example
   `yt-dlp -f "bv*[height<=720]+ba/b[height<=720]" --merge-output-format mp4 -o "footage/x.mp4" <url>`
   (update yt-dlp first if YouTube answers 403).
2. Transcript: `python -I transcribe.py footage/x.mp4 work/transcript.json` (Whisper large-v3,
   ffmpeg decodes the audio; its timestamps run together, so silences come from step 4).
3. Cutscenes: one small frame per second, `ffmpeg -i footage/x.mp4 -vf "fps=1,scale=320:-1"
   -q:v 5 work/sec/s_%05d.jpg`, then `python -I hud.py work/sec work/hud.json`: seconds without
   the green health bar (bottom right) in runs of 4 s or more are cutscenes.
4. Speech: `python -I speech_map.py footage/x.mp4 work/speech.json` (Silero VAD).
5. Slots: `python -I slots.py footage/x.mp4 work/transcript.json work/hud.json work/slots
   work/speech.json`: every silence of 3 s or more inside a cutscene, the line before it, and a
   frame (one every 8 s in long silences).
6. Split work/slots/slots.json into batches with context_before (the five lines before) and have
   Claude (subagents) look at each frame and write descriptions into work/desc/batch_N.json:
   short (about 2.5 words a second, at most 25 words), present tense, no spoilers, the player is
   "you", characters named only when the dialogue makes them clear.
7. `python -I build_descriptions.py work/desc mod/Wandsong/Scripts/descriptions.lua`.

In game, the log shows every subtitle line ("line <id> [voice] <s>: <text>") and every
description fired ("description N (match 0.xx)"); a description that never fires means its
"after" text differs too much from the game's line: fix the after text from the log.

First run (Oct 6): intro playthrough vJ74tpHXWyg (85 min), 36 cutscene spans, 129 silences.
