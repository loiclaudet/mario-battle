--!strict
-- enemies: filled in at step 5. this stub keeps the module graph buildable.
local Enemies = {}
export type State = { list: { any } }
function Enemies.new(): State
    return { list = {} }
end
return Enemies
