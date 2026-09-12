-- spike: proves the entity path. a script-instanced Spiny component walks along
-- the floor, its pose view model flips every 2 seconds, keyboard and gamepad
-- events are printed, and a key press plays the jump sound.

type Game = {
    spiny: Input<Artboard<Data.Enemy>>,
    inst: Artboard<Data.Enemy>?,
    vm: Data.Enemy?,
    size: Vector,
    acc: number,
    frame: number,
    x: number,
    dir: number,
    jump: AudioSource?,
    context: Context?,
}

local STEP = 1 / 60

function init(self: Game, context: Context): boolean
    self.context = context
    print("game init")
    return true
end

function resize(self: Game, size: Vector, scale: number)
    self.size = size
    print(`resize {size.x}x{size.y} @{scale}`)
end

local function ensureInstance(self: Game)
    if self.inst ~= nil then
        return
    end
    local vm = Data.Enemy.new()
    self.inst = self.spiny:instance(vm)
    self.vm = vm
    print("spiny instanced")
    local context = self.context
    if context ~= nil then
        self.jump = context:audio("jump")
        print(`audio jump {if self.jump ~= nil then "ok" else "nil"}`)
    end
end

local function step(self: Game)
    self.frame += 1
    self.x += 0.75 * self.dir
    if self.x > 240 then
        self.dir = -1
    elseif self.x < 0 then
        self.dir = 1
    end
    local vm = self.vm
    if vm ~= nil then
        local flipped = (self.frame // 120) % 2 == 1
        vm.pose.value = if flipped then "flipped" else "walk"
    end
end

function advance(self: Game, seconds: number): boolean
    ensureInstance(self)
    self.acc += seconds
    while self.acc >= STEP do
        self.acc -= STEP
        step(self)
    end
    local inst = self.inst
    if inst ~= nil then
        inst:advance(seconds)
    end
    return true
end

function draw(self: Game, renderer: Renderer)
    local inst = self.inst
    if inst == nil then
        return
    end
    renderer:save()
    if self.dir < 0 then
        -- flip horizontally around the sprite's own 16px box
        renderer:transform(Mat2D.withScaleAndTranslation(-1, 1, self.x + 16, 192))
    else
        renderer:transform(Mat2D.withTranslation(self.x, 192))
    end
    inst:draw(renderer)
    renderer:restore()
end

function keyboardEvent(self: Game, event: KeyboardEvent): boolean
    print(`key {event.key} {event.phase}`)
    if event.phase == "down" and self.jump ~= nil then
        Audio.play(self.jump)
    end
    return true
end

function gamepadConnected(self: Game, event: GamepadConnected)
    print(`gamepad connected {event.deviceId}`)
end

function gamepadEvent(self: Game, event: GamepadEvent)
    print(`gamepad {event.deviceId} {event.changeKind} {event.changeIndex} = {event.changeValue} south={event.south} west={event.west} left={event.dpadLeft} stick={event.leftStick.x}`)
end

return function(context: Context): Layout<Game>
    return {
        spiny = late(),
        inst = nil,
        vm = nil,
        size = Vector.xy(256, 240),
        acc = 0,
        frame = 0,
        x = 16,
        dir = 1,
        jump = nil,
        context = nil,
        init = init,
        resize = resize,
        advance = advance,
        draw = draw,
        keyboardEvent = keyboardEvent,
        gamepadConnected = gamepadConnected,
        gamepadEvent = gamepadEvent,
    }
end
