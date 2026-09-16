--!strict
-- the cpu player. every frame it reads the arena, keeps a plan and outputs the intent a pad would,
-- so scripts/players.luau moves it under the exact same physics. deterministic, the brain table
-- is its only memory. threats override the plan; the plan is the best scored target right now.
local Stage = require('scripts/stage')
local Physics = require('scripts/physics')
local World = require('scripts/world')
local Players = require('scripts/players')
local Enemies = require('scripts/enemies')
local Fireballs = require('scripts/fireballs')
local Input = require('scripts/input')
local Nav = require('scripts/nav')

local Npc = {}

export type Kind = 'kick' | 'flip' | 'pow' | 'bump' | 'stomp' | 'post' | 'escape'
-- row and x: where to stand. slot: the enemy slot or player index it is about. targetRow: the row the target walks
export type Plan = { kind: Kind, row: number, x: number, slot: number, targetRow: number }
export type Brain = {
    index: number,
    plan: Plan?,
    replanIn: number,
    jumping: boolean, -- an airborne move the brain started (jump or drop), keep steering it
    jumpHold: number, -- frames left holding the jump button
    airDir: number,
    lastRow: number, -- the row last stood on, used while airborne or on the pow
    evadeFrames: number, -- keep running from the last threat this long
    evadeDir: number,
    release: number, -- frames to keep the jump button up after a press, so the next press is fresh
}

Npc.REPLAN_FRAMES = 8
Npc.LOOKAHEAD = 16 -- frames of enemy motion projected for the threat check
Npc.IMMINENT = 6 -- inside this many frames a threat overrides even an escape in progress
Npc.ESCAPE_GAP = 28 -- px between the launch point and the threat when we jump
Npc.KICK_MARGIN = 24 -- frames a flipped enemy must still be down after the trip to it
Npc.EVADE_FRAMES = 10
Npc.POSTS = { { 1, 80 }, { 1, 168 }, { 2, 40 }, { 2, 216 } } -- row and x of the waiting spots: the floor under the lower ledges, and the ledges
Npc.DANGER_FRAMES = 40 -- how far ahead a live enemy on the target row is projected when scoring a spot
Npc.DANGER_PX = 40
Npc.FAR = 400 -- travel frames beyond which a target is not worth it

function Npc.new(index: number): Brain
    return { index = index, plan = nil, replanIn = 0, jumping = false, jumpHold = 0, airDir = 0, lastRow = Nav.FLOOR, evadeFrames = 0, evadeDir = 0, release = 0 }
end

local function intent(dir: number, run: boolean, jump: boolean): Input.Intent
    return { left = dir < 0, right = dir > 0, up = false, down = false, jump = jump, run = run, start = false }
end

local function sign(v: number): number
    return if v > 0 then 1 elseif v < 0 then -1 else 0
end

-- the short way round from x to tx, in px
local function wrapDx(x: number, tx: number): number
    return (tx - x + 128) % 256 - 128
end

-- run to a point on the row: full run far off, a walk near, coast the braking distance (8 v squared px)
local function moveTo(row: number, b: Physics.Body, tx: number): Input.Intent
    local dx = Nav.dx(row, b.x, tx)
    if math.abs(dx) <= 2 then
        return intent(0, false, false)
    end
    local v = b.vx / 16
    if sign(v) == sign(dx) and math.abs(dx) <= v * v * 8 then
        return intent(0, false, false)
    end
    return intent(sign(dx), math.abs(dx) > 16, false)
end

local function stopped(b: Physics.Body): boolean
    return math.abs(b.vx) <= 2
end

-- room for a hop that moves `dir`: nothing solid in the 40 px above the head over the next 24 px, the pow included
local function headroom(w: World.State, b: Physics.Body, dir: number): boolean
    for ahead = 0, 24, 8 do
        local x = Stage.wrapX(b.x + 8 + dir * ahead)
        for k = 8, 40, 8 do
            if Stage.solidAt(x, b.y - k) then
                return false
            end
        end
    end
    local pow = Stage.powRect(w.powHits)
    if pow ~= nil and World.boxOverlap(b.x + 4, b.y - 40, 8, 40, pow.x, pow.y, pow.w, pow.h) then
        return false
    end
    return true
