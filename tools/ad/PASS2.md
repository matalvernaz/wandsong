# Second description pass: instructions for a describer

You are writing audio description (AD) for blind players of Hogwarts Legacy, spoken by the
Wandsong mod through the player's screen reader in the silences of each cutscene. The
first pass was too thin: many gaps got three words ("Fig turns.") or nothing. This pass makes
every scene followable, film-style. Read tools/ad/STYLE.md in the repo first; these rules add to it.

## Input

Packets: `C:\claudeProjects\wandsong-ad\work\pass2\packets\span<NN>_<k>.json`, one per
chunk (at most 90 s) of a cutscene from a playthrough recording. Each holds:

- `previous_lines`: dialogue just before the chunk.
- `lines`: every spoken line overlapping the chunk: `index` (transcript index, the key you write
  against), `start`/`end` (video seconds), `text` (speech-to-text, may misspell names),
  `silence_after` (seconds of silence after the line ends), `existing` (first-pass descriptions
  already spoken in that silence, with their delay after the line end).
- `frames`: pictures every 2 s (near-duplicates removed) with their time `t` in video seconds, on
  the same clock as the lines.

Look at every frame with the Read tool, in time order (several Read calls per message is fine),
so you know what is on screen during each line and each silence.

## What to write

Descriptions so a blind player follows the whole scene: who does what, gestures and faces, who
enters or leaves, objects handed over or picked up, where people are, and the setting whenever
it changes. Be specific and concrete ("Fig holds the engraved metal case up to the window and
turns it over in his hands", not "Fig looks at something"). Describe only what is visible; no
spoilers, no guessed motives.

- Most lines run straight into the next: `silence_after` is the real gap (it was overstated in
  the first packets, fixed Oct 8). Write only where it's 1.2 s or more.
- A line near a packet's edge appears in two packets. Describe only the stretch of its silence
  your frames cover; the neighbouring packet does the rest.
- The story's very first moments, before anyone speaks, are described by the mod itself (the
  golden sparks, the street, the carriage, Professor Fig): don't repeat them after line 0.
- Every description hangs off a line: `line` is that line's `index`; `delay` is seconds after
  the line ENDS when the description starts (0.4 minimum). It must finish before the next line
  starts: budget about 3 words per second of the time left (`silence_after` minus `delay`).
  A 2 s silence holds about 5 words ("Fig frowns at the case."). Skip silences under 1.2 s.
- Long silences: a description about every 4 to 5 seconds, each about what has happened since
  the previous one. Never repeat.
- Do not repeat `existing` descriptions. Add what they miss. Where an existing one is vague or
  wrong for what the frames show, write a better one and set `replaces` to the existing text
  exactly; it will be swapped out.
- The first time something important happens during a line (an action the words don't
  explain), describe it in the next silence: "Fig hands you a small green vial."
- The player is "you". Never describe your face, hair, skin, body, clothes or gender (each
  player made their own character). Your actions are fine: "You take the key."
- Name characters only once the dialogue has named them, with the names the game's subtitles
  use: Professor Fig (Eleazar Fig), George Osric, the Goblin Banker, Ranrok, Lodgok, the
  Carriage Driver, Professor Weasley (Matilda Weasley), Headmaster Black (Phineas Nigellus Black),
  Sebastian Sallow, Ominis Gaunt, Natsai Onai (Natty), Professor Ronen, Professor Hecat, Imelda
  Reyes, Leander Prewett, Samantha Dale, the Sorting Hat, Peeves. Use the full name and title
  ("Professor Fig") at the first mention in each scene and wherever the silence has room; the
  short form ("Fig") only where it's tight. Introduce each one briefly at their first
  appearance: build, clothes, one striking feature. Before they are named: "a goblin in a green
  waistcoat", "a dark-haired Slytherin girl". Fix speech-to-text spellings (Ranrok, Pensieve,
  Ronen, Wiggenweld).
- Replace any existing description that names someone wrongly or vaguely, or calls Professor
  Fig "Fig" where there is room for the full form (set `replaces`).
- Magical arrivals and departures are always described: golden sparks, apparating, Portkeys,
  Floo flames.
- Logos and title cards: describe what they look like (colours, shape, emblem), then the words.
  Replace any existing "The ... logo appears." with such a description.
- Present tense, active voice, plain words. Never "we see", "the camera", "shot", "frame".
  Mark a cut with "Now", "Later", "Outside", "Inside".
- Spells: what the spell looks like and who or what it hits. Fights: who attacks whom, who falls.
- Menus, maps, the Field Guide, inventory screens, button prompts, HUD text, subtitles and
  dialogue-choice lists are never described (the mod reads them). If a whole packet is such a
  screen, write no items and set `ui` to true.
- In gameplay stretches inside a packet (you control your character; a health bar shows bottom
  right), describe only story events, not your own movement. Never describe something the
  player does themselves in gameplay (drinking a potion, casting at a target, opening a door):
  the recording's player did it then, but a player using the mod may not have yet ("You raise
  the vial and drink" played before Matt had drunk it, Oct 8).
- When a line refers to something on screen ("Why would someone have built this here?",
  "What's that?"), make sure that thing was described in plain words just before, or describe
  it in the nearest silence before the line. Plain words: "the ruins of a castle on a tall rock
  in the sea", not "a sea stack" (Matt didn't know what "this" was, Oct 8).

## Output

For each packet, write `C:\claudeProjects\wandsong-ad\work\pass2\desc\<same file name>`
with the Write tool (UTF-8):

    {"span": 4, "chunk": 0, "ui": false,
     "items": [{"line": 212, "delay": 0.5, "text": "..."},
               {"line": 214, "delay": 0.4, "text": "...", "replaces": "Fig turns."}],
     "notes": ["anything a reviewer should know"]}

Items in time order. Reply at the end with one line per packet: file name, number of items,
and any note.
