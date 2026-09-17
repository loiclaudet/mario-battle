--!strict
-- the playfield: runs the battle at a fixed 60 steps per second, writes the view models the markup
-- reads (phase, winner, coins, shake, entity poses) and draws the entity component instances.
local Stage = require('scripts/stage')
local Input = require('scripts/input')
local Sfx = require('scripts/sfx')
local World = require('scripts/world')
local Players = require('scripts/players')
local Enemies = require('scripts/enemies')
local Fireballs = require('scripts/fireballs')
local Menu = require('scripts/menu')
local Npc = require('scripts/npc')

type Phase = 'title' | 'playing' | 'over'
type Winner = 'none' | 'mario' | 'luigi'

local STEP = 1 / 60
local OVER_FRAMES = 0x80 -- Vs_TimeToExit
local HALT = 0xFF

type EnemyView = { inst: Artboard<Data.Enemy>, vm: Data.Enemy }
type FireballView = { inst: Artboard<Data.Fireball>, vm: Data.Fireball }

type Game = {
    playerArtboard: Input<Artboard<Data.Player>>,
    spinyArtboard: Input<Artboard<Data.Enemy>>,
    flyArtboard: Input<Artboard<Data.Enemy>>,
    crabArtboard: Input<Artboard<Data.Enemy>>,
    powArtboard: Input<Artboard<Data.Pow>>,
    fireballArtboard: Input<Artboard<Data.Fireball>>,
    powInst: Artboard<Data.Pow>?,
    powVm: Data.Pow?,
    fireballViews: { [number]: FireballView },
    -- the components' view models, nested in the Game view model and bound to the placements in game.rml
    overlayVm: Input<Data.Overlay>?,
    menuVm: Input<Data.Menu>?,
    cursor1: Input<Data.MenuCursor>?, -- the menu cursors, one per input slot, inside Menu
    cursor2: Input<Data.MenuCursor>?,
    cursor3: Input<Data.MenuCursor>?,
    cursor4: Input<Data.MenuCursor>?,
    hudSlot1: Input<Data.HudSlot>?, -- one per player
    hudSlot2: Input<Data.HudSlot>?,
    hudSlot3: Input<Data.HudSlot>?,
    hudSlot4: Input<Data.HudSlot>?,
    stage1: Input<Data.StageData>?, -- the stages in scene/stages, an empty map means no stage in that slot
    stage2: Input<Data.StageData>?,
    stage3: Input<Data.StageData>?,
    stage4: Input<Data.StageData>?,
    stage: number, -- the one this round plays, 1 based
    seed: number, -- the stage pick's lcg
    stageForced: boolean, -- --data=stage=n: play that stage every round
    menu: Menu.State,
    brains: { Npc.Brain }, -- one per player, used when the player has no controller
    ready: boolean,
    context: Context?,
    vm: Data.Game?,
    sfx: Sfx.Bank?,
    input: Input.State,
    world: World.State,
    players: { Players.Player },
    playerInst: { Artboard<Data.Player> },
    playerVm: { Data.Player },
    enemies: Enemies.State,
    enemyViews: { [number]: EnemyView }, -- by enemy slot
    fireballs: Fireballs.State,
    bumpCooldown: number,
    coins: { number },
    phase: Phase,
    winner: Winner,
    overFrames: number,
    style: number,
    debug: number, -- --data=debug=1 spawns a fireball at once, 2 the ender, 4 the boxes, 8 a round trace on the console
    paused: boolean,
    prevStart: boolean,
    acc: number,
    blockImage: Image?,
    sampler: ImageSampler,
    black: Paint,
    path: Path,
    pipeMask: Path, -- the screen minus the four pipes: enemies in a pipe draw behind them (SPR_BEHINDBG)
    showBoxes: boolean, -- F1 or --data=debug=4: draw the collision boxes
    boxPaint: Paint,
    size: Vector,
}

