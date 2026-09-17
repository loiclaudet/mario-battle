--!strict
-- the start menu: one cursor per input slot over the character cards and a START item below.
-- pure state. the script feeds Menu.layout into the view model and the markup draws it, so
-- adding a player or a card is a new slot or a new rect here plus a cursor node in game.rml.
local Input = require('scripts/input')

local Menu = {}

export type Rect = { x: number, y: number, w: number, h: number }
export type Slot = {
    focus: number, -- a card index, or Menu.START
    card: number, -- the card last focused, where up from START returns
    locked: number, -- 0, or the card this slot is locked on
    prev: Input.Intent, -- last frame, for edge detection
}
-- off: the cards nobody plays this round (neither a human nor the cpu). the run button on an unlocked card
-- toggles it; at least two cards stay on
export type State = { slots: { Slot }, off: { boolean } }
export type Events = { moved: boolean, locked: boolean, unlocked: boolean, refused: boolean, launch: boolean, toggled: boolean }
export type Role = 'cpu' | 'off' | number -- who plays a card: the cpu, nobody, or the input slot locked on it
export type SlotView = { cursor: Rect, marker: { x: number, y: number } }

Menu.CARDS = { 'mario', 'luigi', 'wario', 'waluigi' } -- card index = player index
Menu.MIN_ON = 2
Menu.START = #Menu.CARDS + 1
-- four card places, 60 wide with 4 px gaps, as drawn by scene/components/menu.rml (tools/gen_ui_rml.py)
local CARD_RECTS: { Rect } = { { x = 4, y = 80, w = 60, h = 80 }, { x = 68, y = 80, w = 60, h = 80 }, { x = 132, y = 80, w = 60, h = 80 }, { x = 196, y = 80, w = 60, h = 80 } }
local START_RECT: Rect = { x = 104, y = 180, w = 48, h = 16 }
Menu.CARD_RECTS = CARD_RECTS
Menu.START_RECT = START_RECT
Menu.CURSOR_OUTSET = { 6, 4, 2, 0 } -- px outside the target per slot: each cursor sits 2 px inside the previous one
Menu.MARKER_W = 16 -- "1P" in the 8 px font
Menu.MARKER_PITCH = 16 -- markers sharing a target sit this far apart (four on one card overflow it by 2 px a side)
Menu.MARKER_LIFT = 16 -- marker top above the target top

local function copyIntent(i: Input.Intent): Input.Intent
    return { left = i.left, right = i.right, up = i.up, down = i.down, jump = i.jump, run = i.run, start = i.start }
end

-- slot i starts on card i, nothing locked
function Menu.new(slots: number): State
    local m: State = { slots = {}, off = {} }
    for i = 1, slots do
        local card = (i - 1) % #Menu.CARDS + 1
        m.slots[i] = { focus = card, card = card, locked = 0, prev = copyIntent(Input.NONE) }
    end
    for card = 1, #Menu.CARDS do
        m.off[card] = false
    end
    return m
end

-- who plays a card once the round starts
function Menu.roleFor(m: State, card: number): Role
    local slot = Menu.controllerFor(m, card)
    if slot ~= nil then
        return slot
    end
    return if m.off[card] then 'off' else 'cpu'
end

-- how many cards are in the round
function Menu.onCount(m: State): number
    local n = 0
    for card = 1, #Menu.CARDS do
        if Menu.roleFor(m, card) ~= 'off' then
            n += 1
        end
    end
    return n
end

-- the slot locked on a card, nil when the card goes to an npc
function Menu.controllerFor(m: State, card: number): number?
    for i, s in m.slots do
        if s.locked == card then
            return i
        end
    end
    return nil
end

function Menu.isLocked(m: State, card: number): boolean
    return Menu.controllerFor(m, card) ~= nil
end

-- one frame: every slot reads its intent, presses count on the edge
function Menu.update(m: State, intents: { Input.Intent }): Events
    local ev: Events = { moved = false, locked = false, unlocked = false, refused = false, launch = false, toggled = false }
    for i, s in m.slots do
        local intent = intents[i] or Input.NONE
        local prev = s.prev
        local left = intent.left and not prev.left
        local right = intent.right and not prev.right
        local up = intent.up and not prev.up
        local down = intent.down and not prev.down
        local jump = intent.jump and not prev.jump
        local run = intent.run and not prev.run
        local start = intent.start and not prev.start
        if start then
            ev.launch = true
        end
        if s.focus == Menu.START then
            if up then
                s.focus = s.card
                ev.moved = true
            elseif jump then
                ev.launch = true
            end
        else
            if left and s.focus > 1 then
                s.focus -= 1
                s.card = s.focus
                ev.moved = true
            elseif right and s.focus < #Menu.CARDS then
                s.focus += 1
                s.card = s.focus
                ev.moved = true
            elseif down then
                s.focus = Menu.START
                ev.moved = true
            elseif jump then
                if s.locked == s.focus then
                    s.locked = 0
                    ev.unlocked = true
                elseif Menu.isLocked(m, s.focus) then
                    ev.refused = true
                else
                    s.locked = s.focus
                    m.off[s.focus] = false -- taking a card turns it on
                    s.focus = Menu.START
                    ev.locked = true
                end
            elseif run then
                -- an unlocked card goes cpu / off, while at least two cards stay on
                if Menu.isLocked(m, s.focus) then
                    ev.refused = true
                elseif not m.off[s.focus] and Menu.onCount(m) <= Menu.MIN_ON then
                    ev.refused = true
                else
                    m.off[s.focus] = not m.off[s.focus]
                    ev.toggled = true
                end
            end
        end
        s.prev = copyIntent(intent)
    end
    return ev
end

-- back from a round: locks stay, every cursor sits on START so a jump replays, and a button still
-- held from the round cannot launch again
function Menu.rearm(m: State)
    for _, s in m.slots do
        s.focus = Menu.START
        s.prev.jump = true
        s.prev.start = true
        s.prev.run = true
    end
end

function Menu.targetRect(focus: number): Rect
    return if focus == Menu.START then Menu.START_RECT else Menu.CARD_RECTS[focus]
end

-- where each slot's cursor outline and marker go. the marker stays on the locked card, otherwise it
-- follows the cursor; markers sharing a target line up side by side, centred on it
function Menu.layout(m: State): { SlotView }
    local targets: { number } = {}
    local counts: { [number]: number } = {}
    for i, s in m.slots do
        local t = if s.locked ~= 0 then s.locked else s.focus
        targets[i] = t
        counts[t] = (counts[t] or 0) + 1
    end
    local views: { SlotView } = {}
    local placed: { [number]: number } = {}
    for i, s in m.slots do
        local out = Menu.CURSOR_OUTSET[i] or 0
        local r = Menu.targetRect(s.focus)
        local t = targets[i]
        local tr = Menu.targetRect(t)
        local n = counts[t]
        local j = placed[t] or 0
        placed[t] = j + 1
        local span = Menu.MARKER_W + (n - 1) * Menu.MARKER_PITCH
        local left = tr.x + tr.w / 2 - span / 2
        views[i] = {
            cursor = { x = r.x - out, y = r.y - out, w = r.w + 2 * out, h = r.h + 2 * out },
            marker = { x = left + j * Menu.MARKER_PITCH, y = tr.y - Menu.MARKER_LIFT },
        }
    end
    return views
end

return Menu
