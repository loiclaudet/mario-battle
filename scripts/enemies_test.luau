--!strict
local Enemies = require('scripts/enemies')
local Players = require('scripts/players')
local World = require('scripts/world')
local Physics = require('scripts/physics')
local Stage = require('scripts/stage')

-- a live spiny standing on the floor at x, as the spawner would leave it
local function spinyAt(x: number): Enemies.Enemy
    local e: Enemies.Enemy = {
        slot = 1,
        kind = 'spiny',
        body = Physics.newBody(x, Stage.FLOOR_TOP - 16),
        dir = 1,
        state = Enemies.STATE_NORMAL,
        pipeTimer = 0,
        getUpTimer = 0,
        restoreVx = 0,
        angry = false,
        last = false,
        halt = 0,
        timer2 = 0,
        timer3 = 0,
        animCnt = 0,
        onGround = true,
        jitter = 0,
        pose = 'walkA',
    }
    return e
end

return function(): Tests
    return function(test: Tester)
        test.group('npc', function()
            test.case('a live enemy passes through a player with no controller', function(expect)
                local s = Enemies.new()
                local w = World.new()
                local e = spinyAt(64)
                table.insert(s.list, e)
                local p = Players.new(1)
                local ev = Enemies.update(s, w, { p }, e.slot, false)
                expect(ev.killed).is(0)
                expect(p.state).is(Players.STATE_NORMAL)
            end)
            test.case('the same touch kills a driven player', function(expect)
                local s = Enemies.new()
                local w = World.new()
                local e = spinyAt(64)
                table.insert(s.list, e)
                local p = Players.new(1)
                Players.setController(p, 1)
                local ev = Enemies.update(s, w, { p }, e.slot, false)
                expect(ev.killed).is(1)
            end)
        end)
    end
end
