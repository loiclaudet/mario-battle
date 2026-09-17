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
local Sim = require('scripts/sim')

type Phase = 'title' | 'playing' | 'over'
type Character = 'mario' | 'luigi' | 'wario' | 'waluigi'
-- a coin on its way from where it was won to the hud, eased in over FLIGHT_FRAMES
type Flight = { x0: number, y0: number, x1: number, y1: number, t: number, player: number }
local FLIGHT_FRAMES = 30
local FLIGHT_GAP = 6 -- frames between two coins leaving the same spot
local BLINK = 4 -- frames per half of an invincible player's blink
local BLUE_FRAMES = 40
local HUD_X = { 8, 68, 128, 188 } -- the hud slots, as placed in game.rml
local COIN_X, COIN_Y = 16, 4 -- the first coin fill inside a slot, 8 px apart
type Winner = 'none' | Character
local CHARACTERS: { Character } = { 'mario', 'luigi', 'wario', 'waluigi' } -- card and player index to name

local STEP = 1 / 60
local OVER_FRAMES = 0x80 -- Vs_TimeToExit: the result holds this long before the MENU button appears
local DEMO_OVER_FRAMES = 0x80 * 4 -- a cpu only round goes back on its own after this
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
    round: Sim.Snap, -- the live round state Sim.step advances: the world, enemies, fireballs, players and coins
    shownCoins: { number }, -- what the hud shows: a coin lights once its sprite has flown there
    flights: { Flight }, -- coin sprites on their way to the hud
    blueFade: { number }, -- per player, 0 normal to 1 blue, eased over BLUE_FRAMES
    off: { boolean }, -- per player, sitting this round out (the menu's off cards)
    lastKilled: number, -- the death that ended the round, whose fall the over phase waits for
    coins: { number },
    phase: Phase,
    winner: Winner,
    overFrames: number,
    overArmed: boolean, -- the over screen takes a press only once every button has been let go
    style: number,
    debug: number, -- --data=debug=1 spawns a fireball at once, 2 the ender, 4 the boxes, 8 a round trace on the console
    paused: boolean,
    prevStart: boolean,
    acc: number,
    blockImage: Image?,
    coinImage: Image?,
    letterImages: { Image? }, -- each character's initial, drawn over a target's head when two are blue
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
        overlay.menuShown.value = if self.phase == 'over' and self.overFrames <= 0 then 1 else 0
    end
    -- the hud components: one box per player
    local huds: { Input<Data.HudSlot>? } = { self.hudSlot1, self.hudSlot2, self.hudSlot3, self.hudSlot4 }
    for i, h in huds do
        if h ~= nil then
            local p = self.players[i]
            h.letter.value = i - 1
            h.coins.value = self.shownCoins[i] or 0
            h.coinsBlue.value = if p ~= nil and p.blue then self.shownCoins[i] or 0 else 0
            h.shown.value = if p ~= nil and p.state == Players.STATE_NORMAL then 1 else 0 -- gone with the player
        end
    end
    -- the menu component: taken cards hop, the cursor outlines and markers follow scripts/menu.luau's layout
    local menuVm = self.menuVm
    if menuVm ~= nil then
        local locks = { menuVm.lock1, menuVm.lock2, menuVm.lock3, menuVm.lock4 }
        local modes = { menuVm.mode1, menuVm.mode2, menuVm.mode3, menuVm.mode4 }
        for card = 1, #Menu.CARDS do
            local role = Menu.roleFor(self.menu, card)
            locks[card].value = if type(role) == 'number' then 1 else 0
            modes[card].value = if role == 'cpu' then 'CPU' elseif role == 'off' then 'OFF' else ''
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
            pvm.blue.value = self.blueFade[i] or 0
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
        if self.off[i] then
            p.state = Players.STATE_OFF
        end
        self.brains[i] = Npc.new(i)
    end
    Sim.resetScore(self.round)
    self.shownCoins = { 0, 0, 0, 0 }
    self.flights = {}
    self.blueFade = { 0, 0, 0, 0 }
    self.lastKilled = 0
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
    self.overArmed = false
    for _, p in self.players do
        if p.state == Players.STATE_NORMAL then
            p.halt = HALT
        end
    end
    Enemies.haltAll(self.enemies)
    Fireballs.haltAll(self.fireballs)
end

-- a live enemy or a fireball touched a player: everything freezes and they fall off the screen
-- a player died this step (Sim.step already dropped their coins and gave them back as enemies). with others
-- still alive the round goes on around the falling body; with one left the round is theirs once the body is gone
local function onDeath(self: Game, index: number)
    if not self.players[index].blue then
        play(self, 'player_down') -- a beaten target goes quietly, like a kicked enemy
    end
    -- the round is over when nobody else can win: one player left, or one contender left beside the targets
    local alive = Players.alive(self.players)
    local contenders = Sim.contenders(self.round)
    if #alive > 1 and #contenders > 1 then
        return
    end
    if #alive > 1 and #contenders == 1 and #alive - #contenders > 0 then
        -- the last contender wins at once over the targets left standing
        endRound(self, CHARACTERS[contenders[1]])
        return
    end
    local bank = self.sfx
    if bank ~= nil then
        Sfx.stopMusic(bank)
    end
    for i, p in self.players do
        if i ~= index and p.state == Players.STATE_NORMAL then
            p.halt = HALT
        end
    end
    Enemies.haltAll(self.enemies)
    Fireballs.haltAll(self.fireballs)
    self.lastKilled = index
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

-- coins in the air for a player
local function flightsFor(self: Game, player: number): number
    local n = 0
    for _, f in self.flights do
        if f.player == player then
            n += 1
        end
    end
    return n
end

-- a coin leaves (x, y) for the next free fill of the player's hud slot, after `delay` frames
local function launchCoin(self: Game, player: number, x: number, y: number, delay: number?)
    local slot = self.shownCoins[player] + flightsFor(self, player) + 1
    if slot > 5 then
        return
    end
    table.insert(self.flights, { x0 = x + 4, y0 = y + 4, x1 = HUD_X[player] + COIN_X + 8 * (slot - 1), y1 = COIN_Y, t = -(delay or 0), player = player })
end

-- the coins fly with an ease in, and light their fill on arrival; the blue fades settle towards the state
local function stepEffects(self: Game)
    local kept: { Flight } = {}
    for _, f in self.flights do
        f.t += 1
        if f.t >= FLIGHT_FRAMES then
            self.shownCoins[f.player] = math.min(5, self.shownCoins[f.player] + 1)
        else
            table.insert(kept, f)
        end
    end
    self.flights = kept
    for i, c in self.coins do
        if self.shownCoins[i] > c then
            self.shownCoins[i] = c -- beaten or dead: the fills go out
        end
    end
    for i, p in self.players do
        local target = if p.blue then 1 else 0
        local v = self.blueFade[i] or 0
        if v < target then
            v = math.min(1, v + 1 / BLUE_FRAMES)
        elseif v > target then
            v = 0
        end
        self.blueFade[i] = v
    end
end

local function stepPlaying(self: Game)
    local intents: { Input.Intent } = {}
    for i, p in self.players do
        intents[i] = if p.state == Players.STATE_NORMAL then intentFor(self, p) else Input.NONE
    end
    local debugSpawn: number? = nil
    if bit32.band(self.debug, 3) ~= 0 and self.world.frame == 30 then
        debugSpawn = if bit32.band(self.debug, 2) ~= 0 then 2 else 1
    end
    local ev = Sim.step(self.round, intents, debugSpawn)
    stepEffects(self)
    ensureEnemyViews(self)
    ensureFireballViews(self)
    for i, _ in self.players do
        if ev.jumped[i] then
            play(self, 'jump')
        end
        if ev.bumped[i] or ev.stunned[i] then
            play(self, 'bump')
        end
    end
    if ev.pow then
        play(self, 'pow')
    end
    if ev.flip then
        play(self, 'bump')
    end
    if ev.entered then
        play(self, 'pipe') -- only the walk into a bottom pipe, the top pipes stay quiet
    end
    if #ev.kicks > 0 then
        play(self, 'kick')
        play(self, 'coin')
    end
    -- every coin won this step flies from where it was won to its hud slot; the beaten target's coins fly from him
    for _, who in ev.kicks do
        launchCoin(self, who, self.players[who].body.x, self.players[who].body.y)
    end
    for _, hit in ev.beaten do
        play(self, 'coin')
        local victim, by = hit[1], hit[2]
        local n = self.coins[by] - self.shownCoins[by] - flightsFor(self, by)
        for k = 1, n do
            launchCoin(self, by, self.players[victim].body.x, self.players[victim].body.y, (k - 1) * FLIGHT_GAP) -- one after the other
        end
    end
    for _, i in ev.sided do
        play(self, 'bump')
    end
    if ev.suddenDeath then
        -- the last coins can end the round on the target: the theme starts over, faster
        local bank = self.sfx
        if bank ~= nil then
            Sfx.startMusic(bank, true)
        end
    end
    if ev.fireball then
        play(self, 'fireball')
    end
    if bit32.band(self.debug, 8) ~= 0 and (#ev.killed > 0 or #ev.turnedBlue > 0 or #ev.beaten > 0 or #ev.sided > 0) then
        -- the round's events, on the frame they happen, with the sounds the game played for them
        local line = string.format('%5d event', self.world.frame)
        for _, i in ev.turnedBlue do
            line ..= string.format(' blue p%d', i)
        end
        for _, i in ev.sided do
            line ..= string.format(' side p%d', i)
        end
        for _, hit in ev.beaten do
            line ..= string.format(' p%d beat p%d', hit[2], hit[1])
        end
        for _, i in ev.killed do
            line ..= string.format(' dead p%d%s', i, if self.players[i].blue then ' (quiet)' else ' (player_down)')
        end
        print(line)
    end
    if bit32.band(self.debug, 8) ~= 0 and self.world.frame % 15 == 0 then
        -- a round trace for tuning the cpu: paste it back with what the human was doing
        local line = string.format('%5d c', self.world.frame)
        for i, c in self.coins do
            line ..= (if i > 1 then '-' else '') .. tostring(c)
        end
        for i, p in self.players do
            if p.state == Players.STATE_OFF then
                continue
            end
            local plan = self.brains[i].plan
            local who = if Players.isNpc(p) then (if plan then plan.kind .. '>' .. plan.row .. ',' .. plan.x else '-') else 'human'
            local flags = (if p.dizzy > 0 then 'D' else '') .. (if p.blue then 'B' else '') .. (if p.side then 'S' else '') .. (if p.invincible > 0 then 'I' else '')
            line ..= string.format(' | p%d %d,%d %s%s %s', i, p.body.x, p.body.y, if p.onGround then 'g' else 'a', flags, who)
        end
        for _, e in self.enemies.list do
            line ..= string.format(' | %s%d %d,%d s%d', e.kind, e.slot, e.body.x, e.body.y, e.state)
        end
        print(line)
    end
    for _, i in ev.killed do
        onDeath(self, i)
    end
    -- a lone contender beside targets wins at once, however that came about
    if self.lastKilled == 0 then
        local alive = Players.alive(self.players)
        local contenders = Sim.contenders(self.round)
        if #contenders == 1 and #alive > 1 then
            endRound(self, CHARACTERS[contenders[1]])
            return
        end
    end
    -- the last death ends the round once the body has fallen off the screen
    if self.lastKilled > 0 then
        if self.players[self.lastKilled].body.y > Players.GONE_Y then
            local alive = Players.alive(self.players)
            endRound(self, if #alive == 1 then CHARACTERS[alive[1]] else 'none')
        end
        return
    end
    -- the five coins out: the round is the leader's, unless two share the top, then sudden death goes on
    -- around the target until someone stands alone
    if Sim.total(self.round) >= Sim.COINS_TO_WIN then
        local leader = Sim.leader(self.round)
        if leader > 0 then
            endRound(self, CHARACTERS[leader])
        end
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
    Sim.resetScore(self.round)
    self.shownCoins = { 0, 0, 0, 0 }
    self.flights = {}
    self.blueFade = { 0, 0, 0, 0 }
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
    if ev.unlocked or ev.refused or ev.toggled then
        play(self, 'bump')
    end
    if ev.launch then
        -- each card: a human's slot, the cpu, or nobody
        for i, p in self.players do
            local role = Menu.roleFor(self.menu, i)
            Players.setController(p, if type(role) == 'number' then role else nil)
            self.off[i] = role == 'off'
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
        stepEffects(self)
        self.overFrames -= 1
        -- the result stays up: the winner's line, the huds as they ended. a jump or start on any slot goes back
        -- to the menu once the MENU button is up and every button has been let go; a cpu only round goes
        -- back on its own
        if self.overFrames <= 0 then
            local pressed = false
            for i = 1, Input.SLOTS do
                local it = Input.intent(self.input, i)
                pressed = pressed or it.jump or it.start
            end
            if not pressed then
                self.overArmed = true
            elseif self.overArmed then
                backToTitle(self)
            end
            if not hasHuman(self) and self.overFrames <= -DEMO_OVER_FRAMES then
                backToTitle(self)
            end
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
    self.coinImage = context:image('hud_coin')
    self.letterImages = { context:image('letter_m'), context:image('letter_l'), context:image('letter_w'), context:image('letter_wl') }
    buildPipeMask(self.pipeMask)
    for i = 1, #self.players do
        local pvm = Data.Player.new()
        pvm.character.value = CHARACTERS[i]
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

local function drawInstance(renderer: Renderer, inst: Artboard<any>, x: number, y: number, flip: boolean, side: boolean?)
    renderer:save()
    if side then
        -- on his side: a quarter turn about the sprite's centre, the head the way he faces
        local turn = Mat2D.withTranslation(x + 8, y + 8) * Mat2D.withRotation(math.rad(if flip then -90 else 90)) * Mat2D.withTranslation(-8, -8)
        renderer:transform(turn)
    elseif flip then
        renderer:transform(Mat2D.withScaleAndTranslation(-1, 1, x + 16, y))
    else
        renderer:transform(Mat2D.withTranslation(x, y))
    end
    inst:draw(renderer)
    renderer:restore()
end

-- entities near an edge are drawn on both sides so the wrap is seamless
local function drawWrapped(renderer: Renderer, inst: Artboard<any>, x: number, y: number, flip: boolean, side: boolean?)
    drawInstance(renderer, inst, x, y, flip, side)
    if x > Stage.WIDTH - 16 then
        drawInstance(renderer, inst, x - Stage.WIDTH, y, flip, side)
    elseif x < 0 then
        drawInstance(renderer, inst, x + Stage.WIDTH, y, flip, side)
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
    local blues = 0
    for _, p in self.players do
        if p.blue and p.state == Players.STATE_NORMAL then
            blues += 1
        end
    end
    for i, p in self.players do
        local inst = self.playerInst[i]
        local blink = p.invincible > 0 and (self.world.frame // BLINK) % 2 == 1
        if inst ~= nil and p.state ~= Players.STATE_OFF and not blink then
            drawWrapped(renderer, inst, p.body.x, p.body.y, p.dir < 0, p.side)
            if p.blue and blues >= 2 then
                -- two targets look alike: the initial floats over each one's head
                local letter = self.letterImages[i]
                if letter ~= nil then
                    renderer:save()
                    renderer:transform(Mat2D.withTranslation(p.body.x + 4, p.body.y - 11))
                    renderer:drawImage(letter, self.sampler, 'srcOver', 1)
                    renderer:restore()
                end
            end
        end
    end
    if self.showBoxes then
        drawBoxes(self, renderer)
    end
    renderer:restore()
    -- the coins on their way to the hud, over everything and unshaken
    local coin = self.coinImage
    if coin ~= nil then
        for _, f in self.flights do
            if f.t < 0 then
                continue -- not left yet
            end
            local k = f.t / FLIGHT_FRAMES
            k = k * k -- ease in
            renderer:save()
            renderer:transform(Mat2D.withTranslation(f.x0 + (f.x1 - f.x0) * k, f.y0 + (f.y1 - f.y0) * k))
            renderer:drawImage(coin, self.sampler, 'srcOver', 1)
            renderer:restore()
        end
    end
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
    local world = World.new()
    local enemies = Enemies.new()
    local fireballs = Fireballs.new()
    local players: { Players.Player } = {}
    local brains: { Npc.Brain } = {}
    for i = 1, #Menu.CARDS do
        players[i] = Players.new(i)
        brains[i] = Npc.new(i)
    end
    local round = Sim.live(world, enemies, fireballs, players)
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
        menu = Menu.new(Input.SLOTS),
        brains = brains,
        ready = false,
        context = nil,
        vm = nil,
        sfx = nil,
        input = Input.new(),
        world = world,
        players = players,
        playerInst = {},
        playerVm = {},
        enemies = enemies,
        enemyViews = {},
        fireballs = fireballs,
        round = round,
        coins = round.coins,
        off = { false, false, false, false },
        lastKilled = 0,
        shownCoins = { 0, 0, 0, 0 },
        flights = {},
        blueFade = { 0, 0, 0, 0 },
        phase = 'title',
        winner = 'none',
        overFrames = 0,
        style = 0,
        debug = 0,
        paused = false,
        prevStart = false,
        acc = 0,
        blockImage = nil,
        coinImage = nil,
        letterImages = {},
        overArmed = false,
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
