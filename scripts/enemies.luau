--!strict
-- spiny, fighter fly and sidestepper: Vs_SpawnEnemies, Vs_ObjStateNormal, Vs_SpinyAndSidesteppers,
-- Vs_FighterFly, Vs_EnemyHandleHitUnder, Vs_ObjStateFlippedOver, Vs_ObjStateDying, Vs_EnemyUsePipes,
-- Vs_ObjectBumpOffOthers and the enemy half of Vs_ObjectPlayerCollide, from PRG/prg009.asm.
local Stage = require('scripts/stage')
local Physics = require('scripts/physics')
local World = require('scripts/world')
local Players = require('scripts/players')

local Enemies = {}

export type Kind = 'spiny' | 'fly' | 'crab'
export type Pose = 'walkA' | 'walkB' | 'flipped' | 'dying'

Enemies.STATE_NORMAL = 1
Enemies.STATE_FLIPPED = 2
Enemies.STATE_DYING = 3

Enemies.SPAWN_PIPE_FRAMES = 0x30
Enemies.RECYCLE_PIPE_FRAMES = 0x60
Enemies.BUMP_HALT = 0x10
Enemies.BUMP_COOLDOWN = 0x28
Enemies.JITTER_MASKS = { 0x01, 0x02, 0x04 } -- PRG009_B4F5 by getUpTimer / 32

-- Vs_5EnemySets, by style (bonus styles 3, 7 and 11 do not exist here)
local SETS: { { Kind } } = {
    { 'spiny', 'spiny', 'spiny', 'spiny', 'spiny' },
    { 'fly', 'fly', 'fly', 'fly', 'fly' },
    { 'spiny', 'fly', 'spiny', 'fly', 'spiny' },
    { 'spiny', 'crab', 'spiny', 'crab', 'spiny' },
    { 'fly', 'crab', 'fly', 'crab', 'fly' },
    { 'crab', 'crab', 'crab', 'crab', 'crab' },
}
Enemies.SETS = SETS

export type Enemy = {
    slot: number,
    kind: Kind,
    body: Physics.Body,
    dir: number, -- 1 right, -1 left (the sign of the walking velocity)
    state: number,
    pipeTimer: number,
    getUpTimer: number,
    restoreVx: number,
    angry: boolean,
    last: boolean,
    halt: number,
    timer2: number,
    timer3: number,
    animCnt: number,
    onGround: boolean,
    jitter: number,
    pose: Pose,
}

export type State = {
    list: { Enemy },
    spawnCnt: number,
    spawnCnt2: number,
    tooLongCnt: number,
    count: number, -- enemies spawned so far this round
    quota: number, -- how many the round spawns: five, plus one per coin a dead player gave back
    nextIsLast: boolean,
    style: number,
    random: number,
}

Enemies.QUOTA = 5

-- entered: an enemy walked into a bottom pipe this frame (the pipe sound). killed lists every player touched by
-- a live enemy this frame, kicks every kicker
export type Events = { flip: boolean, kick: boolean, coin: number, kicks: { number }, killed: { number }, fireball: boolean, ender: boolean, entered: boolean }

local function noEvents(): Events
    return { flip = false, kick = false, coin = 0, kicks = {}, killed = {}, fireball = false, ender = false, entered = false }
end

function Enemies.new(): State
    return { list = {}, spawnCnt = 0, spawnCnt2 = 0, tooLongCnt = 0, count = 0, quota = Enemies.QUOTA, nextIsLast = false, style = 0, random = 1 }
end

function Enemies.reset(s: State, style: number)
    s.list = {}
    s.spawnCnt = 0
    s.spawnCnt2 = 0
    s.tooLongCnt = 0
    s.count = 0
    s.quota = Enemies.QUOTA
    s.nextIsLast = false
    s.style = style
end

-- a dead player's coins come back as enemies: the round spawns that many more, the last mark waits again
function Enemies.refund(s: State, n: number)
    s.quota += n
    s.nextIsLast = false
end