local function buildPipeMask(path: Path)
    path:reset()
    -- the screen, clockwise
    path:moveTo(Vector.xy(0, 0))
    path:lineTo(Vector.xy(Stage.WIDTH, 0))
    path:lineTo(Vector.xy(Stage.WIDTH, Stage.HEIGHT))
    path:lineTo(Vector.xy(0, Stage.HEIGHT))
    path:close()
    -- each pipe the other way round, so the clockwise fill rule subtracts it
    for _, p in Stage.PIPES do
        path:moveTo(Vector.xy(p.x, p.y))
        path:lineTo(Vector.xy(p.x, p.y + p.h))
        path:lineTo(Vector.xy(p.x + p.w, p.y + p.h))
        path:lineTo(Vector.xy(p.x + p.w, p.y))
        path:close()
    end
end

-- the stages with a map, in slot order
local function stageMaps(self: Game): { string }
    local maps: { string } = {}
    for _, s in { self.stage1, self.stage2, self.stage3, self.stage4 } do
        if s ~= nil then
            local map: string = s.map.value
            if map ~= '' then
                table.insert(maps, map)
            end
        end
    end
    return maps
end

-- pick the stage a round plays: --data=stage=n forces one, else a random one when there are several
local function pickStage(self: Game)
    local maps = stageMaps(self)
    if #maps == 0 then
        return -- the typical arena stage.luau loaded at require stays
    end
    local vm = self.vm
    local forced = if vm ~= nil then math.floor(vm.stage.value) else 0
    local index = forced
    if forced < 1 or forced > #maps or self.stageForced == false then
        self.seed = (self.seed * 1103515245 + 12345 + self.world.frame) % 2147483648
        index = self.seed % #maps + 1
    end
    self.stage = index
    if vm ~= nil then
        vm.stage.value = index
    end
    Stage.load(maps[index])
    buildPipeMask(self.pipeMask)
end

-- view model -------------------------------------------------------------------------------------

local function pushVm(self: Game)
    local vm = self.vm
    if vm == nil then
        return
    end
    vm.phase.value = self.phase
    vm.shakeY.value = -self.world.shakeY
    vm.style.value = self.style
    -- the overlay component: the pause banner, the winner's line
    local overlay = self.overlayVm
    if overlay ~= nil then
        overlay.pauseShown.value = if self.paused then 1 else 0
        overlay.winnerShown.value = if self.phase == 'over' and self.winner ~= 'none' then 1 else 0
        overlay.winnerText.value = string.upper(self.winner) .. ' WINS'
    end
    -- the hud components: one box per player
    local huds: { Input<Data.HudSlot>? } = { self.hudSlot1, self.hudSlot2, self.hudSlot3, self.hudSlot4 }
    for i, h in huds do
        if h ~= nil then
            local p = self.players[i]
            h.letter.value = i - 1
            h.coins.value = self.coins[i] or 0
            h.shown.value = if p ~= nil then 1 else 0
        end
    end
    -- the menu component: taken cards hop, the cursor outlines and markers follow scripts/menu.luau's layout
    local menuVm = self.menuVm
    if menuVm ~= nil then
        local locks = { menuVm.lock1, menuVm.lock2, menuVm.lock3, menuVm.lock4 }
        local modes = { menuVm.mode1, menuVm.mode2, menuVm.mode3, menuVm.mode4 }
        for card = 1, 4 do
            local exists = card <= #Menu.CARDS
            locks[card].value = if exists and Menu.isLocked(self.menu, card) then 1 else 0
            modes[card].value = if not exists then 'OFF' elseif Menu.isLocked(self.menu, card) then '' else 'CPU'
        end
    end
    if self.phase == 'title' then
        local cursors: { Input<Data.MenuCursor>? } = { self.cursor1, self.cursor2, self.cursor3, self.cursor4 }
        local views = Menu.layout(self.menu)
        for i, c in cursors do
            if c == nil then
                continue
            end
            local view = views[i]
            if view ~= nil then
                -- a 1 px stroke sits on pixel centres, so the rect is offset half a pixel and shrunk by one
                c.x.value = view.cursor.x + 0.5
                c.y.value = view.cursor.y + 0.5
                c.w.value = view.cursor.w - 1
                c.h.value = view.cursor.h - 1
                c.markerX.value = view.marker.x
                c.markerY.value = view.marker.y
                c.shown.value = 1
            else
                c.shown.value = 0
            end
        end
    end
    for i, p in self.players do
        local pvm = self.playerVm[i]
        if pvm ~= nil then
            pvm.pose.value = p.pose
        end
    end
    for _, e in self.enemies.list do
        local view = self.enemyViews[e.slot]
        if view ~= nil then
            view.vm.pose.value = e.pose
            view.vm.angry.value = e.angry
            view.vm.last.value = e.last
        end
    end
    local powVm = self.powVm
    if powVm ~= nil then
        powVm.hits.value = self.world.powHits
    end
    for _, f in self.fireballs.list do
        local view = self.fireballViews[f.id]
        if view ~= nil then
            view.vm.pose.value = f.pose
        end
    end
