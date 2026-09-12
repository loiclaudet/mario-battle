--!strict
-- sound effects. sources resolve to nil under --test and play silently under --screenshot,
-- so every call is guarded. names match the AudioAsset names in scene/assets.rml.
local Sfx = {}

export type Bank = { sources: { [string]: AudioSource } }

Sfx.NAMES = { 'jump', 'kick', 'coin', 'bump', 'player_down', 'fireball', 'pow', 'game_over', 'pipe' }

function Sfx.load(context: Context): Bank
    local bank: Bank = { sources = {} }
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

return Sfx
