--!strict
local Physics = require('scripts/physics')

local function jumpEnvelope(hold: boolean): (number, number)
    local b = Physics.newBody(0, 0)
    Physics.jump(b)
    local frames = 0
    while b.vy < 0 do
        Physics.applyY(b)
        Physics.stepPlayerGravity(b, hold)
        frames += 1
    end
    return frames, -b.y
end

return function(): Tests
    return function(test: Tester)
        test.group('jump', function()
            test.case('full jump apex is 33 frames and 71 px (floor of 70.125, like the rom)', function(expect)
                local frames, height = jumpEnvelope(true)
                expect(frames).is(33)
                expect(height).is(71)
            end)
            test.case('tap jump apex is 14 frames and 30 px (floor of 29.3)', function(expect)
                local frames, height = jumpEnvelope(false)
                expect(frames).is(14)
                expect(height).is(30)
            end)
            test.case('fall speed caps at 0x40', function(expect)
                local b = Physics.newBody(0, 0)
                for _ = 1, 100 do
                    Physics.stepPlayerGravity(b, false)
                end
                expect(b.vy).is(0x40)
            end)
        end)

        test.group('run and walk', function()
            test.case('walking reaches 0x0C in 12 frames and holds', function(expect)
                local b = Physics.newBody(0, 0)
                for _ = 1, 12 do
                    Physics.stepPlayerX(b, 1, false, true)
                end
                expect(b.vx).is(0x0C)
                Physics.stepPlayerX(b, 1, false, true)
                expect(b.vx).is(0x0C)
            end)
            test.case('running reaches 0x18 in 24 frames', function(expect)
                local b = Physics.newBody(0, 0)
                for _ = 1, 24 do
                    Physics.stepPlayerX(b, 1, true, true)
                end
                expect(b.vx).is(0x18)
            end)
            test.case('releasing B decays one unit per frame back to walking speed', function(expect)
                local b = Physics.newBody(0, 0)
                b.vx = 0x18
                Physics.stepPlayerX(b, 1, false, true)
                expect(b.vx).is(0x17)
                for _ = 1, 20 do
                    Physics.stepPlayerX(b, 1, false, true)
                end
                expect(b.vx).is(0x0C)
            end)
            test.case('no direction decays to zero from either side on the ground', function(expect)
                local b = Physics.newBody(0, 0)
                b.vx = 3
                Physics.stepPlayerX(b, 0, false, true)
                Physics.stepPlayerX(b, 0, false, true)
                Physics.stepPlayerX(b, 0, false, true)
                expect(b.vx).is(0)
                b.vx = -2
                Physics.stepPlayerX(b, 0, false, true)
                Physics.stepPlayerX(b, 0, false, true)
                Physics.stepPlayerX(b, 0, false, true)
                expect(b.vx).is(0)
            end)
            test.case('a released pad keeps the speed in the air (PRG009_A5D1 only runs when landed)', function(expect)
                local b = Physics.newBody(0, 0)
                b.vx = 0x18
                for _ = 1, 30 do
                    Physics.stepPlayerX(b, 0, false, false)
                end
                expect(b.vx).is(0x18)
            end)
            test.case('turning around from a full run: 6 frames at 2 to walking speed, 12 at 1 to a stop, then 24 to full speed', function(expect)
                local b = Physics.newBody(0, 0)
                b.vx = 0x18
                local frames = 0
                while b.vx > 0 do
                    Physics.stepPlayerX(b, -1, true, true)
                    frames += 1
                end
                expect(frames).is(18) -- 12 with a flat 2, the rom's 24 with a flat 1
                while b.vx > -0x18 do
                    Physics.stepPlayerX(b, -1, true, true)
                    frames += 1
                end
                expect(frames).is(18 + 24)
            end)
            test.case('walking moves 0.75 px per frame: 3 px every 4 frames', function(expect)
                local b = Physics.newBody(100, 0)
                b.vx = 0x0C
                for _ = 1, 4 do
                    Physics.applyX(b)
                end
                expect(b.x).is(103)
                expect(b.subX).is(0)
            end)
            test.case('negative velocity carries subpixels correctly', function(expect)
                local b = Physics.newBody(100, 0)
                b.vx = -0x0C
                for _ = 1, 4 do
                    Physics.applyX(b)
                end
                expect(b.x).is(97)
                expect(b.subX).is(0)
            end)
        end)

        test.group('enemies', function()
            test.case('get-up speed grades climb 6 to 10 to 12 to 16', function(expect)
                expect(Physics.fasterVx(6)).is(0x0A)
                expect(Physics.fasterVx(0x0A)).is(0x0C)
                expect(Physics.fasterVx(0x0C)).is(0x10)
                expect(Physics.fasterVx(0x10)).is(0x10)
                expect(Physics.fasterVx(-6)).is(-0x0A)
            end)
            test.case('walker gravity is 2 per frame, fly gravity 1, both capped at 0x40', function(expect)
                local b = Physics.newBody(0, 0)
                for _ = 1, 10 do
                    Physics.stepObjectGravity(b, Physics.ENEMY_GRAVITY)
                end
                expect(b.vy).is(20)
                for _ = 1, 200 do
                    Physics.stepObjectGravity(b, Physics.ENEMY_GRAVITY)
                end
                expect(b.vy).is(0x40)
                local f = Physics.newBody(0, 0)
                for _ = 1, 10 do
                    Physics.stepObjectGravity(f, Physics.FLY_GRAVITY)
                end
                expect(f.vy).is(10)
            end)
            test.case('fireball vy clamps at 0x10 either way', function(expect)
                local b = Physics.newBody(0, 0)
                for _ = 1, 40 do
                    Physics.stepFireballY(b, true)
                end
                expect(b.vy).is(0x10)
                for _ = 1, 80 do
                    Physics.stepFireballY(b, false)
                end
                expect(b.vy).is(-0x10)
            end)
            test.case('ceiling stick frames', function(expect)
                expect(Physics.ceilingStickFrames(-0x42)).is(12)
                expect(Physics.ceilingStickFrames(-8)).is(5)
            end)
        end)
    end
end