end

local function ensureFireballViews(self: Game)
    for _, f in self.fireballs.list do
        if self.fireballViews[f.id] == nil then
            local vm = Data.Fireball.new()
            self.fireballViews[f.id] = { inst = self.fireballArtboard:instance(vm), vm = vm }
        end
    end
end

-- every spawned enemy gets its own component instance, picked by kind
local function ensureEnemyViews(self: Game)
    for _, e in self.enemies.list do
        if self.enemyViews[e.slot] == nil then
            local vm = Data.Enemy.new()
            local source = if e.kind == 'spiny' then self.spinyArtboard elseif e.kind == 'fly' then self.flyArtboard else self.crabArtboard
            self.enemyViews[e.slot] = { inst = source:instance(vm), vm = vm }
        end
    end
end

local function play(self: Game, name: string)
    local bank = self.sfx
    if bank ~= nil then
        Sfx.play(bank, name)
    end
end

-- round flow -------------------------------------------------------------------------------------

local function startRound(self: Game)
    local vm = self.vm
    if vm ~= nil and vm.style.value ~= self.style then
        self.style = math.floor(vm.style.value) % 6 -- --data=style=n picks the enemy set
    end
    if vm ~= nil then
        self.debug = math.floor(vm.debug.value)
        if bit32.band(self.debug, 4) ~= 0 then
            self.showBoxes = true
        end
        if not self.stageForced and vm.stage.value ~= self.stage then
            self.stageForced = true -- --data=stage=n set it before the first round
        end
    end
    pickStage(self)
    World.reset(self.world)
    Enemies.reset(self.enemies, self.style)
    self.enemyViews = {}
    Fireballs.reset(self.fireballs)
    self.fireballViews = {}
    for i, p in self.players do
        Players.reset(p)
        self.brains[i] = Npc.new(i)
    end
    self.coins = { 0, 0 }
    self.bumpCooldown = 0
    self.winner = 'none'
    self.phase = 'playing'
    self.overFrames = 0
    self.paused = false
    local bank = self.sfx
    if bank ~= nil then
        Sfx.startMusic(bank)
    end
end

local function endRound(self: Game, winner: Winner)
    local bank = self.sfx
    if bank ~= nil then
        Sfx.stopMusic(bank)
    end
    self.phase = 'over'
    self.winner = winner
    self.overFrames = OVER_FRAMES
    for _, p in self.players do
        if p.state == Players.STATE_NORMAL then
            p.halt = HALT
        end
    end
    Enemies.haltAll(self.enemies)
    Fireballs.haltAll(self.fireballs)
end

-- a live enemy or a fireball touched a player: everything freezes and they fall off the screen
local function killPlayer(self: Game, index: number)
    local victim = self.players[index]
    if victim.state ~= Players.STATE_NORMAL then
        return
    end
    Players.kill(victim)
    local bank = self.sfx
    if bank ~= nil then
        Sfx.stopMusic(bank)
    end
    play(self, 'player_down')
    for i, p in self.players do
        if i ~= index then
            p.halt = HALT
        end
    end
    Enemies.haltAll(self.enemies)
    Fireballs.haltAll(self.fireballs)
end

-- one 1/60 step ----------------------------------------------------------------------------------

