--!strict
local Input = require('scripts/input')

-- a pad snapshot with everything released
local function pad(fields: { [string]: any }): GamepadEvent
    local e: { [string]: any } = {
        deviceId = 7,
        leftStick = { x = 0, y = 0 },
        dpadLeft = false,
        dpadRight = false,
        dpadUp = false,
        dpadDown = false,
        east = false,
        south = false,
        north = false,
        west = false,
        start = false,
    }
    for k, v in fields do
        e[k] = v
    end
    return e :: any
end

return function(): Tests
    return function(test: Tester)
        test.group('up and down', function()
            test.case('W and S steer p1 on the keyboard, the arrows p2', function(expect)
                local s = Input.new()
                Input.keyDown(s, 87)
                expect(Input.intent(s, 1).up).is(true)
                expect(Input.intent(s, 1).down).is(false)
                Input.keyDown(s, 264)
                expect(Input.intent(s, 2).down).is(true)
                expect(Input.intent(s, 2).up).is(false)
            end)
            test.case('the dpad and the stick both count on a pad', function(expect)
                local s = Input.new()
                Input.padEvent(s, pad({ dpadUp = true }))
                expect(Input.intent(s, 1).up).is(true)
                Input.padEvent(s, pad({ leftStick = { x = 0, y = 0.8 } }))
                expect(Input.intent(s, 1).down).is(true)
                expect(Input.intent(s, 1).up).is(false)
            end)
            test.case('four slots: the pads first, then the keyboard sets, then nothing', function(expect)
                local s = Input.new()
                expect(Input.present(s, 1)).is(true) -- keyboard set 1
                expect(Input.present(s, 2)).is(true)
                expect(Input.present(s, 3)).is(false)
                Input.keyDown(s, 65) -- A: set 1 left
                expect(Input.intent(s, 1).left).is(true)
                Input.padEvent(s, pad({ dpadRight = true }))
                -- one pad: it takes slot 1, the keyboard sets move to slots 2 and 3
                expect(Input.intent(s, 1).right).is(true)
                expect(Input.intent(s, 1).left).is(false)
                expect(Input.intent(s, 2).left).is(true)
                Input.keyDown(s, 263) -- left arrow: set 2
                expect(Input.intent(s, 3).left).is(true)
                expect(Input.present(s, 3)).is(true)
                expect(Input.present(s, 4)).is(false)
                expect(Input.intent(s, 4).left).is(false)
            end)
            test.case('the shared empty intent is all false', function(expect)
                expect(Input.NONE.left).is(false)
                expect(Input.NONE.up).is(false)
                expect(Input.NONE.jump).is(false)
                expect(Input.NONE.start).is(false)
            end)
        end)
    end
end
