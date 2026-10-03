# Hogwarts Legacy class-name intel

Harvested from public sources — the SDK dump `Roadou/HogwartsLegacy-SDK` (game module
codename **Phoenix**) cross-checked against working UE4SS mods. These are the filters the
scanner (`mod/Wandsong/Scripts/scanner.lua`) uses; the first live run
confirms/corrects them via the mod's per-category `in-range=N` log lines and its
`unclassified:` dump.

Two naming rules for what `actor:GetClass():GetFName():ToString()` returns:
- Native C++ class: FName **without** the `A`/`U` prefix — `AContainer` → `"Container"`.
- Blueprint class: asset name **with** a `_C` suffix — `"BP_OL_Chest_C"`.
- `FindAllOf("Name")` matches that class **and all subclasses** → filter on BASE classes.

| Category | Filter class(es) | Notes |
|---|---|---|
| Player pawn | `Biped_Player` (or BP `BP_Biped_Player_C`) | mod-confirmed; `FindFirstOf` it |
| Player controller | `PhoenixPlayerController` | |
| Enemies (all hostiles) | `Enemy_Character` (+ `EnemyBroomRider`) | subclass-matches goblins/dark wizards/etc |
| Beasts | `Creature_Character` | |
| Chests/containers | `Container` (base) + `BP_OL_Chest_C`, `BP_HouseChest_C` (collection), `BP_Disillusionment_Chest_C` (eye chest) | |
| Collectibles | `FieldGuidePage`, `FlyingBook`, `CooldownPickup` | |
| Doors/locks | `Door`, `PadlockDoor` (Alohomora), `Lockable` | |
| Floo / fast travel | `Floo`, `BP_FastTravel_PillarPlaque_C` | mod-confirmed |
| Friendly NPCs | `NPC_Character` | enemies/beasts derive from this — claim them first, dedup |
| Interactables (broad) | `InteractiveObjectActor` (broadest), `SimpleInteractObject` | lowest priority so specific wins |
| Menus (UMG) | `PhoenixUserWidget` (base) → `Screen`, `TabPageWidget`, `SystemMenuWidget` | for menu-narration pass |
| HUD / subtitles | `PhoenixHUDWidget`, `UI_BP_Subtitle_HUD_C` | |

Inheritance worth knowing: `Enemy_Character` → `NPC_Character` → `Base_Character`;
`Container` → `WorldObject` → `InteractiveObjectActor`. That ordering is why the scanner
processes specific categories before broad ones and dedups each actor by address.

Gaps: individual enemy species (goblin vs spider) and NPC roles (professor vs student) are
Blueprint subclasses / data-driven, not distinct C++ classes — filter on the base and read
the instance name to disambiguate. Merlin trials have no single clean base; match
`InteractiveObjectActor`/`WorldObject` + name substring `Puzzle`/`Merlin`.

Sources: `Roadou/HogwartsLegacy-SDK` (`src/Phoenix_classes.h`, `src/Ambulatory_classes.h`,
per-Blueprint `src/*_classes.h`); [modding.wiki HL Lua examples](https://modding.wiki/en/hogwartslegacy/developers/luaexamples).
