-- Sea Piece combat helpers: ConqCoating / FightStance / SwimSet.
-- Server-side handlers in ServerScriptService.Core.comms.Server do not gate these
-- on ownership/level/stat-unlock, so firing them from the client succeeds without
-- prerequisites.  Each call goes through the character-scope comms folder at
-- workspace.Alive.<player>.ClientCore.Server.cc.comms.

local lp = game:GetService("Players").LocalPlayer

local function getComms()
    local alive  = workspace:WaitForChild("Alive", 10)
    local me     = alive  and alive:WaitForChild(lp.Name, 10)
    local cc     = me     and me:WaitForChild("ClientCore", 10)
    local server = cc     and cc:WaitForChild("Server", 10)
    local cc2    = server and server:WaitForChild("cc", 10)
    return cc2 and cc2:WaitForChild("comms", 10)
end

local comms = getComms()
if not comms then
    warn("[combat] could not resolve character comms -- character not loaded?")
    return
end

local events  = comms:WaitForChild("events")
local remotes = comms:WaitForChild("remotes")

_G.ConqCoat = function()
    local ok, err = pcall(function() events.ConqCoating:FireServer() end)
    print("ConqCoat:", ok and "fired" or err)
end

_G.FightStance = function()
    local ok, err = pcall(function() remotes.FightStance:InvokeServer() end)
    print("FightStance:", ok and "toggled" or err)
end

_G.SwimSet = function(state)
    local v = state and true or false
    local ok, err = pcall(function() events.SwimSet:FireServer(v) end)
    print("SwimSet:", ok and tostring(v) or err)
end

print("combat helpers loaded")
print("_G.ConqCoat / _G.FightStance / _G.SwimSet")
