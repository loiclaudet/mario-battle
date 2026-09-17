--!strict
-- one step of a round, shared by the game and the cpu: scripts/game.luau steps its live state with it and only
-- adds sounds and views from the events; the cpu clones the state (Sim.snapshot) and runs the same function
-- forward, so what it foresees is exactly what happens. the free for all rules live here: a kick is a coin,
-- the fourth coin marks the survivors, the fireballs aim at an alive player in turn, every alive pair can bump,
-- and the target: a player touched by an enemy or a flame while holding coins, with two or more others alive,
-- turns blue instead of dying, with a grace period nothing touches him in (a blue player touched after it lands
-- on his side; touched there by another player he is beaten, his coins go to the beater and he falls off); and
-- when the five coins are out with a tie at the top, the player with coins below the leaders turns blue the
-- same way: sudden death, whoever beats him takes his coins and may take the round.
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
    coinSeq: { number }, -- when each player took their latest coin, as a running kick count (the trace)
    kickCount: number,
    cooldowns: { [number]: number }, -- Players.bumpEachOther per pair, keyed i * 8 + j
}

-- per player flags are indexed by player. killed lists every player who died this step (fell off), turnedBlue
-- every player who became the target, beaten the blue players another player took (with the beater), sided the
-- blue players laid on their side; kicks lists every kicker; fireball is a spawn (the sound)
export type Events = {
    killed: { number },
    turnedBlue: { number },
    suddenDeath: boolean, -- a target was made because the five coins are out and the top is shared
    beaten: { { number } },
    sided: { number },
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

-- the player who wins on coins: the one with the most, alone at the top. 0 while two share it (the showdown
-- decides) or nobody has any
function Sim.leader(snap: Snap): number
    local best, tie = 0, false
    for i, c in snap.coins do
        if c > 0 and (best == 0 or c > snap.coins[best]) then
            best, tie = i, false
        elseif best > 0 and c == snap.coins[best] then
            tie = true
        end
    end
    return if tie then 0 else best
end

-- the players still able to win: alive and not the target
function Sim.contenders(snap: Snap): { number }
    local out: { number } = {}
    for i, p in snap.players do
        if p.state == Players.STATE_NORMAL and not p.blue then
            table.insert(out, i)
        end
    end
    return out
end

local function noEvents(n: number): Events
    local ev: Events = { killed = {}, turnedBlue = {}, suddenDeath = false, beaten = {}, sided = {}, coin = 0, kicks = {}, flips = 0, righted = 0, flip = false, pow = false, entered = false, fireball = false, jumped = {}, bumped = {}, stunned = {} }
    for i = 1, n do
        ev.jumped[i] = false
        ev.bumped[i] = false
        ev.stunned[i] = false
    end
    return ev
end

-- a blue player lays on his side: the stun launch, then no control until a hit from under rights him
local function layDown(p: Players.Player, i: number, ev: Events)
    if p.side then
        return
    end
    Players.stun(p, if p.body.vx < 0 then -1 else 1)
    p.onGround = false
    table.insert(ev.sided, i)
end

-- a live enemy or a flame touched a player. holding coins with two or more other contenders alive he turns
-- blue instead of dying; blue already, he lands on his side; else he dies and falls off
local function touched(snap: Snap, i: number, ev: Events)
    local p = snap.players[i]
    if p.state ~= Players.STATE_NORMAL then
        return
    end
    if p.blue then
        layDown(p, i, ev)
        return
    end
    -- the target only makes sense with two or more others still able to win: a target beside a lone
    -- contender would hand him the round, so the touch kills instead and the contender wins
    if snap.coins[i] > 0 and #Sim.contenders(snap) >= 3 then
        Players.makeBlue(p) -- standing, and untouchable for a while
        table.insert(ev.turnedBlue, i)
        return
    end
    Players.kill(p)
    table.insert(ev.killed, i)
    snap.coins[i] = 0
    snap.coinSeq[i] = 0
end

-- another player touched a blue player on his side: the coins change hands and the blue one falls off
local function beat(snap: Snap, victim: number, by: number, ev: Events)
    local p = snap.players[victim]
    local taken = snap.coins[victim]
    snap.coins[victim] = 0
    snap.coinSeq[victim] = 0
    if taken > 0 then
        snap.kickCount += 1
        snap.coins[by] += taken
        snap.coinSeq[by] = snap.kickCount
    end
    Players.kill(p)
    table.insert(ev.killed, victim)
    table.insert(ev.beaten, { victim, by })
end

-- the five coins are out but two players share the top: the one with coins below them becomes the target
local function showdown(snap: Snap, ev: Events)
    local top, count = 0, 0
    for i, c in snap.coins do
        if c > top then
            top, count = c, 1
        elseif c == top and c > 0 then
            count += 1
        end
    end
    if count < 2 then
        return
    end
    for _, p in snap.players do
        if p.blue and p.state == Players.STATE_NORMAL then
            return -- one target at a time
        end
    end
    local odd, most = 0, 0
    for i, c in snap.coins do
        if c > 0 and c < top and c > most and snap.players[i].state == Players.STATE_NORMAL then
            odd, most = i, c
        end
    end
    if odd > 0 then
        Players.makeBlue(snap.players[odd])
        table.insert(ev.turnedBlue, odd)
        ev.suddenDeath = true
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
    -- every alive pair can stomp or shove, each pair on its own cooldown; a blue player on his side is beaten
    -- by whoever touches him
    for i = 1, #players do
        for j = i + 1, #players do
            if Players.touchable(players[i]) and Players.touchable(players[j]) then
                local a, b = players[i], players[j]
                if a.side or b.side then
                    local ax, ay, aw, ah = World.playerBox(a.body)
                    local bx, by, bw, bh = World.playerBox(b.body)
                    if World.boxOverlap(ax, ay, aw, ah, bx, by, bw, bh) then
                        if a.side and not b.side then
                            beat(snap, i, j, ev)
                        elseif b.side and not a.side then
                            beat(snap, j, i, ev)
                        end
                    end
                    continue
                end
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
        touched(snap, i, ev)
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
    if Sim.total(snap) >= Sim.COINS_TO_WIN then
        showdown(snap, ev)
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
        touched(snap, i, ev)
    end
    return ev
end

return Sim