-- what drives a player this frame: its input slot, or the cpu brain
local function intentFor(self: Game, p: Players.Player): Input.Intent
    local slot = p.controller
    if slot == nil then
        return Npc.think(self.brains[p.index], p, self.world, self.enemies, self.fireballs, self.players, self.brains, self.coins)
    end
    return Input.intent(self.input, slot)
end

local function stepPlaying(self: Game)
    World.update(self.world)
    for i, p in self.players do
        local ev = Players.update(p, self.world, intentFor(self, p))
        if ev.jump then
            play(self, 'jump')
        end
        if ev.bump then
            play(self, 'bump')
        end
        if ev.stun then
            play(self, 'bump')
        end
        if ev.pow then
            play(self, 'pow')
        end
    end
    local cooldown, stunned = Players.bumpEachOther(self.players[1], self.players[2], self.bumpCooldown)
    self.bumpCooldown = cooldown
    if stunned then
        play(self, 'bump')
    end

    local halted = false
    for _, p in self.players do
        if p.halt > 0 or p.state == Players.STATE_DYING then
            halted = true
        end
    end
    local eev = Enemies.update(self.enemies, self.world, self.players, self.world.frame, halted)
    ensureEnemyViews(self)
    if bit32.band(self.debug, 8) ~= 0 and self.world.frame % 15 == 0 then
        -- a round trace for tuning the cpu: paste it back with what the human was doing
        local line = string.format('%5d c%d-%d', self.world.frame, self.coins[1], self.coins[2])
        for i, p in self.players do
            local plan = self.brains[i].plan
            local who = if Players.isNpc(p) then (if plan then plan.kind .. '>' .. plan.row .. ',' .. plan.x else '-') else 'human'
            line ..= string.format(' | p%d %d,%d %s%s %s', i, p.body.x, p.body.y, if p.onGround then 'g' else 'a', if p.dizzy > 0 then 'D' else '', who)
        end
        for _, e in self.enemies.list do
            line ..= string.format(' | %s%d %d,%d s%d', e.kind, e.slot, e.body.x, e.body.y, e.state)
        end
        print(line)
    end
    if eev.flip then
        play(self, 'bump')
    end
    if eev.entered then
        play(self, 'pipe') -- only the walk into a bottom pipe, the top pipes stay quiet
    end
    if eev.killed > 0 then
        killPlayer(self, eev.killed)
        return
    end
    if eev.kick then
        play(self, 'kick')
        play(self, 'coin')
        for _, who in eev.kicks do
            self.coins[who] += 1
        end
        if self.coins[1] + self.coins[2] == 4 then
            Enemies.markLast(self.enemies)
        end
    end
    if bit32.band(self.debug, 3) ~= 0 and self.world.frame == 30 then
        if bit32.band(self.debug, 2) ~= 0 then
            eev.ender = true
        else
            eev.fireball = true
        end
    end
    if eev.fireball or eev.ender then
        -- level with a random player, like Vs_Random picking the y
        local target = self.players[self.world.frame % 2 + 1]
        if eev.ender then
            Fireballs.spawnEnder(self.fireballs, self.enemies.spawnCnt2, target.body.y)
        else
            Fireballs.spawnHorz(self.fireballs, self.enemies.spawnCnt2, target.body.y)
        end
        play(self, 'fireball')
    end
    local fev = Fireballs.update(self.fireballs, self.world, self.players, self.world.frame)
    ensureFireballViews(self)
    if fev.killed > 0 then
        killPlayer(self, fev.killed)
        return
    end

    -- a dying player ends the round once they have fallen off the screen
    for i, p in self.players do
        if p.state == Players.STATE_DYING and p.body.y > Stage.HEIGHT + 16 then
            endRound(self, if i == 1 then 'luigi' else 'mario')
            return
        end
    end
    if self.coins[1] + self.coins[2] >= 5 then
        endRound(self, if self.coins[1] >= self.coins[2] then 'mario' else 'luigi')
    end
end

