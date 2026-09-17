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
local Sim = require('scripts/sim')

local Npc = {}

export type Kind = 'kick' | 'flip' | 'pow' | 'trap' | 'deny' | 'bump' | 'stomp' | 'shadow' | 'post' | 'escape' | 'flee'
-- row and x: where to stand. slot: the enemy slot or player index it is about. targetRow: the row the target walks.
-- block: for a deny, the block bumped when it is not the downed enemy's own but one on the rival's way to it
export type Plan = { kind: Kind, row: number, x: number, slot: number, targetRow: number, block: number? }
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
    override: Input.Intent?, -- a move the search chose over the policy, held for overrideLeft frames
    overrideLeft: number,
    frame: number, -- frames thought so far, paces the periodic search
    hunt: boolean, -- the coins are lost: no more kicks, only the human's death wins now
    coins: { number },
    denyFrames: number, -- frames spent sitting under a downed enemy the human has not come for
    lastBase: number, -- the policy's last rollout score, for the trace
    lastScores: string, -- the searched moves' scores, for the trace
}

Npc.REPLAN_FRAMES = 8
Npc.LOOKAHEAD = 24 -- frames of enemy motion projected for the threat check; the look ahead covers the rest
Npc.FIREBALL_LOOKAHEAD = 56 -- a fireball crosses in a straight line, so it is seen from far, sparkle included
Npc.IMMINENT = 6 -- inside this many frames a threat overrides even an escape in progress
Npc.ESCAPE_GAP = 28 -- px between the launch point and the threat when we jump
Npc.KICK_MARGIN = 24 -- frames a flipped enemy must still be down after the trip to it
Npc.EVADE_FRAMES = 10
Npc.POSTS = {} :: { { number } } -- row and x of the waiting spots, from Npc.configure
Npc.POW_X = 120 -- stand here to punch the pow, from Npc.configure
Npc.TRAP_REACH = 20 -- px between the human and a downed enemy when the pow rights it under their feet
Npc.POW_FRAMES = 8 -- frames from the jump under the pow to the hit, measured by npc_test
Npc.LAND_PX = 24 -- clearance wanted around a landing spot
Npc.DANGER_FRAMES = 40 -- how far ahead a live enemy on the target row is projected when scoring a spot
Npc.DANGER_PX = 28
Npc.DANGER_COST = 15 -- score lost per live enemy that will be near a spot, kept low since the look ahead keeps it alive
Npc.RIVAL_NEAR = 60 -- frames: a human this close to a downed enemy makes denying it worth more than kicking it
Npc.REACTION = 24 -- frames added to a rival's trip when they are not already moving along it, twice that moving away
Npc.GUARD_SLACK = 8 -- frames of margin allowed when picking a block on the rival's way that we can reach in time
Npc.THROW_MARGIN = 4 -- px a landing must be inside the far half of a guard block, its spot is only a guess
Npc.TRAP_FAR = 150 -- a rival this many frames from a downed enemy is still worth waiting for under the pow
Npc.KEEP_BONUS = 15 -- score kept by the plan already in hand, so the choice does not flip on a small shift
Npc.DENY_PATIENCE = 90 -- frames to sit under a downed enemy before taking the kick ourselves
Npc.LINGER_PX = 64 -- a human this close to a downed enemy we sit under, not coming, gets it righted at them
Npc.FAR = 400 -- travel frames beyond which a target is not worth it
Npc.HORIZON = 48 -- frames the brain runs the battle forward before committing
Npc.MACRO_FRAMES = 12 -- frames a searched move is held before the policy takes over again
Npc.SEARCH_EVERY = 6 -- frames between searches for a better move while the policy is safe
Npc.DEATH = -10000
Npc.COINS_TO_WIN = 5

function Npc.new(index: number): Brain
    return { index = index, plan = nil, replanIn = 0, jumping = false, jumpHold = 0, airDir = 0, lastRow = Nav.FLOOR, evadeFrames = 0, evadeDir = 0, release = 0, override = nil, overrideLeft = 0, frame = 0, hunt = false, coins = { 0, 0 }, denyFrames = 0, lastBase = 0, lastScores = '' }
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

-- does a 12x4 box moving from (ex, ey) meet our box within `frames`. it keeps its velocity, and it falls
-- under gravity once airborne, or once its walk carries it off the end of its row
local function meets(b: Physics.Body, ex: number, ey: number, evx: number, evy: number, grounded: boolean, gravity: number, frames: number): boolean
    local pvx = b.vx / 16
    local rx = b.x + wrapDx(b.x, ex)
    local row = if grounded then Nav.rowAt(ex, ey) else nil
    local fallFrom = if grounded and row ~= nil then math.huge else 0
    if gravity == 0 then
        fallFrom = math.huge -- a fireball weaves on its own, it never falls
    end
    local g = gravity / 16
    for t = 1, frames do
        local px = b.x + pvx * t
        local tx = rx + evx * t
        if row ~= nil and t < fallFrom and not Nav.onRow(Nav.ROWS[row], Stage.wrapX(tx)) then
            fallFrom = t
        end
        local ty = ey
        local pad = 0
        if gravity == 0 then
            -- a fireball weaves 16 px either way around its line, so its whole band counts
            ty = ey + evy * t
            pad = 16
        elseif t >= fallFrom then
            local dt = t - fallFrom
            ty = ey + evy * dt + g * dt * dt / 2
        end
        if World.boxOverlap(px + 4, b.y + 2, 8, 14, tx + 2, ty + 6 - pad, 12, 4 + 2 * pad) then
            return true
        end
    end
    return false
end

local function threatFrom(b: Physics.Body, x: number, y: number, vx: number, vy: number, grounded: boolean, gravity: number): Threat?
    local frames = if gravity == 0 then Npc.FIREBALL_LOOKAHEAD else Npc.LOOKAHEAD
    if not meets(b, x, y, vx, vy, grounded, gravity, frames) then
        return nil
    end
    return { dir = sign(wrapDx(b.x, x)), above = y < b.y - 4, x = x, vx = vx, soon = meets(b, x, y, vx, vy, grounded, gravity, Npc.IMMINENT) }
end