end

-- threats --------------------------------------------------------------------------------------

type Threat = { dir: number, above: boolean, x: number, vx: number, soon: boolean }

-- does a 12x4 box moving from (ex, ey) meet our box within `frames`, both on their current velocity
local function meets(b: Physics.Body, ex: number, ey: number, evx: number, evy: number, frames: number): boolean
    local pvx = b.vx / 16
    local rx = b.x + wrapDx(b.x, ex)
    for t = 1, frames do
        local px = b.x + pvx * t
        local tx = rx + evx * t
        local ty = ey + evy * t
        if World.boxOverlap(px + 4, b.y + 2, 8, 14, tx + 2, ty + 6, 12, 4) then
            return true
        end
    end
    return false
end

local function threatFrom(b: Physics.Body, x: number, y: number, vx: number, vy: number): Threat?
    if not meets(b, x, y, vx, vy, Npc.LOOKAHEAD) then
        return nil
    end
    return { dir = sign(wrapDx(b.x, x)), above = y < b.y - 12, x = x, vx = vx, soon = meets(b, x, y, vx, vy, Npc.IMMINENT) }
end

local function findThreat(p: Players.Player, enemies: Enemies.State, fireballs: Fireballs.State): Threat?
    local b = p.body
    for _, e in enemies.list do
        if e.state == Enemies.STATE_NORMAL and e.pipeTimer == 0 then
            local t = threatFrom(b, e.body.x, e.body.y, e.body.vx / 16, e.body.vy / 16)
            if t ~= nil then
                return t
            end
        end
    end
    for _, f in fireballs.list do
        if f.pose == 'flying' then
            local t = threatFrom(b, f.body.x, f.body.y, f.body.vx / 16, f.body.vy / 16)
            if t ~= nil then
                return t
            end
        end
    end
    return nil
end

-- a threat on our row and no room to hop: the nearest jump off the row that we reach before it does
local function escapePlan(brain: Brain, b: Physics.Body, threat: Threat): Plan?
    local row = brain.lastRow
    local sx = Nav.seg(Nav.ROWS[row], b.x)
    local best: Plan? = nil
    local bestFrames = math.huge
    for _, l in Nav.LINKS do
        if l.from ~= row or l.kind ~= 'jump' then
            continue
        end
        local ax = math.clamp(sx, l.lo, l.hi)
        local mine = math.abs(ax - sx) / Nav.RUN_PX
        local ex = Nav.seg(Nav.ROWS[row], b.x + wrapDx(b.x, threat.x))
        -- the launch point must be on our side of the threat, and ours first by a margin
        if sign(ax - sx) == sign(ex - sx) and math.abs(ex - sx) < math.abs(ax - sx) then
            continue
        end
        -- and the threat must still be well clear of the launch point when we get there
        local gap = math.abs(ax - (ex + threat.vx * mine))
        if gap >= Npc.ESCAPE_GAP and mine < bestFrames then
            bestFrames = mine
            best = { kind = 'escape', row = l.to, x = l.landX, slot = 0, targetRow = l.to }
        end
    end
    return best
end

-- live enemies and fireballs that will be within reach of (row, x) in `frames`, on their current motion
local function danger(row: number, x: number, frames: number, enemies: Enemies.State, fireballs: Fireballs.State): number
    local y = Nav.ROWS[row].y
    local n = 0
    local function near(ex: number, ey: number, evx: number)
        if math.abs(ey - y) >= 24 then
            return
        end
        local d = wrapDx(x, ex)
        local later = d + evx * frames
        if math.abs(d) < Npc.DANGER_PX or math.abs(later) < Npc.DANGER_PX or sign(d) ~= sign(later) then
            n += 1
        end
    end
    for _, e in enemies.list do
        if e.state == Enemies.STATE_NORMAL and e.pipeTimer == 0 then
            near(e.body.x, e.body.y, e.body.vx / 16)
        end
    end
    for _, f in fireballs.list do
        if f.pose == 'flying' then
            near(f.body.x, f.body.y, f.body.vx / 16)
        end
    end
    return n
