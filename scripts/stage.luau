--!strict
-- the arena, read from a stage's tile map: 30 rows of 32 tiles of 8 px (the rom's grid), rows joined with '|'.
-- '#' solid, 'T' / 'B' the top left tile of a 32x32 top / bottom pipe (scenery: the top ones spawn enemies, the
-- bottom ones recycle them), 'P' the top left tile of the pow, '1'..'4' where player n starts (the top left of its
-- 16x16 body, facing right on the left half). every other module reads the tables Stage.load fills, and the
-- ones that build on them at require time (nav, npc) register a rebuild with Stage.onLoad. the typical smb3
-- arena (PRG/levels/2PVs/Typical.asm) is loaded at require; scripts/game.luau loads the stage a round plays.
-- everything is in nes framebuffer pixels (256x240, y down).
local Stage = {}

Stage.WIDTH = 256
Stage.HEIGHT = 240
Stage.TILE = 8
Stage.COLS = 32
Stage.ROWS = 30

export type Rect = { x: number, y: number, w: number, h: number }
export type Start = { x: number, y: number, dir: number }

-- filled by Stage.load
Stage.PLATFORMS = {} :: { Rect } -- solid rectangles (the four pipes are deliberately absent)
Stage.TOP_PIPES = {} :: { Rect } -- left then right
Stage.BOTTOM_PIPES = {} :: { Rect }
Stage.PIPES = {} :: { Rect } -- all four, for the pipe mask
Stage.FLOOR_TOP = 208 -- the lowest platform's top
Stage.SPAWN_X = { 16, 224 } -- Vs_SpawnEnemyStartX: inside the left top pipe, inside the right one
Stage.SPAWN_Y = 32
Stage.BOTTOM_PIPE_ENTRANCE_X = { 208, 32 } -- Vs_BottomPipeEntranceX: moving right (into the right pipe), moving left
Stage.BOTTOM_PIPE_LIMIT_X = { 224, 16 } -- Vs_BottomPipeLimitX
Stage.BOTTOM_PIPE_Y = 176 -- the bottom pipes' top: an enemy recycles only from that height
Stage.PLAYER_START = {} :: { Start }
-- POW block (Vs_POW_X / Vs_POW_Y). Vs_POWHeight is how much the box shrinks per hit taken: the
-- box top stays at POW_Y and the bottom offset is 16 minus it, so the box is 15, 12 then 10 tall.
Stage.POW_X = 120
Stage.POW_Y = 152
Stage.POW_W = 16
Stage.POW_YOFF = { 1, 4, 6 }

-- the typical arena. keep scene/stages/typical.rml's map identical (tools/gen_stages_rml.py writes both maps)
Stage.TYPICAL = table.concat({
    '................................',
    '................................',
    'T...........................T...',
    '................................',
    '................................',
    '................................',
    '############........############',
    '############........############',
    '................................',
    '................................',
    '................................',
    '................................',
    '........################........',
    '........################........',
    '####........................####',
    '####........................####',
    '................................',
    '................................',
    '.3...........................4..',
    '...............P................',
    '############........############',
    '############........############',
    'B...........................B...',
    '................................',
    '........1.............2.........',
    '................................',
    '################################',
    '################################',
    '################################',
    '################################',
}, '|')

local grid: { { boolean } } = {}
for row = 0, Stage.ROWS - 1 do
    local cells: { boolean } = {}
    for col = 0, Stage.COLS - 1 do
        cells[col + 1] = false
    end
    grid[row + 1] = cells
end

local listeners: { () -> () } = {}

-- run fn after every load (and now, if a stage is loaded already): nav and npc rebuild their tables with it
function Stage.onLoad(fn: () -> ())
    table.insert(listeners, fn)
end

-- wrap an x coordinate into 0..255 (the rom stores x in one byte)
function Stage.wrapX(x: number): number
    return x % Stage.WIDTH
end

-- is the tile under this pixel solid? x wraps, y outside the screen is never solid
function Stage.solidAt(x: number, y: number): boolean
    if y < 0 or y >= Stage.HEIGHT then
        return false
    end
    local col = Stage.wrapX(math.floor(x)) // Stage.TILE
    local row = math.floor(y) // Stage.TILE
    return grid[row + 1][col + 1]
end