-- back to the menu with the next enemy set queued. the locks survive, the cursors sit on START
local function backToTitle(self: Game)
    local bank = self.sfx
    if bank ~= nil then
        Sfx.stopMusic(bank)
    end
    self.phase = 'title'
    self.winner = 'none'
    self.paused = false
    self.style = (self.style + 1) % 6
    World.reset(self.world)
    Enemies.reset(self.enemies, self.style)
    self.enemyViews = {}
    Fireballs.reset(self.fireballs)
    self.fireballViews = {}
    for _, p in self.players do
        Players.reset(p)
    end
    self.coins = { 0, 0 }
    Menu.rearm(self.menu)
end

local function hasHuman(self: Game): boolean
    for _, p in self.players do
        if not Players.isNpc(p) then
            return true
        end
    end
    return false
end

-- the menu: each slot steers its cursor, a lock hops the brother, START (or the start button) launches
local function stepTitle(self: Game)
    local intents: { Input.Intent } = {}
    for i = 1, #self.menu.slots do
        intents[i] = Input.intent(self.input, i)
    end
    local ev = Menu.update(self.menu, intents)
    if ev.locked then
        play(self, 'jump')
    end
    if ev.unlocked or ev.refused then
        play(self, 'bump')
    end
    if ev.launch then
        for i, p in self.players do
            Players.setController(p, Menu.controllerFor(self.menu, i))
        end
        startRound(self)
    end
end

local function step(self: Game)
    local anyStart = false
    for i = 1, #self.menu.slots do
        anyStart = anyStart or Input.intent(self.input, i).start
    end
    local startPressed = anyStart and not self.prevStart
    self.prevStart = anyStart
    if self.phase == 'title' then
        stepTitle(self)
    elseif self.phase == 'playing' then
        if startPressed then
            -- start pauses a real round; a demo with two npcs goes back to the menu instead
            if hasHuman(self) then
                self.paused = not self.paused
            else
                backToTitle(self)
                return
            end
        end
        if not self.paused then
            stepPlaying(self)
        end
    else
        -- over: everything is halted except a dying player and the last kicked enemy, which keep
        -- flying off like in the rom (Vs_ObjStateDying skips the halt for the last object)
        for _, p in self.players do
            if p.state == Players.STATE_DYING then
                Players.update(p, self.world, intentFor(self, p))
            end
        end
        World.update(self.world)
        Enemies.update(self.enemies, self.world, self.players, self.world.frame, true)
        Fireballs.update(self.fireballs, self.world, self.players, self.world.frame)
        self.overFrames -= 1
        if self.overFrames <= 0 then
            backToTitle(self)
        end
    end
end

-- lifecycle --------------------------------------------------------------------------------------

function init(self: Game, context: Context): boolean
    self.context = context
    local vm = context:viewModel()
    if vm ~= nil then
        self.vm = vm :: any
    end
    return true
end

function resize(self: Game, size: Vector, scale: number)
    self.size = size
end

local function ensureReady(self: Game)
    if self.ready then
        return
    end
    local context = self.context
    if context == nil then
        return
    end
    self.ready = true
    self.sfx = Sfx.load(context)
    self.blockImage = context:image('block')
    buildPipeMask(self.pipeMask)
    for i = 1, 2 do
        local pvm = Data.Player.new()
        pvm.character.value = if i == 1 then 'mario' else 'luigi'
        self.playerVm[i] = pvm
        self.playerInst[i] = self.playerArtboard:instance(pvm)
    end
    local powVm = Data.Pow.new()
    self.powVm = powVm
    self.powInst = self.powArtboard:instance(powVm)
    print('game ready')
end

function advance(self: Game, seconds: number): boolean
    ensureReady(self)
    self.acc += math.min(seconds, 0.25)
    while self.acc >= STEP do
        self.acc -= STEP
        step(self)
    end
    pushVm(self)
    local bank = self.sfx
    if bank ~= nil then
        Sfx.updateMusic(bank)
    end
    for _, inst in self.playerInst do
        inst:advance(seconds)
    end
    for _, view in self.enemyViews do
        view.inst:advance(seconds)
    end
    for _, view in self.fireballViews do
        view.inst:advance(seconds)
    end
    local powInst = self.powInst
    if powInst ~= nil then
        powInst:advance(seconds)
    end
    return true
end

