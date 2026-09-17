--!strict
-- the free for all rules in scripts/sim.luau, the one round step the game and the cpu share
local Sim = require('scripts/sim')
local Players = require('scripts/players')
local Enemies = require('scripts/enemies')
local Fireballs = require('scripts/fireballs')
local World = require('scripts/world')
local Physics = require('scripts/physics')
local Input = require('scripts/input')

local function spiny(slot: number, x: number, y: number, vx: number, flipped: boolean): Enemies.Enemy
    local e: Enemies.Enemy = {
        slot = slot, kind = 'spiny', body = Physics.newBody(x, y), dir = if vx < 0 then -1 else 1,
        state = if flipped then Enemies.STATE_FLIPPED else Enemies.STATE_NORMAL, pipeTimer = 0, getUpTimer = if flipped then 0xFF else 0,
        restoreVx = 0, angry = false, last = false, halt = 0, timer2 = 0, timer3 = 0, animCnt = 0, onGround = true, jitter = 0,
        pose = if flipped then 'flipped' else 'walkA',
    }
    e.body.vx = vx
    return e
end

-- four players on the floor, far apart, nobody moving
local function round(): Sim.Snap
    local players: { Players.Player } = {}
    for i = 1, 4 do
        local p = Players.new(i)
        Players.setController(p, i)
        p.body.x = 16 + (i - 1) * 64
        p.body.y = 192
        p.onGround = true
        players[i] = p
    end
    return Sim.live(World.new(), Enemies.new(), Fireballs.new(), players)
end

local function none(n: number): { Input.Intent }
    local out = {}
    for i = 1, n do
        out[i] = Input.NONE
    end
    return out
end

return function(): Tests
    return function(test: Tester)
        test.group('round', function()
            test.case('a death with three others alive drops the coins, refunds them as enemies and the round goes on', function(expect)
                local r = round()
                r.coins[2] = 2
                r.coinSeq[2] = 2
                r.kickCount = 2
                r.s.count = 5 -- the five are out
                table.insert(r.s.list, spiny(9, r.players[2].body.x, 192, 0, false)) -- a live spiny on player 2
                local ev = Sim.step(r, none(4))
                expect(ev.killed[1]).is(2)
                expect(ev.refunded).is(2)
                expect(r.players[2].state).is(Players.STATE_DYING)
                expect(r.coins[2]).is(0)
                expect(r.s.quota).is(7)
                expect(#Players.alive(r.players)).is(3)
                -- the spawner keeps going for the two refunds
                for _ = 1, 600 do
                    Sim.step(r, none(4))
                end
                expect(r.s.count).greaterThanOrEqual(6)
            end)
            test.case('an off player is never touched', function(expect)
                local r = round()
                r.players[3].state = Players.STATE_OFF
                table.insert(r.s.list, spiny(9, r.players[3].body.x, 192, 0, false))
                local ev = Sim.step(r, none(4))
                expect(#ev.killed).is(0)
                expect(r.players[3].state).is(Players.STATE_OFF)
            end)
            test.case('a kick is a coin for the kicker, in kick order for the tie', function(expect)
                local r = round()
                table.insert(r.s.list, spiny(9, r.players[1].body.x + 4, 192, 0, true))
                table.insert(r.s.list, spiny(8, r.players[3].body.x + 4, 192, 0, true))
                for _ = 1, 4 do
                    Sim.step(r, none(4))
                end
                expect(r.coins[1]).is(1)
                expect(r.coins[3]).is(1)
                expect(Sim.total(r)).is(2)
                expect(r.coinSeq[1] ~= r.coinSeq[3]).is(true)
                expect(Sim.leader(r)).is(if r.coinSeq[1] < r.coinSeq[3] then 1 else 3)
            end)
            test.case('the leader is the most coins, a tie to whoever got there first', function(expect)
                local r = round()
                r.coins = { 2, 2, 1, 0 }
                r.coinSeq = { 5, 4, 3, 0 }
                expect(Sim.leader(r)).is(2)
                r.coins[3] = 3
                expect(Sim.leader(r)).is(3)
            end)
            test.case('the fourth coin marks the survivors once, the refund unmarks the next spawn', function(expect)
                local r = round()
                table.insert(r.s.list, spiny(9, 100, 192, Physics.ENEMY_SPAWN_VX, false)) -- a walker between players 2 and 3
                r.coins = { 2, 1, 0, 0 }
                r.coinSeq = { 3, 2, 0, 0 }
                r.kickCount = 3
                table.insert(r.s.list, spiny(8, r.players[4].body.x + 4, 192, 0, true))
                for _ = 1, 4 do
                    Sim.step(r, none(4))
                end
                expect(Sim.total(r)).is(4)
                expect(r.s.list[1].last).is(true)
                local v = r.s.list[1].body.vx
                Sim.step(r, none(4))
                expect(r.s.list[1].body.vx).is(v) -- not graded twice
                expect(r.s.nextIsLast).is(true)
                Enemies.refund(r.s, 1)
                expect(r.s.nextIsLast).is(false)
            end)
        end)
    end
end
