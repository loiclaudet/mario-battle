--!strict
local Nav = require('scripts/nav')

-- the typical stage's rows by where they are, since the indices are sorted by height at load
local LOWER = Nav.rowAt(20, 144) or 0
local STUBS = Nav.rowAt(240, 96) or 0
local CENTRE = Nav.rowAt(120, 80) or 0
local UPPER = Nav.rowAt(60, 32) or 0

return function(): Tests
    return function(test: Tester)
        test.group('rows', function()
            test.case('the typical stage gives the five rows, lowest first, the ledge pairs joined through the seam', function(expect)
                expect(#Nav.ROWS).is(5)
                local want = { { 192, 0, 256 }, { 144, 160, 352 }, { 96, 224, 288 }, { 80, 64, 192 }, { 32, 160, 352 } }
                for i, w in want do
                    expect(Nav.ROWS[i].y).is(w[1])
                    expect(Nav.ROWS[i].x0).is(w[2])
                    expect(Nav.ROWS[i].x1).is(w[3])
                end
            end)
            test.case('every row is found from a standing position, the rings through the seam', function(expect)
                expect(Nav.rowAt(100, 192)).is(Nav.FLOOR)
                expect(Nav.rowAt(20, 144)).is(LOWER)
                expect(Nav.rowAt(200, 144)).is(LOWER)
                expect(Nav.rowAt(120, 144)).is(nil)
                expect(Nav.rowAt(120, 80)).is(CENTRE)
                expect(Nav.rowAt(240, 96)).is(STUBS)
                expect(Nav.rowAt(4, 96)).is(STUBS)
                expect(Nav.rowAt(60, 32)).is(UPPER)
                expect(Nav.rowAt(120, 32)).is(nil)
            end)
            test.case('distances follow the row, the floor the short way round', function(expect)
                expect(Nav.dx(Nav.FLOOR, 10, 250)).is(-16)
                expect(Nav.dx(LOWER, 200, 20)).is(76)
                expect(Nav.dx(CENTRE, 100, 70)).is(-30)
            end)
            test.case('the row below', function(expect)
                expect(Nav.rowBelow(40, 144)).is(Nav.FLOOR)
                expect(Nav.rowBelow(70, 80)).is(LOWER)
                expect(Nav.rowBelow(128, 80)).is(Nav.FLOOR)
                expect(Nav.rowBelow(240, 32)).is(STUBS)
                expect(Nav.rowBelow(80, 32)).is(CENTRE)
            end)
        end)

        test.group('links', function()
            test.case('every row is reachable from the floor and back', function(expect)
                for r = 1, #Nav.ROWS do
                    local x = Nav.ROWS[r].x0 % 256 + 8
                    expect(Nav.travel(Nav.FLOOR, 100, r, x)).lessThan(600)
                    expect(Nav.travel(r, x, Nav.FLOOR, 100)).lessThan(600)
                end
            end)
            test.case('the floor reaches the lower ring by a jump at an inner end', function(expect)
                local step = Nav.step(Nav.FLOOR, 100, LOWER, 40)
                assert(step ~= nil)
                expect(step.kind).is('jump')
                expect(step.dir).is(-1)
                expect(step.x).greaterThan(88)
            end)
            test.case('the lower ring drops to the floor off an inner end', function(expect)
                local step = Nav.step(LOWER, 40, Nav.FLOOR, 128)
                assert(step ~= nil)
                expect(step.kind).is('drop')
                expect(step.dir).is(1)
            end)
            test.case('bump frames: the floor hits the lower ledge on frame 5', function(expect)
                expect(Nav.bumpFrames(Nav.FLOOR, LOWER)).is(5)
                expect(Nav.bumpFrames(LOWER, CENTRE)).greaterThan(5)
                expect(Nav.bumpFrames(Nav.FLOOR, CENTRE)).is(nil)
            end)
        end)
    end
end