-- drawing ----------------------------------------------------------------------------------------

local function drawInstance(renderer: Renderer, inst: Artboard<any>, x: number, y: number, flip: boolean)
    renderer:save()
    if flip then
        renderer:transform(Mat2D.withScaleAndTranslation(-1, 1, x + 16, y))
    else
        renderer:transform(Mat2D.withTranslation(x, y))
    end
    inst:draw(renderer)
    renderer:restore()
end

-- entities near an edge are drawn on both sides so the wrap is seamless
local function drawWrapped(renderer: Renderer, inst: Artboard<any>, x: number, y: number, flip: boolean)
    drawInstance(renderer, inst, x, y, flip)
    if x > Stage.WIDTH - 16 then
        drawInstance(renderer, inst, x - Stage.WIDTH, y, flip)
    elseif x < 0 then
        drawInstance(renderer, inst, x + Stage.WIDTH, y, flip)
    end
end

local function rect(self: Game, x: number, y: number, w: number, h: number)
    self.path:reset()
    self.path:moveTo(Vector.xy(x, y))
    self.path:lineTo(Vector.xy(x + w, y))
    self.path:lineTo(Vector.xy(x + w, y + h))
    self.path:lineTo(Vector.xy(x, y + h))
    self.path:close()
end

-- debug overlay: the rom's collision boxes (player x+4,y+2 8x14; objects x+2,y+6 12x4; the pow)
local function outline(self: Game, renderer: Renderer, x: number, y: number, w: number, h: number)
    rect(self, x, y, w + 1, h + 1)
    renderer:drawPath(self.path, self.boxPaint)
end

local function drawBoxes(self: Game, renderer: Renderer)
    -- the stage's map over its art: every solid tile tinted, so a map that drifted from the art shows
    local tint = Paint.with({ color = Color.rgba(255, 0, 255, 90) })
    for row = 0, Stage.ROWS - 1 do
        for col = 0, Stage.COLS - 1 do
            if Stage.solidAt(col * Stage.TILE, row * Stage.TILE) then
                self.path:reset()
                self.path:moveTo(Vector.xy(col * Stage.TILE, row * Stage.TILE))
                self.path:lineTo(Vector.xy(col * Stage.TILE + Stage.TILE, row * Stage.TILE))
                self.path:lineTo(Vector.xy(col * Stage.TILE + Stage.TILE, row * Stage.TILE + Stage.TILE))
                self.path:lineTo(Vector.xy(col * Stage.TILE, row * Stage.TILE + Stage.TILE))
                self.path:close()
                renderer:drawPath(self.path, tint)
            end
        end
    end
    for _, p in self.players do
        outline(self, renderer, World.playerBox(p.body))
    end
    for _, e in self.enemies.list do
        outline(self, renderer, World.enemyBox(e.body))
    end
    for _, f in self.fireballs.list do
        if f.pose == 'flying' then
            outline(self, renderer, World.enemyBox(f.body))
        end
    end
    local pow = Stage.powRect(self.world.powHits)
    if pow ~= nil then
        outline(self, renderer, pow.x, pow.y, pow.w, pow.h)
    end
end

