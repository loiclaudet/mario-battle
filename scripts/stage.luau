--!strict
-- the arena: a 32x30 grid of 8px tiles read from PRG/levels/2PVs/Typical.asm, plus the POW block.
-- everything is in nes framebuffer pixels (256x240, y down). pipes are scenery, not solid.
local Stage = {}

Stage.WIDTH = 256
Stage.HEIGHT = 240
Stage.TILE = 8
Stage.FLOOR_TOP = 208

-- solid rectangles: x, y, w, h (the four pipes are deliberately absent)
Stage.PLATFORMS = {
    { x = 0, y = 48, w = 96, h = 16 }, -- upper ledge left
    { x = 160, y = 48, w = 96, h = 16 }, -- upper ledge right
    { x = 64, y = 96, w = 128, h = 16 }, -- centre platform
    { x = 0, y = 112, w = 32, h = 16 }, -- edge stub left
    { x = 224, y = 112, w = 32, h = 16 }, -- edge stub right
    { x = 0, y = 160, w = 96, h = 16 }, -- lower ledge left
    { x = 160, y = 160, w = 96, h = 16 }, -- lower ledge right
    { x = 0, y = 208, w = 256, h = 32 }, -- floor
}

-- POW block (Vs_POW_X / Vs_POW_Y). Vs_POWHeight is how much the box shrinks per hit taken: the
-- box top stays at POW_Y and the bottom offset is 16 minus it, so the box is 15, 12 then 10 tall.
Stage.POW_X = 120
Stage.POW_Y = 152
Stage.POW_W = 16
Stage.POW_YOFF = { 1, 4, 6 }

-- spawn and pipe constants (Vs_SpawnEnemyStartX, Vs_BottomPipeEntranceX, Vs_BottomPipeLimitX, Vs_HFireballX)
Stage.SPAWN_X = { 16, 224 }
Stage.SPAWN_Y = 32
Stage.BOTTOM_PIPE_ENTRANCE_X = { 208, 32 } -- moving right, moving left
Stage.BOTTOM_PIPE_LIMIT_X = { 224, 16 }
Stage.FIREBALL_X = { 8, 232 }
Stage.PLAYER_START_X = { 64, 176 }

local grid: { { boolean } } = {}
for row = 0, 29 do
    local cells: { boolean } = {}
    for col = 0, 31 do
        cells[col + 1] = false
    end
    grid[row + 1] = cells
end
for _, p in Stage.PLATFORMS do
    for row = p.y // 8, (p.y + p.h) // 8 - 1 do
        for col = p.x // 8, (p.x + p.w) // 8 - 1 do
            grid[row + 1][col + 1] = true
        end
    end
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
    local col = Stage.wrapX(math.floor(x)) // 8
    local row = math.floor(y) // 8
    return grid[row + 1][col + 1]
end

-- top edge of the solid tile containing (x, y), or nil
function Stage.tileTopAt(x: number, y: number): number?
    if not Stage.solidAt(x, y) then
        return nil
    end
    return (math.floor(y) // 8) * 8
end

-- bottom edge of the solid tile containing (x, y), or nil
function Stage.tileBottomAt(x: number, y: number): number?
    if not Stage.solidAt(x, y) then
        return nil
    end
    return (math.floor(y) // 8) * 8 + 8
end

-- POW collision rectangle for the given number of hits taken (0..2), nil once it is used up
function Stage.powRect(hits: number): { x: number, y: number, w: number, h: number }?
    if hits >= 3 then
        return nil
    end
    return { x = Stage.POW_X, y = Stage.POW_Y, w = Stage.POW_W, h = 16 - Stage.POW_YOFF[hits + 1] }
end

return Stage