-- Vs_Randomize stand-in: a small lcg, only used to pick a top pipe when recycling
local function random01(s: State): number
    s.random = (s.random * 1103515245 + 12345) % 2147483648
    return (s.random // 65536) % 2
end

local function spawnVx(dir: number, fast: boolean): number
    local v = if fast then Physics.ENEMY_SPAWN_VX_FAST else Physics.ENEMY_SPAWN_VX
    return v * dir
end

local function spawn(s: State): Enemy
    local kind = SETS[s.style + 1][s.count % 5 + 1] -- past the five, the set repeats
    local side = s.count % 2 -- 0 left pipe walking right, 1 right pipe walking left
    local dir = if side == 0 then 1 else -1
    s.count += 1
    local last = s.count == s.quota and s.nextIsLast
    local e: Enemy = {
        slot = s.count,
        kind = kind,
        body = Physics.newBody(Stage.SPAWN_X[side + 1], Stage.SPAWN_Y),
        dir = dir,
        state = Enemies.STATE_NORMAL,
        pipeTimer = Enemies.SPAWN_PIPE_FRAMES,
        getUpTimer = 0,
        restoreVx = 0,
        angry = false,
        last = last,
        halt = 0,
        timer2 = 0,
        timer3 = 0,
        animCnt = 0,
        onGround = false,
        jitter = 0,
        pose = 'walkA',
    }
    e.body.vx = spawnVx(dir, last)
    table.insert(s.list, e)
    return e
end

-- Vs_SpawnEnemies: one enemy every 256 frames, fireball attempts at the half cycle, the ender on the long count
function Enemies.spawner(s: State, halted: boolean, ev: Events)
    if halted then
        return
    end
    s.spawnCnt = (s.spawnCnt + 1) % 256
    if s.spawnCnt % 32 == 0 then
        s.tooLongCnt = (s.tooLongCnt + 1) % 256
        if s.tooLongCnt == 0 then
            ev.ender = true
            return
        end
    end
    if s.spawnCnt == 0x80 then
        s.spawnCnt2 = (s.spawnCnt2 + 1) % 256
        if s.spawnCnt2 % 8 == 0 then
            ev.fireball = true
            return
        end
    end
    if s.count < s.quota and s.spawnCnt == 0 then
        spawn(s)
    end
end

-- partial re-init (PRG009_ACC2): walking velocity reset to the slowest grade in the given direction
local function reinit(e: Enemy, dir: number)
    e.dir = dir
    e.body.vx = spawnVx(dir, e.last)
end

-- Vs_EnemyHandleHitUnder: a bounced block under a foot, or an active pow, while not rising and not in a pipe
local function handleHitUnder(e: Enemy, w: World.State, probe: World.Probe, ev: Events)
    if e.body.vy < 0 or e.pipeTimer > 0 then
        return
    end
    if not probe.underHit and w.powCnt == 0 then
        return
    end
    ev.flip = true
    e.halt = 0
    e.timer2 = 0
    if e.kind == 'crab' and e.state ~= Enemies.STATE_FLIPPED and not e.angry then
        e.angry = true
        e.body.vx = Physics.fasterVx(e.body.vx)
        e.getUpTimer = Physics.GETUP_TIMER
    else
        if e.state == Enemies.STATE_FLIPPED then
            -- flipped back upright: slowest speed, no get-up boost
            e.state = Enemies.STATE_NORMAL
            reinit(e, e.dir)
            e.getUpTimer = 0
        else
            e.state = Enemies.STATE_FLIPPED
            e.getUpTimer = Physics.GETUP_TIMER
        end
    end
    if probe.underHit then
        -- hit by a bumped block (not the pow): stash the walk speed and drift away from the hit side
        local hitLeft = probe.underHitLeft and not probe.underHitRight
        local hitRight = probe.underHitRight and not probe.underHitLeft
        if hitLeft or hitRight then
            e.restoreVx = e.body.vx
            reinit(e, if hitLeft then 1 else -1)
        end
    end
    e.body.vy = Physics.ENEMY_HIT_VY
end

-- Vs_EnemyUsePipes. returns true when the enemy teleported to a top pipe this frame
local function usePipes(s: State, e: Enemy, ev: Events): boolean
    local b = e.body
    if b.y < Stage.BOTTOM_PIPE_Y - 16 then
        return false
    end
    local side = if e.dir > 0 then 1 else 2
    if b.x == Stage.BOTTOM_PIPE_ENTRANCE_X[side] then
        -- x sits on the entrance for a few frames at pipe speed: the sound is the first of them
        if e.pipeTimer == 0 then
            ev.entered = true
        end
        e.pipeTimer = Enemies.RECYCLE_PIPE_FRAMES
        return false
    end
    if b.x ~= Stage.BOTTOM_PIPE_LIMIT_X[side] then
        return false
    end
    b.y = Stage.SPAWN_Y
    b.subY = 0
    local top = random01(s)
    b.x = Stage.SPAWN_X[top + 1]
    local wantDir = if top == 0 then 1 else -1
    if e.dir ~= wantDir then
        e.dir = wantDir
        b.vx = -b.vx
        if e.restoreVx ~= 0 then
            e.restoreVx = -e.restoreVx
        end
    end
    return true
end

-- Vs_EnemyMove: inside a pipe the walk uses the reduced pipe speed
local function move(e: Enemy)
    local b = e.body
    if e.pipeTimer > 0 then
        e.pipeTimer -= 1
        local x, sub = Physics.applyVel(b.x, b.subX, Physics.ENEMY_PIPE_VX * e.dir)
        b.x, b.subX = x, sub
    else
        Physics.applyX(b)
    end
    b.x = Stage.wrapX(b.x)
end

local function landOnFloor(e: Enemy)
    local b = e.body
    b.y = b.y - b.y % 16
    b.subY = 0
    b.vy = 0
    e.onGround = true
end

local function walkerNormal(s: State, e: Enemy, w: World.State, ev: Events)
    local b = e.body
    if usePipes(s, e, ev) then
        return
    end
    move(e)
    local vyBefore = b.vy
    Physics.applyY(b)
    Physics.stepObjectGravity(b, Physics.ENEMY_GRAVITY)
    local probe = World.probe(w, b)
    e.onGround = false
    if probe.ground then
        landOnFloor(e)
        handleHitUnder(e, w, probe, ev)
        e.animCnt += 1
        if e.kind == 'crab' then
            e.animCnt += 1
        end
        if e.last or e.angry then
            e.animCnt += 1
        end
        if e.pipeTimer > 0 then
            e.animCnt += 1
        end
        if vyBefore >= 0x10 and e.restoreVx ~= 0 then
            b.vx = e.restoreVx
            e.restoreVx = 0
        end
    else
        e.animCnt = 0
    end
end

local function flyNormal(s: State, e: Enemy, w: World.State, ev: Events)
    local b = e.body
    if usePipes(s, e, ev) then
        return
    end
    if e.getUpTimer > 0 then
        e.getUpTimer -= 1
        if e.getUpTimer == 0 then
            b.vy = Physics.FLY_HOP_VY
        end
    end
    if e.getUpTimer == 0 or b.vy < 0 then
        move(e)
    end
    Physics.applyY(b)
    Physics.stepObjectGravity(b, Physics.FLY_GRAVITY)
    local probe = World.probe(w, b)
    e.onGround = false
    if probe.ground then
        e.animCnt = 8
        if e.getUpTimer == 0 then
            e.getUpTimer = Physics.FLY_REST_FRAMES
        end
        landOnFloor(e)
        handleHitUnder(e, w, probe, ev)
    else
        e.animCnt += 4
    end
end

local function flipped(e: Enemy, w: World.State, frame: number, ev: Events)
    local b = e.body
    e.animCnt = 0
    e.jitter = 0
    if e.getUpTimer == 0 then
        e.state = Enemies.STATE_NORMAL
        local base = if e.restoreVx ~= 0 then e.restoreVx else b.vx
        if base == 0 then
            base = spawnVx(e.dir, false)
        end
        b.vx = Physics.fasterVx(base)
        e.dir = if b.vx < 0 then -1 else 1
        e.restoreVx = 0
        return
    end
    if frame % 2 == 0 then
        e.getUpTimer -= 1
    end
    if e.getUpTimer < Physics.GETUP_JITTER_BELOW then
        local mask = Enemies.JITTER_MASKS[e.getUpTimer // 32 + 1]
        if bit32.band(frame, mask) ~= 0 then
            e.jitter = 1
        end
    end
    local probe = World.probe(w, b)
    e.onGround = false
    if probe.ground then
        landOnFloor(e)
        b.vx = 0
        handleHitUnder(e, w, probe, ev)
    end
    Physics.applyX(b)
    b.x = Stage.wrapX(b.x)
    Physics.applyY(b)
    Physics.stepObjectGravity(b, Physics.ENEMY_GRAVITY)
end

local function dying(e: Enemy, frame: number): boolean
    local b = e.body
    if b.y >= 224 then
        return false
    end
    Physics.applyX(b)
    b.x = Stage.wrapX(b.x)
    Physics.applyY(b)
    Physics.stepObjectGravity(b, Physics.ENEMY_GRAVITY)
    b.vy = math.min(b.vy + 1, Physics.TERMINAL_VY)
    if frame % 2 == 0 and b.vx ~= 0 then
        b.vx += if b.vx > 0 then -1 else 1
    end
    return true
end

-- Vs_ObjectBumpOffEachother for one pair: grounded enemies that touch turn away from each other and pause
local function bumpPair(a: Enemy, b: Enemy)
    if a.state == Enemies.STATE_DYING or b.state == Enemies.STATE_DYING then
        return
    end
    if a.pipeTimer > 0 or b.pipeTimer > 0 then
        return
    end
    if a.timer3 > 0 or b.timer3 > 0 then
        return
    end
    local ax, ay, aw, ah = World.enemyBox(a.body)
    local bx, by, bw, bh = World.enemyBox(b.body)
    if not World.boxOverlap(ax, ay, aw, ah, bx, by, bw, bh) then
        return
    end
    if not (a.onGround and b.onGround) then
        return
    end
    for _, pair in { { a, b }, { b, a } } do
        local me, other = pair[1], pair[2]
        if me.halt == 0 then
            me.timer3 = Enemies.BUMP_COOLDOWN
            if me.state == Enemies.STATE_NORMAL then
                me.halt = Enemies.BUMP_HALT
                me.animCnt = 8
            end
            local toward = if other.body.x > me.body.x then 1 else -1
            if me.body.vx * toward > 0 then
                me.body.vx = -me.body.vx
                me.dir = -me.dir
                if me.restoreVx ~= 0 then
                    me.restoreVx = -me.restoreVx
                end
            end
        end
    end
end

-- the enemy half of Vs_ObjectPlayerCollide, on alternate frames per slot
local function collidePlayers(e: Enemy, players: { Players.Player }, frame: number, ev: Events)
    if (e.slot + frame) % 2 == 1 or e.pipeTimer > 0 or e.state == Enemies.STATE_DYING then
        return
    end
    local ex, ey, ew, eh = World.enemyBox(e.body)
    for i, p in players do
        if p.state ~= Players.STATE_NORMAL or p.halt > 0 then
            continue
        end
        local px, py, pw, ph = World.playerBox(p.body)
        if not World.boxOverlap(px, py, pw, ph, ex, ey, ew, eh) then
            continue
        end
        if e.state == Enemies.STATE_NORMAL then
            table.insert(ev.killed, i)
            e.animCnt = 0x20
            e.dir = if p.body.x >= e.body.x then 1 else -1
            return
        end
        -- kicked off. two enemies can go in one frame, so every kick is listed with its kicker
        ev.kick = true
        ev.coin = i
        table.insert(ev.kicks, i)
        e.body.vx = if p.body.vx < 0 then -Physics.ENEMY_KICK_VX else Physics.ENEMY_KICK_VX
        e.body.vy = Physics.ENEMY_KICK_VY
        e.state = Enemies.STATE_DYING
        p.kick = Players.KICK_FRAMES
        return
    end
end

-- the fourth coin flags the survivors as last and gives each a speed grade, once
function Enemies.markLast(s: State)
    s.nextIsLast = true
    for _, e in s.list do
        if e.state ~= Enemies.STATE_DYING and not e.last then
            e.body.vx = Physics.fasterVx(e.body.vx)
            e.last = true
        end
    end
end

function Enemies.haltAll(s: State)
    for _, e in s.list do
        e.halt = 0xFF
    end
end

local function pose(e: Enemy): Pose
    if e.state == Enemies.STATE_DYING then
        return 'dying'
    end
    if e.state == Enemies.STATE_FLIPPED then
        return 'flipped'
    end
    return if (e.animCnt // 8) % 2 == 0 then 'walkA' else 'walkB'
end

-- one 1/60 step for every enemy
function Enemies.update(s: State, w: World.State, players: { Players.Player }, frame: number, halted: boolean): Events
    local ev = noEvents()
    Enemies.spawner(s, halted, ev)
    local kept: { Enemy } = {}
    for _, e in s.list do
        local alive = true
        if e.halt > 0 then
            e.halt -= 1
        end
        if e.timer2 > 0 then
            e.timer2 -= 1
        end
        if e.timer3 > 0 then
            e.timer3 -= 1
        end
        if e.state == Enemies.STATE_NORMAL then
            if e.halt > 0 or e.timer2 > 0 then
                local probe = World.probe(w, e.body)
                if probe.ground then
                    handleHitUnder(e, w, probe, ev)
                end
            elseif e.kind == 'fly' then
                flyNormal(s, e, w, ev)
            else
                walkerNormal(s, e, w, ev)
            end
        elseif e.state == Enemies.STATE_FLIPPED then
            if e.halt == 0 then
                flipped(e, w, frame, ev)
            end
        else
            if e.last or e.halt == 0 then
                alive = dying(e, frame)
            end
        end
        if alive then
            table.insert(kept, e)
        end
    end
    s.list = kept
    -- bump off each other, alternating frames like the rom
    for i = 2, #s.list do
        if (i + frame) % 2 == 1 then
            for j = 1, i - 1 do
                bumpPair(s.list[i], s.list[j])
            end
        end
    end
    for _, e in s.list do
        collidePlayers(e, players, frame, ev)
        e.pose = pose(e)
    end
    return ev
end

return Enemies
