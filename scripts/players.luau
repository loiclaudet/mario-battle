--!strict
-- VsPlayer_Normal, VsPlayer_Dying and VsPlayer_BumpEachother from PRG/prg009.asm.
local Stage = require('scripts/stage')
local Physics = require('scripts/physics')
local World = require('scripts/world')
local Input = require('scripts/input')

local Players = {}

Players.STATE_NORMAL = 1
Players.STATE_DYING = 2
Players.WALK_RATE = { 0x10, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0 } -- Vs_WalkCntRate by |vx| / 4
Players.KICK_FRAMES = 0x0C
Players.BUMP_COOLDOWN = 8

export type Pose = 'stand' | 'walk' | 'skid' | 'jump' | 'fall' | 'stun' | 'kick' | 'dead'

export type Player = {
    index: number, -- 1 mario, 2 luigi
    body: Physics.Body,
    dir: number, -- facing, 1 right or -1 left
    state: number,
    onGround: boolean,
    jumped: boolean,
    dizzy: number,
    kick: number,
    stick: number,
    halt: number,
    walkCnt: number,
    walkFrame: number,
    pose: Pose,
    prevJump: boolean,
}

export type Events = { jump: boolean, bump: boolean, stun: boolean, pow: boolean, kick: boolean }

function Players.new(index: number): Player
    local p: Player = {
        index = index,
        body = Physics.newBody(Stage.PLAYER_START_X[index], Stage.FLOOR_TOP - 16),
        dir = if index == 1 then 1 else -1,
        state = Players.STATE_NORMAL,
        onGround = true,
        jumped = false,
        dizzy = 0,
        kick = 0,
        stick = 0,
        halt = 0,
        walkCnt = 0,
        walkFrame = 0,
        pose = 'stand',
        prevJump = true, -- the press that started the round must not also jump
    }
    return p
end

function Players.reset(p: Player)
    local fresh = Players.new(p.index)
    p.body = fresh.body
    p.dir = fresh.dir
    p.state = fresh.state
    p.onGround = fresh.onGround
    p.jumped = fresh.jumped
    p.dizzy = fresh.dizzy
    p.kick = fresh.kick
    p.stick = fresh.stick
    p.halt = fresh.halt
    p.walkCnt = fresh.walkCnt
    p.walkFrame = fresh.walkFrame
    p.pose = fresh.pose
    p.prevJump = fresh.prevJump
end

local function noEvents(): Events
    return { jump = false, bump = false, stun = false, pow = false, kick = false }
end

-- stun from a bumped platform, a stomp or the pow (PRG009_A58D)
function Players.stun(p: Player, kickDir: number)
    p.dizzy = Physics.STUN_FRAMES
    p.body.vy = Physics.STUN_VY
    p.body.vx = Physics.STUN_VX * kickDir
end

function Players.kill(p: Player)
    p.state = Players.STATE_DYING
    p.body.vy = Physics.DEATH_VY
    p.body.vx = 0
    p.dizzy = 0
    p.kick = 0
end

local function powCollide(p: Player, w: World.State, ev: Events)
    local rect = Stage.powRect(w.powHits)
    if rect == nil then
        return
    end
    local b = p.body
    local px, py, pw, ph = World.playerBox(b)
    if not World.boxOverlap(px, py, pw, ph, rect.x, rect.y, rect.w, rect.h) then
        return
    end
    local yoff = Stage.POW_YOFF[w.powHits + 1]
    if b.y - yoff < Stage.POW_Y - 11 then
        -- above the block: stand on it
        if b.vy >= 0 then
            b.y = Stage.POW_Y - 16
            b.subY = 0
            b.vy = 0
            p.onGround = true
        end
        return
    end
    if b.y + yoff < Stage.POW_Y + 9 or b.vy >= 0 then
        return
    end
    -- rising into it from below
    ev.pow = true
    World.hitPow(w)
    b.vy = 0
    b.y = Stage.POW_Y + 17 - yoff
    b.subY = 0
    p.stick = 8
end