end

-- plans ----------------------------------------------------------------------------------------

local function findEnemy(enemies: Enemies.State, slot: number): Enemies.Enemy?
    for _, e in enemies.list do
        if e.slot == slot then
            return e
        end
    end
    return nil
end

local function enemyRow(e: Enemies.Enemy): number?
    if not e.onGround then
        return nil
    end
    return Nav.rowAt(e.body.x, e.body.y)
end

-- the block under a 16 px body's centre, as the player x that puts the head probe in it
local function blockUnder(x: number): number
    return math.floor((x + 8) / 16) * 16
end

local function choose(brain: Brain, p: Players.Player, w: World.State, enemies: Enemies.State, fireballs: Fireballs.State, players: { Players.Player }): Plan
    local b = p.body
    local row = brain.lastRow
    local bestScore = -math.huge
    local best: Plan? = nil
    -- every spot is worth less the longer the trip and the more live enemies it will have around it
    local function offer(value: number, plan: Plan)
        local travel = Nav.travel(row, b.x, plan.row, plan.x)
        if travel >= Npc.FAR then
            return
        end
        local score = value - travel / 4 - 40 * danger(plan.row, plan.x, travel + Npc.DANGER_FRAMES, enemies, fireballs)
        if score > bestScore then
            bestScore = score
            best = plan
        end
    end

    local grounded = 0
    for _, e in enemies.list do
        if e.pipeTimer > 0 or e.state == Enemies.STATE_DYING then
            continue
        end
        local er = enemyRow(e)
        if e.state == Enemies.STATE_FLIPPED then
            if er ~= nil then
                local travel = Nav.travel(row, b.x, er, e.body.x)
                local remaining = e.getUpTimer * 2
                if remaining > travel + Npc.KICK_MARGIN then
                    offer(100 + (if e.last then 20 else 0), { kind = 'kick', row = er, x = e.body.x, slot = e.slot, targetRow = er })
                end
            end
        elseif e.state == Enemies.STATE_NORMAL then
            if er ~= nil then
                grounded += 1
                if er ~= Nav.FLOOR then
                    local below = Nav.rowBelow(e.body.x, e.body.y)
                    if below ~= nil and Nav.bumpFrames(below, er) ~= nil then
                        offer(60, { kind = 'flip', row = below, x = blockUnder(e.body.x), slot = e.slot, targetRow = er })
                    end
                end
            end
        end
    end

    if Stage.powRect(w.powHits) ~= nil and w.powCnt == 0 and grounded >= 2 then
        offer(30 * grounded, { kind = 'pow', row = Nav.FLOOR, x = 120, slot = 0, targetRow = Nav.FLOOR })
    end

    for i, h in players do
        if i == brain.index or h.state ~= Players.STATE_NORMAL then
            continue
        end
        local hr = if h.onGround then Nav.rowAt(h.body.x, h.body.y) else nil
        if hr ~= nil and hr ~= Nav.FLOOR then
            local below = Nav.rowBelow(h.body.x, h.body.y)
            if below ~= nil and Nav.bumpFrames(below, hr) ~= nil then
                local near = false
                for _, e in enemies.list do
                    if e.state == Enemies.STATE_NORMAL and e.pipeTimer == 0 and enemyRow(e) == hr and math.abs(wrapDx(h.body.x, e.body.x)) < 40 then
                        near = true
                    end
                end
                offer(if near then 80 else 30, { kind = 'bump', row = below, x = blockUnder(h.body.x), slot = i, targetRow = hr })
            end
        end
        if h.dizzy > 0 and hr == row and math.abs(Nav.dx(row, b.x, h.body.x)) < 48 then
            offer(25, { kind = 'stomp', row = row, x = h.body.x, slot = i, targetRow = row })
        end
    end

    for _, spot in Npc.POSTS do
        offer(0, { kind = 'post', row = spot[1], x = spot[2], slot = 0, targetRow = spot[1] })
    end
    local chosen = best -- a plain local narrows, the upvalue the offers write does not
    if chosen == nil then
        return { kind = 'post', row = Nav.FLOOR, x = 80, slot = 0, targetRow = Nav.FLOOR }
    end
    return chosen
