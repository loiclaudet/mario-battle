--!strict
local Players = require('scripts/players')
local World = require('scripts/world')
local Stage = require('scripts/stage')
local Physics = require('scripts/physics')
local Input = require('scripts/input')

local function intent(left: boolean, right: boolean, jump: boolean, run: boolean): Input.Intent
    return { left = left, right = right, jump = jump, run = run, start = false }
end

local IDLE = intent(false, false, false, false)

-- a player dropped onto the pow from just above it, settled for a few frames
local function droppedOnPow(hits: number): (Players.Player, World.State)
    local w = World.new()
    w.powHits = hits
    local p = Players.new(1)
    p.body.x = 120
    p.body.y = 128
    p.onGround = false
    p.prevJump = false
    for _ = 1, 30 do
        Players.update(p, w, IDLE)
    end
    return p, w
end

return function(): Tests
    return function(test: Tester)
        test.group('pow', function()
            test.case('standing on it sits 1, 4 then 6 px lower as it flattens (Vs_POWHeight)', function(expect)
                for hits, y in { 137, 140, 142 } do
                    local p = droppedOnPow(hits - 1)
                    expect(p.body.y).is(y)
                    expect(p.onGround).is(true)
                    expect(p.body.vy).is(0)
                end
            end)
            test.case('a rising head hits it, counts a hit and snaps under it by 17 minus Vs_POWHeight', function(expect)
                for hits, y in { 168, 165, 163 } do
                    local w = World.new()
                    w.powHits = hits - 1
                    local p = Players.new(1)
                    p.body.x = 120
                    p.body.y = 176
                    p.body.vy = Physics.JUMP_VY
                    p.onGround = false
                    p.prevJump = false
                    local hit = false
                    for _ = 1, 20 do
                        local ev = Players.update(p, w, IDLE)
                        if ev.pow then
                            hit = true
                            break
                        end
                    end
                    expect(hit).is(true)
                    expect(w.powHits).is(hits)
                    expect(p.body.y).is(y)
                    expect(p.stick).is(8)
                end
            end)
            test.case('gone after three hits: the player falls through its cell to the floor', function(expect)
                local p = droppedOnPow(3)
                expect(p.body.y).is(Stage.FLOOR_TOP - 16)
            end)
        end)

        test.group('control', function()
            test.case('a dizzy player still steers and jumps', function(expect)
                local w = World.new()
                local p = Players.new(1)
                p.prevJump = false
                p.dizzy = 10
                Players.update(p, w, intent(false, true, false, false))
                expect(p.body.vx).is(1)
                local ev = Players.update(p, w, intent(false, false, true, false))
                expect(ev.jump).is(true)
                expect(p.jumped).is(true)
            end)
            test.case('releasing the pad in the air keeps the speed, landing decays it', function(expect)
                local w = World.new()
                local p = Players.new(1)
                p.prevJump = false
                p.body.vx = 0x0C
                p.body.x = 120
                p.body.y = Stage.FLOOR_TOP - 16 - 40
                p.onGround = false
                Players.update(p, w, IDLE)
                expect(p.body.vx).is(0x0C)
                for _ = 1, 40 do
                    Players.update(p, w, IDLE)
                end
                expect(p.onGround).is(true)
                expect(p.body.vx).is(0)
            end)
        end)
    end
end
