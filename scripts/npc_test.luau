--!strict
local Npc = require('scripts/npc')
local Players = require('scripts/players')
local Enemies = require('scripts/enemies')
local Fireballs = require('scripts/fireballs')
local World = require('scripts/world')
local Physics = require('scripts/physics')
local Input = require('scripts/input')

type Scene = {
    w: World.State,
    s: Enemies.State,
    f: Fireballs.State,
    players: { Players.Player },
    brain: Npc.Brain,
    kicks: number,
    flips: number,
    pows: number,
    killed: number,
}

-- a spiny at (x, y) walking at vx sixteenths, or flipped with a get-up timer
local function spiny(slot: number, x: number, y: number, vx: number, flipped: boolean, getUp: number): Enemies.Enemy
    local e: Enemies.Enemy = {
        slot = slot,
        kind = 'spiny',
        body = Physics.newBody(x, y),
        dir = if vx < 0 then -1 else 1,
        state = if flipped then Enemies.STATE_FLIPPED else Enemies.STATE_NORMAL,
        pipeTimer = 0,
        getUpTimer = getUp,
        restoreVx = 0,
        angry = false,
        last = false,
        halt = 0,
        timer2 = 0,
        timer3 = 0,
        animCnt = 0,
        onGround = true,
        jitter = 0,
        pose = if flipped then 'flipped' else 'walkA',
    }
    e.body.vx = vx
    return e
end

-- p1 is the npc on the floor at x, p2 a human standing still at 176
local function scene(x: number): Scene
    local p = Players.new(1)
    p.body.x = x
    local h = Players.new(2) -- the human waits on the centre platform, halted so nothing can touch it
    Players.setController(h, 2)
    h.body.x = 128
    h.body.y = 80
    h.halt = 0xFFFF
    return { w = World.new(), s = Enemies.new(), f = Fireballs.new(), players = { p, h }, brain = Npc.new(1), kicks = 0, flips = 0, pows = 0, killed = 0 }
end

local function run(sc: Scene, frames: number)
    local p = sc.players[1]
    for _ = 1, frames do
        World.update(sc.w)
        local ev = Players.update(p, sc.w, Npc.think(sc.brain, p, sc.w, sc.s, sc.f, sc.players))
        Players.update(sc.players[2], sc.w, Input.NONE)
        if ev.pow then
            sc.pows += 1
        end
        local eev = Enemies.update(sc.s, sc.w, sc.players, sc.w.frame, false)
        if eev.kick and eev.coin == 1 then
            sc.kicks += 1
        end
        if eev.flip then
            sc.flips += 1
        end
        local fev = Fireballs.update(sc.f, sc.w, sc.players, sc.w.frame)
        if eev.killed > 0 or fev.killed > 0 then
            sc.killed = math.max(eev.killed, fev.killed)
            return
        end
    end
end

return function(): Tests
    return function(test: Tester)
        test.group('npc', function()
            test.case('kicks a flipped spiny on its row', function(expect)
                local sc = scene(64)
                table.insert(sc.s.list, spiny(9, 150, 192, 0, true, 0xFF))
                run(sc, 150)
                expect(sc.kicks).is(1)
                expect(sc.killed).is(0)
            end)
            test.case('never walks into a live spiny coming at it on the floor', function(expect)
                local sc = scene(100)
                table.insert(sc.s.list, spiny(9, 200, 192, -Physics.ENEMY_SPAWN_VX, false, 0))
                run(sc, 600)
                expect(sc.killed).is(0)
            end)
            test.case('flips a spiny walking on the lower ledge by bumping it from the floor', function(expect)
                local sc = scene(176)
                table.insert(sc.s.list, spiny(9, 176, 144, Physics.ENEMY_SPAWN_VX, false, 0))
                run(sc, 150)
                expect(sc.flips).is(1)
                expect(sc.kicks).is(1) -- and then it goes up and kicks it
                expect(sc.killed).is(0)
            end)
            test.case('hits the pow when two live enemies are grounded', function(expect)
                local sc = scene(120)
                table.insert(sc.s.list, spiny(9, 60, 192, Physics.ENEMY_SPAWN_VX, false, 0))
                table.insert(sc.s.list, spiny(8, 190, 192, -Physics.ENEMY_SPAWN_VX, false, 0))
                run(sc, 90)
                expect(sc.pows).is(1)
                expect(sc.killed).is(0)
            end)
            test.case('leaves a flipped enemy alone when it is about to get up', function(expect)
                local sc = scene(64)
                table.insert(sc.s.list, spiny(9, 200, 192, 0, true, 10))
                run(sc, 300)
                expect(sc.kicks).is(0)
                expect(sc.killed).is(0)
            end)
            test.case('rights a downed enemy with the pow as the human reaches for it', function(expect)
                local sc = scene(Npc.POW_X)
                local h = sc.players[2]
                h.halt = 0
                h.body.x = 128 -- closer to the downed enemy than the npc is, so the kick is theirs and the trap is ours
                h.body.y = 192
                h.onGround = true
                table.insert(sc.s.list, spiny(9, 150, 192, 0, true, 0xFF))
                local right: Input.Intent = { left = false, right = true, up = false, down = false, jump = false, run = true, start = false }
                local p = sc.players[1]
                local powHits = 0
                local killed = 0
                for _ = 1, 120 do
                    World.update(sc.w)
                    local ev = Players.update(p, sc.w, Npc.think(sc.brain, p, sc.w, sc.s, sc.f, sc.players))
                    Players.update(h, sc.w, right)
                    if ev.pow then
                        powHits += 1
                    end
                    local eev = Enemies.update(sc.s, sc.w, sc.players, sc.w.frame, false)
                    if eev.killed > 0 then
                        killed = eev.killed
                        break
                    end
                end
                expect(powHits).is(1)
                expect(killed).is(2)
            end)
            test.case('climbs three rows to kick a flipped enemy on the upper ring', function(expect)
                local sc = scene(64)
                table.insert(sc.s.list, spiny(9, 40, 32, 0, true, 0xFF))
                run(sc, 500)
                expect(sc.kicks).is(1)
                expect(sc.killed).is(0)
            end)
        end)
    end
end
