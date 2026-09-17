# mario battle: rules and numbers

everything below is read from the Super Mario Bros. 3 disassembly by southbird, bank `PRG/prg009.asm`
(https://github.com/captainsouthbird/smb3, credit link http://www.sonicepoch.com/sm3mix/). the battle mode
has its own movement code, separate from the main game, so published "smb3 physics" tables do not apply.
units: 60 frames per second, velocities in 1/16 px per frame (raw), positions in nes framebuffer pixels
(256x240, y down). positions integrate with two's complement fixed point (`Vs_ApplyYVel`), so a jump of
70.125 px reads 71 px at the apex.

## controls

four input slots. the pads take the slots in the order they connect; the two keyboard sets fill the slots after
them (no pad: keyboard set 1 is slot 1 and set 2 is slot 2; one pad: it is slot 1, the sets are slots 2 and 3).
a slot with nothing behind it has no cursor.

| device | controls |
|---|---|
| a pad | dpad or left stick, B jump, Y run, plus start (nintendo layout) |
| keyboard set 1 | W A S D, G jump, F run, enter start |
| keyboard set 2 | arrows, K jump, L run, space start |

the title is a start menu in the smb3 style: a card per character in a 2x2 grid (mario and luigi above,
wario and waluigi below), START under them, one cursor per slot (the same dashed rect for all, in white, grey,
cyan and tan, none of the characters' colours with the dash pattern shifted 2 px per slot, each with its 1P..4P marker). left, right, up
and down move between the cards, down from the bottom row goes to START, up comes back. jump on a card locks that character (the marker stays on it and the
character hops), jump on your own card unlocks it, a card another player took refuses. the run button on a free
card turns it off and on again (OFF under the name: nobody plays it; CPU: the cpu does), with at least two cards
on; taking an off card turns it on. jump on START, or the start button anywhere, launches with every card that
is on: the locked ones for their players, the rest for the cpu (see the npc section), under the same rules as
you. start pauses a round with a human in it and ends a cpu only demo. after a round the menu returns with the
locks and the off cards kept and the cursors on START, so a jump replays. play with `rive . --fit=contain`.
`Input.PAD_LAYOUT` in `scripts/input.luau` is `nintendo` (jump on the east slot, run on the north slot, which is
B and Y on a switch pro controller); set it to `xbox` for south jump / west run. F1 toggles the collision box
overlay (`--data=debug=4` headless).

## arena (`PRG/levels/2PVs/Typical.asm`)

| element | x | y | size |
|---|---|---|---|
| top pipes | 0, 224 | 16 | 32x32, scenery |
| upper ledges | 0, 160 | 48 | 96x16 |
| centre platform | 64 | 96 | 128x16 |
| edge stubs | 0, 224 | 112 | 32x16 |
| lower ledges | 0, 160 | 160 | 96x16 |
| bottom pipes | 0, 224 | 176 | 32x32, scenery |
| floor | 0 | 208 | 256x32 |
| pow | 120 | 152 | 16 wide, box 15 / 12 / 10 tall after 0 / 1 / 2 hits (`Vs_POWHeight` 1, 4, 6), gone after 3 |

x wraps at 256 (one byte in the rom). mario starts at x 64 facing right, luigi at 176 facing left, wario at 8 and
waluigi at 232 on the lower ledges above the bottom pipes. the hud boxes sit at x 8, 68, 128 and 188, y 0
(60x17 each); the five coin slots start 16 px in, y 4, 8 px apart.

## stages (scene/stages, scripts/stage.luau)

the arena above is the `typical` stage. a stage is a component artboard in `scene/stages/<name>.rml` holding the
art, bound to its own `StageData` instance whose `map` is the geometry the simulation plays: 30 rows of 32 tiles
of 8 px, rows joined with `|`, `#` solid, `T` and `B` the top left tile of a 32x32 top and bottom pipe (scenery:
the top ones spawn, the bottom ones recycle), `P` the top left tile of the pow, `1`..`4` where each player's
16x16 body starts (facing right on the left half). `Stage.load` derives everything else: the collision grid,
the platforms, the spawn x, the pipe entrances and limits, the pow, the starts; nav rebuilds its rows (one per
platform top, the two halves of a ledge pair joined through the seam, lowest first) and their jumps, and the
cpu its waiting posts. the art is free, the map must match it: `--data=debug=4` (F1) tints every solid tile
over the art. with one stage the game plays it, with several a round picks one at random; `--data=stage=n`
forces one. to add a stage: add its rectangles to `STAGES` in `tools/gen_stages_rml.py` and run it (it writes
the rml and the view model instance from the same numbers), then in `scene/game.rml` give the `Stages` solo a
`NestedArtboard` bound to `9:200-9:25x`, the `Stage` layer a state, and the playfield a `stageN` input, with a
`stageN` property on `Game` pointing at the new instance. the second shipped stage, `steps`, has the centre
platform and the stubs two tiles lower; the cpu is tuned on `typical` and plays `steps` less well.

## player (`VsPlayer_Normal`)

| quantity | raw | px/frame |
|---|---|---|
| walk cap | 0x0C | 0.75 |
| run cap, B held | 0x18 | 1.5 |
| acceleration, deceleration, friction | 1 per frame | 0.0625 |
| turning against the motion | 2 per frame above walking speed, 1 at or below (`Physics.turnDecel`; lodz's tweak: the rom uses 1 at every speed, a flat 2 was too sharp). a full run stops in 18 frames, the rom takes 24 | 0.125 / 0.0625 |
| jump | -0x42 | -4.125 (every reachable entry of `Vs_PlayerJumpHeightBySpd`) |
| gravity | +2 always, +3 more when falling or when A is not held | |
| terminal fall | 0x40 | 4.0 |

- full air control, no skid state (turning is acceleration the other way), jump only from the ground
- a released pad only slows the player on the ground: the friction code (`PRG009_A5D1`) sits inside the landed
  branch, so the air speed is kept until a direction is pressed or the player lands
- full jump: 33 frames to the apex, 71 px. tap: 14 frames, 30 px. `scripts/physics_test.luau` asserts both
- collision box x+4, y+2, 8x14. floor probes at (x+4, y+16) and (x+12, y+16) count when the body is within
  6 px of the tile top and not rising; the ceiling probe at (x+8, y) counts when the head is 9 px or more into
  the tile and rising. a ceiling hit bounces the 16x16 block above (`TILE18_BOUNCEDBLOCK` $C2, 14 frames, block
  sprite vy -0x20 then +5 per frame), zeroes vy, pins the player `|vy|/8 + 4` frames and snaps y to the block
  bottom minus 2. the bounced tile stays solid: the rom sets the under-hit bit only after the tile passed the
  solidity check, so nothing ever falls through a bouncing block and a head under it stops without bouncing it again
- stun (`Vs_PlayerDizzy`): 18 frames, vy -0x38, vx +/-0x08. from a bounced block under the feet, from the pow
  while grounded, or from being stomped. the shipped rom NOPs out the control lockout (`PRG009_A4E4`), so the
  stun is the launch plus 18 frames of the dizzy sprite: steering and jumping keep working
- player on player, 8 frame cooldown: vertical gap 8 or more, the top one bounces at -0x30 unless rising and the
  grounded one is stunned; side by side, both shoved at +/-0x10 and turned apart
- touching a live enemy or a fireball kills instantly: everything halts, the victim pops up at -0x30 with +2 gravity
  and the round is over once they leave the screen. no lives
- walk frames: a counter adds `Vs_WalkCntRate[|vx| / 4]` = 0x10, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0 each
  frame and toggles the frame on overflow. poses: stand, walk, skid (pressing against the motion), jump, fall
  (walk frame in the air without a jump), stun, kick (12 frames), dead

## pow (`Vs_POWCollide`)

hit by rising into it from below: vy 0, y snapped under it, pinned 8 frames, hits++, 16 frames of shake
(`Vs_POWVertShakes` 0, 1, 4, 3 every 2 frames). while active every grounded enemy is hit as if bumped and every
grounded player is stunned, the puncher included if they land in time. players can stand on it: the floor snap is
`(y & ~7) + Vs_POWHeight[hits]`, so the feet sit at 152, 155 then 157 as the block flattens, and a head hit snaps
y to `152 + 17 - Vs_POWHeight[hits]`. the flattened sprites (10 and 6 rows) sit centred in the 16 px cell, which is
where those contact rows put them; the sheet had them bottom aligned.

## enemies (`Vs_SpawnEnemies`, `Vs_SpinyAndSidesteppers`, `Vs_FighterFly`, `Vs_ObjStateFlippedOver`)

- five per round, sets by style: spiny x5, fly x5, spiny/fly/spiny/fly/spiny, spiny/crab/spiny/crab/spiny,
  fly/crab/fly/crab/fly, crab x5. rounds cycle through the six
- one spawn every 256 frames (`Vs_SpawnCnt` wraps) from alternating top pipes at x 16 / 224, y 32, 48 frames
  emerging at +/-6. spawning pauses while a player is halted
- walking speed 6 (0.375 px/frame). each get-up promotes it: under 10 to 10, under 12 to 12, else 16
  (`Vs_ObjectGetUpXVel`). gravity +2 per frame for spiny and crab, +1 for the fly, terminal 0x40. y snaps to the
  16 px grid on landing
- hit from under (bounced block under a foot, or the pow), only while not rising and not in a pipe: a calm crab
  turns angry and gains a grade instead of flipping; anything else toggles normal / flipped and bounces at -0x20.
  hitting a flipped enemy rights it at the slowest speed. hit by a block from one side only, it drifts away at
  the pipe speed and gets its walk speed back on landing
- flipped: timer 255, decremented every other frame (510 frames), jitters when under 96. getting up applies
  the speed promotion. colour does not change in smb3
- the fourth coin flags the survivor (or the fifth when it spawns, at +/-0x10) as last: blue skin and a grade
- kick: touching a flipped enemy, kick sound, enemy flung at +/-0x20 away and -0x20 up, dying, one coin to the
  kicker at once. dying enemies slow 1 unit every other frame and vanish at y 224
- floor recycling: on the floor row an enemy entering x 208 walking right (32 walking left) goes into the bottom
  pipe for 96 frames and reappears from a random top pipe at y 32
- fighter fly: hops at -0x1C after resting 16 frames, only hittable on the ground
- enemies on the same floor that touch turn around and pause 16 frames (40 frame cooldown). player contact
  is tested on alternate frames per slot. box x+2, y+6, 12x4; box edges that touch count (`Vs_CheckBoxCollision`)
- inside a pipe the sprite is drawn 3 px higher and behind the pipe art (`SPR_BEHINDBG` in `Vs_ObjectDraw`)
- animation: a counter grows 1 per frame, +1 for the crab, +1 when angry or last, +1 in a pipe; the frame is
  `(counter / 8) % 2`. the fly counts 4 in the air and holds 8 on the ground

## fireballs (`Vs_Fireballs`)

- at the half cycle (`Vs_SpawnCnt` = 0x80) a second counter grows; every 8th one spawns a fireball, so about every
  2048 frames, the first near frame 1920. after 8192 frames (`Vs_TooLongCnt`) the game ender spawns
- spawn x 8 moving right or 232 moving left (side = counter / 2 & 1), y = a player's y, vx +/-0x10; vy accelerates
  +/-1 per frame between -0x10 and +0x10, a weave. burns out 32 frames after reaching the far edge, or when a
  bounced block is under it or the pow is active. the ender keeps +/-0x10 on both axes and reflects off platform
  sides, floors and ceilings
- fireballs never count for coins and kill on touch
- lodz's additions, not in the rom: a 32 frame sparkle plays at the screen edge before the flame enters, and the
  flame starts one sprite width off screen and is removed once fully past the far edge (the rom's 8 and 232
  leave an 8 px safe strip at each side)

## round

a free for all for up to four: five coins exist, one per kicked enemy, and two enemies kicked in the same
frame are two coins (the rom's counter only grows by one there, and the second kick in a frame is a case it never
meets). every coin won flies from where it was won to its hud slot with an ease in (30 frames) before its
fill lights. the round ends when one player has the most coins with the five out, or when one player is left
alive, or when one player is left who is not a target (a target cannot win, so the last other player standing
takes the round at once). a touch by a live enemy or a flame kills a player without coins, or with one other
player alive: he falls off the screen and the round goes on around the body, or ends when nobody else is left.
a dead player's hud goes out with him; a target's coins show in blue. holding coins
with two or more others alive he becomes **the target** instead, standing where he was and keeping his coins:
he wears the last enemy's blue (a 40 frame fade that does not stop play) and gets 275 frames of grace (the
theme's intro at 1.2x) in which he blinks and nothing but the blocks touches him, no enemy, flame or player,
and no sound plays. after it, any stun (a bumped block, the pow, a stomp) or a touch by an enemy or a flame
lays him on his side (a quarter turn) with no control until a hit from under his feet (a bumped block or the
pow) stands him up; a stomp on his head is the surest way. another player touching him on his side beats him:
the coins change hands (no kick sound and no death sound; they fly to the beater's hud one after the other)
and he falls off. with the five coins out and two players
sharing the top, the player with coins below them becomes the target the same way, and that is sudden death:
the theme starts over at 1.2x, a leader beating him takes his coins and wins, a player below beating him takes
the coins and becomes the target in turn, until someone stands alone at the top.
the result stays up, the winner's line over the arena and the huds as they ended, and after 128 frames
(`Vs_TimeToExit`) a MENU button appears: jump or start on any slot returns to the menu with the next style, the
locks and the off cards kept (a cpu only round returns on its own). two targets at once can happen (a tie's
target plus a player caught holding coins): each wears his initial over his head then, and whoever beats
either takes that one's coins. mario and luigi start on the floor at x 64 and 176, wario and waluigi on the lower ledges above the
bottom pipes at 8 and 232, every start facing the middle. `scripts/sim.luau` is the one round step: the game
plays it on its live state and the cpu on a clone, so the rules cannot drift between them.

## npc (scripts/npc.luau, scripts/nav.luau, scripts/sim.luau)

the rom has no cpu player, so this one is ours. it is a pure function of the game state that outputs the same
intent a pad would, every frame, and `Players.update` moves it under the exact physics above. deterministic, no
random numbers, so a lockstep multiplayer can run it on every peer.

- it looks ahead. `sim.luau` clones the whole battle (world, enemies, fireballs, players) and steps it with the
  same modules the game uses. every frame the brain runs its own policy 48 frames forward on the clone, the
  human kept on their current motion, the other cpu on its policy; if that stretch ends in its death, or every
  6 frames anyway, it also tries six plain moves (stand, run left, run right, jump, jump running left or
  right), each held 12 frames then the policy, and when doomed each held the whole way. the best stretch
  wins: a death is -10000, the other player's death +5000, a coin +200, a coin for them -100, an enemy
  flipped +40, one righted -80, a stun taken -60, one given +30, minus the trip left to the plan's spot,
  counted from where a jump in progress comes down. a chosen move is held while it still comes out alive,
  and a jump in progress is only second guessed when it ends in a death. cost is about 2 ms a frame per brain.
- it reads the other player where they will land, not where they float: a human mid jump towards a downed
  enemy counts as closer to it, which is what turns a kick plan into a deny in time. one standing still gets
  24 frames of reaction time added to their trip, one moving the other way 48: a trip not begun is longer
  than the map says, and a cpu that sat under a block for 130 frames because the human "could" get there
  first lost to a human who simply waited.

- `nav.luau` sees the arena as five rows: floor, lower ring (the two lower ledges join through the wrap), centre
  platform, the two stubs (a ring too), upper ring, all derived from the stage's platforms at load (one row per
  platform top, lowest first, a ledge pair joined through the seam). the jumps and drops between rows are found at load by running
  the real player once per row end, from a standstill and at full run, so every launch window and landing spot
  is what the game does; a route aims 2 px inside a window, and the last step to it is walked, not waited out
  (the walk stops within 2 px of its target, which once left the cpu a pixel short of a window for 120 frames).
  `Nav.bumpFrames` is measured the same way (the floor hits the lower ledge on frame 5).
  a body stands on a row when a foot probe is on it, so it can hang 12 px past an end, and `Nav.spotFor` finds
  the x that keeps the head in a block while a foot is on the row: that is how the centre platform's edge bumps
  the first block an enemy walking out of a pipe steps on, and the opening goes straight there.
- every frame, threats first: each live enemy is projected 36 frames ahead on its velocity, falling under
  gravity once its walk leaves its row, a resting fly also as if it hopped now; a fireball (sparkle included)
  56 frames ahead along its line with 16 px of weave. a predicted touch triggers a hop over it when the 40 px
  above the head are free over the next 24 px and it is close or coming, easing off when it walks away ahead,
  else an escape by the nearest jump or drop off the row that the threat cannot reach first, else a run the
  other way. a threat within 6 frames overrides even an escape in progress. it never leaps or drops onto a live
  enemy or into an occupied column, and thrown up by a stun it steers clear of what is coming.
- then the plan, rescored every 8 frames and on every landing. each target is worth its value minus a quarter
  of the travel frames, minus 40 per live enemy that will be near the spot, minus 70 for a kick the other
  player reaches first and 20 for a flip they would kick, plus 15 for the plan already in hand so a trip half
  made is not thrown away for a sliver: kick a flipped enemy that stays down long enough
  (100, +20 for the blue last one); flip a walker by bumping the block under its path from the row below (60,
  50 while it is still in the pipe), jumping as the walker steps onto the block with one foot, so the hit
  throws it back onto the block it just left, next to the cpu, where it is kicked or denied (hit on the way
  out it would land a block on, a gift to whoever waits there); a fly where
  it will land, as it rests or touches down; the pow when two or more live enemies are grounded (30 each); the
  trap (90, 80 while the human is still on their way): the human heading for a downed enemy, anywhere, when
  the cpu reaches the pow before they reach the enemy, so the pow rights it under their feet, punched as they
  close on it or as they are about to come down next to it (the pow is 8 frames from the floor);
  deny (85, 110 when the human is within 60 frames of it): a downed enemy on a ledge the human is closer
  to than we are, or simply near, so it sits under a block on their way to it and bumps it as their feet
  reach it, or as they land on it: the enemy's own block when it can be there in time (it rights the enemy
  into them, which beats kicking it), else the block they arrive on or cross, bounced as their centre is over
  the far half so the throw sends them back, never onto the enemy (a landing is only a guess, so it wants
  4 px of margin). no block in time means no deny, the kick is tried instead; a human who lingers within
  64 px of it, waiting for the cpu to leave, gets it righted at them once 90 frames of patience are out;
  bump the block under the human (30, 100 with a live enemy within 40 px of them); stomp the human while they
  are dizzy on the same row (25); otherwise wait at the safest post (either side of the pow on the floor, the
  middle of each ledge on the lowest row, or under the first block the next enemy steps on while nothing has
  spawned yet).
- the target: a blue cpu chases nothing any more. every replan it picks the spot the nearest rival needs
  longest to reach (the posts and three points on every row, its own trip and any live enemy near the spot
  counted against it) and goes there, and its look ahead counts every frame within 64 px of a rival against
  it, landing on its side as a loss. a blue rival is a coin purse: one on his side is walked into like a
  kick, one standing is stomped (100, +20 per coin he holds, the surest stun), bumped from under, or powed
  while grounded (70).
- the hunt: when no coin left can put it ahead (you have 3, or 2 to its 0 with... in short, the arithmetic says
  the coins are lost), it stops kicking and flipping altogether, since a coin only ends the round and a downed
  enemy is a harmless one. it goes for your death instead: bump the block under you (90, 140 with a live enemy
  near you), stomp you dizzy (60), the trap and the deny (95), the pow while you are grounded (40, +40 per
  downed enemy it rights, -20 per live one it would down), and otherwise shadows you on your row (20) for
  whatever shove, stomp or block the look ahead finds. the look ahead scores the same way: your stun +80, a
  righted enemy +40, a flipped one -40, its own coin -200.
- a press is one frame, then the button stays up two frames so the next press is fresh. a jump that started a
  move is held and steered until landing.

## assets and credits

- sprites: "Battle MiniGame from SMB3" sheet ripped by SamsterBoy (mariouniverse.com), the "Battle Mode"
  backgrounds sheet ripped by Doc von Schmeltwick (spriters-resource.com), player poses and blue palettes from
  the Super Mario Wiki gallery for Mario Bros. (Super Mario Bros. 3). blue skins are palette swaps learned from
  the wiki pairs (`tools/slice_sprites.py`)
- the faster theme for the target is the same cut at 1.2x (`tools/fast_music.py`, ffmpeg atempo); the blue
  takes of the four characters are palette swaps in the last enemy's blues (`tools/recolor_sprites.py`)
- sounds: The Mushroom Kingdom wav archive (themushroomkingdom.net), ask-first, credit link owed. the pow uses
  the thwomp sample, no rip of the real pow hit exists
- music: the super mario all-stars rendition of the smb3 enemy battle theme, 30 s transcode from the Super Mario
  Wiki (`tools/sheets/battle_theme.mp3`). `tools/cut_music.py` finds the repeat period on the rms envelope
  (12.684 s, eight bars at 151 bpm) and the intro end at the onset whose period repeats best (2.974 s), then
  writes `assets/music/battle_intro.flac` and `battle_loop.flac`. `scripts/sfx.luau` plays the intro once at
  round start and schedules the loop back to back on the audio engine clock, stopped at round end
- font: Press Start 2P, SIL open font licence, `assets/fonts/OFL.txt`
- the rips are fine for a personal rive piece, not for a store listing, free or paid
