# Audio versions of the game's minigames: ideas from real audio games

Matt (Oct 8): look at actual audio games for concepts that could replace the inaccessible
minigames. Rule from earlier work: an equivalent audio puzzle, never the answer walked to or
marked. Timed ones: name it before it comes, one sound means now, never drown speech.

None of this is built. Each needs the game's own data probed first (positions, angles, states).
Ordered by when bob meets them in the story.

## Flying class and broom races: rings in the sky

- [Audio Rally Racing](https://inviocean.com/games-catalog/audio-rally-racing-en/): a co-driver
  warns of turns, obstacles and terrain ahead, and each track has its own soundscape.
  [AudioSpeed Racing](https://applevis.com/forum/macos-mac-apps/audiospeed-racing-now-available-mac-pc)
  does the same with a robot navigator.
- [A Blind Legend](https://www.pcgamer.com/uk/a-game-about-a-blind-knight-played-entirely-with-sound):
  you follow your daughter's footsteps, and she calls "Turn to the left!", "I'm straight
  ahead!", "You're close!".
- For us: the next ring as a 3D tone, named before it comes ("ring ahead, up and left"), its
  pitch closing in as you line up, a chime as you pass through, the one after it already
  sounding.

## Astronomy tables: lining the telescope up on a constellation

- The game: left stick points, right stick turns the lens, triggers zoom; the constellation
  flashes when the circles match it; guides say to match the big circle to the biggest star.
- [Stellar Sounds](https://2022.spaceappschallenge.org/challenges/2022-challenges/twinkle-twinkle-little-star/teams/sirius-team/project)
  (a NASA Space Apps concept): beeps on the left or right tell you which way to aim.
- [Audio Universe](https://www.openaccessgovernment.org/audio-universe/125688/): each star is a
  note, pitch from its colour, loudness from its brightness, place from where it is.
- For us: the constellation's stars as notes around the scope's centre, the biggest star
  loudest; turn and zoom until they sit together in the middle, and the chord resolves.

## Alohomora: lining up the lock's two rings

- The game: both sticks turn until inner and outer indicators line up; the circles shake
  slightly near the right spot.
- [Night Latch](https://thezaikman.itch.io/night-latch): three tumblers are three out-of-tune
  settings of one synthesizer; you turn each until it's right, in order.
- For us: each ring a tone, detuned by how far it is from its spot. Two near tones beat, and
  the beating slows as you close in (the game's shake, as sound); in tune means there.

## Merlin Trials

- Hitting things (nine balls on pillars, Confringo slabs, braziers): BSC Games'
  [Troopanum](https://we-make-money-not-art.com/blind_computer/), "You're listening for
  objects, and you're centering them", and a lock-on sound says when one is in range. For
  us: each target sounds, a lock-on tone when your aim is on it, silence once it's done;
  braziers tick down as they cool.
- Balls and the boulder into holes (Accio, Depulso):
  [Super Egg Hunt](https://www.afb.org/aw/21/3/16932): centre the beeping egg in stereo; eggs
  behind you beep lower. For us: the hole hums, the ball rolls audibly; centre the hole
  behind the ball, then push.
- Moths to the statues (Lumos): the follow mechanic turned round. The moths follow your
  light; the statue hums; bring the flutter to the hum.
- Flipping the symbol cubes (Flipendo): [Blind Flagflip](https://minotalen.itch.io/blind-flagflip):
  each piece has its own note, and a key plays a column as notes. For us: each symbol a
  note, a key plays the cube's face against the pedestal's.
- The jumping course: the mod's hop, climb and drop cues already cover it.

## Arithmancy doors

A sum, not a sight puzzle: read each creature's number and the dials aloud, any of them on
demand, like [Blindfold Sudoku](https://www.applevis.com/comment/37242) reads any cell, row or
column. No sound design needed.

## Daedalian keys, flying Field Guide pages, balloons

Super Egg Hunt's stereo centering plus A Blind Legend's guide: the key's jingle moves ahead
of you and calls out when you fall behind.

## Combat

- [AudioWizards](https://rawg.io/games/audiowizards): each element has its own sound, and you
  counter each enemy with the matching element. For us: each shield colour its own sound,
  matched to the spells that break it.
- A Blind Legend's blocks: the swing sounds while it's coming, and you block at the moment of
  impact. The mod's attack warnings already work this way; the hit and block sounds of
  combat.lua finish it.
