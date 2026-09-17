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
            test.case('touched with coins and three alive, a player turns blue with a grace period instead of dying', function(expect)
                local r = round()
                r.coins[2] = 2
                r.coinSeq[2] = 2
                r.kickCount = 2
                table.insert(r.s.list, spiny(9, r.players[2].body.x + 4, 192, 0, false)) -- a live spiny on player 2
                local ev = Sim.step(r, none(4))
                expect(ev.turnedBlue[1]).is(2)
                expect(ev.suddenDeath).is(false)
                expect(#ev.sided).is(0)
                expect(#ev.killed).is(0)
                local p = r.players[2]
                expect(p.blue).is(true)
                expect(p.side).is(false)
                expect(p.invincible).is(Players.INVINCIBLE_FRAMES)
                expect(p.state).is(Players.STATE_NORMAL)
                expect(r.coins[2]).is(2)
                -- the spiny walks through him for the whole grace, and he keeps steering
                local right: Input.Intent = { left = false, right = true, up = false, down = false, jump = false, run = true, start = false }
                r.s.list[1].body.vx = 0
                for _ = 1, Players.INVINCIBLE_FRAMES do
                    local intents = none(4)
                    intents[2] = right
                    local e2 = Sim.step(r, intents)
                    expect(#e2.sided).is(0)
                end
                expect(p.side).is(false)
                expect(p.body.x > r.players[2].body.x - 1).is(true)
                expect(p.invincible).is(0)
                -- after it a touch lays him down
                r.s.list[1].body.x = p.body.x + 4
                r.s.list[1].body.y = p.body.y
                for _ = 1, 3 do
                    Sim.step(r, none(4))
                end
                expect(p.side).is(true)
            end)
            test.case('touched without coins a player dies and falls off, the round goes on', function(expect)
                local r = round()
                table.insert(r.s.list, spiny(9, r.players[2].body.x + 4, 192, 0, false))
                local ev = Sim.step(r, none(4))
                expect(ev.killed[1]).is(2)
                expect(r.players[2].state).is(Players.STATE_DYING)
                expect(#Players.alive(r.players)).is(3)
            end)
            test.case('with one other alive a touch kills, coins or not', function(expect)
                local r = round()
                r.players[3].state = Players.STATE_OFF
                r.players[4].state = Players.STATE_OFF
                r.coins[2] = 2
                table.insert(r.s.list, spiny(9, r.players[2].body.x + 4, 192, 0, false))
                local ev = Sim.step(r, none(4))
                expect(ev.killed[1]).is(2)
                expect(#ev.turnedBlue).is(0)
            end)
            test.case('a blue player on his side is beaten by the player who touches him, who takes his coins', function(expect)
                local r = round()
                local p = r.players[2]
                r.coins[2] = 2
                Players.makeBlue(p)
                p.invincible = 0
                p.side = true
                r.players[1].body.x = p.body.x - 8 -- player 1 overlaps him
                local ev = Sim.step(r, none(4))
                expect(#ev.beaten).is(1)
                expect(ev.beaten[1][1]).is(2)
                expect(ev.beaten[1][2]).is(1)
                expect(r.coins[1]).is(2)
                expect(r.coins[2]).is(0)
                expect(p.state).is(Players.STATE_DYING)
                expect(ev.killed[1]).is(2)
            end)
            test.case('a stomp lays a blue player on his side, and the last contender wins over the targets', function(expect)
                local r = round()
                local p = r.players[2]
                Players.makeBlue(p)
                p.invincible = 0
                local top = r.players[1]
                top.body.x = p.body.x
                top.body.y = p.body.y - 12 -- coming down on his head
                top.body.vy = 0x20
                top.onGround = false
                Sim.step(r, none(4))
                expect(p.side).is(true)
                expect(#Sim.contenders(r)).is(3)
                r.players[3].state = Players.STATE_DYING
                r.players[4].state = Players.STATE_DYING
                expect(#Sim.contenders(r)).is(1) -- player 1 alone can still win, player 2 is the target
            end)
            test.case('a hit from under rights a blue player on his side, and the same bounce does not lay him back down', function(expect)
                local r = round()
                local p = r.players[2]
                Players.makeBlue(p)
                p.invincible = 0
                p.side = true
                World.bump(r.w, p.body.x + 8, p.body.y + 16) -- the block under his feet, bouncing 14 frames
                for _ = 1, 20 do
                    Sim.step(r, none(4))
                end
                expect(p.side).is(false)
                expect(p.dizzy).is(0)
                expect(p.blue).is(true)
            end)
            test.case('a bounce under a target in his grace does not stun him', function(expect)
                local r = round()
                local p = r.players[2]
                Players.makeBlue(p)
                World.bump(r.w, p.body.x + 8, p.body.y + 16)
                for _ = 1, 20 do
                    Sim.step(r, none(4))
                end
                expect(p.side).is(false)
                expect(p.dizzy).is(0)
                expect(p.onGround).is(true)
            end)
            test.case('five coins with a tie at the top: the odd one out turns blue, a leader beating him wins', function(expect)
                local r = round()
                r.coins = { 2, 2, 0, 0 }
                r.coinSeq = { 3, 4, 0, 0 }
                r.kickCount = 4
                table.insert(r.s.list, spiny(9, r.players[3].body.x + 4, 192, 0, true)) -- player 3 takes the fifth
                local sudden = false
                for _ = 1, 4 do
                    if Sim.step(r, none(4)).suddenDeath then
                        sudden = true
                    end
                end
                expect(sudden).is(true)
                expect(Sim.total(r)).is(5)
                expect(Sim.leader(r)).is(0) -- a tie, no winner yet
                expect(r.players[3].blue).is(true)
                expect(r.players[3].side).is(false)
                expect(r.players[3].invincible).greaterThan(250)
                -- player 4 (no coins) lays him down and takes the coin: the tie stands, player 4 is blue now
                r.players[3].invincible = 0
                r.players[3].side = true
                r.players[4].body.x = r.players[3].body.x - 8
                Sim.step(r, none(4))
                expect(r.coins[4]).is(1)
                expect(r.players[4].blue).is(true)
                expect(Sim.leader(r)).is(0)
                -- player 1 beats player 4: three coins, alone at the top
                r.players[4].invincible = 0
                r.players[4].side = true
                r.players[1].body.x = r.players[4].body.x - 8
                Sim.step(r, none(4))
                expect(r.coins[1]).is(3)
                expect(Sim.leader(r)).is(1)
            end)
            test.case('an off player is never touched', function(expect)
                local r = round()
                r.players[3].state = Players.STATE_OFF
                table.insert(r.s.list, spiny(9, r.players[3].body.x, 192, 0, false))
                local ev = Sim.step(r, none(4))
                expect(#ev.killed).is(0)
                expect(r.players[3].state).is(Players.STATE_OFF)
            end)
            test.case('a kick is a coin for the kicker', function(expect)
                local r = round()
                table.insert(r.s.list, spiny(9, r.players[1].body.x + 4, 192, 0, true))
                table.insert(r.s.list, spiny(8, r.players[3].body.x + 4, 192, 0, true))
                for _ = 1, 4 do
                    Sim.step(r, none(4))
                end
                expect(r.coins[1]).is(1)
                expect(r.coins[3]).is(1)
                expect(Sim.total(r)).is(2)
                expect(Sim.leader(r)).is(0) -- one each: nobody leads
            end)
            test.case('the leader is the one alone with the most coins', function(expect)
                local r = round()
                r.coins = { 2, 2, 1, 0 }
                expect(Sim.leader(r)).is(0)
                r.coins[3] = 3
                expect(Sim.leader(r)).is(3)
            end)
            test.case('the fourth coin marks the survivors once', function(expect)
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
            end)
        end)
    end
end
