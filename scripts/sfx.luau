--!strict
-- sound effects. sources resolve to nil under --test and play silently under --screenshot,
-- so every call is guarded. names match the AudioAsset names in scene/assets.rml.
local Sfx = {}

export type Bank = {
    sources: { [string]: AudioSource },
    -- music: the intro plays once, then the loop is scheduled back to back on the engine clock
    intro: AudioSource?,
    loop: AudioSource?,
    playing: { AudioSound },
    nextLoopFrame: number, -- engine frame the next loop iteration starts at
    scheduled: number, -- how many loop iterations are queued past nextLoopFrame
}

Sfx.NAMES = { 'jump', 'kick', 'coin', 'bump', 'player_down', 'fireball', 'pow', 'pipe' }
-- cut points from tools/music_cuts.json, written by tools/cut_music.py (manual cut: intro 6 s, loop 6 to 19 s)
Sfx.INTRO_SECONDS = 242550 / 44100
Sfx.LOOP_SECONDS = 551250 / 44100
Sfx.LEAD_FRAMES = 2205 -- schedule 50 ms ahead so the first play lands on a clean engine frame

function Sfx.load(context: Context): Bank
    local bank: Bank = { sources = {}, intro = nil, loop = nil, playing = {}, nextLoopFrame = 0, scheduled = 0 }
    bank.intro = context:audio('battle_intro')
    bank.loop = context:audio('battle_loop')
    if bank.intro == nil or bank.loop == nil then
        print('sfx: music assets missing')
    end
    for _, name in Sfx.NAMES do
        local source = context:audio(name)
        if source ~= nil then
            bank.sources[name] = source
        else
            print(`sfx: no audio asset named {name}`)
        end
    end
    return bank
end

function Sfx.play(bank: Bank, name: string)
    local source = bank.sources[name]
    if source ~= nil then
        Audio.play(source)
    end
end

local function frames(seconds: number): number
    return math.floor(seconds * Audio.sampleRate() + 0.5)
end

-- start the theme: intro now, first loop scheduled exactly at the intro's end
function Sfx.startMusic(bank: Bank)
    Sfx.stopMusic(bank)
    local intro, loop = bank.intro, bank.loop
    if intro == nil or loop == nil then
        return
    end
    local t0 = Audio.timeFrame() + Sfx.LEAD_FRAMES
    print(`music: engine {Audio.sampleRate()} Hz, intro {Sfx.INTRO_SECONDS} s then loop {Sfx.LOOP_SECONDS} s from frame {t0}`)
    local a = Audio.playAtFrame(intro, t0)
    if a ~= nil then
        table.insert(bank.playing, a)
    end
    bank.nextLoopFrame = t0 + frames(Sfx.INTRO_SECONDS)
    local b = Audio.playAtFrame(loop, bank.nextLoopFrame)
    if b ~= nil then
        table.insert(bank.playing, b)
    end
    bank.scheduled = 1
end

-- call every frame: keeps one loop iteration queued beyond the one that is playing, and forgets finished sounds
function Sfx.updateMusic(bank: Bank)
    local loop = bank.loop
    if loop == nil or bank.scheduled == 0 then
        return
    end
    local loopFrames = frames(Sfx.LOOP_SECONDS)
    local now = Audio.timeFrame()
    -- the queued iteration starts at nextLoopFrame; once we are inside it, queue the following one
    if now >= bank.nextLoopFrame then
        bank.nextLoopFrame += loopFrames
        local c = Audio.playAtFrame(loop, bank.nextLoopFrame)
        if c ~= nil then
            table.insert(bank.playing, c)
        end
    end
    local kept: { AudioSound } = {}
    for _, sound in bank.playing do
        if not sound:completed() then
            table.insert(kept, sound)
        end
    end
    bank.playing = kept
end

function Sfx.stopMusic(bank: Bank)
    for _, sound in bank.playing do
        sound:stop(0.1)
    end
    bank.playing = {}
    bank.scheduled = 0
    bank.nextLoopFrame = 0
end

return Sfx
