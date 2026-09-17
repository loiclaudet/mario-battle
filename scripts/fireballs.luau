--!strict
-- Vs_Fireballs from PRG/prg009.asm: the weaving horizontal fireball and the bouncing game ender.
-- lodz's additions: a 32 frame warning sparkle at the spawn edge before the flame enters, and the flame
-- starts fully off screen and leaves fully off screen (the rom uses x 8 and 232, which leaves a safe strip).
local Stage = require('scripts/stage')
local Physics = require('scripts/physics')
local World = require('scripts/world')
local Players = require('scripts/players')

local Fireballs = {}

export type Kind = 'horz' | 'ender'
export type Pose = 'warning' | 'flying'

Fireballs.WARNING_FRAMES = 32
Fireballs.BURN_START = 0x40
Fireballs.BURN_END = 0x20
Fireballs.ENTER_X = { -16, Stage.WIDTH } -- moving right, moving left: one sprite width off screen

export type Fireball = {
    id: number,
    kind: Kind,
    body: Physics.Body,
    dir: number, -- horizontal direction, 1 right or -1 left
    vdir: number, -- weave direction, 1 down or -1 up
    warning: number,
    burn: number,
    halt: number,
    animCnt: number,
    pose: Pose,
}

export type State = { list: { Fireball }, nextId: number }

export type Events = { killed: { number } } -- every player a flame touched this frame

function Fireballs.new(): State
    return { list = {}, nextId = 1 }
end

function Fireballs.reset(s: State)
    s.list = {}
end

local function spawn(s: State, kind: Kind, side: number, y: number): Fireball
    local dir = if side == 0 then 1 else -1
    local f: Fireball = {
        id = s.nextId,
        kind = kind,
        body = Physics.newBody(Fireballs.ENTER_X[side + 1], y),
        dir = dir,
        vdir = 1,
        warning = Fireballs.WARNING_FRAMES,
        burn = 0,
        halt = 0,
        animCnt = 0,
        pose = 'warning',
    }
    s.nextId += 1
    f.body.vx = Physics.FIREBALL_VX * dir
    if kind == 'ender' then
        f.body.vy = Physics.FIREBALL_VY_LIMIT
    end
    table.insert(s.list, f)
    return f
end

-- where to draw: the warning sparkle sits just inside the edge the flame will come from
function Fireballs.drawX(f: Fireball): number
    if f.pose == 'warning' then
        return math.clamp(f.body.x, 0, Stage.WIDTH - 16)
    end
    return f.body.x
end

-- Vs_SpawnCnt2 picks the side: (count / 2) & 1
function Fireballs.spawnHorz(s: State, spawnCnt2: number, y: number)
    spawn(s, 'horz', (spawnCnt2 // 2) % 2, y)
end

function Fireballs.spawnEnder(s: State, spawnCnt2: number, y: number)
    spawn(s, 'ender', (spawnCnt2 // 2) % 2, y)
end

function Fireballs.haltAll(s: State)
    for _, f in s.list do
        f.halt = 0xFF
    end
end

local function collidePlayers(f: Fireball, players: { Players.Player }, frame: number, ev: Events)
    if (f.id + frame) % 2 == 1 then
        return
    end
    local fx, fy, fw, fh = World.enemyBox(f.body)
    for i, p in players do
        if p.state ~= Players.STATE_NORMAL or p.halt > 0 then
            continue
        end
        local px, py, pw, ph = World.playerBox(p.body)
        if World.boxOverlap(px, py, pw, ph, fx, fy, fw, fh) then
            table.insert(ev.killed, i)
        end
    end
end

local function weave(f: Fireball)
    local b = f.body
    Physics.applyX(b) -- no wrap: the horizontal fireball crosses once and leaves
    Physics.applyY(b)
    Physics.stepFireballY(b, f.vdir > 0)
    if math.abs(b.vy) >= Physics.FIREBALL_VY_LIMIT then
        f.vdir = -f.vdir
    end
end

-- the ender keeps its speed and reflects off platform sides, floors and ceilings
local function bounce(f: Fireball, w: World.State)
    local b = f.body
    if b.vx > 0 and World.solidAt(w, b.x + 14, b.y + 8) then
        b.vx = -b.vx
        f.dir = -1
    elseif b.vx < 0 and World.solidAt(w, b.x + 2, b.y + 8) then
        b.vx = -b.vx
        f.dir = 1
    end
    if b.vy > 0 and (World.solidAt(w, b.x + 4, b.y + 16) or World.solidAt(w, b.x + 12, b.y + 16)) then
        b.vy = -b.vy
    elseif b.vy < 0 and (b.y <= 0 or World.solidAt(w, b.x + 8, b.y)) then
        b.vy = -b.vy
    end
    Physics.applyX(b)
    b.x = Stage.wrapX(b.x)
    Physics.applyY(b)
end

function Fireballs.update(s: State, w: World.State, players: { Players.Player }, frame: number): Events
    local ev: Events = { killed = {} }
    local kept: { Fireball } = {}
    for _, f in s.list do
        local alive = true
        if f.halt > 0 then
            f.halt -= 1
        elseif f.warning > 0 then
            f.warning -= 1
            if f.warning == 0 then
                f.pose = 'flying'
            end
        elseif f.burn > 0 then
            f.burn -= 1
            if f.burn <= Fireballs.BURN_END then
                alive = false
            end
        else
            f.animCnt += 2
            local b = f.body
            collidePlayers(f, players, frame, ev)
            -- a bumped block under it or the pow burns it out
            local probe = World.probe(w, b)
            if w.powCnt > 0 or probe.underHit then
                f.burn = Fireballs.BURN_START
            end
            if f.burn == 0 then
                if f.kind == 'horz' then
                    weave(f)
                    -- gone once fully past the far edge
                    if (f.dir > 0 and b.x >= Stage.WIDTH) or (f.dir < 0 and b.x <= -16) then
                        alive = false
                    end
                else
                    bounce(f, w)
                end
            end
        end
        if alive then
            table.insert(kept, f)
        end
    end
    s.list = kept
    return ev
end

return Fireballs
