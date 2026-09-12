--!strict
-- turns keyboard and gamepad events into one intent table per player.
-- gamepads first: the first pad connected takes player 1, the second takes player 2.
-- the keyboard fills whatever slot has no pad: p1 = W A S D + G jump + F run, p2 = arrows + K jump + L run.
local Input = {}

export type Intent = { left: boolean, right: boolean, jump: boolean, run: boolean, start: boolean }

-- glfw key codes, confirmed against samples/input_demo and format.md (262/263 arrows)
Input.KEYS = {
    { left = 65, right = 68, up = 87, down = 83, jump = 71, run = 70, start = 257 }, -- A D W S, G, F, enter
    { left = 263, right = 262, up = 265, down = 264, jump = 75, run = 76, start = 32 }, -- arrows, K, L, space
}

export type State = {
    held: { [number]: boolean }, -- keyboard keys currently down
    pads: { number }, -- device ids in player order
    padState: { [number]: GamepadEvent }, -- last full snapshot per device
}

function Input.new(): State
    return { held = {}, pads = {}, padState = {} }
end

function Input.keyDown(s: State, key: number)
    s.held[key] = true
end

function Input.keyUp(s: State, key: number)
    s.held[key] = false
end

function Input.padConnected(s: State, deviceId: number)
    for _, id in s.pads do
        if id == deviceId then
            return
        end
    end
    table.insert(s.pads, deviceId)
end

function Input.padDisconnected(s: State, deviceId: number)
    for i, id in s.pads do
        if id == deviceId then
            table.remove(s.pads, i)
            break
        end
    end
    s.padState[deviceId] = nil
end

function Input.padEvent(s: State, event: GamepadEvent)
    Input.padConnected(s, event.deviceId)
    s.padState[event.deviceId] = event
end

local function emptyIntent(): Intent
    return { left = false, right = false, jump = false, run = false, start = false }
end

-- intent for player 1 or 2 this frame
function Input.intent(s: State, player: number): Intent
    local out = emptyIntent()
    local padId = s.pads[player]
    local pad = if padId ~= nil then s.padState[padId] else nil
    if pad ~= nil then
        local stickX = pad.leftStick.x
        out.left = pad.dpadLeft or stickX < -0.5
        out.right = pad.dpadRight or stickX > 0.5
        out.jump = pad.south
        out.run = pad.west
        out.start = pad.start
        return out
    end
    local keys = Input.KEYS[player]
    out.left = s.held[keys.left] == true
    out.right = s.held[keys.right] == true
    out.jump = s.held[keys.jump] == true
    out.run = s.held[keys.run] == true
    out.start = s.held[keys.start] == true
    return out
end

return Input
