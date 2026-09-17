--!strict
-- turns keyboard and gamepad events into one intent table per player.
-- gamepads first: the first pad connected takes player 1, the second takes player 2.
-- the keyboard fills whatever slot has no pad: p1 = W A S D + G jump + F run, p2 = arrows + K jump + L run.
-- up and down (W S, up and down arrows, the dpad or the stick) only steer the start menu.
local Input = {}

-- face buttons by w3c slot: the runtime reports a switch pro controller with its A on the south slot
-- and X on the west slot, so nes style B jump / Y run is the east and north slots. flip to 'xbox'
-- for south jump / west run on an xbox or playstation pad.
Input.PAD_LAYOUT = 'nintendo'

local function padJump(pad: GamepadEvent): boolean
    return if Input.PAD_LAYOUT == 'nintendo' then pad.east else pad.south
end

local function padRun(pad: GamepadEvent): boolean
    return if Input.PAD_LAYOUT == 'nintendo' then pad.north else pad.west
end

export type Intent = {
    left: boolean,
    right: boolean,
    up: boolean, -- up and down only matter on the menu
    down: boolean,
    jump: boolean,
    run: boolean,
    start: boolean,
}

-- the intent of a slot with no one on it (an npc). shared, nobody writes into an intent
local NONE: Intent = { left = false, right = false, up = false, down = false, jump = false, run = false, start = false }
Input.NONE = NONE

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
    return { left = false, right = false, up = false, down = false, jump = false, run = false, start = false }
end

Input.SLOTS = 4

-- the keyboard set a slot falls back on: the slots past the pads take the sets in order
local function keySet(s: State, slot: number): { [string]: number }?
    return Input.KEYS[slot - #s.pads]
end

-- does anything drive this slot: a pad, or a free keyboard set
function Input.present(s: State, slot: number): boolean
    return s.pads[slot] ~= nil or keySet(s, slot) ~= nil
end

-- intent for a slot this frame: its pad, else its keyboard set, else nothing
function Input.intent(s: State, player: number): Intent
    local out = emptyIntent()
    local padId = s.pads[player]
    local pad = if padId ~= nil then s.padState[padId] else nil
    if pad ~= nil then
        local stickX = pad.leftStick.x
        local stickY = pad.leftStick.y
        out.left = pad.dpadLeft or stickX < -0.5
        out.right = pad.dpadRight or stickX > 0.5
        out.up = pad.dpadUp or stickY < -0.5
        out.down = pad.dpadDown or stickY > 0.5
        out.jump = padJump(pad)
        out.run = padRun(pad)
        out.start = pad.start
        return out
    end
    local keys = keySet(s, player)
    if keys == nil then
        return out
    end
    out.left = s.held[keys.left] == true
    out.right = s.held[keys.right] == true
    out.up = s.held[keys.up] == true
    out.down = s.held[keys.down] == true
    out.jump = s.held[keys.jump] == true
    out.run = s.held[keys.run] == true
    out.start = s.held[keys.start] == true
    return out
end

return Input
