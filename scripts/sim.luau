--!strict
-- a copy of the whole battle the cpu can run forward: the same modules the game steps, on cloned
-- state, so a brain sees exactly what its next frames do before it commits to them.
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
    bumpCooldown: number,
}

export type Events = { killed: number, coin: number, flips: number, righted: number, pow: boolean, stunned: { boolean } }

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

function Sim.snapshot(w: World.State, s: Enemies.State, f: Fireballs.State, players: { Players.Player }): Snap
    local coins = {}
    for i = 1, #players do
        coins[i] = 0
    end
    return { w = copy(w), s = copy(s), f = copy(f), players = copy(players), coins = coins, bumpCooldown = 0 }
end

-- one frame, the way scripts/game.luau steps a round (sounds, views and the debug knobs aside)
function Sim.step(snap: Snap, intents: { Input.Intent }): Events
    local ev: Events = { killed = 0, coin = 0, flips = 0, righted = 0, pow = false, stunned = {} }
    local w, players = snap.w, snap.players
    local downBefore = 0
    for _, e in snap.s.list do
        if e.state == Enemies.STATE_FLIPPED then
            downBefore += 1
        end
    end
    World.update(w)
    for i, p in players do
        local pev = Players.update(p, w, intents[i] or Input.NONE)
        ev.stunned[i] = pev.stun
        if pev.pow then
            ev.pow = true
        end
    end
    if #players >= 2 then
        local cooldown, stunned = Players.bumpEachOther(players[1], players[2], snap.bumpCooldown)
        snap.bumpCooldown = cooldown
        if stunned then
            for i, p in players do
                if p.dizzy > 0 then
                    ev.stunned[i] = true
                end
            end
        end
    end
    local halted = false
    for _, p in players do
        if p.halt > 0 or p.state == Players.STATE_DYING then
            halted = true
        end
    end
    local eev = Enemies.update(snap.s, w, players, w.frame, halted)
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
    if eev.killed > 0 then
        ev.killed = eev.killed
        return ev
    end
    if eev.kick then
        ev.coin = eev.coin
        for _, who in eev.kicks do
            snap.coins[who] += 1
        end
        local total = 0
        for _, c in snap.coins do
            total += c
        end
        if total == 4 then
            Enemies.markLast(snap.s)
        end
    end
    if eev.fireball or eev.ender then
        local target = players[w.frame % 2 + 1]
        if eev.ender then
            Fireballs.spawnEnder(snap.f, snap.s.spawnCnt2, target.body.y)
        else
            Fireballs.spawnHorz(snap.f, snap.s.spawnCnt2, target.body.y)
        end
    end
    local fev = Fireballs.update(snap.f, w, players, w.frame)
    if fev.killed > 0 then
        ev.killed = fev.killed
    end
    return ev
end

return Sim