local function findThreat(p: Players.Player, enemies: Enemies.State, fireballs: Fireballs.State): Threat?
    local b = p.body
    for _, e in enemies.list do
        if e.state == Enemies.STATE_NORMAL and e.pipeTimer == 0 then
            local g = if e.kind == 'fly' then Physics.FLY_GRAVITY else Physics.ENEMY_GRAVITY
            local t = threatFrom(b, e.body.x, e.body.y, e.body.vx / 16, e.body.vy / 16, e.onGround, g)
            if t == nil and e.kind == 'fly' and e.onGround then
                -- a resting fly is also about to hop: check that flight too
                t = threatFrom(b, e.body.x, e.body.y, e.body.vx / 16, Physics.FLY_HOP_VY / 16, false, g)
            end
            if t ~= nil then
                return t
            end
        end
    end
    for _, f in fireballs.list do
        -- the sparkle counts too: the flame follows it in a straight line
        local t = threatFrom(b, f.body.x, f.body.y, f.body.vx / 16, f.body.vy / 16, false, 0)
        if t ~= nil then
            return t
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
        if l.from ~= row then
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
            local plan: Plan = { kind = 'escape', row = l.to, x = l.landX, slot = 0, targetRow = l.to }
            best = plan
        end
    end
    return best
end

-- live enemies and fireballs that will be within reach of (row, x) in `frames`, on their current motion
local function danger(row: number, x: number, frames: number, enemies: Enemies.State, fireballs: Fireballs.State, ignore: number, radius: number?): number
    local y = Nav.ROWS[row].y
    local px = radius or Npc.DANGER_PX
    local n = 0
    local function near(ex: number, ey: number, evx: number, grounded: boolean)
        if ey > y + 24 then
            return -- below the spot, it cannot reach us
        end
        local d = wrapDx(x, ex)
        local later = d + evx * frames
        local close = math.abs(d) < px or math.abs(later) < px or sign(d) ~= sign(later)
        if not close then
            return
        end
        if math.abs(ey - y) < 24 then
            n += 1
        elseif ey < y then
            -- above: counts when it is falling, or its walk leaves its row and lands on ours
            local er = if grounded then Nav.rowAt(ex, ey) else nil
            if er == nil or not Nav.onRow(Nav.ROWS[er], Stage.wrapX(ex + evx * frames)) then
                if Nav.rowBelow(x, ey) == row then
                    n += 1
                end
            end
        end
    end
    for _, e in enemies.list do
        if e.state == Enemies.STATE_NORMAL and e.pipeTimer == 0 and e.slot ~= ignore then
            near(e.body.x, e.body.y, e.body.vx / 16, e.onGround)
        end
    end
    for _, f in fireballs.list do
        near(f.body.x, f.body.y, f.body.vx / 16, false)
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

-- where an airborne enemy comes down (a fly's hop, a flipped one's bounce): the row, x and frames until
-- it lands. one on the ground is already there
local function flyLanding(e: Enemies.Enemy): (number?, number, number)
    if e.onGround then
        return Nav.rowAt(e.body.x, e.body.y), e.body.x, 0
    end
    local x, y = e.body.x, e.body.y
    local vx, vy = e.body.vx / 16, e.body.vy / 16
    local g = (if e.kind == 'fly' then Physics.FLY_GRAVITY else Physics.ENEMY_GRAVITY) / 16
    for t = 1, 120 do
        vy += g
        local ny = y + vy
        x = Stage.wrapX(x + vx)
        if vy > 0 then
            for i, r in Nav.ROWS do
                if y <= r.y and ny >= r.y and Nav.onRow(r, x) then
                    return i, x, t
                end
            end
        end
        y = ny
    end
    return nil, 0, 0
end

-- the row under the block a target at (x, y) on row `er` stands on, and the player x to bump it from:
-- the nearest row below from which a foot can be on the row while the head is in the block
local function underSpot(x: number, y: number, er: number): (number?, number)
    local bx = blockUnder(x)
    local best: number? = nil
    local bestSpot = 0
    for i, r in Nav.ROWS do
        if r.y > y and (best == nil or r.y < Nav.ROWS[best].y) and Nav.bumpFrames(i, er) ~= nil then
            local spot = Nav.spotFor(i, bx)
            if spot ~= nil then
                best = i
                bestSpot = spot
            end
        end
    end
    return best, bestSpot
end

-- where a walker on row `er` can next be bumped from below: the first block along its walk (up to
-- 160 px ahead) with a row under it that a jump reaches. returns the row below and the block, or nil
local function flipSpot(e: Enemies.Enemy, er: number): (number?, number, number)
    local steps = if e.kind == 'fly' then 0 else 20
    local dir = if e.body.vx < 0 then -1 else 1
    -- still in the pipe: nothing touches it until it is out, so start one block past where it comes out,
    -- the exit block's bounce would carry it off the block
    local start = e.body.x + dir * (e.pipeTimer * Physics.ENEMY_PIPE_VX / 16 + 8)
    local row = er
    local y = e.body.y
    for k = 0, steps do
        local x = Stage.wrapX(start + dir * k * 8)
        if not Nav.onRow(Nav.ROWS[row], x) then
            -- off the end: it drops to the first row under and keeps walking, plan for that row too
            local under = Nav.rowBelow(x, y)
            if under == nil or under == Nav.FLOOR then
                break
            end
            row = under
            y = Nav.ROWS[under].y
        end
        local below, spot = underSpot(x, y, row)
        if below ~= nil then
            -- a walker must still be on its way into the block, flipped on entry it comes down on it
            local bx = blockUnder(x)
            local entering = if e.kind == 'fly' then true elseif dir > 0 then wrapDx(bx, e.body.x) < 0 else wrapDx(bx, e.body.x) >= 0
            if entering then
                return below, spot, row
            end
        end
    end
    return nil, 0, er
end

-- where a player comes down: the row, x and frames, for one in the air (keeping their motion, jump held
-- while rising), or where they stand
local function playerLanding(h: Players.Player): (number?, number, number)
    if h.onGround then
        return Nav.rowAt(h.body.x, h.body.y), h.body.x, 0
    end
    local w = World.new()
    local p = Sim.copy(h)
    local v = h.body.vx
    local dir = if v >= 4 then 1 elseif v <= -4 then -1 else 0
    for t = 1, 90 do
        Players.update(p, w, intent(dir, math.abs(v) > Physics.WALK_MAX, p.body.vy < 0 and h.jumped))
        if p.onGround then
            return Nav.rowAt(p.body.x, p.body.y), p.body.x, t
        end
    end
    return nil, 0, 0
end

