--!strict
-- shared arena state and collision probes: bounced blocks, the pow block, box overlaps.
-- transcribed from Vs_CollideAgainstWorld and the pow routine in PRG/prg009.asm.
local Stage = require('scripts/stage')
local Physics = require('scripts/physics')

local World = {}

export type Block = { x: number, y: number, cellY: number, vy: number, sub: number, frames: number }

export type State = {
    bounced: { [number]: number }, -- 16px block key -> frames left as a bounced block
    blocks: { Block }, -- the bumped block sprites in flight
    powHits: number,
    powCnt: number, -- Vs_POWBlockCnt, 16 frames of shake and mass flip
    shakeY: number,
    frame: number,
}

World.BLOCK_FRAMES = 0x0E
World.BLOCK_VY = -0x20
World.BLOCK_GRAVITY = 5
World.POW_CNT = 0x10
World.POW_SHAKES = { 0, 1, 4, 3 }

function World.new(): State
    return { bounced = {}, blocks = {}, powHits = 0, powCnt = 0, shakeY = 0, frame = 0 }
end

function World.reset(w: State)
    w.bounced = {}
    w.blocks = {}
    w.powHits = 0
    w.powCnt = 0
    w.shakeY = 0
    w.frame = 0
end

-- 16x16 block key, x wraps
function World.blockKey(x: number, y: number): number
    local col = (Stage.wrapX(math.floor(x))) // 16
    local row = math.floor(y) // 16
    return row * 16 + col
end

function World.isBounced(w: State, x: number, y: number): boolean
    return w.bounced[World.blockKey(x, y)] ~= nil
end

-- a player's head hit the block above at (x, y): it leaves the tile grid for 14 frames and bounces
function World.bump(w: State, x: number, y: number)
    local bx = Stage.wrapX(math.floor(x)) - Stage.wrapX(math.floor(x)) % 16
    local by = math.floor(y) - math.floor(y) % 16
    w.bounced[World.blockKey(bx, by)] = World.BLOCK_FRAMES
    table.insert(w.blocks, { x = bx, y = by, cellY = by, vy = World.BLOCK_VY, sub = 0, frames = World.BLOCK_FRAMES })
end

function World.hitPow(w: State)
    w.powHits += 1
    w.powCnt = World.POW_CNT
end

-- per frame bookkeeping: bounced tiles expire, block sprites fly, the pow shake runs its table
function World.update(w: State)
    w.frame += 1
    for key, left in w.bounced do
        if left <= 1 then
            w.bounced[key] = nil
        else
            w.bounced[key] = left - 1
        end
    end
    local kept: { Block } = {}
    for _, b in w.blocks do
        b.frames -= 1
        if b.frames > 0 then
            local y, sub = Physics.applyVel(b.y, b.sub, b.vy)
            b.y, b.sub = y, sub
            b.vy += World.BLOCK_GRAVITY
            table.insert(kept, b)
        end
    end
    w.blocks = kept
    if w.powCnt > 0 then
        w.powCnt -= 1
        w.shakeY = World.POW_SHAKES[((World.POW_CNT - w.powCnt) // 2) % 4 + 1]
    else
        w.shakeY = 0
    end
end

-- solid tile probe. a bounced block (TILE18_BOUNCEDBLOCK, $C2) stays solid in the rom: its under-hit bit is
-- only ever set after the tile passed the solidity check, so nothing falls through a block that is bouncing
function World.solidAt(w: State, x: number, y: number): boolean
    return Stage.solidAt(x, y)
end

export type Probe = { ground: boolean, ceiling: boolean, ceilingBounced: boolean, underHit: boolean, underHitLeft: boolean, underHitRight: boolean }

-- Vs_CollideAgainstWorld for a 16x16 body: floor probes at (x+4, y+16) and (x+12, y+16) count when
-- the body is within 6px of the tile top and not rising; the ceiling probe at (x+8, y) counts when
-- the head is at least 9px into the tile and rising. underHit is true when a foot stands on a bounced block.
function World.probe(w: State, b: Physics.Body): Probe
    local out: Probe = { ground = false, ceiling = false, ceilingBounced = false, underHit = false, underHitLeft = false, underHitRight = false }
    local fy = b.y + 16
    local left = b.x + 4
    local right = b.x + 12
    if b.vy >= 0 and fy % 16 < 6 then
        if World.solidAt(w, left, fy) or World.solidAt(w, right, fy) then
            out.ground = true
        end
    end
    if b.vy < 0 and b.y % 16 >= 9 and World.solidAt(w, b.x + 8, b.y) then
        out.ceiling = true
        out.ceilingBounced = World.isBounced(w, b.x + 8, b.y)
    end
    if fy % 16 < 6 then
        out.underHitLeft = Stage.solidAt(left, fy) and World.isBounced(w, left, fy)
        out.underHitRight = Stage.solidAt(right, fy) and World.isBounced(w, right, fy)
        out.underHit = out.underHitLeft or out.underHitRight
    end
    return out
end

-- Vs_CheckBoxCollision: two rectangles given as top-left plus size
function World.boxOverlap(ax: number, ay: number, aw: number, ah: number, bx: number, by: number, bw: number, bh: number): boolean
    return ax <= bx + bw and bx <= ax + aw and ay <= by + bh and by <= ay + ah
end

-- player box: x+4, y+2, 8x14 (VsPlayer_CalcBoundBox)
function World.playerBox(b: Physics.Body): (number, number, number, number)
    return b.x + 4, b.y + 2, 8, 14
end

-- enemy box: x+2, y+6, 12x4 (VsPlayer_CalcObjBoundBox)
function World.enemyBox(b: Physics.Body): (number, number, number, number)
    return b.x + 2, b.y + 6, 12, 4
end

return World
