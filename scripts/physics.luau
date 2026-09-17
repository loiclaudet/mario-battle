--!strict
-- battle mode movement, transcribed from PRG/prg009.asm (VsPlayer_Normal and the object routines).
-- velocities are signed integers in 1/16 px per frame, exactly like the rom; positions are pixels
-- with a subpixel accumulator. every function is pure over a plain table so it can be unit tested.
local Physics = {}

-- player constants
Physics.WALK_MAX = 0x0C -- 0.75 px/frame
Physics.RUN_MAX = 0x18 -- 1.5 px/frame
Physics.ACCEL = 1
-- while pressing against the motion. lodz's tweak: the rom uses 1 at every speed (PRG009_A4EA); 2 alone stopped a
-- full run in 12 frames and felt too sharp, so the brake bites at 2 above walking speed and eases to the rom's 1
-- below it: 18 frames from a full run, between the two
Physics.TURN_DECEL_FAST = 2
Physics.TURN_DECEL = 1
Physics.JUMP_VY = -0x42 -- -4.125 px/frame, Vs_PlayerJumpHeightBySpd (every reachable entry)
Physics.GRAVITY = 2 -- always
Physics.GRAVITY_EXTRA = 3 -- when falling, or rising without A held
Physics.TERMINAL_VY = 0x40 -- 4.0 px/frame
Physics.STUN_FRAMES = 0x12 -- Vs_PlayerDizzy
Physics.STUN_VY = -0x38
Physics.STUN_VX = 0x08
Physics.STOMP_VY = -0x30
Physics.SHOVE_VX = 0x10
Physics.DEATH_VY = -0x30
Physics.DEATH_GRAVITY = 2

-- enemy constants
Physics.ENEMY_GRAVITY = 2 -- spiny and sidestepper (Vs_SpinyAndSidesteppers adds 2)
Physics.FLY_GRAVITY = 1 -- fighter fly and dying objects add 1
Physics.ENEMY_SPAWN_VX = 0x06
Physics.ENEMY_SPAWN_VX_FAST = 0x10
Physics.ENEMY_PIPE_VX = 0x06
Physics.ENEMY_GETUP_VX = { 0x0A, 0x0C, 0x10 } -- Vs_ObjectGetUpXVel, by previous speed
Physics.ENEMY_HIT_VY = -0x20
Physics.ENEMY_KICK_VX = 0x20
Physics.ENEMY_KICK_VY = -0x20
Physics.FLY_HOP_VY = -0x1C
Physics.FLY_REST_FRAMES = 0x10
Physics.GETUP_TIMER = 0xFF
Physics.GETUP_JITTER_BELOW = 0x60

-- fireball constants
Physics.FIREBALL_VX = 0x10
Physics.FIREBALL_VY_ACCEL = 1
Physics.FIREBALL_VY_LIMIT = 0x10

export type Body = {
    x: number, -- pixels
    y: number,
    subX: number, -- 0..15 subpixel accumulators
    subY: number,
    vx: number, -- sixteenths per frame
    vy: number,
}

function Physics.newBody(x: number, y: number): Body
    return { x = x, y = y, subX = 0, subY = 0, vx = 0, vy = 0 }
end

-- one axis of Vs_ApplyXVel / Vs_ApplyYVel: the low nibble accumulates, the high nibble moves.
-- returns the new position and accumulator.
function Physics.applyVel(pos: number, sub: number, vel: number): (number, number)
    local total = sub + vel
    local whole = total // 16
    return pos + whole, total - whole * 16
end

function Physics.applyX(b: Body)
    b.x, b.subX = Physics.applyVel(b.x, b.subX, b.vx)
end

function Physics.applyY(b: Body)
    b.y, b.subY = Physics.applyVel(b.y, b.subY, b.vy)
end

-- horizontal control. dir is -1, 0 or 1; run is the B button; grounded is the floor bit of the previous
-- frame's collision. with a direction held (PRG009_A4EA, on the ground and in the air alike) the speed
-- approaches the cap one unit per frame, TURN_DECEL units while it still points the other way. with no
-- direction (PRG009_A5D1) it decays one unit per frame, but that code sits inside the landed branch:
-- a released pad keeps the speed while airborne.
-- the brake against the motion at this speed
function Physics.turnDecel(vx: number): number
    return if math.abs(vx) > Physics.WALK_MAX then Physics.TURN_DECEL_FAST else Physics.TURN_DECEL
end

function Physics.stepPlayerX(b: Body, dir: number, run: boolean, grounded: boolean)
    if dir == 0 then
        if not grounded then
            return
        end
        if b.vx > 0 then
            b.vx -= Physics.ACCEL
        elseif b.vx < 0 then
            b.vx += Physics.ACCEL
        end
        return
    end
    local cap = if run then Physics.RUN_MAX else Physics.WALK_MAX
    if dir > 0 then
        if b.vx < 0 then
            b.vx += Physics.turnDecel(b.vx)
        elseif b.vx < cap then
            b.vx += Physics.ACCEL
        elseif b.vx > cap then
            b.vx -= Physics.ACCEL
        end
    else
        if b.vx > 0 then
            b.vx -= Physics.turnDecel(b.vx)
        elseif b.vx > -cap then
            b.vx -= Physics.ACCEL
        elseif b.vx < -cap then
            b.vx += Physics.ACCEL
        end
    end
end

-- vertical: gravity from PRG009_A650. +2 always, +3 more when moving down or when A is not held.
function Physics.stepPlayerGravity(b: Body, jumpHeld: boolean)
    if b.vy >= Physics.TERMINAL_VY then
        return
    end
    local g = Physics.GRAVITY
    if b.vy >= 0 or not jumpHeld then
        g += Physics.GRAVITY_EXTRA
    end
    b.vy = math.min(b.vy + g, Physics.TERMINAL_VY)
end

function Physics.jump(b: Body)
    b.vy = Physics.JUMP_VY
end

-- objects fall by a fixed amount per frame (2 for walkers, 1 for the fly and dying objects) to 0x40
function Physics.stepObjectGravity(b: Body, gravity: number)
    if b.vy < Physics.TERMINAL_VY then
        b.vy = math.min(b.vy + gravity, Physics.TERMINAL_VY)
    end
end

-- Vs_ObjectMoveFaster: the speed grade an enemy gets when it rights itself, by its previous |vx|
function Physics.fasterVx(vx: number): number
    local a = math.abs(vx)
    local grade = if a < 0x0A then 1 elseif a < 0x0C then 2 else 3
    local v = Physics.ENEMY_GETUP_VX[grade]
    return if vx < 0 then -v else v
end

-- the fireball weaves: vy accelerates toward the target sign and clamps at +/-0x10
function Physics.stepFireballY(b: Body, down: boolean)
    if down then
        b.vy = math.min(b.vy + Physics.FIREBALL_VY_ACCEL, Physics.FIREBALL_VY_LIMIT)
    else
        b.vy = math.max(b.vy - Physics.FIREBALL_VY_ACCEL, -Physics.FIREBALL_VY_LIMIT)
    end
end

-- stick-to-ceiling frames after a head bump: (|vy| / 8) + 4
function Physics.ceilingStickFrames(vy: number): number
    return math.abs(vy) // 8 + 4
end

return Physics