-- frames a player needs to reach a spot, from where they land if in the air. a grounded one not already
-- moving the way their route starts gets a reaction time added, one moving the other way twice that: a
-- trip they have not begun is longer than the map says. nil for one out of the round
local function playerTrip(h: Players.Player, row: number, x: number): number?
    if h.state ~= Players.STATE_NORMAL or h.halt > 0 then
        return nil
    end
    local hr, hx, ht = playerLanding(h)
    if hr == nil then
        return nil
    end
    local trip = ht + Nav.travel(hr, hx, row, x)
    if h.onGround then
        local step = Nav.step(hr, hx, row, x)
        if step ~= nil then
            local dx = Nav.dx(hr, hx, step.x)
            local way = if math.abs(dx) > 2 then sign(dx) else step.dir
            local v = h.body.vx / 16
            if way ~= 0 and math.abs(v) < 0.5 then
                trip += Npc.REACTION
            elseif way ~= 0 and sign(v) ~= way then
                trip += 2 * Npc.REACTION
            end
        end
    end
    return trip
end

-- frames the other players need to reach a spot, the nearest of them
local function rivalTravel(brain: Brain, players: { Players.Player }, row: number, x: number): number
    local best = math.huge
    for i, h in players do
        if i ~= brain.index then
            local trip = playerTrip(h, row, x)
            if trip ~= nil then
                best = math.min(best, trip)
            end
        end
    end
    return best
end

-- does a bounced block throw a player whose centre is at cx away from ex, with `margin` px of the centre
-- still in that half either way: the half of the block it is over decides (PRG009_A58D, the same rule as
-- Players.update), and a landing spot is only a guess to a few px
local function throwsAway(cx: number, ex: number, margin: number): boolean
    local half = cx % 16
    local away = sign(wrapDx(ex, cx))
    if away > 0 then
        return half >= 8 + margin
    end
    return half < 8 - margin
end

-- the block whose bounce catches a rival on their way to a downed enemy at (er, ex), the rival's feet on it
-- soonest after we can be under it: the block has a row under it we reach, jump included, before they get
-- there. the enemy's own block is worth a little lateness (it rights the enemy too) and throws them
-- wherever; another block must throw them back, not onto the enemy, so one they land on the wrong half
-- of is skipped. returns the block, the row under it and the spot, or nil when none is in time
local function guardBlock(brain: Brain, b: Physics.Body, players: { Players.Player }, er: number, ex: number): (number?, number, number)
    local row = brain.lastRow
    local ey = Nav.ROWS[er].y
    local bestBlock: number? = nil
    local bestBelow, bestSpot = 0, 0
    local bestMargin = -math.huge
    for i, h in players do
        if i == brain.index or h.state ~= Players.STATE_NORMAL or h.halt > 0 then
            continue
        end
        local hr, hx, ht = playerLanding(h)
        if hr == nil then
            continue
        end
        local entryX, entryFrames = Nav.approach(hr, hx, er, ex)
        -- the blocks their feet cross from where they arrive on the row to the enemy, the enemy's own last
        local dir = sign(Nav.dx(er, entryX, ex))
        if dir == 0 then
            dir = 1
        end
        local from = blockUnder(entryX)
        local to = blockUnder(ex)
        local n = math.abs(Nav.dx(er, from, to)) // 16
        for k = 0, n do
            local bx = Stage.wrapX(from + dir * k * 16)
            local below, spot = underSpot(bx + 4, ey, er)
            if below == nil then
                continue
            end
            local hit = Nav.bumpFrames(below, er) or 0
            local theirs = ht + entryFrames + math.abs(Nav.dx(er, entryX, bx + 4)) / Nav.RUN_PX
            local mine = Nav.travel(row, b.x, below, spot) + hit
            local margin = theirs + Npc.GUARD_SLACK - mine
            if bx == to then
                margin += 2 * Npc.GUARD_SLACK
            elseif k == 0 and (not h.onGround or entryFrames > 0) and not throwsAway(entryX + 8, ex, Npc.THROW_MARGIN) then
                continue -- they land on this block's near half: the bounce would throw them onto the enemy
            end
            if margin >= 0 and margin > bestMargin then
                bestMargin = margin
                bestBlock, bestBelow, bestSpot = bx, below, spot
            end
        end
    end
    return bestBlock, bestBelow, bestSpot
end

