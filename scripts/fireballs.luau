--!strict
-- fireballs: filled in at step 6. this stub keeps the module graph buildable.
local Fireballs = {}
export type State = { list: { any } }
function Fireballs.new(): State
    return { list = {} }
end
return Fireballs