function draw(self: Game, renderer: Renderer)
    if self.phase == 'title' then
        return -- the menu is markup, and the arena is hidden behind it
    end
    renderer:save()
    renderer:transform(Mat2D.withTranslation(0, -self.world.shakeY))
    -- bumped blocks: black out the tile, draw the block sprite where it has bounced to
    local block = self.blockImage
    for _, b in self.world.blocks do
        rect(self, b.x, b.cellY, 16, 16)
        renderer:drawPath(self.path, self.black)
        if block ~= nil then
            renderer:save()
            renderer:transform(Mat2D.withTranslation(b.x, b.y))
            renderer:drawImage(block, self.sampler, 'srcOver', 1)
            renderer:restore()
        end
    end
    local powInst = self.powInst
    if powInst ~= nil then
        drawInstance(renderer, powInst, Stage.POW_X, Stage.POW_Y, false)
    end
    for _, e in self.enemies.list do
        local view = self.enemyViews[e.slot]
        if view ~= nil then
            if e.pipeTimer > 0 then
                -- in a pipe: 3 px higher and hidden by the pipe art, like the rom's behind-background sprite
                renderer:save()
                renderer:clipPath(self.pipeMask)
                drawWrapped(renderer, view.inst, e.body.x + e.jitter, e.body.y - 3, e.dir < 0)
                renderer:restore()
            else
                drawWrapped(renderer, view.inst, e.body.x + e.jitter, e.body.y, e.dir < 0)
            end
        end
    end
    for _, f in self.fireballs.list do
        local view = self.fireballViews[f.id]
        if view ~= nil then
            if f.kind == 'ender' then
                drawWrapped(renderer, view.inst, f.body.x, f.body.y, f.dir < 0)
            else
                drawInstance(renderer, view.inst, Fireballs.drawX(f), f.body.y, f.dir < 0)
            end
        end
    end
    for i, p in self.players do
        local inst = self.playerInst[i]
        if inst ~= nil then
            drawWrapped(renderer, inst, p.body.x, p.body.y, p.dir < 0)
        end
    end
    if self.showBoxes then
        drawBoxes(self, renderer)
    end
    renderer:restore()
end

-- input ------------------------------------------------------------------------------------------

function keyboardEvent(self: Game, event: KeyboardEvent): boolean
    if event.phase == 'down' and event.key == 290 then
        self.showBoxes = not self.showBoxes -- F1
    end
    if event.phase == 'down' then
        Input.keyDown(self.input, event.key)
    elseif event.phase == 'up' then
        Input.keyUp(self.input, event.key)
    end
    return true
end

function gamepadConnected(self: Game, event: GamepadConnected)
    Input.padConnected(self.input, event.deviceId)
end

function gamepadDisconnected(self: Game, event: GamepadDisconnected)
    Input.padDisconnected(self.input, event.deviceId)
end

function gamepadEvent(self: Game, event: GamepadEvent)
    Input.padEvent(self.input, event)
end

return function(context: Context): Layout<Game>
    return {
        playerArtboard = late(),
        spinyArtboard = late(),
        flyArtboard = late(),
        crabArtboard = late(),
        powArtboard = late(),
        fireballArtboard = late(),
        powInst = nil,
        powVm = nil,
        fireballViews = {},
        overlayVm = nil,
        menuVm = nil,
        cursor1 = nil,
        cursor2 = nil,
        cursor3 = nil,
        cursor4 = nil,
        hudSlot1 = nil,
        hudSlot2 = nil,
        hudSlot3 = nil,
        hudSlot4 = nil,
        stage1 = nil,
        stage2 = nil,
        stage3 = nil,
        stage4 = nil,
        stage = 1,
        seed = 7,
        stageForced = false,
        menu = Menu.new(2),
        brains = { Npc.new(1), Npc.new(2) },
        ready = false,
        context = nil,
        vm = nil,
        sfx = nil,
        input = Input.new(),
        world = World.new(),
        players = { Players.new(1), Players.new(2) },
        playerInst = {},
        playerVm = {},
        enemies = Enemies.new(),
        enemyViews = {},
        fireballs = Fireballs.new(),
        bumpCooldown = 0,
        coins = { 0, 0 },
        phase = 'title',
        winner = 'none',
        overFrames = 0,
        style = 0,
        debug = 0,
        paused = false,
        prevStart = false,
        acc = 0,
        blockImage = nil,
        sampler = ImageSampler('clamp', 'clamp', 'nearest'),
        black = Paint.with({ color = Color.rgb(0, 0, 0) }),
        path = Path.new(),
        pipeMask = Path.new(),
        showBoxes = false,
        boxPaint = Paint.with({ color = Color.rgb(0, 255, 0), style = 'stroke', thickness = 1 }),
        size = Vector.xy(256, 240),
        init = init,
        resize = resize,
        advance = advance,
        draw = draw,
        keyboardEvent = keyboardEvent,
        gamepadConnected = gamepadConnected,
        gamepadDisconnected = gamepadDisconnected,
        gamepadEvent = gamepadEvent,
    }
end
