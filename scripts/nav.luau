--!strict
-- the arena as five rows (floor, lower ring, centre, stubs, upper ring) and the ways between them.
-- the jumps and drops are not hand listed: at load the real player physics runs once per row end,
-- so every launch window and landing spot is exactly what the game will do.
local Stage = require('scripts/stage')
local Physics = require('scripts/physics')
local World = require('scripts/world')
local Players = require('scripts/players')
local Input = require('scripts/input')

local Nav = {}

-- x0..x1 run past 256 for a segment that wraps (the two lower ledges are one ring through the seam)
export type Row = { name: string, y: number, x0: number, x1: number }
export type Link = { from: number, to: number, kind: 'jump' | 'drop', dir: number, lo: number, hi: number, landX: number, frames: number }
export type Step = { kind: 'move' | 'jump' | 'drop', x: number, dir: number }

local ROWS: { Row } = {
    { name = 'floor', y = 192, x0 = 0, x1 = 256 },
    { name = 'lower', y = 144, x0 = 160, x1 = 352 },
    { name = 'centre', y = 80, x0 = 64, x1 = 192 },
    { name = 'stubs', y = 96, x0 = 224, x1 = 288 },
    { name = 'upper', y = 32, x0 = 160, x1 = 352 },
}
Nav.ROWS = ROWS
Nav.FLOOR = 1
Nav.LOWER = 2
Nav.CENTRE = 3
Nav.STUBS = 4
Nav.UPPER = 5

Nav.RUN_PX = 1.5 -- px per frame at full run, for travel estimates
Nav.SIM_FRAMES = 120

-- a row's own coordinate: x, or x + 256 when the segment wraps past the seam
function Nav.seg(row: Row, x: number): number
    local c = x + 8
    if c < row.x0 and c + 256 < row.x1 then
        return x + 256
    end
    return x
end

-- is a 16 px body at x standing over this row: a foot probe (x+4 or x+12, like the collision) is on it,
-- so a body can hang 12 px past an end, which is where the edge blocks get bumped from
function Nav.onRow(row: Row, x: number): boolean
    local sx = Nav.seg(row, x)
    local a, b = sx + 4, sx + 12
    return (a >= row.x0 and a < row.x1) or (b >= row.x0 and b < row.x1)
end

-- the player x that puts the head probe (x+8) in the 16 px block at bx while still standing on the row
function Nav.spotFor(row: number, bx: number): number?
    local r = ROWS[row]
    for x = bx, bx + 7 do
        if Nav.onRow(r, Stage.wrapX(x)) then
            return Stage.wrapX(x)
        end
    end
    for x = bx - 1, bx - 8, -1 do
        if Nav.onRow(r, Stage.wrapX(x)) then
            return Stage.wrapX(x)
        end
    end
    return nil
end

function Nav.rowAt(x: number, y: number): number?
    for i, r in ROWS do
        if r.y == y and Nav.onRow(r, x) then
            return i
        end
    end
    return nil
end

-- signed distance along a row from x to tx, the short way round on the floor
function Nav.dx(row: number, x: number, tx: number): number
    if row == Nav.FLOOR then
        return (tx - x + 128) % 256 - 128
    end
    local r = ROWS[row]
    return Nav.seg(r, tx) - Nav.seg(r, x)
end

-- the first row under (x, y): the nearest one with a larger y that covers x
function Nav.rowBelow(x: number, y: number): number?
    local best: number? = nil
    for i, r in ROWS do
        if r.y > y and Nav.onRow(r, x) and (best == nil or r.y < ROWS[best].y) then
            best = i
        end
    end
    return best
end

local function held(dir: number, run: boolean, jump: boolean): Input.Intent
    return { left = dir < 0, right = dir > 0, up = false, down = false, jump = jump, run = run, start = false }
end

-- run the real player from (x, row.y) holding dir (and jump when asked) until it lands on another row.
-- returns that row, the landing x and the frame count, or nil
local function fly(x: number, fromRow: number, dir: number, jump: boolean, vx: number): (number?, number, number)
    local w = World.new()
    local p = Players.new(1)
    p.body.x = Stage.wrapX(x)
    p.body.y = ROWS[fromRow].y
    p.body.vx = vx
    p.prevJump = false
    p.controller = 1
    for t = 1, Nav.SIM_FRAMES do
        Players.update(p, w, held(dir, true, jump))
        if p.state ~= Players.STATE_NORMAL then
            return nil, 0, t
        end
        if p.onGround and t > 2 then
            local r = Nav.rowAt(p.body.x, p.body.y)
            if r ~= nil and r ~= fromRow then
                return r, p.body.x, t
            end
            if not jump and r == fromRow then
                -- a drop that is still walking on its own row
                continue
            end
            if jump then
                return nil, 0, t -- back on the same row, or on the pow
            end
        end
    end
    return nil, 0, Nav.SIM_FRAMES
end

local LINKS: { Link } = {}
Nav.LINKS = LINKS

