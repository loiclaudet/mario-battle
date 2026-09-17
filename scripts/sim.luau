--!strict
-- one step of a round, shared by the game and the cpu: scripts/game.luau steps its live state with it and only
-- adds sounds and views from the events; the cpu clones the state (Sim.snapshot) and runs the same function
-- forward, so what it foresees is exactly what happens. the free for all rules live here: a kick is a coin,
-- a death loses the coins and gives them back as enemies, the fourth coin marks the survivors, the fireballs
-- aim at an alive player in turn, every alive pair can bump.
local World = require('scripts/world')
local Players = require('scripts/players')
local Enemies = require('scripts/enemies')
local Fireballs = require('scripts/fireballs')
local Input = require('scripts/input')

local Sim = {}

export type Snap = {
    w: World.State,
    s: Enemies.State,
    f: Fireballs.State,
    players: { Players.Player },
    coins: { number },
    coinSeq: { number }, -- when each player took their latest coin, as a running kick count (ties)
    kickCount: number,
    cooldowns: { [number]: number }, -- Players.bumpEachOther per pair, keyed i * 8 + j
}

-- per player flags are indexed by player. killed lists every player who died this step, refunded how many
-- enemies came back for them; kicks lists every kicker; fireball is a spawn (the sound)
export type Events = {
    killed: { number },
    refunded: number,
    coin: number,
    kicks: { number },
    flips: number,
    righted: number,
    flip: boolean,
    pow: boolean,
    entered: boolean,
    fireball: boolean,
    jumped: { boolean },
    bumped: { boolean },
    stunned: { boolean },
}

Sim.COINS_TO_WIN = 5
Sim.LAST_AT = 4

-- the state tables hold only values and other plain tables, no cycles
local function copy(v: any): any
    if type(v) ~= 'table' then
        return v
    end
    local out = {}
    for k, x in v do
        out[k] = copy(x)
    end
    return out
end
Sim.copy = copy

-- a round state over these live tables: the game builds one once and keeps stepping it
function Sim.live(w: World.State, s: Enemies.State, f: Fireballs.State, players: { Players.Player }): Snap
    local snap: Snap = { w = w, s = s, f = f, players = players, coins = {}, coinSeq = {}, kickCount = 0, cooldowns = {} }
    Sim.resetScore(snap)
    return snap
end

