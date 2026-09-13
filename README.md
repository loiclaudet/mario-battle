# mario battle, in rive

the two player "Mario Bros." battle game hidden in Super Mario Bros. 3 (NES), rebuilt as a single `.riv` file
with the [Rive CLI](https://rive.app/docs/cli): RML markup for the stage, hud and every component, Luau scripts
for the simulation. every rule and physics number is transcribed from [the game's disassembly](https://github.com/captainsouthbird/smb3).

![gameplay](docs/gameplay.gif)

## play

```bash
rive login            # once
rive . --fit=contain  # opens the viewer, resize it to full screen
```

any jump or start press on the title starts a round. two players, gamepads first (first pad is mario, second
luigi, B jumps, Y runs, plus pauses), keyboard fills the empty slots: mario on `W A S D` + `G` jump + `F` run,
luigi on the arrows + `K` jump + `L` run. `F1` shows the collision boxes.

five enemies come out of the top pipes. bump the platform under one to flip it, touch it while it is on its
back to kick it off and take its coin. three coins win. touching a live enemy or a fireball ends the round.
the pow block in the middle flips everything on the ground, three times.

## how it is built

- `scene/game.rml` is the 256x240 artboard: stage strips cut from the original tiles, the coin hud, title,
  winner and pause overlays, and a state machine whose layers follow view model values
- `scene/components/` holds one component artboard per entity (Player, Spiny, FighterFly, Sidestepper, Pow,
  Fireball): frames in a `Solo`, one animation per pose, a small state machine driven by the entity's view model
- `scripts/` is the game: a fixed 60 step loop in `game.luau`, with `players`, `enemies`, `fireballs`, `world`,
  `physics` and `stage` modules and their unit tests (`rive . --test`)
- `docs/rules.md` has every constant with the label it came from in the disassembly, and the credits
- `AGENTS.md` has the verify / inspect / test / screenshot loop and the gotchas

the sim is deterministic integer physics in sixteenths of a pixel, exactly like the rom, so the jump takes 33
frames to its apex and reads 71 px, and the enemies walk at 0.375 px per frame until they get up faster.

## credits and status

a fan project, non commercial. Mario, the characters, sprites, sounds and music belong to Nintendo. the
sprite rips come from the Super Mario Wiki, mariouniverse.com (SamsterBoy) and the Spriters Resource
(Doc von Schmeltwick), the sounds from The Mushroom Kingdom, the rules and physics from the
[SMB3 disassembly](https://github.com/captainsouthbird/smb3) by southbird (http://www.sonicepoch.com/sm3mix/).
the font is Press Start 2P (OFL). the code in `scripts/`, `scene/` and `tools/` is MIT, see `LICENSE`; the
files under `assets/` and `tools/sheets/` are not covered by it.

built in a day with Claude Code, plan and process in the commit history.