-- a jump link: from row `from`, standing d px outside the `endX` end of row `to`, holding `dir` toward it
local function findJump(from: number, to: number, endX: number, dir: number)
    local lo, hi, landX, frames = 0, 0, 0, 0
    local fromRow = ROWS[from]
    for d = 4, 72, 2 do
        local x = Stage.wrapX(endX - dir * d - 8)
        if not Nav.onRow(fromRow, x) then
            continue
        end
        -- the window must work from a standstill and at full run, the npc arrives at any speed between
        local r, lx, t = fly(x, from, dir, true, 0)
        local r2, _, _ = fly(x, from, dir, true, dir * Physics.RUN_MAX)
        if r == to and r2 == to then
            if lo == 0 then
                lo = d
                landX = lx
                frames = t
            end
            hi = d
        elseif lo ~= 0 then
            break
        end
    end
    if lo ~= 0 then
        -- the window in the from row's own coordinate, whichever way dir orders it
        local a = Nav.seg(fromRow, Stage.wrapX(endX - dir * hi - 8))
        local b = Nav.seg(fromRow, Stage.wrapX(endX - dir * lo - 8))
        local link: Link = { from = from, to = to, kind = 'jump', dir = dir, lo = math.min(a, b), hi = math.max(a, b), landX = landX, frames = frames }
        table.insert(LINKS, link)
    end
end

-- a drop: walk off the `endX` end of row `from` moving `dir`
local function findDrop(from: number, endX: number, dir: number)
    local x = Stage.wrapX(endX - dir * 4 - 8)
    local r, lx, t = fly(x, from, dir, false, 0)
    if r ~= nil then
        local sx = Nav.seg(ROWS[from], x)
        local link: Link = { from = from, to = r, kind = 'drop', dir = dir, lo = sx, hi = sx, landX = lx, frames = t }
        table.insert(LINKS, link)
    end
end

for i, r in ROWS do
    if r.x1 - r.x0 >= 256 then
        continue -- the floor has no ends
    end
    findDrop(i, r.x0, -1)
    findDrop(i, r.x1, 1)
    for j, lower in ROWS do
        if lower.y > r.y and lower.y - r.y <= 70 then
            findJump(j, i, r.x0, 1)
            findJump(j, i, r.x1, -1)
        end
    end
end

-- frames of travel between two points of one row
local function walk(row: number, x: number, tx: number): number
    return math.abs(Nav.dx(row, x, tx)) / Nav.RUN_PX
end

-- cheapest route: total frames and the first step to take from (row, x)
local function route(row: number, x: number, toRow: number, tx: number, seen: { [number]: boolean }): (number, Step?)
    if row == toRow then
        return walk(row, x, tx), { kind = 'move', x = tx, dir = 0 }
    end
    local best = math.huge
    local bestStep: Step? = nil
    seen[row] = true
    for _, l in LINKS do
        if l.from ~= row or seen[l.to] then
            continue
        end
        -- the nearest point of the launch window
        local ax = math.clamp(Nav.seg(ROWS[row], x), l.lo, l.hi)
        local rest, _ = route(l.to, l.landX, toRow, tx, seen)
        local cost = walk(row, x, ax) + l.frames + rest
        if cost < best then
            best = cost
            if l.kind == 'jump' then
                bestStep = { kind = 'jump', x = ax, dir = l.dir }
            else
                bestStep = { kind = 'drop', x = ax, dir = l.dir }
            end
        end
    end
    seen[row] = nil
    return best, bestStep
end

function Nav.travel(row: number, x: number, toRow: number, tx: number): number
    local cost, _ = route(row, x, toRow, tx, {})
    return cost
end

function Nav.step(row: number, x: number, toRow: number, tx: number): Step?
    local _, step = route(row, x, toRow, tx, {})
    return step
end

-- is x inside the launch window of the jump step (the window is in row coordinates)
function Nav.inWindow(row: number, x: number, step: Step): boolean
    for _, l in LINKS do
        if l.from == row and l.kind == 'jump' and l.dir == step.dir and step.x >= l.lo and step.x <= l.hi then
            local sx = Nav.seg(ROWS[row], x)
            return sx >= l.lo and sx <= l.hi
        end
    end
    return false
end

-- frames from a full jump on `below` until the head bumps the platform of `row`, nil when out of reach
local BUMP: { [number]: number } = {}
function Nav.bumpFrames(below: number, row: number): number?
    local key = below * 8 + row
    if BUMP[key] ~= nil then
        return if BUMP[key] > 0 then BUMP[key] else nil
    end
    -- any column where both rows are stacked, and the head really hits this row's platform bottom
    local b, r = ROWS[below], ROWS[row]
    local frames = 0
    for c = r.x0, r.x1 - 1, 16 do
        local x = Stage.wrapX(c - 8)
        if not Nav.onRow(b, x) then
            continue
        end
        local w = World.new()
        local p = Players.new(1)
        p.body.x = x
        p.body.y = b.y
        p.prevJump = false
        for t = 1, 40 do
            local ev = Players.update(p, w, held(0, false, true))
            if ev.bump then
                if p.body.y + 2 == r.y + 32 then
                    frames = t
                end
                break
            end
        end
        if frames > 0 then
            break
        end
    end
    BUMP[key] = frames
    return if frames > 0 then frames else nil
end

return Nav