-- one frame for one player. returns the sounds it wants played.
function Players.update(p: Player, w: World.State, intent: Input.Intent): Events
    local ev = noEvents()
    local b = p.body
    if p.halt > 0 then
        p.halt -= 1
        return ev
    end
    if p.state == Players.STATE_DYING then
        Physics.applyY(b)
        if b.vy < Physics.TERMINAL_VY then
            b.vy = math.min(b.vy + Physics.DEATH_GRAVITY, Physics.TERMINAL_VY)
        end
        p.pose = 'dead'
        return ev
    end

    -- horizontal control (skipped while dizzy, the rom jumps straight to the y velocity)
    local dirPressed = 0
    if p.dizzy == 0 then
        if intent.left then
            dirPressed = -1
        elseif intent.right then
            dirPressed = 1
        end
        if dirPressed ~= 0 then
            p.dir = dirPressed
        end
        Physics.stepPlayerX(b, dirPressed, intent.run)
    end
    Physics.applyX(b)
    b.x = Stage.wrapX(b.x)

    -- jump on a fresh press from the ground
    local jumpPressed = intent.jump and not p.prevJump
    p.prevJump = intent.jump
    if p.dizzy == 0 and jumpPressed and p.onGround then
        Physics.jump(b)
        p.jumped = true
        p.onGround = false
        ev.jump = true
    end

    -- vertical
    if p.stick > 0 then
        p.stick -= 1
    else
        Physics.applyY(b)
        Physics.stepPlayerGravity(b, intent.jump)
    end

    -- world collision
    local probe = World.probe(w, b)
    if probe.ceiling then
        p.stick = Physics.ceilingStickFrames(b.vy)
        World.bump(w, b.x + 8, b.y)
        b.vy = 0
        b.y = (b.y - b.y % 16) + 14
        b.subY = 0
        ev.bump = true
    end
    p.onGround = false
    if probe.ground then
        b.y = b.y - b.y % 16
        b.subY = 0
        b.vy = 0
        p.onGround = true
        p.jumped = false
    end
    powCollide(p, w, ev)

    -- a bounced block under the feet, or the pow while grounded, stuns
    if p.dizzy == 0 and p.onGround and (probe.underHit or w.powCnt > 0) then
        local kickDir = if b.vx < 0 then -1 else 1
        if probe.underHit then
            kickDir = if (b.x + 8) % 16 < 8 then -1 else 1
        end
        Players.stun(p, kickDir)
        ev.stun = true
        p.onGround = false
    end

    -- animation (PRG009_A662 onward)
    local frame = 0
    if b.vx ~= 0 then
        local moving = if b.vx > 0 then 1 else -1
        if moving ~= p.dir then
            frame = 2 -- skid
        else
            local rate = Players.WALK_RATE[math.abs(b.vx) // 4 + 1]
            p.walkCnt += rate
            if p.walkCnt >= 256 then
                p.walkCnt -= 256
                p.walkFrame = (p.walkFrame + 1) % 2
            end
            frame = p.walkFrame
        end
    end
    if not p.onGround then
        frame = if p.jumped then 3 else 1
    end
    if p.dizzy > 0 then
        p.dizzy -= 1
        frame = 4
    end
    if p.kick > 0 then
        p.kick -= 1
        frame = 5
    end
    local poses: { Pose } = { 'stand', 'walk', 'skid', 'jump', 'stun', 'kick' }
    p.pose = poses[frame + 1]
    if frame == 1 and not p.onGround then
        p.pose = 'fall'
    end
    return ev
end

-- VsPlayer_BumpEachother: a stomp launches the top player and stuns the grounded one, side by side shoves
function Players.bumpEachOther(a: Player, b: Player, cooldown: number): (number, boolean)
    if a.state ~= Players.STATE_NORMAL or b.state ~= Players.STATE_NORMAL then
        return cooldown, false
    end
    if cooldown > 0 then
        return cooldown - 1, false
    end
    local ax, ay, aw, ah = World.playerBox(a.body)
    local bx, by, bw, bh = World.playerBox(b.body)
    if not World.boxOverlap(ax, ay, aw, ah, bx, by, bw, bh) then
        return 0, false
    end
    local stunned = false
    local dy = a.body.y - b.body.y
    if math.abs(dy) >= 8 then
        local top, bottom = a, b
        if dy > 0 then
            top, bottom = b, a
        end
        if top.body.vy >= 0 then
            top.body.vy = Physics.STOMP_VY
            top.jumped = true
        end
        if bottom.onGround then
            bottom.body.vy = 0
            bottom.dizzy = Physics.STUN_FRAMES
            stunned = true
        end
    else
        local rightMost, leftMost = a, b
        if a.body.x < b.body.x then
            rightMost, leftMost = b, a
        end
        rightMost.body.vx = Physics.SHOVE_VX
        leftMost.body.vx = -Physics.SHOVE_VX
        rightMost.dir = -1
        leftMost.dir = 1
    end
    return Players.BUMP_COOLDOWN, stunned
end

return Players