end

-- is the current plan still about something real
local function valid(brain: Brain, plan: Plan, p: Players.Player, w: World.State, enemies: Enemies.State, players: { Players.Player }): boolean
    if plan.kind == 'kick' then
        local e = findEnemy(enemies, plan.slot)
        return e ~= nil and e.state == Enemies.STATE_FLIPPED and e.getUpTimer * 2 > Npc.KICK_MARGIN
    elseif plan.kind == 'flip' then
        local e = findEnemy(enemies, plan.slot)
        return e ~= nil and e.state == Enemies.STATE_NORMAL and e.pipeTimer == 0 and (not e.onGround or enemyRow(e) == plan.targetRow)
    elseif plan.kind == 'pow' then
        return Stage.powRect(w.powHits) ~= nil and w.powCnt == 0
    elseif plan.kind == 'escape' then
        return brain.lastRow ~= plan.row
    elseif plan.kind == 'bump' then
        local h = players[plan.slot]
        return h.state == Players.STATE_NORMAL and (not h.onGround or Nav.rowAt(h.body.x, h.body.y) == plan.targetRow)
    elseif plan.kind == 'stomp' then
        return players[plan.slot].dizzy > 0
    end
    return true
end

-- jump now if the target's feet will be on our block while it bounces (14 frames from the hit)
local function bumpNow(brain: Brain, plan: Plan, b: Physics.Body, tx: number, tvx: number): boolean
    local hit = Nav.bumpFrames(plan.row, plan.targetRow)
    if hit == nil then
        return false
    end
    local rel = wrapDx(plan.x, tx)
    for t = hit, hit + World.BLOCK_FRAMES - 1 do
        local d = rel + tvx * t
        if d >= -11 and d <= 11 then
            return true
        end
    end
    return false
end

-- press jump now. the button then stays up for two frames so a press that did not take can repeat,
-- and the landing replans at once
local function jump(brain: Brain, dir: number, hold: number): Input.Intent
    brain.jumping = true
    brain.jumpHold = hold
    brain.airDir = dir
    brain.release = 2
    brain.replanIn = 0
    return intent(dir, true, true)
end

-- where a jump or drop step from this row lands, and how long it takes
local function landing(row: number, step: Nav.Step): (number, number, number)
    for _, l in Nav.LINKS do
        if l.from == row and l.kind == step.kind and l.dir == step.dir and step.x >= l.lo and step.x <= l.hi then
            return l.to, l.landX, l.frames
        end
    end
    return row, step.x, 0
end

