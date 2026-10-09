# Access mod conventions (research, 2026-10-02)

Sources: project docs of several open-source game access mods; reviews of A Hero's Call and
Swamp; TLOU2 accessibility blog.

## Ideas to borrow
- **Buffers:** focus speaks a short label; Ctrl+Up/Down walks the focused
  item's buffer (name, cost, description); Ctrl+Left/Right switches buffers (item, player
  stats, quest, event log). F1 = help for current screen.
- **Speech grammar:** say everything a sighted player sees, no
  editorialising. Order: label, hotkey, stats, description. One utterance per action,
  periods between parts, re-announce context only when it changes. Flight recorder log.
- **Repeat last:** one key repeats last speech; double/triple tap goes
  further back.
- **Info keys:** help key per menu, an info key for the focused item, an
  alt-info key, a "what window is this" key; search in every menu.
- **Object tracker:** Ctrl+PgUp/PgDn category, PgUp/PgDn object, nearest
  first; Home = info, End = distance and direction, Ctrl+Home = auto-walk, Esc cancels.
  Favourites per area on Alt+1..0. Mute list for noisy names.
- **3D cues:** auto-speak crosshair target with state; target sound with
  volume = distance, pitch = height; fall detector before big drops; bow aim assist tones;
  F4 menu of every helper so unbound features stay reachable.
- **Radar (A Hero's Call / Swamp):** distinct sounds for wall, door, open space, object;
  three-step pitch rise as you near a wall, panned left/right; compass key; terrain
  footsteps; beacons on number keys.
- **Combat (other access mods; TLOU2):** optional combat mode; enemy clicks panned in 3D, pitch =
  health, filtered when above/below; aim assist nearest/strongest; room-cleared sound;
  spoken incoming-attack warnings (HL's "spidey sense" telegraph is ideal).
- **Keys:** never Insert/CapsLock; avoid numpad (NVDA desktop review). Use PgUp/PgDn/Home/End,
  brackets, Ctrl/Alt+letters, F-keys. All rebindable. A "vanilla mode" toggle. Document
  NVDA's "speech interrupt for typed characters" and suggest an NVDA profile for the game.
