--!strict
local World = require('scripts/world')
local Physics = require('scripts/physics')

return function(): Tests
    return function(test: Tester)
        test.group('bounced blocks', function()
            test.case('a bumped block stays solid and flags what stands on it', function(expect)
                local w = World.new()
                World.bump(w, 72, 169) -- mario's head under the lower left ledge (block 64..79, 160..175)
                expect(World.solidAt(w, 72, 165)).is(true)
                expect(World.isBounced(w, 72, 165)).is(true)
                local spiny = Physics.newBody(66, 144) -- feet at 160, on that block
                local probe = World.probe(w, spiny)
                expect(probe.ground).is(true)
                expect(probe.underHit).is(true)
                expect(probe.underHitLeft).is(true)
            end)
            test.case('the bounce expires after 14 frames', function(expect)
                local w = World.new()
                World.bump(w, 72, 169)
                for _ = 1, 13 do
                    World.update(w)
                end
                expect(World.isBounced(w, 72, 165)).is(true)
                World.update(w)
                expect(World.isBounced(w, 72, 165)).is(false)
                expect(#w.blocks).is(0)
            end)
            test.case('a rising head under a bouncing block still stops but does not bounce it again', function(expect)
                local w = World.new()
                World.bump(w, 72, 169)
                local mario = Physics.newBody(64, 170)
                mario.vy = -0x30
                local probe = World.probe(w, mario)
                expect(probe.ceiling).is(true)
                expect(probe.ceilingBounced).is(true)
            end)
        end)
        test.group('boxes', function()
            test.case('touching edges count as a hit, like Vs_CheckBoxCollision', function(expect)
                expect(World.boxOverlap(0, 0, 8, 8, 8, 0, 8, 8)).is(true)
                expect(World.boxOverlap(0, 0, 8, 8, 9, 0, 8, 8)).is(false)
            end)
        end)
    end
end
