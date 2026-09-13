# mario battle: rules and numbers

everything below is read from the Super Mario Bros. 3 disassembly by southbird, bank `PRG/prg009.asm`
(https://github.com/captainsouthbird/smb3, credit link http://www.sonicepoch.com/sm3mix/). the battle mode
has its own movement code, separate from the main game, so published "smb3 physics" tables do not apply.
units: 60 frames per second, velocities in 1/16 px per frame (raw), positions in nes framebuffer pixels
(256x240, y down). positions integrate with two's complement fixed point (`Vs_ApplyYVel`), so a jump of
70.125 px reads 71 px at the apex.

## controls

| player | gamepad (first pad = p1, second = p2) | keyboard fallback |
|---|---|---|
| p1 mario | dpad or left stick, B jump, Y run, plus pause (nintendo layout) | A D move, G jump, F run, enter pause |
| p2 luigi | same on the second pad | arrows, K jump, L run, space pause |

any jump or start press on the title starts a round. start pauses. play with `rive . --fit=contain`.
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

x wraps at 256 (one byte in the rom). mario starts at x 64 facing right, luigi at 176 facing left.
the hud boxes sit at x 52 and 140, y 12; the five coin slots start at x 72 and 160, y 16, 8 px apart.

## player (`VsPlayer_Normal`)

| quantity | raw | px/frame |
|---|---|---|
| walk cap | 0x0C | 0.75 |
| run cap, B held | 0x18 | 1.5 |
| acceleration, deceleration, friction | 1 per frame | 0.0625 |
| jump | -0x42 | -4.125 (every reachable entry of `Vs_PlayerJumpHeightBySpd`) |
| gravity | +2 always, +3 more when falling or when A is not held | |
| terminal fall | 0x40 | 4.0 |

- full air control, no skid state (turning is acceleration the other way), jump only from the ground
- full jump: 33 frames to the apex, 71 px. tap: 14 frames, 30 px. `scripts/physics_test.luau` asserts both
- collision box x+4, y+2, 8x14. floor probes at (x+4, y+16) and (x+12, y+16) count when the body is within
  6 px of the tile top and not rising; the ceiling probe at (x+8, y) counts when the head is 9 px or more into
  the tile and rising. a ceiling hit bounces the 16x16 block above (`TILE18_BOUNCEDBLOCK` $C2, 14 frames, block
  sprite vy -0x20 then +5 per frame), zeroes vy, pins the player `|vy|/8 + 4` frames and snaps y to the block
  bottom minus 2. the bounced tile stays solid: the rom sets the under-hit bit only after the tile passed the
  solidity check, so nothing ever falls through a bouncing block and a head under it stops without bouncing it again
- stun (`Vs_PlayerDizzy`): 18 frames, vy -0x38, vx +/-0x08. from a bounced block under the feet, from the pow
  while grounded, or from being stomped. input is ignored while stunned
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
grounded player is stunned, the puncher included if they land in time. players can stand on it.

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

five coins exist, one per kicked enemy. the round ends when the two counts reach five (most coins wins, mario on
a tie, impossible here) or when a player dies. the result holds 128 frames (`Vs_TimeToExit`) then the title
returns with the next style.

## assets and credits

- sprites: "Battle MiniGame from SMB3" sheet ripped by SamsterBoy (mariouniverse.com), the "Battle Mode"
  backgrounds sheet ripped by Doc von Schmeltwick (spriters-resource.com), player poses and blue palettes from
  the Super Mario Wiki gallery for Mario Bros. (Super Mario Bros. 3). blue skins are palette swaps learned from
  the wiki pairs (`tools/slice_sprites.py`)
- sounds: The Mushroom Kingdom wav archive (themushroomkingdom.net), ask-first, credit link owed. the pow uses
  the thwomp sample, no rip of the real pow hit exists. no battle theme rip exists, only a midi, so no music
- font: Press Start 2P, SIL open font licence, `assets/fonts/OFL.txt`
- the rips are fine for a personal rive piece, not for a store listing, free or paid