-- top edge of the solid tile containing (x, y), or nil
function Stage.tileTopAt(x: number, y: number): number?
    if not Stage.solidAt(x, y) then
        return nil
    end
    return (math.floor(y) // Stage.TILE) * Stage.TILE
end

-- bottom edge of the solid tile containing (x, y), or nil
function Stage.tileBottomAt(x: number, y: number): number?
    if not Stage.solidAt(x, y) then
        return nil
    end
    return (math.floor(y) // Stage.TILE) * Stage.TILE + Stage.TILE
end

-- POW collision rectangle for the given number of hits taken (0..2), nil once it is used up
function Stage.powRect(hits: number): Rect?
    if hits >= 3 then
        return nil
    end
    return { x = Stage.POW_X, y = Stage.POW_Y, w = Stage.POW_W, h = 16 - Stage.POW_YOFF[hits + 1] }
end

-- the map's rows as strings, padded or cut to the grid
local function rows(map: string): { string }
    local out: { string } = {}
    for line in string.gmatch(map .. '|', '([^|]*)|') do
        table.insert(out, line)
    end
    while #out < Stage.ROWS do
        table.insert(out, '')
    end
    return out
end

local function tile(lines: { string }, col: number, row: number): string
    local line = lines[row + 1]
    if line == nil or col >= #line then
        return '.'
    end
    return string.sub(line, col + 1, col + 1)
end

-- solid rectangles: horizontal runs of '#' per tile row, then rows with the same run stacked into one rect
local function platforms(lines: { string }): { Rect }
    local runs: { Rect } = {}
    for row = 0, Stage.ROWS - 1 do
        local col = 0
        while col < Stage.COLS do
            if tile(lines, col, row) == '#' then
                local start = col
                while col < Stage.COLS and tile(lines, col, row) == '#' do
                    col += 1
                end
                table.insert(runs, { x = start * Stage.TILE, y = row * Stage.TILE, w = (col - start) * Stage.TILE, h = Stage.TILE })
            else
                col += 1
            end
        end
    end
    local merged: { Rect } = {}
    for _, r in runs do
        local joined = false
        for _, m in merged do
            if m.x == r.x and m.w == r.w and m.y + m.h == r.y then
                m.h += r.h
                joined = true
                break
            end
        end
        if not joined then
            table.insert(merged, { x = r.x, y = r.y, w = r.w, h = r.h })
        end
    end
    return merged
end

-- read a map into every table above, then tell nav and npc
function Stage.load(map: string)
    local lines = rows(map)
    for row = 0, Stage.ROWS - 1 do
        for col = 0, Stage.COLS - 1 do
            grid[row + 1][col + 1] = tile(lines, col, row) == '#'
        end
    end
    Stage.PLATFORMS = platforms(lines)
    local floorTop = Stage.HEIGHT
    for _, p in Stage.PLATFORMS do
        if p.w >= Stage.WIDTH and p.y < floorTop then
            floorTop = p.y
        end
    end
    Stage.FLOOR_TOP = floorTop
    local tops: { Rect } = {}
    local bottoms: { Rect } = {}
    local starts: { Start } = {}
    for row = 0, Stage.ROWS - 1 do
        for col = 0, Stage.COLS - 1 do
            local t = tile(lines, col, row)
            local x, y = col * Stage.TILE, row * Stage.TILE
            if t == 'T' then
                table.insert(tops, { x = x, y = y, w = 32, h = 32 })
            elseif t == 'B' then
                table.insert(bottoms, { x = x, y = y, w = 32, h = 32 })
            elseif t == 'P' then
                Stage.POW_X = x
                Stage.POW_Y = y
            elseif t >= '1' and t <= '4' then
                starts[tonumber(t) :: number] = { x = x, y = y, dir = if x < Stage.WIDTH / 2 then 1 else -1 }
            end
        end
    end
    table.sort(tops, function(a: Rect, b: Rect)
        return a.x < b.x
    end)
    table.sort(bottoms, function(a: Rect, b: Rect)
        return a.x < b.x
    end)
    Stage.TOP_PIPES = tops
    Stage.BOTTOM_PIPES = bottoms
    Stage.PIPES = {}
    for _, p in tops do
        table.insert(Stage.PIPES, p)
    end
    for _, p in bottoms do
        table.insert(Stage.PIPES, p)
    end
    if #tops >= 2 then
        -- an enemy walks out from inside the pipe: 16 px in from the left pipe's edge, at the right pipe's edge
        Stage.SPAWN_X = { tops[1].x + 16, tops[2].x }
        Stage.SPAWN_Y = tops[1].y + 16
    end
    if #bottoms >= 2 then
        -- walking right into the right pipe: in at 16 px before it, gone at its edge; walking left into the left one
        Stage.BOTTOM_PIPE_ENTRANCE_X = { bottoms[2].x - 16, bottoms[1].x + 32 }
        Stage.BOTTOM_PIPE_LIMIT_X = { bottoms[2].x, bottoms[1].x + 16 }
        Stage.BOTTOM_PIPE_Y = bottoms[1].y
    end
    Stage.PLAYER_START = {}
    for i = 1, 4 do
        Stage.PLAYER_START[i] = starts[i] or { x = 64 + (i - 1) * 40, y = Stage.FLOOR_TOP - 16, dir = 1 }
    end
    for _, fn in listeners do
        fn()
    end
end

Stage.load(Stage.TYPICAL)

return Stage