-- coins and ties back to zero, in place (the game's other tables point at these)
function Sim.resetScore(snap: Snap)
    table.clear(snap.coins)
    table.clear(snap.coinSeq)
    table.clear(snap.cooldowns)
    for i = 1, #snap.players do
        snap.coins[i] = 0
        snap.coinSeq[i] = 0
    end
    snap.kickCount = 0
end

function Sim.snapshot(w: World.State, s: Enemies.State, f: Fireballs.State, players: { Players.Player }): Snap
    local snap = Sim.live(copy(w), copy(s), copy(f), copy(players))
    return snap
end

-- a deep copy of a round state
function Sim.clone(snap: Snap): Snap
    return copy(snap)
end

function Sim.total(snap: Snap): number
    local total = 0
    for _, c in snap.coins do
        total += c
    end
    return total
end

-- the player who wins on coins: the most, a tie to whoever reached that count first. 0 when nobody has any
function Sim.leader(snap: Snap): number
    local best = 0
    for i, c in snap.coins do
        if c > 0 and (best == 0 or c > snap.coins[best] or (c == snap.coins[best] and snap.coinSeq[i] < snap.coinSeq[best])) then
            best = i
        end
    end
    return best
end

local function noEvents(n: number): Events
    local ev: Events = { killed = {}, refunded = 0, coin = 0, kicks = {}, flips = 0, righted = 0, flip = false, pow = false, entered = false, fireball = false, jumped = {}, bumped = {}, stunned = {} }
    for i = 1, n do
        ev.jumped[i] = false
        ev.bumped[i] = false
        ev.stunned[i] = false
    end
    return ev
end

-- a player dies: falls off, loses the coins, and that many enemies come back out of the pipes
local function die(snap: Snap, i: number, ev: Events)
    local p = snap.players[i]
    if p.state ~= Players.STATE_NORMAL then
        return
    end
    Players.kill(p)
    table.insert(ev.killed, i)
    local lost = snap.coins[i]
    snap.coins[i] = 0
    snap.coinSeq[i] = 0
    if lost > 0 then
        Enemies.refund(snap.s, lost)
        ev.refunded += lost
    end
end

-- one frame. debugSpawn 1 forces a horizontal fireball, 2 the ender (the --data=debug knobs)
function Sim.step(snap: Snap, intents: { Input.Intent }, debugSpawn: number?): Events
    local w, players = snap.w, snap.players
    local ev = noEvents(#players)
    local downBefore = 0
    for _, e in snap.s.list do
        if e.state == Enemies.STATE_FLIPPED then
            downBefore += 1
        end
    end
    World.update(w)
    for i, p in players do
        local pev = Players.update(p, w, intents[i] or Input.NONE)
        ev.jumped[i] = pev.jump
        ev.bumped[i] = pev.bump
        ev.stunned[i] = pev.stun
        if pev.pow then
            ev.pow = true
        end
    end
    -- every alive pair can stomp or shove, each pair on its own cooldown
    for i = 1, #players do
        for j = i + 1, #players do
            if players[i].state == Players.STATE_NORMAL and players[j].state == Players.STATE_NORMAL then
                local key = i * 8 + j
                local cooldown, stunned = Players.bumpEachOther(players[i], players[j], snap.cooldowns[key] or 0)
                snap.cooldowns[key] = cooldown
                if stunned then
                    for _, k in { i, j } do
                        if players[k].dizzy > 0 then
                            ev.stunned[k] = true
                        end
                    end
                end
            end
        end
    end
    local halted = false
    for _, p in players do
        if p.halt > 0 then
            halted = true
        end
    end
    local eev = Enemies.update(snap.s, w, players, w.frame, halted)
    ev.flip = eev.flip
    ev.entered = eev.entered
    if eev.flip then
        -- a hit from under flips a walker, or rights one that was down: count which
        local downAfter = 0
        for _, e in snap.s.list do
            if e.state == Enemies.STATE_FLIPPED then
                downAfter += 1
            end
        end
        if downAfter > downBefore then
            ev.flips = downAfter - downBefore
        elseif downAfter < downBefore then
            ev.righted = downBefore - downAfter
        end
    end
    for _, i in eev.killed do
        die(snap, i, ev)
    end
    if eev.kick then
        ev.coin = eev.coin
        for _, who in eev.kicks do
            if players[who].state == Players.STATE_NORMAL then
                snap.kickCount += 1
                snap.coins[who] += 1
                snap.coinSeq[who] = snap.kickCount
                table.insert(ev.kicks, who)
            end
        end
    end
    if Sim.total(snap) == Sim.LAST_AT then
        Enemies.markLast(snap.s)
    end
    if debugSpawn == 2 then
        eev.ender = true
    elseif debugSpawn == 1 then
        eev.fireball = true
    end
    if eev.fireball or eev.ender then
        -- level with an alive player in turn, like Vs_Random picking the y
        local alive = Players.alive(players)
        if #alive > 0 then
            local target = players[alive[w.frame % #alive + 1]]
            if eev.ender then
                Fireballs.spawnEnder(snap.f, snap.s.spawnCnt2, target.body.y)
            else
                Fireballs.spawnHorz(snap.f, snap.s.spawnCnt2, target.body.y)
            end
            ev.fireball = true
        end
    end
    local fev = Fireballs.update(snap.f, w, players, w.frame)
    for _, i in fev.killed do
        die(snap, i, ev)
    end
    return ev
end

return Sim
