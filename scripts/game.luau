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
    debug: number, -- --data=debug=1 spawns a fireball at once, 2 the ender (headless checks only)
    paused: boolean,
    prevStart: boolean,
    acc: number,
    blockImage: Image?,
    sampler: ImageSampler,
    black: Paint,
    path: Path,
    size: Vector,
}

-- view model -------------------------------------------------------------------------------------

local function pushVm(self: Game)
    local vm = self.vm
    if vm == nil then
        return
    end
    vm.phase.value = self.phase
    vm.winner.value = self.winner
    vm.coinsP1.value = self.coins[1]
    vm.coinsP2.value = self.coins[2]
    vm.shakeY.value = -self.world.shakeY
    vm.style.value = self.style
    vm.paused.value = self.paused
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
    end
    World.reset(self.world)
    Enemies.reset(self.enemies, self.style)
    self.enemyViews = {}
    Fireballs.reset(self.fireballs)
    self.fireballViews = {}
    for _, p in self.players do
        Players.reset(p)
    end
    self.coins = { 0, 0 }
    self.bumpCooldown = 0
    self.winner = 'none'
    self.phase = 'playing'
    self.overFrames = 0
    self.paused = false
end

local function endRound(self: Game, winner: Winner)
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

local function stepPlaying(self: Game)
    World.update(self.world)
    for i, p in self.players do
        local ev = Players.update(p, self.world, Input.intent(self.input, i))
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
    if eev.spawned then
        play(self, 'pipe')
    end
    if eev.flip then
        play(self, 'bump')
    end
    if eev.killed > 0 then
        killPlayer(self, eev.killed)
        return
    end
    if eev.kick then
        play(self, 'kick')
        play(self, 'coin')
        self.coins[eev.coin] += 1
        if self.coins[1] + self.coins[2] == 4 then
            Enemies.markLast(self.enemies)
        end
    end
    if self.debug > 0 and self.world.frame == 30 then
        if self.debug == 2 then
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

local function step(self: Game)
    local anyJump = false
    local anyStart = false
    for i = 1, 2 do
        local intent = Input.intent(self.input, i)
        anyJump = anyJump or intent.jump or intent.start
        anyStart = anyStart or intent.start
    end
    local startPressed = anyStart and not self.prevStart
    self.prevStart = anyStart
    if self.phase == 'title' then
        if anyJump then
            startRound(self)
        end
    elseif self.phase == 'playing' then
        if startPressed then
            self.paused = not self.paused
        end
        if not self.paused then
            stepPlaying(self)
        end
    else
        -- over: freeze, show the winner, then back to the title
        for _, p in self.players do
            if p.state == Players.STATE_DYING then
                Players.update(p, self.world, Input.intent(self.input, p.index))
            end
        end
        self.overFrames -= 1
        if self.overFrames <= 0 then
            self.phase = 'title'
            self.winner = 'none'
            self.style = (self.style + 1) % 6
            -- clear the arena behind the title
            World.reset(self.world)
            Enemies.reset(self.enemies, self.style)
            self.enemyViews = {}
            Fireballs.reset(self.fireballs)
            self.fireballViews = {}
            for _, p in self.players do
                Players.reset(p)
            end
            self.coins = { 0, 0 }
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

function draw(self: Game, renderer: Renderer)
    renderer:save()
    renderer:transform(Mat2D.withTranslation(0, -self.world.shakeY))
    -- bumped blocks: black out the tile, draw the block sprite where it has bounced to
    local block = self.blockImage
    for _, b in self.world.blocks do
        rect(self, b.x, b.y - b.y % 16, 16, 16)
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
            drawWrapped(renderer, view.inst, e.body.x + e.jitter, e.body.y, e.dir < 0)
        end
    end
    for _, f in self.fireballs.list do
        local view = self.fireballViews[f.id]
        if view ~= nil then
            drawWrapped(renderer, view.inst, f.body.x, f.body.y, f.dir < 0)
        end
    end
    for i, p in self.players do
        local inst = self.playerInst[i]
        if inst ~= nil then
            drawWrapped(renderer, inst, p.body.x, p.body.y, p.dir < 0)
        end
    end
    renderer:restore()
end

-- input ------------------------------------------------------------------------------------------

function keyboardEvent(self: Game, event: KeyboardEvent): boolean
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
