--!strict
local Fireballs = require('scripts/fireballs')
local World = require('scripts/world')
local Stage = require('scripts/stage')
local Players = require('scripts/players')

return function(): Tests
    return function(test: Tester)
        test.group('horizontal fireball', function()
            test.case('warns at the edge, enters from off screen and leaves fully past the far edge', function(expect)
                local s = Fireballs.new()
                local w = World.new()
                Fireballs.spawnHorz(s, 8, 192) -- count 8: side 0, moving right
                local f = s.list[1]
                expect(f.body.x).is(-16)
                expect(Fireballs.drawX(f)).is(0)
                for _ = 1, Fireballs.WARNING_FRAMES do
                    Fireballs.update(s, w, {}, 0)
                end
                expect(f.pose).is('flying')
                expect(f.body.x).is(-16)
                for _ = 1, 100 do
                    Fireballs.update(s, w, {}, 0)
                end
                expect(f.body.x).is(84)
                for _ = 1, 171 do
                    Fireballs.update(s, w, {}, 0)
                end
                expect(f.body.x).is(Stage.WIDTH - 1)
                expect(#s.list).is(1)
                Fireballs.update(s, w, {}, 0)
                expect(#s.list).is(0)
            end)
            test.case('the left mover spawns at the right edge and dies at -16', function(expect)
                local s = Fireballs.new()
                local w = World.new()
                Fireballs.spawnHorz(s, 10, 100) -- count 10: side 1, moving left
                local f = s.list[1]
                expect(f.body.x).is(Stage.WIDTH)
                expect(Fireballs.drawX(f)).is(Stage.WIDTH - 16)
                for _ = 1, Fireballs.WARNING_FRAMES + 271 do
                    Fireballs.update(s, w, {}, 0)
                end
                expect(f.body.x).is(-15)
                Fireballs.update(s, w, {}, 0)
                expect(#s.list).is(0)
            end)
        end)
        test.group('npc', function()
            test.case('a flying fireball passes through a player with no controller, burns a driven one', function(expect)
                local s = Fireballs.new()
                local w = World.new()
                Fireballs.spawnHorz(s, 8, Stage.FLOOR_TOP - 16)
                local f = s.list[1]
                f.warning = 0
                f.pose = 'flying'
                f.body.x = 60
                local p = Players.new(1)
                expect(Fireballs.update(s, w, { p }, f.id).killed).is(0)
                Players.setController(p, 1)
                f.body.x = 60
                expect(Fireballs.update(s, w, { p }, f.id).killed).is(1)
            end)
        end)
    end
end
