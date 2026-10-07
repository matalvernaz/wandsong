# Roadmap (2026-10-06): following a reference access mod

Matt's direction (Oct 6): base Wandsong on a reference access mod for another game as much as possible. Its player's guide is the reference design: what it does, the keys it
uses and how it talks. This file maps each of its features onto Hogwarts Legacy, marks what we
have, and orders the rest. Deliberate differences are listed at the end with the reason.

Our own rules still hold: passive sounds while playing (zero-key world), keys for detail, every
instruction in the mod's terms, everything rebindable, no Insert/Caps Lock/numpad, and the crash
rules in CLAUDE.md.

## Keys: the reference mod's layout, adapted

The game ignores Ctrl and Shift on its own bindings (Left Ctrl = Dodge, Left Shift = Sprint),
and F1-F4 are its spell sets. So, like the reference mod, mod keys use Shift combos, Page/Home/End
and free F keys, never Ctrl in the world.

| Reference mod            | Wandsong              | Status |
| --- | --- | --- |
| Page Down / Up           | Page Down / Up               | done |
| Shift+Page Down / Up     | Shift+Page Down / Up         | done (was Ctrl) |
| Home: re-announce + turn | Home                         | done |
| Shift+Home: auto walk    | Shift+Home                   | done |
| Shift+Q: walk to quest   | Shift+grave (Q is Protego)   | done |
| Shift+F: follow someone  | autowalk follows a moving target; dedicated key to do (F is Interact) |
| Shift+End: teleport      | Shift+End                    | implemented, needs game check |
| End: subfilter           | key to choose; End is gauges | to do |
| U: interact from afar    | to choose (U is a game key)  | to do |
| F4: route beacons        | F5 (beacon on/off)           | partly: passive beacon exists |
| N / Shift+N: compass, where am I | Up arrow (facing, objective, quest) | partly |
| Comma: face nearest enemy| Comma                        | done |
| Period: gauges           | End: health and healing potions | implemented, HUD events need game check |
| F2 repeat                | F7                           | done |
| F3 message history       | to choose (Shift+F7 reads subtitles) | to do |
| F6 key glossary          | F6 (guide + every key)       | done |
| F1 menu shortcuts        | semicolon in menus           | done |

## Features, in order

1. Scanner (the heart of the mod)
   - done: categories, nearest first, own floor first, above/below, fresh positions, Home turns,
     Shift+Home walks, empty categories skipped, quest objective as its own category.
   - to do: particulars per entry (locked, empty, already looted); doors that say where they
     lead; group identical things ("Pot, 5 nearby"); quest items / clues category (things the
     quest marks); destructibles category (things Confringo/Basic Cast breaks); corpses/loot;
     subfilter (characters: all / quest givers / merchants), key to choose; larger radius (100 m) with a
     setting; real names for everything (no technical names).
2. Quests
   - done: up arrow reads the tracked quest and task (unconfirmed in game).
   - to do: announce new, completed and failed objectives automatically (objective watch is in,
     unconfirmed); the journal screen read as a list with track-this-quest; objective entry
     names the person when the target is a person.
3. Getting around
   - done: autowalk on the game's route, trail following, walking up to a standing guide,
     navmesh fallback (unconfirmed), held jumps when blocked, height-aware arrival, bounded
     stuck detection and failed/partial scanner paths. Shift+End teleport is implemented.
   - game verification first: broken steps after the first fight, stationary targets around
     obstacles, another-floor targets, partial navmesh paths and remapped movement/jump.
   - to do: specific obstacle reasons (locked door, something to break); open unlocked doors on
     the way; follow-a-character key; route beacons mode
     (rhythm = distance, pitch = height, a sound at each turn and on arrival).
4. Combat sounds (speak little, sound a lot)
   - implemented, needs game verification: block/dodge warning pitches and health below 50%
     and 20%, from HUD Blueprint events in feedback.lua. End reads health and potion count.
   - to do: hit confirmation; enemy killed; enemy radar (4 nearest within 20 m, already partly in
     the world layer); lock-on announced with the enemy's name and a sheet key; cutscene start
     and end sounds. First look at the game's own accessibility audio-cue events (gamecues.lua).
5. Information keys: gauges (health, ancient magic, potions), where am I (region, place,
   indoors), message history of notifications (XP, items, discoveries, tutorials).
6. Map: our own list of every pin, nearest first, categories, status filter, details, fast
   travel from the list, custom marker that becomes a scanner target.
7. Menus: name and shortcuts announced on opening; screens with parts (inventory, gear,
   talents, shop, quests) browsed the same way everywhere; item details after the name; real
   prices; tooltips and comparisons. Most screens already read through the review keys; this is
   about consistency and the parts model.
8. Settings inside the game: a mod settings screen (sounds each with a switch and volume, the
   scanner radius, read subtitles aloud, announce shortcuts on menu open), an audio glossary
   (sounds.lua, already in).
9. Subtitles read aloud (off by default), plus intro audio description. Replay/skip/load/pause
   handling is implemented and tested offline. Later-game descriptions and dialogue choices
   still need coverage.

## Deliberate differences from the reference mod

- Directions are relative to the camera ("ahead left") rather than compass points, because
  turning is by the arrow keys in 45-degree steps here and relative words match that. Compass
  words are available from the up arrow. Revisit if Matt prefers compass.
- Intro audio description uses screen-reader speech from a maintained description catalogue.
- Passive world sounds (people, items, walls, ledges) stay on by default: Matt's zero-key rule.
