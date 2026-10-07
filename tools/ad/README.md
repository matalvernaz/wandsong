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
7. `python -I build_descriptions.py work/desc mod/Wandsong/Scripts/descriptions.lua`
   (first pass only; superseded by steps 8 to 11).

Second pass (Oct 7, denser and more detailed; instructions for describers in PASS2.md):

8. `python -I extract_frames.py footage/x.mp4 work/hud.json work/frames2` (a frame every 2 s).
9. `python -I pass2_packets.py work work/frames2 work/pass2/packets` (90 s chunks: lines,
   silences, existing descriptions, distinct frames), then describers write work/pass2/desc.
10. `python -I merge_pass2.py work work/pass2/desc work/merged/desc work/merged/batches`.
11. `python -I build_keyed.py work work/merged/desc mod/Wandsong/Scripts/descriptions.lua
    <Wandsong logs...>`: aligns the transcript with every game session's subtitle lines
    (kept in work/game_sessions.json) and keys each description to the game's line ID. Rerun
    it with new logs after playing further: each new scene keys more descriptions.

`python -I gaps.py work desc2 batches2` lists undescribed quiet inside cutscenes.

In game, the log shows every subtitle line ("line <id> [voice] <s>: <text>") and every
description fired ("description N (match 0.xx)"); a description that never fires means its
line was never keyed and its text differs too much: play the scene and rebuild (step 11).

First run (Oct 6): intro playthrough vJ74tpHXWyg (85 min), 36 cutscene spans, 129 silences.