local function choose(brain: Brain, p: Players.Player, w: World.State, enemies: Enemies.State, fireballs: Fireballs.State, players: { Players.Player }): Plan
    local b = p.body
    local row = brain.lastRow
    local bestScore = -math.huge
    local best: Plan? = nil
    if p.blue then
        -- the target: no more coins to chase, only the other players to keep away from. the spot the
        -- nearest rival needs longest to reach, our own trip counted against it
        local spots: { { number } } = {}
        for _, post in Npc.POSTS do
            table.insert(spots, post)
        end
        for r, seg in Nav.ROWS do
            local width = seg.x1 - seg.x0
            for k = 1, 3 do
                table.insert(spots, { r, Stage.wrapX(seg.x0 + width * k // 4) })
            end
        end
        for _, spot in spots do
            local sr, sx = spot[1], spot[2]
            local theirs = math.huge
            for i, h in players do
                if i ~= brain.index and h.state == Players.STATE_NORMAL and h.halt == 0 then
                    local hr, hx, ht = playerLanding(h)
                    if hr ~= nil then
                        theirs = math.min(theirs, ht + Nav.travel(hr, hx, sr, sx))
                    end
                end
            end
            if theirs == math.huge then
                theirs = Npc.FAR
            end
            local mine = Nav.travel(row, b.x, sr, sx)
            if mine < Npc.FAR then
                local danger_ = danger(sr, sx, mine + Npc.DANGER_FRAMES, enemies, fireballs, 0)
                local score = math.min(theirs, Npc.FAR) / 2 - mine / 4 - Npc.DANGER_COST * danger_
                if score > bestScore then
                    bestScore = score
                    local flee: Plan = { kind = 'flee', row = sr, x = sx, slot = 0, targetRow = sr }
                    best = flee
                end
            end
        end
        local fled = best
        if fled ~= nil then
            return fled
        end
    end
    -- every spot is worth less the longer the trip, the more live enemies it will have around it, and
    -- when a rival gets there first (a kick is theirs then, a flip is a gift to them)
    local function offer(value: number, plan: Plan)
        local travel = Nav.travel(row, b.x, plan.row, plan.x)
        if travel >= Npc.FAR then
            return
        end
        local ignore = if plan.kind == 'flip' or plan.kind == 'kick' then plan.slot else 0
        local score = value - travel / 4 - Npc.DANGER_COST * danger(plan.row, plan.x, travel + Npc.DANGER_FRAMES, enemies, fireballs, ignore)
        local held = brain.plan
        if held ~= nil and held.kind == plan.kind and held.slot == plan.slot and plan.kind ~= 'post' then
            score += Npc.KEEP_BONUS -- the plan in hand keeps a little credit, a trip half made is not thrown away for a sliver
        end
        if plan.kind == 'kick' or plan.kind == 'flip' then
            local rival = rivalTravel(brain, players, plan.row, plan.x)
            if plan.kind == 'kick' and rival < travel then
                score -= 70
            elseif plan.kind == 'flip' and rival < travel then
                score -= 20
            end
        end
        if score > bestScore then
            bestScore = score
            best = plan
        end
    end

    local grounded = 0
    for _, e in enemies.list do
        if e.state == Enemies.STATE_DYING then
            continue
        end
        local er = enemyRow(e)
        if e.pipeTimer > 0 then
            -- still in a pipe: it will walk out onto this row, be under its path already
            if er ~= nil and e.state == Enemies.STATE_NORMAL then
                local below, bx, onRow = flipSpot(e, er)
                if below ~= nil then
                    offer(50, { kind = 'flip', row = below, x = bx, slot = e.slot, targetRow = onRow })
                end
            end
            continue
        end
        if e.state == Enemies.STATE_FLIPPED then
            -- still bouncing from the hit: plan for where it lands
            local lr, lx, _ = flyLanding(e)
            if lr ~= nil then
                local travel = Nav.travel(row, b.x, lr, lx)
                local remaining = e.getUpTimer * 2
                if not brain.hunt and remaining > travel + Npc.KICK_MARGIN then
                    offer(100 + (if e.last then 20 else 0), { kind = 'kick', row = lr, x = lx, slot = e.slot, targetRow = lr })
                end
                -- the human closer to it than we are, or simply near it: sit under its block and right it as
                -- they reach for it. their death ends the round, so near them this beats the kick
                local rival = rivalTravel(brain, players, lr, lx)
                local current = brain.plan
                local waited = current ~= nil and current.kind == 'deny' and current.slot == e.slot and brain.denyFrames > Npc.DENY_PATIENCE
                if waited and not brain.hunt then
                    offer(115, { kind = 'kick', row = lr, x = lx, slot = e.slot, targetRow = lr }) -- they are not coming, take it
                elseif lr ~= Nav.FLOOR and (brain.hunt or rival < travel or rival < Npc.RIVAL_NEAR) then
                    local value = if brain.hunt then 95 elseif rival < Npc.RIVAL_NEAR then 110 else 85
                    -- the block we can be under in time on their way to it, its own when there is time for that
                    local gb, gBelow, gSpot = guardBlock(brain, b, players, lr, lx)
                    if gb ~= nil then
                        offer(value, { kind = 'deny', row = gBelow, x = gSpot, slot = e.slot, targetRow = lr, block = gb })
                    end
                end
            end
        elseif e.state == Enemies.STATE_NORMAL then
            if er ~= nil then
                grounded += 1
            end
            if brain.hunt then
                -- a downed enemy is a harmless one: leave the walkers alive
            elseif e.kind == 'fly' then
                -- a fly is flipped where it lands: be under that block when it touches down
                local lr, lx, _ = flyLanding(e)
                if lr ~= nil and lr ~= Nav.FLOOR then
                    local below, spot = underSpot(lx, Nav.ROWS[lr].y, lr)
                    if below ~= nil then
                        offer(60, { kind = 'flip', row = below, x = spot, slot = e.slot, targetRow = lr })
                    end
                end
            elseif er ~= nil and er ~= Nav.FLOOR then
                local below, bx, onRow = flipSpot(e, er)
                if below ~= nil then
                    offer(60, { kind = 'flip', row = below, x = bx, slot = e.slot, targetRow = onRow })
                end
            end
        end
    end

    if Stage.powRect(w.powHits) ~= nil and w.powCnt == 0 then
        if brain.hunt then
            -- hunting: the pow stuns a grounded human and rights every downed enemy, worth it when they are grounded
            local downed = 0
            for _, e in enemies.list do
                if e.state == Enemies.STATE_FLIPPED then
                    downed += 1
                end
            end
            for i, h in players do
                if i ~= brain.index and h.state == Players.STATE_NORMAL and h.onGround then
                    offer(40 + 40 * downed - 20 * grounded, { kind = 'pow', row = Nav.FLOOR, x = Npc.POW_X, slot = 0, targetRow = Nav.FLOOR })
                end
            end
        elseif grounded >= 2 then
            offer(30 * grounded, { kind = 'pow', row = Nav.FLOOR, x = Npc.POW_X, slot = 0, targetRow = Nav.FLOOR })
        end
    end

    -- the trap: a human going for a downed enemy, and the pow rights it under their feet. a kill ends the round.
    -- one on its row, or coming down onto it, is worth the most; one still on the way is worth waiting for
    -- under the pow when we get there first
    if Stage.powRect(w.powHits) ~= nil and w.powCnt == 0 then
        local powTrip = Nav.travel(row, b.x, Nav.FLOOR, Npc.POW_X)
        for i, h in players do
            if i == brain.index or h.state ~= Players.STATE_NORMAL or h.halt > 0 then
                continue
            end
            local hr, hx, _ = playerLanding(h)
            if hr == nil then
                continue
            end
            for _, e in enemies.list do
                if e.state ~= Enemies.STATE_FLIPPED or not e.onGround then
                    continue
                end
                local er = enemyRow(e)
                if er == nil then
                    continue
                end
                -- only when we are under the pow before they are on it
                local theirs = playerTrip(h, er, e.body.x) or math.huge
                if theirs < Npc.TRAP_FAR and powTrip + Npc.POW_FRAMES <= theirs then
                    local onIt = hr == er and math.abs(wrapDx(hx, e.body.x)) < 80
                    offer(if brain.hunt then (if onIt then 95 else 85) else (if onIt then 90 else 80), { kind = 'trap', row = Nav.FLOOR, x = Npc.POW_X, slot = e.slot, targetRow = i })
                end
            end
        end
    end

    for i, h in players do
        if i == brain.index or h.state ~= Players.STATE_NORMAL then
            continue
        end
        local hr = if h.onGround then Nav.rowAt(h.body.x, h.body.y) else nil
        if h.blue and h.side and hr ~= nil then
            -- the target on his side: touch him and his coins are ours (worth more the more he holds)
            offer(110 + 30 * (brain.coins[i] or 0), { kind = 'kick', row = hr, x = h.body.x, slot = -i, targetRow = hr })
            continue
        end
        if h.blue and h.invincible == 0 and not p.blue then
            -- the target standing: a stomp lays him down, the surest way; so does the pow while he is grounded
            local sr, sx, _ = playerLanding(h)
            if sr ~= nil then
                offer(100 + 20 * (brain.coins[i] or 0), { kind = 'stomp', row = sr, x = sx, slot = i, targetRow = sr })
            end
            if h.onGround and Stage.powRect(w.powHits) ~= nil and w.powCnt == 0 then
                offer(70 + 10 * (brain.coins[i] or 0), { kind = 'pow', row = Nav.FLOOR, x = Npc.POW_X, slot = 0, targetRow = Nav.FLOOR })
            end
        end
        if hr ~= nil and hr ~= Nav.FLOOR then
            local below, spot = underSpot(h.body.x, h.body.y, hr)
            if below ~= nil then
                local near = false
                for _, e in enemies.list do
                    if e.state == Enemies.STATE_NORMAL and e.pipeTimer == 0 and enemyRow(e) == hr and math.abs(wrapDx(h.body.x, e.body.x)) < 40 then
                        near = true
                    end
                end
                local value = if near then 100 else 10
                if brain.hunt then
                    value = if near then 140 else 90
                end
                if h.blue then
                    value = math.max(value, 80 + 20 * (brain.coins[i] or 0)) -- a stun lays the target down for the taking
                end
                offer(value, { kind = 'bump', row = below, x = spot, slot = i, targetRow = hr })
            end
        end
        if h.dizzy > 0 and hr == row and math.abs(Nav.dx(row, b.x, h.body.x)) < 48 then
            offer(if brain.hunt then 60 else 25, { kind = 'stomp', row = row, x = h.body.x, slot = i, targetRow = row })
        end
        if brain.hunt and hr ~= nil then
            -- stick to them: a shove, a stomp, a block in their way, whatever the look ahead finds
            offer(20, { kind = 'shadow', row = hr, x = h.body.x, slot = i, targetRow = hr })
        end
    end

    for _, spot in Npc.POSTS do
        offer(0, { kind = 'post', row = spot[1], x = spot[2], slot = 0, targetRow = spot[1] })
    end
    if #enemies.list == 0 then
        -- the pipes alternate, left first: be under the block the next one is flipped from and kept on, the
        -- centre platform's edge (the stub is earlier but the bounce carries the enemy off its block)
        local side = enemies.count % 2
        local ex = if side == 0 then Stage.SPAWN_X[1] + 32 else Stage.SPAWN_X[2] - 32
        local spawnRow = Nav.rowAt(ex, Stage.SPAWN_Y)
        if spawnRow ~= nil then
            local below, spot = underSpot(ex, Stage.SPAWN_Y, spawnRow)
            if below ~= nil then
                offer(45, { kind = 'post', row = below, x = spot, slot = 0, targetRow = below })
            end
        end
    end
    local chosen = best -- a plain local narrows, the upvalue the offers write does not
    if chosen == nil then
        return { kind = 'post', row = Nav.FLOOR, x = Npc.POW_X - 40, slot = 0, targetRow = Nav.FLOOR }
    end
    return chosen
end

-- is the current plan still about something real
local function valid(brain: Brain, plan: Plan, p: Players.Player, w: World.State, enemies: Enemies.State, players: { Players.Player }): boolean
    if plan.kind == 'kick' then
        if plan.slot < 0 then
            local h = players[-plan.slot]
            return h.state == Players.STATE_NORMAL and h.blue and h.side and Nav.rowAt(h.body.x, h.body.y) == plan.targetRow
        end
        local e = findEnemy(enemies, plan.slot)
        if e == nil or e.state ~= Enemies.STATE_FLIPPED or e.getUpTimer * 2 <= Npc.KICK_MARGIN then
            return false
        end
        local lr, _, _ = flyLanding(e)
        return lr == plan.targetRow
    elseif plan.kind == 'flip' then
        local e = findEnemy(enemies, plan.slot)
        if e == nil or e.state ~= Enemies.STATE_NORMAL then
            return false
        end
        if e.kind == 'fly' then
            local lr, _, _ = flyLanding(e)
            return lr == plan.targetRow
        end
        -- a walker still on its way down to the target row is fine, one that went elsewhere is not
        local er = enemyRow(e)
        return not e.onGround or er == plan.targetRow or (er ~= nil and Nav.ROWS[er].y < Nav.ROWS[plan.targetRow].y)
    elseif plan.kind == 'pow' then
        return Stage.powRect(w.powHits) ~= nil and w.powCnt == 0
    elseif plan.kind == 'deny' then
        local e = findEnemy(enemies, plan.slot)
        if e == nil or e.state ~= Enemies.STATE_FLIPPED or e.getUpTimer * 2 <= Npc.KICK_MARGIN then
            return false
        end
        local lr, _, _ = flyLanding(e)
        return lr == plan.targetRow
    elseif plan.kind == 'shadow' then
        return players[plan.slot].state == Players.STATE_NORMAL
    elseif plan.kind == 'trap' then
        local e = findEnemy(enemies, plan.slot)
        local h = players[plan.targetRow]
        if Stage.powRect(w.powHits) == nil or w.powCnt > 0 or e == nil or e.state ~= Enemies.STATE_FLIPPED or h.state ~= Players.STATE_NORMAL then
            return false
        end
        local er = enemyRow(e)
        return er ~= nil and rivalTravel(brain, players, er, e.body.x) < Npc.TRAP_FAR
    elseif plan.kind == 'escape' then
        return brain.lastRow ~= plan.row
    elseif plan.kind == 'flee' then
        return true
    elseif plan.kind == 'bump' then
        local h = players[plan.slot]
        return h.state == Players.STATE_NORMAL and (not h.onGround or Nav.rowAt(h.body.x, h.body.y) == plan.targetRow)
    elseif plan.kind == 'stomp' then
        local h = players[plan.slot]
        return h.state == Players.STATE_NORMAL and (h.dizzy > 0 or (h.blue and not h.side))
    end
    return true
end

-- jump now if the target's feet will be on our block while it bounces (14 frames from the hit). with `keep`
-- (a flip we mean to follow up) the hit must land as the walker steps onto the block, one foot on: it is
-- then thrown back the way it came (Vs_EnemyHandleHitUnder drifts it away from the hit side) and comes
-- down on the block it just left, next to us. flipped on the way out it lands a block on, a gift to
-- whoever waits there
local function bumpNow(brain: Brain, plan: Plan, b: Physics.Body, tx: number, tvx: number, keep: boolean): boolean
    local hit = Nav.bumpFrames(plan.row, plan.targetRow)
    if hit == nil then
        return false
    end
    local bx = blockUnder(plan.x)
    if keep and tvx ~= 0 then
        local d = wrapDx(bx, tx + tvx * hit)
        return if tvx > 0 then (d >= -8 and d < 0) else (d >= 0 and d < 8)
    end
    for t = hit, hit + World.BLOCK_FRAMES - 1 do
        local ex = tx + tvx * t
        local l, r = wrapDx(bx, ex + 4), wrapDx(bx, ex + 12)
        if (l >= 0 and l < 16) or (r >= 0 and r < 16) then
            return true
        end
    end
    return false
end

-- is the air above us clear of live enemies and fireballs, so a jump does not rise into one
local function columnClear(b: Physics.Body, enemies: Enemies.State, fireballs: Fireballs.State): boolean
    for _, e in enemies.list do
        -- a walker on the platform above is behind that platform; an airborne one is in our air
        local airborne = not e.onGround or e.kind == 'fly'
        if e.state == Enemies.STATE_NORMAL and e.pipeTimer == 0 and airborne and math.abs(wrapDx(b.x, e.body.x)) < 28 and e.body.y >= b.y - 80 and e.body.y < b.y + 8 then
            return false
        end
    end
    for _, f in fireballs.list do
        if f.pose == 'flying' and math.abs(wrapDx(b.x, f.body.x)) < 32 and f.body.y >= b.y - 80 and f.body.y < b.y + 8 then
            return false
        end
    end
    return true
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
        local clear = danger(toRow, landX, frames, enemies, fireballs, 0, Npc.LAND_PX) == 0 and columnClear(b, enemies, fireballs)
        if not clear and danger(row, b.x, Npc.LOOKAHEAD, enemies, fireballs, 0) > 0 then
            brain.replanIn = 0 -- waiting here is no better than the landing, find something else
        end
        if step.kind == 'jump' then
            if Nav.inWindow(row, b.x, step) then
                if not clear then
                    return intent(0, false, false)
                end
                return jump(brain, step.dir, 60)
            end
            -- the walk stops within 2 px of its target; a step short of the window is walked, not waited out
            local dx = Nav.dx(row, b.x, step.x)
            if math.abs(dx) <= 2 then
                return intent(sign(dx), false, false)
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
        local tx = 0
        if plan.slot < 0 then
            tx = players[-plan.slot].body.x
        else
            local e = findEnemy(enemies, plan.slot)
            if e == nil then
                return intent(0, false, false)
            end
            tx = e.body.x
        end
        local dx = Nav.dx(row, b.x, tx)
        return intent(if dx ~= 0 then sign(dx) else p.dir, math.abs(dx) > 8, false)
    elseif plan.kind == 'flip' or plan.kind == 'bump' then
        if math.abs(Nav.dx(row, b.x, plan.x)) > 2 or not stopped(b) then
            return moveTo(row, b, plan.x)
        end
        local tx, tvx = 0, 0
        if plan.kind == 'flip' then
            local e = findEnemy(enemies, plan.slot)
            if e == nil then
                return intent(0, false, false)
            end
            if e.kind == 'fly' then
                -- jump so the block bounces while it rests on it, or as it lands on it
                local hit = Nav.bumpFrames(plan.row, plan.targetRow) or 0
                local lr, lx, lt = flyLanding(e)
                local onBlock = lr == plan.targetRow and math.abs(wrapDx(plan.x, lx)) <= 11
                local timed = if e.onGround then e.getUpTimer >= hit + 2 else (lt >= hit - 1 and lt <= hit + 12)
                if onBlock and timed and columnClear(b, enemies, fireballs) then
                    return jump(brain, 0, hit + 2)
                end
                return intent(0, false, false)
            end
            if not e.onGround then
                return intent(0, false, false)
            end
            tx = e.body.x
            tvx = e.body.vx / 16
        else
            local h = players[plan.slot]
            if not h.onGround then
                return intent(0, false, false)
            end
            tx = h.body.x
            tvx = h.body.vx / 16
        end
        if bumpNow(brain, plan, b, tx, tvx, plan.kind == 'flip') and columnClear(b, enemies, fireballs) then
            local hit = Nav.bumpFrames(plan.row, plan.targetRow) or 0
            return jump(brain, 0, hit + 2)
        end
        return intent(0, false, false)
    elseif plan.kind == 'deny' then
        if math.abs(Nav.dx(row, b.x, plan.x)) > 2 or not stopped(b) then
            return moveTo(row, b, plan.x)
        end
        brain.denyFrames += 1
        local e = findEnemy(enemies, plan.slot)
        if e == nil or not e.onGround then
            return intent(0, false, false)
        end
        -- the nearest other player heading for it: jump so the block bounces as they touch, or as their feet
        -- come down on it. one that lingers next to it, waiting for us to leave, gets it righted at them once
        -- our patience is out. under a block on their way rather than the enemy's, jump as they step onto it
        local hit = Nav.bumpFrames(plan.row, plan.targetRow) or 0
        local bx = blockUnder(plan.x)
        local own = plan.block == nil or plan.block == blockUnder(e.body.x)
        for i, h in players do
            if i == brain.index or h.state ~= Players.STATE_NORMAL then
                continue
            end
            if not h.onGround then
                -- coming down onto the block: bounce it under their landing
                local lr, lx, lt = playerLanding(h)
                if lr == plan.targetRow and lt >= hit - 1 and lt <= hit + 12 then
                    local l, r = wrapDx(bx, lx + 4), wrapDx(bx, lx + 12)
                    local onBlock = (l >= 0 and l < 16) or (r >= 0 and r < 16)
                    local nearEnemy = own and math.abs(wrapDx(lx, e.body.x)) - 16 <= Npc.TRAP_REACH
                    local away = own or throwsAway(lx + 8, e.body.x, Npc.THROW_MARGIN)
                    if (onBlock or nearEnemy) and away and columnClear(b, enemies, fireballs) then
                        return jump(brain, 0, hit + 2)
                    end
                end
                continue
            end
            if math.abs(h.body.y - e.body.y) > 8 then
                continue
            end
            if not own then
                -- bounce it as their centre crosses the far half, so the throw sends them back
                local cx = h.body.x + h.body.vx / 16 * hit + 8
                local d = wrapDx(bx, cx)
                if d >= 0 and d < 16 and throwsAway(cx, e.body.x, 1) and columnClear(b, enemies, fireballs) then
                    return jump(brain, 0, hit + 2)
                end
                continue
            end
            local d = wrapDx(h.body.x, e.body.x)
            local gap = math.abs(d) - 16
            local v = h.body.vx / 16
            local closing = sign(v) == sign(d) and math.abs(v) > 0.2
            local tt = if closing then gap / math.abs(v) else math.huge
            local lingering = brain.denyFrames > Npc.DENY_PATIENCE and gap <= Npc.LINGER_PX
            if gap <= 2 or (tt >= hit - 1 and tt <= hit + 12) or lingering then
                if columnClear(b, enemies, fireballs) then
                    return jump(brain, 0, hit + 2)
                end
            end
        end
        return intent(0, false, false)
    elseif plan.kind == 'pow' or plan.kind == 'trap' then
        if math.abs(Nav.dx(row, b.x, plan.x)) > 2 or not stopped(b) then
            return moveTo(row, b, plan.x)
        end
        if not columnClear(b, enemies, fireballs) then
            return intent(0, false, false)
        end
        if plan.kind == 'trap' then
            -- wait under the pow until the human is a step from the downed enemy, or about to come down next
            -- to it, then punch: the pow takes POW_FRAMES to reach from the floor
            local e = findEnemy(enemies, plan.slot)
            local h = players[plan.targetRow]
            if e == nil then
                return intent(0, false, false)
            end
            if not h.onGround then
                local lr, lx, lt = playerLanding(h)
                local er = enemyRow(e)
                if lr ~= nil and lr == er and math.abs(wrapDx(lx, e.body.x)) - 16 <= Npc.TRAP_REACH and lt <= Npc.POW_FRAMES + 1 then
                    return jump(brain, 0, 1)
                end
                return intent(0, false, false)
            end
            local d = wrapDx(h.body.x, e.body.x)
            local closing = sign(h.body.vx) == sign(d)
            if math.abs(d) - 16 > Npc.TRAP_REACH or (not closing and math.abs(d) - 16 > 4) then
                return intent(0, false, false)
            end
        end
        return jump(brain, 0, 1)
    elseif plan.kind == 'shadow' then
        return moveTo(row, b, players[plan.slot].body.x)
    elseif plan.kind == 'stomp' then
        local h = players[plan.slot]
        local hr = Nav.rowAt(h.body.x, h.body.y)
        if hr ~= nil and hr ~= row then
            -- on another row: get to his, the trip is the same as to any spot there
            local step = Nav.step(row, b.x, hr, h.body.x)
            if step ~= nil and step.kind == 'move' then
                return moveTo(row, b, step.x)
            end
        end
        local dx = Nav.dx(row, b.x, h.body.x)
        if math.abs(dx) < 20 and math.abs(h.body.y - b.y) <= 8 then
            return jump(brain, sign(dx), 8)
        end
        return moveTo(row, b, h.body.x)
    end
    return moveTo(row, b, plan.x)
end

-- the policy: threats first, then the plan. one frame of the hand written player, no look ahead.
-- with replan false (inside a rollout) the plan is kept unless it has become impossible
local function policy(brain: Brain, p: Players.Player, w: World.State, enemies: Enemies.State, fireballs: Fireballs.State, players: { Players.Player }, replan: boolean): Input.Intent
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
        -- airborne: finish the move the brain started; thrown up by a stun or a stomp, steer clear of what is coming
        if brain.jumping then
            brain.jumpHold -= 1
            return intent(brain.airDir, true, brain.jumpHold > 0)
        end
        local threat = findThreat(p, enemies, fireballs)
        if threat ~= nil then
            return intent(if threat.dir == 0 then -p.dir else -threat.dir, true, false)
        end
        return Input.NONE
    end

    local threat = findThreat(p, enemies, fireballs)
    local escaping = brain.plan ~= nil and (brain.plan :: Plan).kind == 'escape'
    if threat ~= nil and (threat.soon or not escaping) then
        local away = if threat.dir == 0 then -p.dir else -threat.dir
        local gap = math.abs(wrapDx(b.x, threat.x)) - 16
        local toward = sign(threat.vx) == -threat.dir
        if threat.above then
            brain.evadeFrames = Npc.EVADE_FRAMES
            brain.evadeDir = away
        elseif not toward and gap >= 28 then
            -- it walks away ahead of us and we are the one closing: ease off and follow at a distance
            brain.evadeFrames = 0
            return intent(0, false, false)
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
    if current == nil or (replan and brain.replanIn <= 0) or not valid(brain, current, p, w, enemies, players) then
        plan = choose(brain, p, w, enemies, fireballs, players)
        if current == nil or plan.kind ~= current.kind or plan.slot ~= current.slot then
            brain.denyFrames = 0
        end
        brain.plan = plan
        brain.replanIn = Npc.REPLAN_FRAMES
    else
        plan = current
    end
    return execute(brain, plan, p, w, enemies, fireballs, players)
end

-- what a human will most likely keep doing: the same thing
local function humanIntent(h: Players.Player): Input.Intent
    local v = h.body.vx
    local dir = if v >= 4 then 1 elseif v <= -4 then -1 else 0
    return intent(dir, math.abs(v) > Physics.WALK_MAX, not h.onGround and h.body.vy < 0)
end

local MACROS: { Input.Intent } = {
    intent(0, false, false),
    intent(-1, true, false),
    intent(1, true, false),
    intent(0, false, true),
    intent(-1, true, true),
    intent(1, true, true),
}

-- run the battle forward from here: `macro` held for MACRO_FRAMES then the policy, the other players on
-- their own policy or their current motion. returns how good the stretch was for brain.index
local function rollout(brain: Brain, macro: Input.Intent?, hold: number, w: World.State, enemies: Enemies.State, fireballs: Fireballs.State, players: { Players.Player }, brains: { Brain }?): number
    local snap = Sim.snapshot(w, enemies, fireballs, players)
    local me = brain.index
    for i, c in brain.coins do
        snap.coins[i] = c
    end
    local hunt = brain.hunt
    local minds: { [number]: Brain } = {}
    for i, p in snap.players do
        if i == me then
            minds[i] = Sim.copy(brain)
        elseif Players.isNpc(p) and brains ~= nil and brains[i] ~= nil and Players.active(players) <= 2 then
            minds[i] = Sim.copy(brains[i]) -- in a bigger round the other cpus keep their motion, a policy each is too dear
        end
    end
    local score = 0
    for t = 1, Npc.HORIZON do
        local intents: { Input.Intent } = {}
        for i, p in snap.players do
            local mind = minds[i]
            if i == me and macro ~= nil and t <= hold then
                intents[i] = macro
            elseif mind ~= nil then
                intents[i] = policy(mind, p, snap.w, snap.s, snap.f, snap.players, false)
            else
                intents[i] = humanIntent(p)
            end
        end
        local ev = Sim.step(snap, intents)
        for _, dead in ev.killed do
            if dead == me then
                return Npc.DEATH + t
            end
        end
        for _, i in ev.turnedBlue do
            score += if i == me then -300 else 60 -- the target is a walking coin purse, and it is bad to be one
        end
        for _, i in ev.sided do
            if i == me then
                score -= 500 -- on our side we are a coin purse on the floor
            end
        end
        if snap.players[me].blue then
            -- the target keeps its distance from every rival
            local mine_ = snap.players[me].body
            for i, h in snap.players do
                if i ~= me and h.state == Players.STATE_NORMAL then
                    local d = math.abs(wrapDx(mine_.x, h.body.x)) + math.abs(mine_.y - h.body.y)
                    if d < 64 then
                        score -= (64 - d) / 8
                    end
                end
            end
        end
        for _, hit in ev.beaten do
            if hit[2] == me then
                score += 200 * (brain.coins[hit[1]] or 1)
            end
        end
        if #ev.killed > 0 then
            -- a rival down: the round is ours when nobody else can win, a big step otherwise
            local contenders = Sim.contenders(snap)
            if #contenders <= 1 and (#contenders == 0 or contenders[1] == me) then
                return 5000 - t
            end
            score += 150 * #ev.killed
        end
        if ev.coin == me then
            score += if hunt then -200 else 200 -- hunting, a coin only brings the round's end closer, and it is lost
        elseif ev.coin > 0 then
            score -= 100
        end
        if hunt then
            score += 40 * ev.righted - 40 * ev.flips
        else
            score += 40 * ev.flips
            if ev.righted > 0 then
                -- righted next to a rival it is a threat to them, righted for nothing it is a coin thrown away
                local threat = false
                for i, h in snap.players do
                    if i ~= me and h.state == Players.STATE_NORMAL then
                        for _, e in snap.s.list do
                            if e.state == Enemies.STATE_NORMAL and math.abs(e.body.y - h.body.y) <= 8 and math.abs(wrapDx(h.body.x, e.body.x)) < Npc.LINGER_PX + 16 then
                                threat = true
                            end
                        end
                    end
                end
                score += if threat then 40 * ev.righted else -80 * ev.righted
            end
        end
        for i, stunned in ev.stunned do
            if stunned then
                score += if i == me then -60 elseif hunt then 80 else 30
            end
        end
    end
    -- what is left of the trip to the plan's spot
    local mind = minds[me]
    local plan = mind.plan
    local body = snap.players[me].body
    if plan ~= nil then
        -- from where it stands, or where a jump in progress comes down
        local me_ = snap.players[me]
        local lr, lx, lt = playerLanding(me_)
        if lr ~= nil then
            score -= (lt + Nav.travel(lr, lx, plan.row, plan.x)) / 4
        else
            score -= Nav.travel(mind.lastRow, body.x, plan.row, plan.x) / 4
        end
    end
    return score
end

-- one frame of thought for player brain.index. the policy decides, the rollout checks it survives the next
-- frames and, now and then, whether one of a few plain moves does better; the best move wins
function Npc.think(brain: Brain, p: Players.Player, w: World.State, enemies: Enemies.State, fireballs: Fireballs.State, players: { Players.Player }, brains: { Brain }?, coins: { number }?): Input.Intent
    if p.state ~= Players.STATE_NORMAL then
        return Input.NONE
    end
    brain.frame += 1
    -- the hunt: when no coin left can put us ahead, the only win is their death
    if coins ~= nil then
        brain.coins = coins
        local total = 0
        local best = 0
        for i, c in coins do
            total += c
            if i ~= brain.index and c > best then
                best = c
            end
        end
        local mine = coins[brain.index] or 0
        local hunt = mine + (Npc.COINS_TO_WIN - total) < best and not p.blue
        if hunt ~= brain.hunt then
            brain.hunt = hunt
            brain.plan = nil
        end
    end
    local override = brain.override
    if override ~= nil and brain.overrideLeft > 0 then
        -- keep a chosen move as long as it still comes out alive
        local held = Sim.copy(override)
        if rollout(brain, held, brain.overrideLeft, w, enemies, fireballs, players, brains) > Npc.DEATH + Npc.HORIZON then
            brain.overrideLeft -= 1
            return override
        end
        brain.override = nil
        brain.overrideLeft = 0
    end
    local chosen = policy(brain, p, w, enemies, fireballs, players, true)
    local base = rollout(brain, nil, 0, w, enemies, fireballs, players, brains)
    local doomed = base <= Npc.DEATH + Npc.HORIZON
    brain.lastBase = base
    brain.lastScores = ''
    -- a jump in progress is only second guessed when it ends in a death: reversing mid air on a small
    -- score difference is how a move to the next platform turns into a fall back
    if not doomed and (brain.frame % Npc.SEARCH_EVERY ~= 0 or (not p.onGround and brain.jumping)) then
        return chosen
    end
    -- a short move then the policy; when the policy dies, also each move held the whole way (a long run)
    local best = base
    local bestMacro: Input.Intent? = nil
    local bestHold = 0
    for _, hold in { Npc.MACRO_FRAMES, Npc.HORIZON } do
        if hold == Npc.HORIZON and not doomed then
            break
        end
        for _, macro in MACROS do
            local score = rollout(brain, macro, hold, w, enemies, fireballs, players, brains)
            brain.lastScores ..= string.format(' %s%s%s=%d', if macro.left then 'L' elseif macro.right then 'R' else '.', if macro.jump then 'J' else '', if hold == Npc.HORIZON then '+' else '', math.floor(score))
            if score > best + 20 then
                best = score
                bestMacro = macro
                bestHold = hold
            end
        end
    end
    if bestMacro == nil then
        return chosen
    end
    brain.override = bestMacro
    brain.overrideLeft = bestHold - 1
    return bestMacro
end

-- the stage dependent spots: the pow, and the waiting posts (either side of the pow on the floor, and the middle
-- of each ledge on the lowest row above it, each with room to hop). runs at require and after every Stage.load
function Npc.configure()
    Npc.POW_X = Stage.POW_X
    Npc.POSTS = { { Nav.FLOOR, Stage.POW_X - 20 }, { Nav.FLOOR, Stage.POW_X + 28 } }
    local lowest: number? = nil
    for _, p in Stage.PLATFORMS do
        if p.w < Stage.WIDTH and (lowest == nil or p.y > lowest) then
            lowest = p.y
        end
    end
    if lowest ~= nil then
        for _, p in Stage.PLATFORMS do
            if p.y == lowest then
                local x = Stage.wrapX(p.x + p.w // 2 - 8)
                local row = Nav.rowAt(x, p.y - 16)
                if row ~= nil then
                    table.insert(Npc.POSTS, { row, x })
                end
            end
        end
    end
end

Npc.configure()
Stage.onLoad(Npc.configure)

return Npc