local function execute(brain: Brain, plan: Plan, p: Players.Player, w: World.State, enemies: Enemies.State, fireballs: Fireballs.State, players: { Players.Player }): Input.Intent
    local b = p.body
    local row = brain.lastRow
    if row ~= plan.row then
        local step = Nav.step(row, b.x, plan.row, plan.x)
        if step == nil then
            return intent(0, false, false)
        end
        if step.kind == 'move' then
            return moveTo(row, b, step.x)
        end
        -- never leap or drop onto a live enemy: wait for the landing spot to clear
        local toRow, landX, frames = landing(row, step)
        local clear = danger(toRow, landX, frames, enemies, fireballs) == 0
        if step.kind == 'jump' then
            if Nav.inWindow(row, b.x, step) then
                if not clear then
                    return intent(0, false, false)
                end
                return jump(brain, step.dir, 60)
            end
            return moveTo(row, b, step.x)
        end
        -- a drop: run off the end
        if not clear then
            return intent(0, false, false)
        end
        brain.jumping = true
        brain.jumpHold = 0
        brain.airDir = step.dir
        brain.replanIn = 0
        return intent(step.dir, true, false)
    end
    if plan.kind == 'kick' then
        local e = findEnemy(enemies, plan.slot)
        if e == nil then
            return intent(0, false, false)
        end
        local dx = Nav.dx(row, b.x, e.body.x)
        return intent(if dx ~= 0 then sign(dx) else p.dir, math.abs(dx) > 8, false)
    elseif plan.kind == 'flip' or plan.kind == 'bump' then
        if math.abs(Nav.dx(row, b.x, plan.x)) > 2 or not stopped(b) then
            return moveTo(row, b, plan.x)
        end
        local tx, tvx = 0, 0
        if plan.kind == 'flip' then
            local e = findEnemy(enemies, plan.slot)
            if e == nil or not e.onGround then
                return intent(0, false, false)
            end
            tx = e.body.x
            tvx = if e.kind == 'fly' then 0 else e.body.vx / 16
        else
            local h = players[plan.slot]
            if not h.onGround then
                return intent(0, false, false)
            end
            tx = h.body.x
            tvx = h.body.vx / 16
        end
        if bumpNow(brain, plan, b, tx, tvx) then
            local hit = Nav.bumpFrames(plan.row, plan.targetRow) or 0
            return jump(brain, 0, hit + 2)
        end
        return intent(0, false, false)
    elseif plan.kind == 'pow' then
        if math.abs(Nav.dx(row, b.x, plan.x)) > 2 or not stopped(b) then
            return moveTo(row, b, plan.x)
        end
        return jump(brain, 0, 1)
    elseif plan.kind == 'stomp' then
        local h = players[plan.slot]
        local dx = Nav.dx(row, b.x, h.body.x)
        if math.abs(dx) < 20 then
            return jump(brain, sign(dx), 8)
        end
        return moveTo(row, b, h.body.x)
    end
    return moveTo(row, b, plan.x)
end

-- one frame of thought for player brain.index
function Npc.think(brain: Brain, p: Players.Player, w: World.State, enemies: Enemies.State, fireballs: Fireballs.State, players: { Players.Player }): Input.Intent
    local b = p.body
    if p.state ~= Players.STATE_NORMAL then
        return Input.NONE
    end
    if p.onGround then
        local row = Nav.rowAt(b.x, b.y)
        if row ~= nil then
            brain.lastRow = row
        end
        brain.jumping = false
        if brain.release > 0 then
            brain.release -= 1
            return intent(0, false, false)
        end
    else
        -- airborne: finish the move the brain started, otherwise just fall
        if brain.jumping then
            brain.jumpHold -= 1
            return intent(brain.airDir, true, brain.jumpHold > 0)
        end
        return Input.NONE
    end

    local threat = findThreat(p, enemies, fireballs)
    local escaping = brain.plan ~= nil and (brain.plan :: Plan).kind == 'escape'
    if threat ~= nil and (threat.soon or not escaping) then
        local away = if threat.dir == 0 then -p.dir else -threat.dir
        if threat.above then
            brain.evadeFrames = Npc.EVADE_FRAMES
            brain.evadeDir = away
        elseif headroom(w, b, threat.dir) then
            brain.evadeFrames = 0
            return jump(brain, threat.dir, 24)
        else
            local escape = if threat.soon then nil else escapePlan(brain, b, threat)
            if escape ~= nil then
                brain.plan = escape
                brain.replanIn = 60
            else
                brain.evadeFrames = Npc.EVADE_FRAMES
                brain.evadeDir = away
            end
        end
    end
    if brain.evadeFrames > 0 then
        brain.evadeFrames -= 1
        return intent(brain.evadeDir, true, false)
    end

    brain.replanIn -= 1
    local current = brain.plan
    local plan: Plan
    if current == nil or brain.replanIn <= 0 or not valid(brain, current, p, w, enemies, players) then
        plan = choose(brain, p, w, enemies, fireballs, players)
        brain.plan = plan
        brain.replanIn = Npc.REPLAN_FRAMES
    else
        plan = current
    end
    return execute(brain, plan, p, w, enemies, fireballs, players)
end

return Npc
