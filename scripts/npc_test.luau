--!strict
local Npc = require('scripts/npc')
local Nav = require('scripts/nav')
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
        for _, who in eev.kicks do
            if who == 1 then
                sc.kicks += 1
            end
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
                run(sc, 220)
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
                run(sc, 100) -- it is up again after 20 frames; a fresh flip and kick would take longer than this
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
            test.case('rights a downed enemy on a ledge under the human reaching for it', function(expect)
                local sc = scene(60) -- under the ledge already, but the kick would take a jump at 92 and a walk back
                local h = sc.players[2]
                h.halt = 0
                h.body.x = 236 -- on the lower ring, running right through the seam towards the downed spiny at 40, closer than the npc's trip
                h.body.y = 144
                h.onGround = true
                table.insert(sc.s.list, spiny(9, 40, 144, 0, true, 0xFF))
                local right: Input.Intent = { left = false, right = true, up = false, down = false, jump = false, run = true, start = false }
                local p = sc.players[1]
                local killed = 0
                local kicked = false
                local rightedNear = false -- the enemy stands up while the human is reaching for it
                for _ = 1, 200 do
                    World.update(sc.w)
                    Players.update(p, sc.w, Npc.think(sc.brain, p, sc.w, sc.s, sc.f, sc.players))
                    Players.update(h, sc.w, right)
                    local eev = Enemies.update(sc.s, sc.w, sc.players, sc.w.frame, false)
                    if eev.kick then
                        kicked = true
                    end
                    local e = sc.s.list[1]
                    if eev.flip and e.state == Enemies.STATE_NORMAL and math.abs((h.body.x - e.body.x + 128) % 256 - 128) < 48 then
                        rightedNear = true
                    end
                    if eev.killed > 0 then
                        killed = eev.killed
                        break
                    end
                end
                expect(kicked).is(false)
                expect(rightedNear or killed == 2).is(true) -- whether the live enemy then lands on them is down to a pixel
            end)
            test.case('with the coins lost it hunts: no kick, the human on a ledge gets bumped', function(expect)
                local sc = scene(150)
                local h = sc.players[2]
                h.halt = 0
                h.body.x = 40 -- standing on the lower ring
                h.body.y = 144
                h.onGround = true
                table.insert(sc.s.list, spiny(9, 200, 192, 0, true, 0xFF)) -- a free kick right next to the npc
                local p = sc.players[1]
                local kicks = 0
                local stuns = 0
                for _ = 1, 240 do
                    World.update(sc.w)
                    Players.update(p, sc.w, Npc.think(sc.brain, p, sc.w, sc.s, sc.f, sc.players, nil, { 0, 3 }))
                    local hev = Players.update(h, sc.w, Input.NONE)
                    if hev.stun then
                        stuns += 1
                    end
                    local eev = Enemies.update(sc.s, sc.w, sc.players, sc.w.frame, false)
                    if eev.kick then
                        kicks += 1
                    end
                    if eev.killed > 0 then
                        break
                    end
                end
                expect(sc.brain.hunt).is(true)
                expect(kicks).is(0)
                expect(stuns).greaterThan(0)
            end)
            test.case('a human lingering next to a downed enemy it sits under gets it righted at them', function(expect)
                local sc = scene(52) -- under block 48 of the upper ring, from the centre platform's edge
                local p = sc.players[1]
                p.body.y = 80
                sc.brain.lastRow = Nav.rowAt(52, 80) or 0
                local h = sc.players[2]
                h.halt = 0
                h.body.x = 88 -- on the upper ring, 30 px from the downed spiny, standing still
                h.body.y = 32
                h.onGround = true
                table.insert(sc.s.list, spiny(9, 46, 32, 0, true, 0xFF))
                local righted = false
                for _ = 1, 200 do
                    World.update(sc.w)
                    Players.update(p, sc.w, Npc.think(sc.brain, p, sc.w, sc.s, sc.f, sc.players))
                    Players.update(h, sc.w, Input.NONE)
                    local eev = Enemies.update(sc.s, sc.w, sc.players, sc.w.frame, false)
                    if sc.s.list[1].state == Enemies.STATE_NORMAL then
                        righted = true
                        break
                    end
                    if eev.killed > 0 then
                        break
                    end
                end
                expect(righted).is(true)
            end)
            test.case('takes a launch window it stopped a step short of', function(expect)
                local sc = scene(207) -- on the lower ring, 1 px past the jump window to the stub, the way to the centre platform
                sc.players[1].body.y = 144
                local e = spiny(9, 20, 32, Physics.ENEMY_SPAWN_VX, false, 0)
                e.pipeTimer = 40 -- walking out of the left pipe: the flip spot is under its first block, two rows up
                table.insert(sc.s.list, e)
                run(sc, 260)
                expect(sc.flips).greaterThanOrEqual(1) -- it used to stand there while the spiny walked the whole ring
                expect(sc.kicks).greaterThanOrEqual(1)
                expect(sc.killed).is(0)
            end)
            test.case('goes for the kick when the human near it only stands there', function(expect)
                local sc = scene(52) -- under the block it flipped the spiny from; the spiny bounced onto the block left of it
                sc.players[1].body.y = 80
                local h = sc.players[2]
                h.halt = 0
                h.body.x = 100 -- in the launch window to the upper ring, a shorter trip than ours, but not moving
                table.insert(sc.s.list, spiny(9, 28, 32, 0, true, 0xFF - 60))
                run(sc, 150)
                expect(sc.kicks).is(1) -- it used to leave for a 130 frame trip to sit under it from the stub
                expect(sc.killed).is(0)
            end)
            test.case('punches the pow before the human drops onto a downed enemy on the ring', function(expect)
                local sc = scene(148) -- on the floor, a short walk from the pow
                local h = sc.players[2]
                h.halt = 0
                h.body.x = 104 -- on the centre platform, running left: off its end and onto the ring next to the spiny
                h.body.y = 80
                table.insert(sc.s.list, spiny(9, 27, 144, 0, true, 0xFF))
                local left: Input.Intent = { left = true, right = false, up = false, down = false, jump = false, run = true, start = false }
                local p = sc.players[1]
                local powHits = 0
                local theirs = 0
                for _ = 1, 120 do
                    World.update(sc.w)
                    local ev = Players.update(p, sc.w, Npc.think(sc.brain, p, sc.w, sc.s, sc.f, sc.players))
                    Players.update(h, sc.w, left)
                    if ev.pow then
                        powHits += 1
                    end
                    local eev = Enemies.update(sc.s, sc.w, sc.players, sc.w.frame, false)
                    for _, who in eev.kicks do
                        if who == 2 then
                            theirs += 1
                        end
                    end
                    if eev.killed > 0 then
                        break
                    end
                end
                expect(powHits).is(1)
                expect(theirs).is(0)
            end)
            test.case('climbs three rows to kick a flipped enemy on the upper ring', function(expect)
                local sc = scene(64)
                table.insert(sc.s.list, spiny(9, 40, 32, 0, true, 0xFF))
                run(sc, 500)
                expect(sc.kicks).greaterThanOrEqual(1) -- it also flips and kicks the spawn that comes out meanwhile
                expect(sc.killed).is(0)
            end)
        end)
    end
end
