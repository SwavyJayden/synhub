-- ============================================================
-- Hub v5
-- ============================================================
-- TABS:
--   ⚔ Combat     · auto-farm (velocity-hover above NPC + Swing remote), watchdog auto-leave
--   🍖 Survival  · auto-eat/drink/repair from hotbar + inventory
--   🗺 Movement  · TP/POI/saved spots, fly, noclip, walk/jump tuning
--   👁 ESP        · players, NPCs, ore, proximity prompts
--   ⚙ Settings   · stats panel, item search, hotkeys, log
--
-- Hotkeys (fixed; shown in Settings):
--   RightShift  → hide/show GUI
--   F8          → PANIC (disable everything)
-- ============================================================

-- ============================================================
-- RE-ENTRY GUARD: the hub was loading 3 times back-to-back when Sea Piece's
-- loadfix toggles HUD.HudClient.init (which triggers a character regen that
-- some autoexec setups treat as a "re-run the hub" signal). Guard with a
-- TIMESTAMP not a boolean so a stuck/aborted previous load self-clears after
-- 30s instead of locking out reloads forever.
-- ============================================================
do
    local now = os.clock()
    local last = _G.ENI_LOADING_AT or 0
    if (now - last) < 30 then
        warn("[hub] another instance loaded <30s ago - aborting this re-execution")
        return
    end
    _G.ENI_LOADING_AT = now
end

-- ============================================================
-- TEARDOWN PREVIOUS INSTANCE
-- ============================================================
if _G.ENI_HELPER then
    pcall(function() _G.ENI_HELPER.gui:Destroy() end)
    if _G.ENI_HELPER.connections then
        for _, c in ipairs(_G.ENI_HELPER.connections) do pcall(function() c:Disconnect() end) end
    end
    if _G.ENI_HELPER.espGuis then
        for _, g in pairs(_G.ENI_HELPER.espGuis) do
            pcall(function() g.gui:Destroy() end); pcall(function() g.hl:Destroy() end)
        end
    end
    -- destroy any leftover ENI-tagged physics movers on the player's HRP.
    -- auto-mine's BodyPosition/BodyGyro leak across reloads otherwise (they're
    -- parented to HRP; old loop dies but children persist applying force).
    pcall(function()
        local plr = game:GetService("Players").LocalPlayer
        local char = plr and plr.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then
            for _, c in ipairs(hrp:GetChildren()) do
                if type(c.Name) == "string" and c.Name:sub(1, 4) == "ENI_" then
                    pcall(function() c:Destroy() end)
                end
            end
        end
    end)
end
_G.ENI_HELPER = {connections={}, espGuis={}, oreGuis={}, promptGuis={}, entityCache={}, version="5.0"}

-- ============================================================
-- SERVICES & LOCALS
-- ============================================================
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local VIM = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
local lp = Players.LocalPlayer or Players:WaitForChild("LocalPlayer", 10)

-- (LIVE log shipper + trace removed -- no longer pinging an external collector)
local LIVE = { on = false, trace = false }
local function shipLine() end
local function shipTrace() end

-- ============================================================
-- THEME
-- ============================================================
local C = {
    -- weathered ship-deck wood (dark -> raised)
    bg=Color3.fromRGB(28,22,16), bg2=Color3.fromRGB(43,33,23), bg3=Color3.fromRGB(60,46,31),
    -- polished brass / gold (main accent, replaces purple) -- Deutan-safe yellow axis
    accent=Color3.fromRGB(216,170,92), accent2=Color3.fromRGB(178,132,58), accentDk=Color3.fromRGB(112,80,36),
    -- aged parchment text
    text=Color3.fromRGB(238,226,200), textDim=Color3.fromRGB(182,164,132), textMute=Color3.fromRGB(132,116,92),
    -- status: teal=good, amber=warn, coral=bad (blue/yellow-axis separated for deuteranopia)
    good=Color3.fromRGB(86,206,196), warn=Color3.fromRGB(240,176,72), bad=Color3.fromRGB(238,104,92),
    info=Color3.fromRGB(108,178,238), player=Color3.fromRGB(120,220,255), npc=Color3.fromRGB(240,190,110),
    hunger=Color3.fromRGB(240,150,80), thirst=Color3.fromRGB(92,180,236),
}

-- ============================================================
-- CONFIG (loaded from disk on boot, saved on change)
-- ============================================================
local CONFIG_FILE = "eni_config.json"

local DEFAULTS = {
    -- ESP
    espOn=false, espPlayers=true, espNpcs=false, espOre=false, espPrompts=false,
    espShowDistance=true, espShowHealth=true,
    espMaxDistance=5000, espUpdateInterval=0.5, espNpcFilter="",
    -- Movement
    walkSpeed=16, jumpPower=50, noClip=false,
    -- Fly (velocity-based; the CFrame-tween path was removed — game flagged it "unauthorized")
    flyOn=false, flySpeed=80, tpGlideSpeed=250,
    -- Auto-repair boat (equip Repair Hammer + native Tool.Activate near the hull, on a timer)
    autoRepairOn=false, autoRepairInterval=5, autoRepairNailFix=false,
    autoInvSort=false,    -- 🔁 auto-sort inventory UI on ChildAdded/Removed (cosmetic, client-side)
    -- Auto-farm (velocity-hover above NPC + Swing remote) — replaced the legacy "press key on a timer" spammer
    autoFarmOn=false, autoFarmTarget="", autoFarmTargets={}, autoFarmAvoidWater=true, autoFarmHeight=3, autoFarmOffsetX=0, autoFarmOffsetZ=0, autoFarmAttackInterval=0.25, autoFarmHpFloor=0,
    autoFarmStuckTime=8,  -- switch target if no damage in Ns (raised from 4 -> 8 so glide convergence has time to land first M1)
    autoFarmTweenRate=5,  -- CFrame:Lerp convergence rate (lower = smoother glide, higher = snappier follow). 12 was teleport-fast; 5 is visible movement.
    autoFarmMeleeRange=8,        -- max distance (studs) at which Swing is allowed to fire; outside this we only glide
    autoFarmApproachSpeed=320,   -- max stud/s while still > meleeRange away (fast cruise)
    autoFarmHoverSpeed=80,       -- max stud/s once inside meleeRange (precise hover, prevents overshoot)
    autoFarmPrioLowHp=true,      -- target selection: lowest-HP eligible mob first, ties broken by distance
    -- Auto-clash: when a nearby opponent starts a heavy (readable via their replicated HeavyAttack/
    -- ChargedAttack animation track), instantly fire our response to clash it. Names are configurable
    -- + a debug toggle logs real track names, since LoadAnimation can rename tracks at runtime.
    autoClashOn=false, autoClashMode="heavy", autoClashRange=60, autoClashDelay=0.3, autoClashGlobalCd=0.8,
    -- ONLY probe-confirmed heavy IDs here. Unverified dump guesses matched the enemy's idle/move
    -- anim and made it spam M2 in range. Add more ONLY after confirming via the heavy_id probe.
    autoClashNames="", autoClashIds="92083565565984,135625547699315,180435792", autoClashDebug=false,
    -- Smart heavy detection: catches any weapon's heavy by AnimationTrack PRIORITY + LENGTH instead
    -- of a hardcoded ID list. Heavy windups in this game use Priority.Action4 with a length >= ~0.6s;
    -- light swings/blocks are Action/Action2 and most are <0.4s. minLen filters out short Action4
    -- bursts (deflect flick etc) without losing real heavies. Falls back to name/ID matches.
    autoClashSmart=true, autoClashSmartMinLen=0.6,
    -- Auto-mine (velocity-hover above nearest OreRoot + native pickaxe Tool.Activate) — same hover physics as auto-farm, separate movers in state.mine
    autoMineOn=false, autoMineHeight=1, autoMineOffsetX=0, autoMineOffsetZ=0, autoMineRange=10000, autoMineFilter="", autoMineSwingInterval=0.3, autoMineStuckTime=25,  -- X/Y/Z offset from ore; switch on inventory drop, stuck-timer is only a backstop
    -- (auto-craft + auto-smelt state removed)
    -- Anti-AFK (idle pulse to prevent kick)
    antiAfk=true,
    -- Auto-eat
    autoEatOn=false, autoEatHungerThreshold=50, autoEatThirstThreshold=50,
    autoEatHungerSlot=0, autoEatThirstSlot=0,  -- 0 = unset (auto-find food on hotbar)
    autoEatInterval=0.5, autoEatCooldown=1.0,  -- loop tick + min seconds between eats
    autoEatFromInventory=false,  -- OFF by request: would fire comms.Bind remote. Hotbar auto-find (input-sim only) used instead.
    autoEatFoodAllowList={},  -- whitelist of realName strings; if non-empty, auto-eat only consumes these items (in addition to the always-on "apple" fallback)
    -- Auto-delete inventory items (DESTRUCTIVE; exact case-insensitive realName match, list-gated).
    -- Fires comms.DeleteRequest:FireServer(uuid) per matching item. Empty list = no-op (never mass-wipes).
    autoDeleteOn=false,            -- continuous loop master toggle
    autoDeleteList={},             -- realName strings to delete (EXACT match, case-insensitive)
    autoDeleteInterval=1.0,        -- continuous loop tick (seconds)
    autoDeleteCooldown=0.35,       -- min seconds between individual DeleteRequest fires (anti-kick)
    autoDeleteSkipBound=true,      -- safety: never delete an item currently bound to a hotbar slot
    -- Auto-rum (independent of auto-eat; buff-presence driven, NOT stamina-driven)
    autoRumOn=false,                -- master toggle for the separate rum loop
    autoRumSlot=0,                  -- 0 = auto-find any drink, else 1-12 = locked hotbar slot
    autoRumInterval=1.0,            -- loop tick (seconds)
    autoRumCooldown=3.0,            -- min seconds between rum activations
    autoRumBuffName="Rum",          -- name of the NumberValue in Stats.StatusEffects that signals buff is active
    -- Auto-train (all-in-one): replicatesignal the selected TrainingFrame.List button
    -- (Meditate / Pushups / Dumbell500 / etc.) -- the proven mechanism. autoTrainPick = which
    -- button. Pure training loop -- enable auto-eat separately if you want hunger handled.
    autoTrainPick="Meditate",
    autoMedOn=false,
    autoMedCastName="",                   -- override for the Cast remote arg if 'Meditation'/'Meditate' don't replicate
    autoMedInterval=0.5,                  -- main loop tick (seconds)
    -- Watchdog (server-hop on player join)
    watchdogOn=false,
    watchdogAction="hop",   -- "hop" = jump to a new server, "leave" = back to home
    watchdogTriggers={"Legionaress"},  -- exact usernames OR display names; case-insensitive substring
    watchdogAnyPlayer=false,  -- when true, ANY player joining fires the watchdog (solo-farm mode)
    watchdogWhitelist={},  -- never fires on these names (case-insensitive exact match)
    -- TP
    savedSpots={}, tpOnDeath=false, lastDeathPos=nil,
    -- Boat farm (sea-encounter state machine: FARM -> GRIP -> LOOT -> REPAIR)
    boatFarmOn=false, boatFarmRadius=10000, boatFarmAvoidWater=true, boatFarmVoidY=-300,
    boatFarmGripAfterKills=true, boatFarmGripRange=30,
    boatFarmLootChests=false, boatFarmLootKeyword="", boatFarmLootRadius=10000,
    boatFarmLootOwnBoat=true,   -- include your own boat's crates in the loot scan (needed when farming on your ship)
    autoLootOn=false, autoLootInterval=2.0,   -- standalone auto-loot loop, runs independent of boat-farm
    boatFarmAutoRepair=true, boatFarmNailFixOn=false,
    -- Minimap (top-down, player-locked rotation, center of screen)
    mapOn=false, mapRange=1500, mapSize=220,
    -- Hotkeys (rebindable)
    keyHideGui="RightShift", keyPanic="F8",
    -- Buy + Bulk craft persistence (audit-added; were assigned via `S.X = S.X or` fallbacks at use sites)
    buyList="", buyQty=10, buyAutoOn=false, buyAutoInterval=30,
    craftBulkItem="Copper Nail", craftBulkQty=50, craftBulkParallel=true,
}

local S = {}
for k, v in pairs(DEFAULTS) do
    if type(v) == "table" then S[k] = {} ; for kk, vv in pairs(v) do S[k][kk] = vv end
    else S[k] = v end
end


-- ============================================================
-- STATE (runtime, not persisted)
-- ============================================================
local state = {
    started=os.time(), packetCount={RECV=0}, log={}, pois={},
    espVisibleCount=0,
    statsRef=nil,   -- cached Players.LP.Stats folder (validated each access)
    autoEat = {
        lastEatTime=0, eatCount=0,
    },
    panic=false,
    logFilter="all",  -- all/good/warn/bad/info
    -- Shared ProximityPrompt cache.  Populated below by DescendantAdded listeners so the
    -- two auto-loot loops (ground + deer hardcode) don't each walk Workspace.GetDescendants().
    promptCache = {},
}
-- expose state + settings to external probes (auto-dump scripts, console debug, etc).
-- safe: this is the hub's own helper table, already created above for connection bookkeeping.
_G.ENI_HELPER.state = state
_G.ENI_HELPER.S = S

-- ============================================================
-- LOGGING
-- ============================================================
local function pushLog(level, msg)
    table.insert(state.log, {ts=os.date("%H:%M:%S"), lv=level, t=msg})
    if #state.log > 200 then table.remove(state.log, 1) end
    shipLine(level, msg)  -- fire to ENI's live collector (batched, non-blocking)
end

-- ============================================================
-- CONFIG SAVE/LOAD
-- ============================================================
local function saveConfig()
    if not writefile then return end
    local ok, j = pcall(function() return HttpService:JSONEncode(S) end)
    if not ok then
        -- a non-JSON value snuck into S (Instance / Vector3 / NaN / inf / function). The old
        -- code swallowed this silently and saved NOTHING -- breaking ALL persistence. Log the
        -- cause once, then save a sanitized copy so configs + saved spots still persist.
        if not state.cfgEncodeWarned then
            state.cfgEncodeWarned = true
            pushLog("bad", "config encode failed (" .. tostring(j) .. ") -> saving sanitized copy")
        end
        local function clean(v, depth)
            local t = type(v)
            if t == "string" or t == "boolean" then return v end
            if t == "number" then if v ~= v or v == math.huge or v == -math.huge then return nil end; return v end
            if t == "table" and depth < 6 then
                local o = {}
                for k2, v2 in pairs(v) do
                    if type(k2) == "string" or type(k2) == "number" then
                        local cv = clean(v2, depth + 1)
                        if cv ~= nil then o[k2] = cv end
                    end
                end
                return o
            end
            return nil   -- function / Instance / userdata -> drop
        end
        local ok2, j2 = pcall(function() return HttpService:JSONEncode(clean(S, 0)) end)
        if not ok2 then pushLog("bad", "config sanitized encode also failed: " .. tostring(j2)); return end
        j = j2
    end
    local okw, werr = pcall(writefile, CONFIG_FILE, j)
    if not okw and not state.cfgWriteWarned then
        state.cfgWriteWarned = true
        pushLog("bad", "config writefile failed: " .. tostring(werr))
    end
end
local function loadConfig()
    if not readfile or not isfile then return end
    if not pcall(function() return isfile(CONFIG_FILE) end) then return end
    if not isfile(CONFIG_FILE) then return end
    local ok, content = pcall(readfile, CONFIG_FILE)
    if not ok or not content then return end
    local ok2, parsed = pcall(function() return HttpService:JSONDecode(content) end)
    if not ok2 or type(parsed) ~= "table" then return end
    -- transient runtime flags must NOT persist across reloads (a saved flyOn=true
    -- would show the toggle lit while no fly loop is actually running).
    -- these never load from saved config — they always boot OFF, so nothing auto-runs on load
    local TRANSIENT = {flyOn=true, noClip=true,
                       autoFarmOn=true, autoEatOn=true, espOn=true, espOre=true, espPrompts=true,
                       autoMineOn=true, autoLootOn=true,
                       -- autoRepairOn is intentionally NOT transient: it's safe (only patches your
                       -- own hull) and nice to keep ON across reloads / zone-hops, per request.
                       watchdogOn=true, panic=true,
                       mapOn=true,
                       -- never auto-resume these combat/destructive loops on reload
                       boatFarmOn=true, autoClashOn=true, autoRumOn=true, autoMedOn=true, autoDeleteOn=true}
    for k, v in pairs(parsed) do
        if S[k] ~= nil and not TRANSIENT[k] then S[k] = v end
    end
    pushLog("good", "config loaded from "..CONFIG_FILE)
end

-- LOAD SAVED CONFIG NOW, before the UI builds, so every WindUI widget is constructed from the
-- user's SAVED values instead of DEFAULTS. (Verified against WindUI source: widgets do NOT fire
-- their callbacks on construction, so this cannot clobber the file.) The old single call sat in
-- the BOOT block ~5000 lines later -- AFTER all widgets were already built from defaults -- which
-- is why saved settings never showed up on reload despite the file being correct.
loadConfig()

-- ============================================================
-- ENTITY CACHE (lightweight, listener-based)
-- ============================================================
local entityCache = _G.ENI_HELPER.entityCache
local function registerEntity(model)
    if not model or not model:IsA("Model") then return end
    if entityCache[model] then return end
    local hum = model:FindFirstChildOfClass("Humanoid"); if not hum then return end
    local hrp = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso") or model:FindFirstChildWhichIsA("BasePart")
    if not hrp then return end
    local player = Players:GetPlayerFromCharacter(model)
    entityCache[model] = {humanoid=hum, hrp=hrp, name=player and player.Name or model.Name,
                          isPlayer=player~=nil, player=player}
end
-- re-resolve player linkage for a cached model (GetPlayerFromCharacter often
-- returns nil at Humanoid-add time before the engine links player.Character).
local function refreshEntityPlayer(model)
    local e = entityCache[model]; if not e then return end
    if not e.isPlayer then
        local p = Players:GetPlayerFromCharacter(model)
        if p then e.isPlayer = true; e.player = p; e.name = p.Name end
    end
    -- keep hrp fresh across respawns
    if not e.hrp or not e.hrp.Parent then
        e.hrp = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso") or model:FindFirstChildWhichIsA("BasePart")
    end
end
local function unregisterEntity(model)
    if entityCache[model] then
        entityCache[model] = nil
        local g = _G.ENI_HELPER.espGuis[model]
        if g then pcall(function() g.gui:Destroy() end); pcall(function() g.hl:Destroy() end); _G.ENI_HELPER.espGuis[model] = nil end
    end
end
local function initialEntityScan()
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Humanoid") and obj.Parent then registerEntity(obj.Parent) end
    end
    -- explicitly seed every player's current character (the reliable path)
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= lp and pl.Character then registerEntity(pl.Character); refreshEntityPlayer(pl.Character) end
    end
end
local function setupCacheListeners()
    table.insert(_G.ENI_HELPER.connections, Workspace.DescendantAdded:Connect(function(d)
        if d:IsA("Humanoid") then task.wait(); registerEntity(d.Parent) end
    end))
    table.insert(_G.ENI_HELPER.connections, Workspace.DescendantRemoving:Connect(function(d)
        if d:IsA("Humanoid") then unregisterEntity(d.Parent) end
    end))
    -- player join/respawn: register the character once it exists (reliable isPlayer=true)
    table.insert(_G.ENI_HELPER.connections, Players.PlayerAdded:Connect(function(pl)
        -- track the inner connection too, else it survives reloads and piles up (bug #26)
        table.insert(_G.ENI_HELPER.connections, pl.CharacterAdded:Connect(function(char)
            task.wait(0.3)
            registerEntity(char); refreshEntityPlayer(char)
        end))
    end))
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= lp then
            table.insert(_G.ENI_HELPER.connections, pl.CharacterAdded:Connect(function(char)
                task.wait(0.3)
                registerEntity(char); refreshEntityPlayer(char)
            end))
        end
    end
end

-- ============================================================
-- CHAR / STATS HELPERS
-- ============================================================
local function getMyHRP() return lp.Character and lp.Character:FindFirstChild("HumanoidRootPart") end
local function getMyHum() return lp.Character and lp.Character:FindFirstChildOfClass("Humanoid") end

-- Forward-declare BF (boat-farm namespace) at chunk scope.  The actual methods are
-- attached later (around line ~3950) but the AUTO-LOOT toggle callbacks reference BF.loot
-- earlier in the file; without this hoist they resolved BF as a global (nil) at call time
-- and silently failed under pcall.  Real bug: auto-loot was broken since first edit.
local BF = {}

-- Populate state.promptCache via DescendantAdded/Removing listeners so all auto-loot loops
-- (ground-loot, deer-hardcode, future boat-prompt scanners) share one O(1)-lookup table
-- instead of walking Workspace:GetDescendants() every tick.
do
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") then state.promptCache[d] = true end
    end
    table.insert(_G.ENI_HELPER.connections, Workspace.DescendantAdded:Connect(function(d)
        if d:IsA("ProximityPrompt") then state.promptCache[d] = true end
    end))
    table.insert(_G.ENI_HELPER.connections, Workspace.DescendantRemoving:Connect(function(d)
        if state.promptCache[d] then state.promptCache[d] = nil end
    end))
end
-- The boat we're CURRENTLY on (seated in OR standing on) -- so auto-repair works on a CREW boat,
-- not just our own. Falls back to our owned boat (workspace.Boats[name]).
local function currentBoat()
    local boats = Workspace:FindFirstChild("Boats"); if not boats then return nil end
    local char = lp.Character
    -- 1) seated in a VehicleSeat? climb to its Boats.* model
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart
    if seat then
        local m = seat
        while m and m.Parent do
            if m.Parent == boats then return m end
            m = m.Parent
        end
    end
    -- 2) standing on a boat? raycast down, climb the hit part to its Boats.* model
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { char }
        local hit = Workspace:Raycast(hrp.Position, Vector3.new(0, -25, 0), params)
        if hit and hit.Instance then
            local m = hit.Instance
            while m and m.Parent do
                if m.Parent == boats then return m end
                m = m.Parent
            end
        end
    end
    -- 3) fallback: our own boat
    return boats:FindFirstChild(lp.Name)
end
-- velocity GLIDE, not a CFrame snap — this game flags CFrame teleports as "unauthorized".
-- Instant CFrame snap (no glide, no yield). Used for long-range one-shots like loot scan
-- where the glide cost dwarfs the work. Noclips the character for one frame so the snap
-- can't snag mid-geometry. Caller's farm/noclip flags keep CanCollide=false afterward.
local function tpInstant(pos)
    local h = getMyHRP()
    if not (h and pos) then return false end
    local target = ((typeof(pos) == "Vector3") and pos or Vector3.new(pos[1], pos[2], pos[3]))
    local char = h.Parent; if not char then return false end
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
    end
    pcall(function() h.CFrame = CFrame.new(target) end)
    pcall(function() h.AssemblyLinearVelocity = Vector3.zero end)
    return true
end

-- PlatformStand kills gravity; we steer via BodyVelocity toward the target. Yields (~1s travel);
-- every caller is a button-click or respawn event, so yielding is safe.
local function tpTo(pos)
    local h = getMyHRP(); local hum = getMyHum()
    if not (h and pos) then return false end
    local target = ((typeof(pos) == "Vector3") and pos or Vector3.new(pos[1], pos[2], pos[3])) + Vector3.new(0, 3, 0)
    if (h.Position - target).Magnitude < 6 then return true end
    pcall(function() if hum then hum.PlatformStand = true end end)
    local bv = Instance.new("BodyVelocity"); bv.MaxForce = Vector3.new(1,1,1)*9e9; bv.P = 1250; bv.Velocity = Vector3.zero; bv.Parent = h
    -- NOCLIP during travel (IY-style): a dedicated RunService.Stepped loop forces CanCollide=false
    -- EVERY physics frame -- Stepped fires right before physics, so collision can't re-enable
    -- mid-glide and snag you on terrain (more robust than re-setting on the travel cadence). Only
    -- parts that were solid get touched; restored to solid on arrival after a short settle, unless
    -- global noclip (S.noClip) is deliberately on.
    local savedCol = {}
    local ncConn = RunService.Stepped:Connect(function()
        local char = (getMyHRP() or h).Parent; if not char then return end
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") and p.CanCollide then
                savedCol[p] = true
                p.CanCollide = false
            end
        end
    end)
    table.insert(_G.ENI_HELPER.connections, ncConn)   -- so a reload mid-TP can't orphan this Stepped loop
    state.tpCancel = false
    local t0 = os.clock()
    while os.clock() - t0 < 10 do
        local hrp = getMyHRP(); if not hrp then break end
        if state.tpCancel then break end   -- "🛑 Stop TP" button
        local delta = target - hrp.Position
        local dist = delta.Magnitude
        if dist < 5 then break end
        -- guard against bv being destroyed if character respawns mid-glide
        if bv and bv.Parent then
            bv.Velocity = delta.Unit * math.clamp(dist * 4, 60, S.tpGlideSpeed)   -- cap = "TP glide speed" slider
        else
            break
        end
        task.wait()
    end
    if bv and bv.Parent then bv.Velocity = Vector3.zero end   -- stop pushing so we settle at the target
    task.wait(0.15)                       -- brief settle before collision returns
    pcall(function() ncConn:Disconnect() end)
    -- restore solid ONLY if no other system still wants noclip. A TP detour during auto-farm /
    -- boat-farm (BF.loot / BF.repair call tpTo mid-run) must NOT re-solidify the character, or it
    -- snags on the hull/terrain the farm is noclipping through until the main Stepped loop re-clears.
    -- fly mode also relies on noclip + PlatformStand, so don't tear those down mid-flight.
    if not (S.noClip or S.autoFarmOn or S.autoMineOn or S.boatFarmOn or S.flyOn) then
        for p in pairs(savedCol) do if p and p.Parent then pcall(function() p.CanCollide = true end) end end
    end
    pcall(function() bv:Destroy() end)
    pcall(function() local freshHum = getMyHum(); if freshHum and not S.flyOn then freshHum.PlatformStand = false end end)
    pcall(function() local hrp = getMyHRP(); if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end end)
    return true
end

-- ============================================================
-- FLY + GO-TO-SPOT  (velocity-based; the old CFrame-tween path was cut — flagged "unauthorized")
-- (wrapped in do-block to conserve main-chunk local slots)
-- ============================================================
local goToSpot, startFly, stopFly, toggleFly
do
-- saved-spot travel just routes to the velocity glide; no tween branch anymore
goToSpot = function(pos) return tpTo(pos) end

-- continuous WASD + Space/Shift fly. Keys tracked via events (IsKeyDown can
-- under-report held keys in some exec sandboxes). Uses BodyVelocity + a
-- LinearVelocity fallback for modern-physics games.
local flyState = { bv=nil, bg=nil, lv=nil, att=nil, conn=nil, keyConns={}, keys={} }
stopFly = function()
    S.flyOn = false
    if flyState.conn then pcall(function() flyState.conn:Disconnect() end); flyState.conn=nil end
    for _,c in ipairs(flyState.keyConns) do pcall(function() c:Disconnect() end) end
    flyState.keyConns = {}; flyState.keys = {}
    if flyState.bv then pcall(function() flyState.bv:Destroy() end); flyState.bv=nil end
    if flyState.bg then pcall(function() flyState.bg:Destroy() end); flyState.bg=nil end
    if flyState.lv then pcall(function() flyState.lv:Destroy() end); flyState.lv=nil end
    if flyState.att then pcall(function() flyState.att:Destroy() end); flyState.att=nil end
    local hum=getMyHum(); if hum then pcall(function() hum.PlatformStand=false end) end
    pushLog("info","fly OFF")
end
startFly = function()
    pushLog("info","🕊 startFly() called")
    local h=getMyHRP(); local hum=getMyHum()
    if not (h and hum) then pushLog("bad","fly: no character (hrp="..tostring(h~=nil).." hum="..tostring(hum~=nil)..")"); return end
    stopFly()
    S.flyOn = true
    local ok, err = pcall(function()
        hum.PlatformStand = true
        local bv = Instance.new("BodyVelocity"); bv.MaxForce=Vector3.new(1,1,1)*9e9; bv.Velocity=Vector3.zero; bv.P=1250; bv.Parent=h
        local bg = Instance.new("BodyGyro"); bg.MaxTorque=Vector3.new(1,1,1)*9e9; bg.P=1e5; bg.D=500; bg.CFrame=h.CFrame; bg.Parent=h
        flyState.bv=bv; flyState.bg=bg
        -- modern-physics fallback: LinearVelocity on an attachment
        local att = Instance.new("Attachment"); att.Parent=h
        local lv = Instance.new("LinearVelocity"); lv.Attachment0=att; lv.MaxForce=9e9
        lv.VectorVelocity=Vector3.zero; lv.RelativeTo=Enum.ActuatorRelativeTo.World; lv.Parent=h
        flyState.att=att; flyState.lv=lv
    end)
    if not ok then pushLog("bad","fly: setup error: "..tostring(err)); S.flyOn=false; return end

    -- event-based key tracking (reliable for held keys)
    local keys = flyState.keys
    flyState.keyConns[#flyState.keyConns+1] = UIS.InputBegan:Connect(function(i, gpe)
        if i.KeyCode then keys[i.KeyCode] = true end
    end)
    flyState.keyConns[#flyState.keyConns+1] = UIS.InputEnded:Connect(function(i)
        if i.KeyCode then keys[i.KeyCode] = nil end
    end)

    local frame=0
    flyState.conn = RunService.RenderStepped:Connect(function()
        if not S.flyOn then return end
        local hrp=getMyHRP(); local humC=getMyHum()
        if not (hrp and humC) then return end
        humC.PlatformStand = true
        local cam = Workspace.CurrentCamera
        local dir = Vector3.zero
        if cam then
            local cf = cam.CFrame
            if keys[Enum.KeyCode.W] then dir = dir + cf.LookVector end
            if keys[Enum.KeyCode.S] then dir = dir - cf.LookVector end
            if keys[Enum.KeyCode.A] then dir = dir - cf.RightVector end
            if keys[Enum.KeyCode.D] then dir = dir + cf.RightVector end
            if flyState.bg then flyState.bg.CFrame = cf end
        end
        if keys[Enum.KeyCode.Space] then dir = dir + Vector3.new(0,1,0) end
        if keys[Enum.KeyCode.LeftShift] then dir = dir - Vector3.new(0,1,0) end
        if dir.Magnitude > 0 then dir = dir.Unit * S.flySpeed end
        if flyState.bv and flyState.bv.Parent then flyState.bv.Velocity = dir end
        if flyState.lv and flyState.lv.Parent then flyState.lv.VectorVelocity = dir end
        frame = frame + 1
        if LIVE.trace and frame % 30 == 0 then
            shipTrace(string.format("FLY vel=%.0f pos=%.0f,%.0f,%.0f plat=%s",
                dir.Magnitude, hrp.Position.X, hrp.Position.Y, hrp.Position.Z, tostring(humC.PlatformStand)))
        end
    end)
    table.insert(_G.ENI_HELPER.connections, flyState.conn)
    pushLog("good", "🕊 fly ON (WASD + Space/Shift, speed "..S.flySpeed..")")
end
local function toggleFly_impl() if S.flyOn then stopFly() else startFly() end end
toggleFly = toggleFly_impl
end  -- close fly do-block

-- ============================================================
-- BOAT HELPERS  (TP to my boat -- boost was removed; server-side speed cap
-- killed any client velocity amplification we tried.)
-- ============================================================
local tpToBoat
do
    local cBoat, cRoot, cEng
    local function findMyBoat()
        local boats = Workspace:FindFirstChild("Boats")
        if boats then
            local mine = boats:FindFirstChild(lp.Name)
            if mine then return mine end
        end
        -- fallback: climb from a VehicleSeat I'm sitting in up to its boat model
        for _, o in ipairs(Workspace:GetDescendants()) do
            if o:IsA("VehicleSeat") and o.Occupant then
                local ch = o.Occupant.Parent
                if ch and Players:GetPlayerFromCharacter(ch) == lp then
                    local m = o
                    while m.Parent and m.Parent ~= Workspace do
                        if m.Parent.Name == "Boats" then return m end
                        m = m.Parent
                    end
                    return o.Parent
                end
            end
        end
        return nil
    end
    local function resolve()
        if cRoot and cRoot.Parent and cEng and cEng.Parent then return true end
        local boat = findMyBoat()
        if not boat then cBoat, cRoot, cEng = nil, nil, nil; return false end
        cBoat = boat
        cEng  = boat:FindFirstChild("Engine") or boat:FindFirstChildWhichIsA("VehicleSeat", true)
        cRoot = boat:FindFirstChild("ShipRoot") or (cEng and cEng.AssemblyRootPart) or boat:FindFirstChildWhichIsA("BasePart", true)
        return cRoot ~= nil
    end
    tpToBoat = function()
        if not resolve() then return false end
        local target = (cEng and cEng:IsA("VehicleSeat")) and cEng or cRoot
        if not target then return false end
        return tpTo(target.Position + Vector3.new(0, 6, 0))
    end
end

local function findStatsFolder()
    local s = lp:FindFirstChild("Stats"); if s then return s end
    local char = lp.Character; if char then s = char:FindFirstChild("Stats"); if s then return s end end
    for _, c in ipairs(lp:GetChildren()) do
        if c:IsA("Folder") and c.Name:lower():find("stat") then return c end
    end
    return nil
end

-- Survival stats (Hunger/Thirst/Health/Stamina) live at workspace.Alive.<player>.Config.<name>
-- (the Players.LP.Stats folder is only progression: Strength/Will/Durability/etc).
local SURVIVAL_STATS = { Hunger=true, Thirst=true, Health=true, Stamina=true, Armament=true }
local function readAliveConfig(name)
    local alive = workspace:FindFirstChild("Alive")
    local char  = alive and alive:FindFirstChild(lp.Name)
    local cfg   = char and char:FindFirstChild("Config")
    local sub   = cfg and cfg:FindFirstChild(name)
    if not sub then return nil end
    if sub:IsA("ValueBase") then
        local ok, v = pcall(function() return sub.Value end)
        if ok and type(v) == "number" then return v end
    end
    local inner = sub:FindFirstChild("Value")
    if inner and inner:IsA("ValueBase") then
        local ok, v = pcall(function() return inner.Value end)
        if ok and type(v) == "number" then return v end
    end
    return nil
end

local function getStat(name)
    if SURVIVAL_STATS[name] then
        local v = readAliveConfig(name)
        if v ~= nil then return v end
        -- fall through to Stats folder in case server mirrors it there too
    end
    -- validate cached ref still in tree; refresh if stale
    if state.statsRef and not state.statsRef.Parent then
        state.statsRef = nil
    end
    local s = state.statsRef or findStatsFolder()
    if s and s ~= state.statsRef then state.statsRef = s end
    if not s then return nil end
    local v = s:FindFirstChild(name)
    if not v then return nil end
    local ok, val = pcall(function() return v.Value end)
    if not ok then return nil end
    return val   -- NOT `ok and val or nil` — that turned a real `false` (e.g. InCombat) into nil
end

-- ============================================================
-- INVENTORY HELPERS
-- ============================================================
local function findInventoryFolder()
    local c = lp.Character
    if c then local i = c:FindFirstChild("Inventory"); if i then return i end end
    return lp:FindFirstChild("Inventory")
end

local function listInventory()
    local inv = findInventoryFolder()
    if not inv then return {} end
    local items = {}
    for _, item in ipairs(inv:GetChildren()) do
        local rn = item:FindFirstChild("realName")
        local stack = item:FindFirstChild("Stack") or item:FindFirstChild("Amount") or item:FindFirstChild("Count")
        table.insert(items, {
            uuid = item.Name,
            realName = rn and rn.Value or item.Name,
            stack = stack and stack.Value or 1,
            instance = item,
        })
    end
    return items
end

local function itemByUuid(uuid)
    if not uuid or uuid == "" or uuid == "None" then return nil end
    local inv = findInventoryFolder()
    if not inv then return nil end
    local item = inv:FindFirstChild(uuid)
    if not item then return nil end
    local rn = item:FindFirstChild("realName")
    return {uuid=uuid, realName=rn and rn.Value or item.Name, instance=item}
end

local function getBindUuid(slot)
    local stats = lp:FindFirstChild("Stats")
    if not stats then return nil end
    local b = stats:FindFirstChild("Bind"..slot)
    if not b then return nil end
    return b.Value
end

-- Bug #434 fix: never M1 a Repair Hammer thinking it's food.
-- All food logic bundled into ONE main-chunk local to stay under Luau's 200-local-per-function ceiling.
local Food = (function()
    local KW = {"apple","bread","cooked","raw fish","raw meat","fish ","meat","steak","soup","stew",
        "rice","fruit","veg","drink","juice","water","sake","grog","milk","tea","food","ration","berry","grape","banana"}
    local function isFood(rn)
        if type(rn) ~= "string" or rn == "" then return false end
        local l = rn:lower()
        for _, kw in ipairs(KW) do if l:find(kw, 1, true) then return true end end
        return false
    end
    local DRINK_KW = {"drink","juice","water","sake","grog","milk","tea","ale","rum","coffee","potion","canteen","flask"}
    local function isDrink(rn)
        if type(rn) ~= "string" or rn == "" then return false end
        local l = rn:lower()
        for _, kw in ipairs(DRINK_KW) do if l:find(kw, 1, true) then return true end end
        return false
    end
    local function findSlot()
        for s = 1, 12 do
            local uuid = getBindUuid(s)
            if uuid and uuid ~= "None" and uuid ~= "" then
                local it = itemByUuid(uuid)
                if it and isFood(it.realName) then return s, it.realName end
            end
        end
        return 0, nil
    end
    -- Return a hotbar slot that holds food, pulling from inventory if needed (0 = failed).
    -- Stats.BindN is a read-only server mirror, so we bind via comms.Bind:FireServer(slot, uuid).
    local function ensure()
        local s = findSlot()
        if s ~= 0 then return s end
        if not S.autoEatFromInventory then return 0 end
        local uuid, name
        for _, it in ipairs(listInventory()) do
            if isFood(it.realName) then uuid = it.uuid; name = it.realName; break end
        end
        if not uuid then return 0 end
        -- prefer a high empty slot so we don't evict tools in slots 1-6
        local empty = 0
        for s2 = 12, 1, -1 do
            local u = getBindUuid(s2)
            if not u or u == "None" or u == "" then empty = s2; break end
        end
        if empty == 0 then empty = 12 end
        local ok = pcall(function() RS.comms.Bind:FireServer(empty, uuid) end)
        if not ok then return 0 end
        pushLog("info", string.format("auto-eat: bound %s from inventory → slot %d", name, empty))
        task.wait(0.35)  -- let the server write Bind%d and replicate the UUID back
        return empty
    end
    return { isFood = isFood, isDrink = isDrink, findSlot = findSlot, ensure = ensure }
end)()

-- ============================================================
-- UI CLICK (game-side) — confirmed mouse-move-first method
-- ============================================================

local function pressKey(kc)
    pcall(function()
        VIM:SendKeyEvent(true,  kc, false, game); task.wait(0.05)
        VIM:SendKeyEvent(false, kc, false, game)
    end)
end


-- Equip a Tool whose realName matches matchFn (searches held + Backpack), Activate it,
-- then restore whatever was held before so we never strand the user on the hammer/food.
-- Tool.Activated replicates natively (no remote, works tabbed out). Returns ok, err.
local function _equipActivateImpl(matchFn, times)
    local char = lp.Character; if not char then return false, "no character" end
    local hum = char:FindFirstChildOfClass("Humanoid"); if not hum then return false, "no humanoid" end
    local function realNameOf(t)
        local own = t:FindFirstChild("realName")          -- the Tool may carry its own realName
        if own then return tostring(own.Value) end
        local inv = lp:FindFirstChild("Inventory")        -- resolve FRESH: may be nil at entry post-spawn/teleport (#2)
        local it = inv and inv:FindFirstChild(t.Name)
        local rn = it and it:FindFirstChild("realName")
        return rn and tostring(rn.Value) or t.Name
    end
    local found
    for _, t in ipairs(char:GetChildren()) do
        if t:IsA("Tool") and matchFn(realNameOf(t)) then found = t; break end
    end
    if not found then
        local bp = lp:FindFirstChild("Backpack")
        if bp then
            for _, t in ipairs(bp:GetChildren()) do
                if t:IsA("Tool") and matchFn(realNameOf(t)) then found = t; break end
            end
        end
    end
    if not found then return false, "tool not found" end
    local prev = char:FindFirstChildOfClass("Tool")   -- restore this after, if we swap
    local swapped = false
    if found.Parent ~= char then
        pcall(function() hum:EquipTool(found) end); task.wait(0.15); swapped = true
    end
    local cur = char:FindFirstChildOfClass("Tool")
    if not cur then return false, "equip failed" end
    -- The consume/repair replicates ASYNC off Tool.Activated and the server keys off us STILL
    -- holding the tool in a NORMAL movement state. (#4) Drop PlatformStand (the farm hover forces
    -- it true, which the server rejects consume under) and signal the farm loop to stop re-asserting
    -- it via state.holdNoHover; (#1) SETTLE ~0.25s after the last Activate so the server consume
    -- LANDS before we unequip -- the old zero-settle unequip dropped it (THE eat/repair death).
    state.holdNoHover = true
    pcall(function() hum.PlatformStand = false end)
    local _times = (times or 1)
    for i = 1, _times do
        pcall(function() cur:Activate() end)
        if i < _times then task.wait(0.1) end
    end
    task.wait(0.25)
    state.holdNoHover = false
    -- swap back to whatever we were holding (e.g. don't leave a sword-user holding the hammer).
    if swapped and prev and prev.Parent and prev ~= found then
        pcall(function() hum:EquipTool(prev) end)
    end
    return true
end

-- Serialize the equip/activate pipe: auto-repair, auto-eat and auto-rum all share one pair
-- of hands, so only ONE may equip+Activate at a time. A second caller bails ("pipe busy")
-- and retries next tick instead of interleaving its Activate / equip-back onto the other's
-- tool. The busy flag always clears (pcall), so it can't deadlock.
local function equipAndActivate(matchFn, times)
    -- stale-timeout: if a prior caller died mid-pcall without clearing the flag, force-reclaim after 5s
    if state.activatePipeBusy and (os.clock() - (state.activatePipeBusyAt or 0)) < 5 then return false, "pipe busy" end
    state.activatePipeBusy = true
    state.activatePipeBusyAt = os.clock()
    local ok, a, b = pcall(_equipActivateImpl, matchFn, times)
    state.activatePipeBusy = false
    if not ok then return false, "pipe error: " .. tostring(a) end
    return a, b
end

local function eatFromSlot(slot, reason)
    -- Find a consumable and eat it via native Tool.Activated. equipAndActivate searches the
    -- held Tool AND the whole Backpack (= your inventory's Tool objects), so this works whether
    -- or not the item is bound to a hotbar slot — pulls straight from inventory, no comms.Bind.
    local isThirst = type(reason) == "string" and reason:find("thirst") ~= nil
    -- prefer the configured slot's item IF it fits the need (exact-name match)
    local wantName
    do
        local u = getBindUuid(slot)
        if u and u ~= "None" and u ~= "" then
            local it = itemByUuid(u)
            local rn = it and it.realName
            if rn then
                if isThirst and Food.isDrink(rn) then wantName = rn
                elseif not isThirst and Food.isFood(rn) and not Food.isDrink(rn) then wantName = rn end
            end
        end
    end
    -- matcher: exact slot item if it fit, else ANY drink (thirst) / solid food (hunger) in inventory
    -- HUNGER path also honors S.autoEatFoodAllowList: if non-empty, only those realNames (plus anything
    -- matching "apple" as a safety fallback) are eligible. Drink/rum path is unaffected by the allow-list
    -- since rum has its own dedicated loop now.
    local allow = S.autoEatFoodAllowList
    local hasAllow = type(allow) == "table" and next(allow) ~= nil
    local allowSet
    if hasAllow then
        allowSet = {}
        for _, n in ipairs(allow) do allowSet[n] = true end
    end
    local function passesAllow(rn)
        if not hasAllow then return true end
        if allowSet[rn] then return true end
        -- always allow apples as a safety fallback (LO's request)
        return type(rn) == "string" and rn:lower():find("apple", 1, true) ~= nil
    end
    local matcher
    if wantName then
        -- an explicit slot binding always wins -- don't re-filter it through the allow-list (bug #5)
        matcher = function(rn) return rn == wantName end
    elseif isThirst then
        matcher = function(rn) return Food.isDrink(rn) end
    else
        -- DON'T exclude isDrink here: KW and DRINK_KW overlap (milk/soup/tea/grog/sake), so the old
        -- `not isDrink` permanently rejected those foods. isFood + allow-list is the right gate (bug #1).
        matcher = function(rn) return Food.isFood(rn) and passesAllow(rn) end
    end

    local statName = isThirst and "Thirst" or "Hunger"
    local before = getStat(statName)
    local ok, err = equipAndActivate(matcher, 1)
    if not ok then
        -- pipe-busy is transient: DON'T arm the cooldown, retry next tick (bug #4)
        if err == "pipe busy" then return false end
        -- genuine miss: arm the cooldown so the no-food warning honors autoEatCooldown
        state.autoEat.lastEatTime = os.clock()
        pushLog("warn", "auto-eat: no "..(isThirst and "drink" or "food").." ("..tostring(err)..")")
        return false
    end

    -- VERIFY THE STAT ACTUALLY MOVED before declaring success (bug #2). Tool:Activate() returning
    -- does NOT mean the server consumed the item; the old code declared success regardless and armed
    -- the cooldown, so a rejected consume silently blocked retries while hunger kept dropping.
    task.wait(0.7)   -- let the consume + stat replicate
    local after = getStat(statName)
    local moved = type(after) == "number" and type(before) == "number" and after > before
    if moved then
        state.autoEat.lastEatTime = os.clock()
        state.autoEat.eatCount = state.autoEat.eatCount + 1
        pushLog("good", string.format("🍖 %s — %s (%s %s→%s)", wantName or (isThirst and "drink" or "food"), reason, statName, tostring(before), tostring(after)))
        if LIVE.trace then shipTrace(string.format("EAT %s %s->%s ✓", statName, tostring(before), tostring(after))) end
        return true
    end
    -- consume didn't register: short bench (~1.5s) instead of the full cooldown so we retry soon,
    -- and log it so we KNOW Activate isn't landing (vs silently pretending it worked).
    state.autoEat.lastEatTime = os.clock() + 1.5 - (S.autoEatCooldown or 1)
    pushLog("warn", string.format("auto-eat: %s didn't change (%s→%s) — Activate may not be consuming", statName, tostring(before), tostring(after)))
    return false
end

-- ============================================================
-- UI BUILDER HELPERS
-- ============================================================
local function corner(p, r) local c=Instance.new("UICorner",p); c.CornerRadius=UDim.new(0,r or 8); return c end
local function pad(p, n) local x=Instance.new("UIPadding",p); x.PaddingTop=UDim.new(0,n); x.PaddingBottom=UDim.new(0,n); x.PaddingLeft=UDim.new(0,n); x.PaddingRight=UDim.new(0,n); return x end
local function lbl(p, t, sz, col, fn)
    local l=Instance.new("TextLabel",p); l.BackgroundTransparency=1; l.Text=t or ""
    l.TextColor3=col or C.text; l.TextSize=sz or 13
    -- guard against an unavailable font enum blanking the label
    local okFont = pcall(function() l.Font = fn or Enum.Font.Gotham end)
    if not okFont then l.Font = Enum.Font.GothamBold end
    l.TextXAlignment=Enum.TextXAlignment.Left; l.TextYAlignment=Enum.TextYAlignment.Center; return l
end
local function btn(p, t)
    local b=Instance.new("TextButton",p); b.BackgroundColor3=C.bg3; b.BorderSizePixel=0
    b.Text=t; b.TextColor3=C.text; b.TextSize=12; b.Font=Enum.Font.GothamMedium; b.AutoButtonColor=false
    corner(b,6)
    b.MouseEnter:Connect(function() TweenService:Create(b,TweenInfo.new(0.15),{BackgroundColor3=C.accentDk}):Play() end)
    b.MouseLeave:Connect(function() TweenService:Create(b,TweenInfo.new(0.15),{BackgroundColor3=C.bg3}):Play() end)
    return b
end

-- ============================================================
-- HOIST: forward decls for cross-scope refs.  The WindUI chunks below
-- reference these from their toggle callbacks; the actual function bodies
-- are assigned in the WATCHDOG LOGIC block at the bottom of this section.
-- ============================================================
local checkPlayerAgainstFlags
local watchdogFire

-- ============================================================
-- STUB GUI: ScreenGui that hosts the minimap and acts as the
-- `while gui.Parent do` liveness anchor for every background loop.
-- (no visible widgets live here -- WindUI manages its own window)
-- ============================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ENI_Helper"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999
gui.Parent = lp:WaitForChild("PlayerGui")
_G.ENI_HELPER.gui = gui

-- ============================================================
-- WINDUI LOADER + WINDOW + TABS
-- ============================================================
local WindUI
do
    local WINDUI_CACHE = "windui_cache.lua"
    -- Cache-ONLY loader. The on-disk windui_cache.lua must already contain WindUI's
    -- bundled release (not source - source has relative requires that loadstring
    -- can't resolve). If you don't have it: download
    -- https://github.com/Footagesus/WindUI/releases/latest/download/main.lua
    -- in your browser, save as windui_cache.lua in your Wave Workspace folder.
    -- Previous auto-fetch was silently overwriting a valid bundle with broken source
    -- from jsdelivr, so we removed that branch entirely.
    if not (isfile and readfile and isfile(WINDUI_CACHE)) then
        warn("[hub] windui_cache.lua missing in Wave Workspace - cannot continue. " ..
             "Download https://github.com/Footagesus/WindUI/releases/latest/download/main.lua and save as windui_cache.lua")
        return
    end
    local okr, src = pcall(readfile, WINDUI_CACHE)
    if not okr or type(src) ~= "string" or #src < 100000 then
        warn(string.format("[hub] windui_cache.lua is wrong size (%s bytes, expected ~250000). " ..
             "Re-download from https://github.com/Footagesus/WindUI/releases/latest/download/main.lua",
             tostring(src and #src or "<read failed>")))
        return
    end
    -- safety: refuse to run a source build (it has relative requires that break)
    if src:find('require%s*%(%s*"%./') or src:find("This is just an example") then
        warn("[hub] windui_cache.lua is the SOURCE (has relative requires) not the BUNDLE. " ..
             "Re-download from https://github.com/Footagesus/WindUI/releases/latest/download/main.lua")
        return
    end
    local okl, lib = pcall(function() return loadstring(src)() end)
    if not (okl and lib) then
        warn("[hub] WindUI loadstring failed: " .. tostring(lib))
        return
    end
    WindUI = lib
    pushLog("good", "✨ WindUI loaded from cache (" .. #src .. " bytes)")
end

local Window = WindUI:CreateWindow({
    Title  = "Hub",
    Icon   = "swords",
    Author = "v5",
    Folder = "Hub",
    Size   = UDim2.fromOffset(440, 320),   -- tight
    Theme  = "Dark",
    SideBarWidth = 110,                     -- minimal sidebar
    HasOutline = true,
    Transparent = true,                     -- glassy backdrop if supported
    Acrylic = true,                         -- frosted-glass effect on supported devices
    User = { Enabled = false },             -- hide the avatar header strip; cleaner top
    -- KeySystem field intentionally OMITTED -- passing it at all (even Enabled=false)
    -- makes WindUI show the key-entry screen on some versions.
})

_G.ENI_HELPER.Window = Window   -- escape hatch: _G.ENI_HELPER.Window:Open() from console if hotkey stuck

pcall(function() Window:SetUIScale(0.85) end)

-- 7-tab layout. Code keys aliased so existing :Button/:Toggle/:Section calls keep working
-- without touching every reference. Fight is combat-only; ESP and Movement get their own
-- tabs (distinct mental models); Sail is boat-only; Gear is buy/craft/equip/inventory;
-- Train is the grind; Settings absorbs Safety (watchdog + flagged is set-once config).
local _Fight    = Window:Tab({ Title = "Fight",    Icon = "swords"       })
local _ESP      = Window:Tab({ Title = "ESP",      Icon = "eye"          })
local _Sail     = Window:Tab({ Title = "Sail",     Icon = "ship"         })
local _Move     = Window:Tab({ Title = "Move",     Icon = "navigation"   })
local _Gear     = Window:Tab({ Title = "Gear",     Icon = "shopping-bag" })
local _Train    = Window:Tab({ Title = "Train",    Icon = "activity"     })
local _Settings = Window:Tab({ Title = "Settings", Icon = "cog"          })

local Tabs = {
    Farming    = _Fight,     -- Auto Farm   → Fight
    Intel      = _ESP,       -- ESP         → ESP   (own tab)
    Safety     = _Settings,  -- Safety      → Settings (folded in)
    Boat       = _Sail,      -- Sailing     → Sail
    BoatFarm   = _Sail,      -- Boat Farm   → Sail
    Movement   = _Move,      -- Movement    → Move  (own tab)
    Production = _Gear,      -- Production  → Gear
    Character  = _Gear,      -- Character   → Gear
    Survival   = _Train,     -- Stats       → Train
    Settings   = _Settings,  -- Settings    → Settings
}
Window:SelectTab(1)

-- friendly load notify with the hotkey hint so you know how to recover it
pcall(function()
    WindUI:Notify({
        Title    = "Loaded",
        Content  = "RightShift to toggle.",
        Duration = 3,
        Icon     = "anchor",
    })
end)

state.winduiParagraphs = state.winduiParagraphs or {}

-- ============================================================
-- WINDUI TABS  (all 7, see windui_chunks/ for individual sources)
-- ============================================================


-- ###### TAB: Combat ######
-- ============================================================
-- WATCHDOG (auto-leave/hop on player join)
-- ============================================================
Tabs.Safety:Section({ Title = "WATCHDOG (auto-leave)", Opened = true })

-- forward-declared so the toggle setters / rescan can reference it before
-- the actual function body (defined further down the file).
-- checkPlayerAgainstFlags hoisted at top of the script
-- helper: when a watchdog toggle flips ON, re-scan players already in the server
-- (PlayerAdded only fires for NEW joiners, so existing players were getting a free pass).
local function rescanForWatchdog()
    if not S.watchdogOn then
        pushLog("warn","🚨 rescan skipped: main 'Enable watchdog' toggle is OFF")
        return
    end
    local n = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then n = n + 1; checkPlayerAgainstFlags(p) end
    end
    pushLog("info","🚨 rescan checked "..n.." player(s)")
end

local watchdogOnTog = Tabs.Safety:Toggle({
    Title = "Enable watchdog",
    Value = S.watchdogOn,
    Callback = function(v)
        S.watchdogOn=v; if v then rescanForWatchdog() end
        saveConfig()
    end,
})

local watchdogAnyTog = Tabs.Safety:Toggle({
    Title = "Trigger on ANY player join (solo-farm)",
    Value = S.watchdogAnyPlayer,
    Callback = function(v)
        S.watchdogAnyPlayer=v
        if v then
            -- auto-enable the master toggle too -- the ANY mode is useless without it
            if not S.watchdogOn then
                S.watchdogOn = true
                pushLog("info","🚨 auto-enabled 'Enable watchdog' (required for ANY-mode)")
                -- reflect new master-toggle state in the UI too
                pcall(function() watchdogOnTog:SetValue(true) end)
            end
            rescanForWatchdog()
        end
        saveConfig()
    end,
})

-- WATCHDOG ACTION (hop vs leave) -- native Dropdown so it renders inside WindUI's Section.
Tabs.Safety:Section({ Title = "WATCHDOG ACTION", Opened = false })
Tabs.Safety:Paragraph({ Title = "When flagged player joins", Desc = "Choose action." })
Tabs.Safety:Dropdown({
    Title = "Action",
    Values = { "hop (server-hop)", "leave (kick self)" },
    Value = (S.watchdogAction == "leave") and "leave (kick self)" or "hop (server-hop)",
    Multi = false,
    Callback = function(opt)
        S.watchdogAction = (opt and opt:sub(1,4) == "leav") and "leave" or "hop"
        saveConfig()
        pushLog("info", "watchdog action -> " .. S.watchdogAction)
    end,
})

-- FLAGGED PLAYERS: native WindUI widgets (guaranteed to render, no raw-frame parenting hacks)
Tabs.Safety:Section({ Title = "FLAGGED PLAYERS", Opened = false })

local flaggedListP   -- forward decl for the render fn below
local flaggedRemoveDd  -- forward decl

local function renderFlagged()
    local lines = {}
    for _, name in ipairs(S.watchdogTriggers) do lines[#lines+1] = "🚨 " .. name end
    if flaggedListP then
        flaggedListP:SetDesc(#lines > 0 and table.concat(lines, "\n") or "(no flagged players yet)")
    end
    if flaggedRemoveDd and flaggedRemoveDd.Refresh then
        pcall(function() flaggedRemoveDd:Refresh(S.watchdogTriggers) end)
    end
end

Tabs.Safety:Input({
    Title = "Add flagged player",
    Value = "",
    Placeholder = "username...",
    Callback = function(text)
        if not text or text == "" then return end
        local name = text:gsub("^%s+",""):gsub("%s+$","")
        if name == "" then return end
        for _, existing in ipairs(S.watchdogTriggers) do
            if existing:lower() == name:lower() then
                pushLog("warn", "watchdog: already watching "..name); return
            end
        end
        table.insert(S.watchdogTriggers, name)
        saveConfig(); renderFlagged()
        pushLog("good", "watchdog: now watching "..name)
    end,
})

flaggedListP = Tabs.Safety:Paragraph({ Title = "Currently flagged", Desc = "(no flagged players yet)" })

flaggedRemoveDd = Tabs.Safety:Dropdown({
    Title = "Remove flagged",
    Values = S.watchdogTriggers,
    Value = nil,
    Multi = false,
    AllowNone = true,
    Callback = function(opt)
        if not opt or opt == "" then return end
        for i, n in ipairs(S.watchdogTriggers) do
            if n == opt then
                table.remove(S.watchdogTriggers, i)
                saveConfig(); renderFlagged()
                pushLog("info", "watchdog: removed "..n)
                return
            end
        end
    end,
})

renderFlagged()

-- ============================================================
-- WHITELIST  (never fires watchdog on these names -- friends, self alts, etc)
-- ============================================================
Tabs.Safety:Section({ Title = "WHITELIST (never fire on these)", Opened = false })

local wlListP, wlRemoveDd

local function renderWhitelist()
    local lines = {}
    for _, name in ipairs(S.watchdogWhitelist or {}) do lines[#lines+1] = "✅ " .. name end
    if wlListP then
        wlListP:SetDesc(#lines > 0 and table.concat(lines, "\n") or "(whitelist is empty)")
    end
    if wlRemoveDd and wlRemoveDd.Refresh then
        pcall(function() wlRemoveDd:Refresh(S.watchdogWhitelist or {}) end)
    end
end

Tabs.Safety:Input({
    Title = "Add to whitelist",
    Value = "",
    Placeholder = "username (exact)...",
    Callback = function(text)
        if not text or text == "" then return end
        local name = text:gsub("^%s+",""):gsub("%s+$","")
        if name == "" then return end
        S.watchdogWhitelist = S.watchdogWhitelist or {}
        for _, existing in ipairs(S.watchdogWhitelist) do
            if existing:lower() == name:lower() then
                pushLog("warn", "whitelist: already has "..name); return
            end
        end
        table.insert(S.watchdogWhitelist, name)
        saveConfig(); renderWhitelist()
        pushLog("good", "whitelist: added "..name)
    end,
})

wlListP = Tabs.Safety:Paragraph({ Title = "Currently whitelisted", Desc = "(whitelist is empty)" })

wlRemoveDd = Tabs.Safety:Dropdown({
    Title = "Remove from whitelist",
    Values = S.watchdogWhitelist or {},
    Value = nil,
    Multi = false,
    AllowNone = true,
    Callback = function(opt)
        if not opt or opt == "" then return end
        for i, n in ipairs(S.watchdogWhitelist or {}) do
            if n == opt then
                table.remove(S.watchdogWhitelist, i)
                saveConfig(); renderWhitelist()
                pushLog("info", "whitelist: removed "..n)
                return
            end
        end
    end,
})

renderWhitelist()

-- (watchdog diagnostic section removed; test/reset buttons were one-time setup tools)
-- watchdogFire hoisted at top of the script so this section can reference it.

-- ============================================================
-- COMBAT TAB  (legacy "Spam attack key" + rebindable hotkey were cut;
--              the real targeted auto-farm below replaced them.)
-- ============================================================
Tabs.Farming:Section({ Title = "AUTO-FARM (hover + Swing)", Opened = true })

Tabs.Farming:Toggle({
    Title = "Enable auto-farm",
    Value = S.autoFarmOn,
    Callback = function(v)
        S.autoFarmOn=v
        if v then
            S.autoMineOn=false   -- mutually exclusive with auto-mine (one HRP mover at a time)
            pcall(function() lp.Character.ClientCore["Server.cc"].comms.remotes.FightStance:InvokeServer(true) end)
        end
        pushLog(v and "good" or "warn", "🎯 auto-farm toggle → "..tostring(v))
        saveConfig()
    end,
})

-- NPC catalog mined from Sea Piece G8 synsave (12 types across 6 categories).
-- Multi-select: every checked type is a name-substring the scanner will match (ANY-of).
-- The free-text box below adds extra comma-separated names on top of the checked ones.
local NPC_GROUP_PRESETS = {
    -- Pirates --
    "Pirate", "Royal Pirate",
    -- Marines (rank ladder) --
    "Marine Soldier", "Marine Officer", "Marine Captain", "Marine Vice Admiral", "Marine Admiral",
    -- Merchants --
    "Merchant", "BoatMerchant",
    -- Animals --
    "Deer",
    -- Bosses --
    "WorldBoss",
}

Tabs.Farming:Dropdown({
    Title = "Target types (multi-select)",
    Desc = "Check one or more NPC types — the farm hits ANY of them. Add custom names in the box below. Nothing checked + empty box = nearest of anything.",
    Values = NPC_GROUP_PRESETS,
    Value = (type(S.autoFarmTargets) == "table" and S.autoFarmTargets) or {},
    Multi = true,
    AllowNone = true,
    Callback = function(v)
        -- normalize WindUI's emission (array | set | bare-string) into a canonical string array,
        -- matching the auto-eat / auto-delete dropdowns. (A raw bare string would otherwise slip
        -- past farmTerms' type(list)=="table" guard and silently drop the selection.)
        local out = {}
        if type(v) == "table" then
            for k, val in pairs(v) do
                if type(val) == "string" and val ~= "" then out[#out + 1] = val
                elseif val == true and type(k) == "string" then out[#out + 1] = k end
            end
        elseif type(v) == "string" and v ~= "" then
            out[#out + 1] = v
        end
        S.autoFarmTargets = out
        saveConfig()
    end,
})

do
    local tgtSlot = Tabs.Farming:Section({ Title = "" })
    local fr=Instance.new("Frame",tgtSlot.ElementFrame.Content); fr.Size=UDim2.new(1,0,0,30); fr.BackgroundTransparency=1
    local tb=Instance.new("TextBox",fr); tb.Size=UDim2.new(1,0,1,0); tb.BackgroundColor3=C.bg3; tb.BorderSizePixel=0
    tb.PlaceholderText="extra names, comma-separated (e.g. Deer, Admiral)"; tb.PlaceholderColor3=C.textMute; tb.Text=S.autoFarmTarget
    tb.TextColor3=C.text; tb.Font=Enum.Font.Code; tb.TextSize=11; tb.ClearTextOnFocus=false
    corner(tb,6); pad(tb,8)
    tb:GetPropertyChangedSignal("Text"):Connect(function()
        S.autoFarmTarget=tb.Text
    end)
end

Tabs.Farming:Slider({
    Title = "Offset X",
    Value = { Min = -40, Max = 40, Default = math.clamp(S.autoFarmOffsetX or 0, -40, 40) },
    Step = 1,
    Callback = function(v) S.autoFarmOffsetX=v; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Offset Y",
    Value = { Min = -10, Max = 80, Default = math.clamp(S.autoFarmHeight or 3, -10, 80) },
    Step = 1,
    Callback = function(v) S.autoFarmHeight=v; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Offset Z",
    Value = { Min = -40, Max = 40, Default = math.clamp(S.autoFarmOffsetZ or 0, -40, 40) },
    Step = 1,
    Callback = function(v) S.autoFarmOffsetZ=v; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Swing interval (×10ms)",
    Desc = "Time between attacks in 10 ms units. Lower = faster attacks.",
    Value = { Min = 5, Max = 150, Default = math.clamp(math.floor((S.autoFarmAttackInterval or 0.25)*100), 5, 150) },
    Step = 1,
    Callback = function(v) S.autoFarmAttackInterval=v/100; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Tween rate (lower = smoother)",
    Desc = "Movement smoothing: lower = slower glide, higher = snappier.",
    Value = { Min = 1, Max = 20, Default = math.clamp(S.autoFarmTweenRate or 5, 1, 20) },
    Step = 1,
    Callback = function(v) S.autoFarmTweenRate=v; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Switch target if no dmg in (s)",
    Desc = "Seconds without damage before switching targets. Counted only at melee range.",
    Value = { Min = 1, Max = 60, Default = math.clamp(math.floor(S.autoFarmStuckTime or 8), 1, 60) },
    Step = 1,
    Callback = function(v) S.autoFarmStuckTime=v; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Melee range (studs)",
    Desc = "Minimum distance (studs) to attack. Attacks outside this range are rejected by server.",
    Value = { Min = 3, Max = 30, Default = math.clamp(math.floor(S.autoFarmMeleeRange or 8), 3, 30) },
    Step = 1,
    Callback = function(v) S.autoFarmMeleeRange=v; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Approach speed (stud/s)",
    Desc = "Max glide speed while still farther than melee range. Higher = close the gap faster.",
    Value = { Min = 60, Max = 600, Default = math.clamp(math.floor(S.autoFarmApproachSpeed or 320), 60, 600) },
    Step = 10,
    Callback = function(v) S.autoFarmApproachSpeed=v; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Hover speed (stud/s)",
    Desc = "Max glide speed once inside melee range. Lower = precise hover, no overshoot.",
    Value = { Min = 20, Max = 200, Default = math.clamp(math.floor(S.autoFarmHoverSpeed or 80), 20, 200) },
    Step = 5,
    Callback = function(v) S.autoFarmHoverSpeed=v; saveConfig() end,
})
Tabs.Farming:Toggle({
    Title = "Prioritize low-HP mobs",
    Desc = "Prefer low-HP targets over distance. Off = closest target only.",
    Default = (S.autoFarmPrioLowHp ~= false),
    Callback = function(v) S.autoFarmPrioLowHp=v; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Bail below HP%",
    Desc = "Pause auto-farm if your HP drops below this. 100 = bail on any damage.",
    Value = { Min = 0, Max = 100, Default = math.clamp(S.autoFarmHpFloor or 0, 0, 100) },
    Step = 1,
    Callback = function(v) S.autoFarmHpFloor=v; saveConfig() end,
})

Tabs.Farming:Section({ Title = "AUTO-LOOT" })

Tabs.Farming:Toggle({
    Title = "Enable auto-loot",
    Value = S.autoLootOn,
    Callback = function(v)
        S.autoLootOn = v; S.boatFarmLootChests = v; saveConfig()
        -- Fire one verbose pass immediately so the user sees WHY it found 0 targets
        -- (own boat skipped, out of range, wrong name match, etc.) instead of silent no-op.
        if v then task.spawn(function() pcall(function() BF.loot({ verbose = true, ignoreGate = true }) end) end) end
    end,
})

Tabs.Farming:Toggle({
    Title = "Include your own boat",
    Desc  = "ON = loot crates on your own ship too (default).  OFF = only enemy/NPC boats.",
    Value = S.boatFarmLootOwnBoat ~= false,
    Callback = function(v) S.boatFarmLootOwnBoat = v and true or false; saveConfig() end,
})

Tabs.Farming:Input({
    Title = "Loot keyword",
    Value = S.boatFarmLootKeyword,
    Placeholder = "(blank = all)",
    Callback = function(text) S.boatFarmLootKeyword = text or ""; saveConfig() end,
})

Tabs.Farming:Slider({
    Title = "Scan tick (seconds)",
    Value = { Min = 1, Max = 30, Default = math.clamp(S.autoLootInterval or 2.0, 1, 30) },
    Step = 0.5,
    Callback = function(v) S.autoLootInterval = v; saveConfig() end,
})

Tabs.Farming:Button({
    Title = "Loot now (verbose)",
    Desc  = "Fire one verbose loot pass.  Logs scan stats so you can see exactly why targets succeed/fail.",
    Callback = function() task.spawn(function() pcall(function() BF.loot({ verbose = true, ignoreGate = true }) end) end) end,
})

-- Boat-loot loop (scans other players' boats for crates/barrels via BF.loot).
-- Kept for boat-farm scenarios; gated on S.boatFarmLootChests which the toggle also sets.
task.spawn(function()
    while gui.Parent do
        if S.autoLootOn and not state.panic then
            pcall(function() BF.loot({ ignoreGate = true }) end)
        end
        task.wait(math.max(1, S.autoLootInterval or 2.0))
    end
end)


Tabs.Farming:Section({ Title = "STATUS" })
state.winduiParagraphs = state.winduiParagraphs or {}
state.winduiParagraphs.cbStatus = Tabs.Farming:Paragraph({ Title = "Combat status", Desc = "..." })

-- ============================================================
-- AUTO-CLASH — detect a nearby opponent's heavy windup (their replicated HeavyAttack/ChargedAttack
-- animation track) and instantly fire our response (HeavySwing / Block / Evade) to clash it.
-- Self-tuning: the debug toggle logs real enemy track names so you can fix the windup-name list,
-- and the response mode lets you find which input actually clashes. Default OFF.
-- ============================================================
Tabs.Farming:Section({ Title = "AUTO-CLASH (react to heavy hits)" })

Tabs.Farming:Toggle({
    Title = "Enable auto-clash",
    Desc = "When a nearby opponent starts a heavy attack, instantly fire your response to clash it.",
    Value = S.autoClashOn,
    Callback = function(v) S.autoClashOn = v; saveConfig() end,
})

Tabs.Farming:Dropdown({
    Title = "Response",
    Values = { "Heavy (HeavySwing)", "Block", "Evade (R)" },
    Value = (S.autoClashMode == "block" and "Block") or (S.autoClashMode == "evade" and "Evade (R)") or "Heavy (HeavySwing)",
    Multi = false,
    Callback = function(opt)
        local o = (type(opt) == "string") and opt or "heavy"
        S.autoClashMode = (o:sub(1, 5) == "Block" and "block")
                       or (o:sub(1, 5) == "Evade" and "evade")
                       or "heavy"
        saveConfig()
    end,
})

Tabs.Farming:Slider({
    Title = "Detect range (studs)",
    Step = 5,
    Value = { Min = 15, Max = 120, Default = S.autoClashRange },
    Callback = function(v) S.autoClashRange = v; saveConfig() end,
})

Tabs.Farming:Slider({
    Title = "Clash reaction delay (s)",
    Desc = "Wait this long after spotting the heavy before swinging -- tune so OUR hit MEETS theirs (clash). Higher = later/safer.",
    Step = 0.05,
    Value = { Min = 0, Max = 0.8, Default = math.clamp(S.autoClashDelay or 0.3, 0, 0.8) },
    Callback = function(v) S.autoClashDelay = v; saveConfig() end,
})

Tabs.Farming:Input({
    Title = "Heavy windup anim names (comma-sep)",
    Value = S.autoClashNames,
    Placeholder = "HeavyAttack,ChargedAttack",
    Callback = function(text) S.autoClashNames = text or ""; saveConfig() end,
})

Tabs.Farming:Input({
    Title = "Heavy windup anim IDs (comma-sep)",
    Desc = "The reliable detector -- track names are generic ('Animation'). Probe-confirmed heavy = 92083565565984.",
    Value = S.autoClashIds,
    Placeholder = "92083565565984",
    Callback = function(text) S.autoClashIds = text or ""; saveConfig() end,
})

Tabs.Farming:Toggle({
    Title = "Smart heavy detect (any weapon)",
    Desc = "Detects heavies by animation PRIORITY (Action4) + LENGTH, not a fixed ID list -- catches every weapon's heavy without you adding IDs.",
    Value = S.autoClashSmart ~= false,
    Callback = function(v) S.autoClashSmart = v; saveConfig() end,
})
Tabs.Farming:Slider({
    Title = "Smart-detect min windup length (s)",
    Desc = "Filters out short Action4 bursts (deflect flick etc). Real heavy windups are >=0.6s. Lower = more sensitive, more false positives.",
    Value = { Min = 0.2, Max = 2.0, Default = math.clamp(S.autoClashSmartMinLen or 0.6, 0.2, 2.0) },
    Step = 0.05,
    Callback = function(v) S.autoClashSmartMinLen = v; saveConfig() end,
})

do
    state.autoClash = state.autoClash or { seen = {}, handled = setmetatable({}, { __mode = "k" }), lastClashT = 0 }

    local function parseNames()
        local set = {}
        for w in tostring(S.autoClashNames or ""):gmatch("[^,%s]+") do set[w:lower()] = true end
        return set
    end
    -- match by AnimationId too: the runtime track NAME is generic ("Animation"), so name-matching
    -- alone never fires -- the heavy is identified reliably by its AnimationId (probe-confirmed).
    local function parseIds()
        local set = {}
        for w in tostring(S.autoClashIds or ""):gmatch("%d+") do set[w] = true end
        return set
    end
    local function playingTracks(hum)
        local anim = hum and hum:FindFirstChildOfClass("Animator")
        if anim then local ok, t = pcall(function() return anim:GetPlayingAnimationTracks() end); if ok and t then return t end end
        local ok2, t2 = pcall(function() return hum:GetPlayingAnimationTracks() end)
        if ok2 and t2 then return t2 end
        return {}
    end
    -- can WE act right now? mirrors sharedModules CanSwing: no hard stun, in fight stance, not blocking
    local function canIClash(mode)
        local char = lp.Character; if not char then return false end
        local cfg = char:FindFirstChild("Config"); if not cfg then return true end
        local stuns = cfg:FindFirstChild("Stuns")
        if stuns and (stuns:FindFirstChild("Low") or stuns:FindFirstChild("High") or stuns:FindFirstChild("Disabled")) then return false end
        if mode == "evade" then
            local er = cfg:FindFirstChild("EvadeRes")
            if er and er.Value ~= 100 then return false end
        else
            local fs = cfg:FindFirstChild("fightStanced")
            if fs and fs.Value == false then return false end
            if mode ~= "block" then
                local bl = cfg:FindFirstChild("Blocking")
                if bl and bl.Value == true then return false end
            end
        end
        return true
    end
    local function fireClash(mode)
        pcall(function()
            local events = lp.Character.ClientCore["Server.cc"].comms.events
            if mode == "block" then
                events.Block:FireServer(true)
                task.delay(0.4, function() pcall(function() events.Block:FireServer(false) end) end)
            elseif mode == "evade" then
                events.Evade:FireServer()
            else
                events.HeavySwing:FireServer(true)
            end
        end)
    end

    task.spawn(function()
        while gui.Parent do
            if not S.autoClashOn or state.panic then
                task.wait(0.2)
            else
                local myHrp = getMyHRP()
                if myHrp then
                    local names = parseNames()
                    local ids   = parseIds()
                    local mode  = S.autoClashMode or "heavy"
                    local range = S.autoClashRange or 60
                    for model, e in pairs(entityCache) do
                        if model ~= lp.Character and e.hrp and e.hrp.Parent and e.humanoid and e.humanoid.Health > 0 then
                            if (e.hrp.Position - myHrp.Position).Magnitude <= range then
                                local smartOn  = S.autoClashSmart ~= false
                                local smartMin = tonumber(S.autoClashSmartMinLen) or 0.6
                                for _, tr in ipairs(playingTracks(e.humanoid)) do
                                    local tn = tr.Name or "?"
                                    local aid = ""
                                    pcall(function() aid = (tostring((tr.Animation and tr.Animation.AnimationId) or "")):match("%d+") or "" end)
                                    -- Smart detect: heavy windups in this game are Priority.Action4 with
                                    -- Length >= ~0.6s; everything else (light swings, idle, run) is lower
                                    -- priority or much shorter. Read both safely (some tracks may not expose Priority).
                                    local prio, alen = nil, 0
                                    pcall(function() prio = tr.Priority end)
                                    pcall(function() alen = tonumber(tr.Length) or 0 end)
                                    local isAction4 = (prio == Enum.AnimationPriority.Action4)
                                    local smartHit  = smartOn and isAction4 and (alen >= smartMin)
                                    if names[tn:lower()] or (aid ~= "" and ids[aid]) or smartHit then
                                        -- fire ONCE per heavy: dedup by the AnimationTrack INSTANCE so a track
                                        -- that lingers for ~1s can't re-trigger; plus a GLOBAL cooldown so it
                                        -- can't chain clashes back-to-back (looked botty + burned our own CD).
                                        if not state.autoClash.handled[tr]
                                           and (os.clock() - (state.autoClash.lastClashT or 0)) > (S.autoClashGlobalCd or 0.8)
                                           and canIClash(mode) then
                                            state.autoClash.handled[tr] = true
                                            state.autoClash.lastClashT = os.clock()
                                            local nm = e.name or "?"
                                            task.spawn(function()
                                                -- reaction OFFSET: wait into the windup so OUR hit meets theirs
                                                -- (clash), instead of swinging on frame 1 and whiffing early.
                                                task.wait(S.autoClashDelay or 0.3)
                                                if canIClash(mode) then
                                                    fireClash(mode)
                                                    local why = smartHit and ("smart Action4 len=" .. string.format("%.2fs", alen))
                                                                or ("id " .. aid)
                                                    pushLog("good", "⚔️ clash! " .. mode .. " vs " .. nm .. " (" .. why .. ")")
                                                end
                                            end)
                                        end
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
                task.wait(0.04)
            end
        end
    end)
end
-- // loop at line 3829 updates this paragraph -- ensure it calls WindUI paragraph (state.winduiParagraphs.cbStatus:SetDesc) instead of old cbStatus.Text

-- ###### TAB: Resources ######
-- ============================================================
-- RESOURCES TAB (WindUI migration)
-- ============================================================

-- bridge table so background loops can update WindUI paragraphs
state.winduiParagraphs = state.winduiParagraphs or {}

-- ---- AUTO-MINE (hover + pickaxe) ----
Tabs.Farming:Section({ Title = "AUTO-MINE (hover + pickaxe)", Opened = true })

Tabs.Farming:Toggle({
    Title = "Enable auto-mine",
    Value = S.autoMineOn,
    Callback = function(v)
        S.autoMineOn=v
        if v then S.autoFarmOn=false end   -- mutually exclusive with auto-farm (one HRP mover at a time)
        pushLog(v and "good" or "warn", "⛏ auto-mine toggle → "..tostring(v))
        saveConfig()
    end,
})

Tabs.Farming:Slider({
    Title = "Mine height (Y)",
    Value = { Min = -10, Max = 40, Default = S.autoMineHeight },
    Step = 1,
    Callback = function(v) S.autoMineHeight=v; saveConfig() end,
})

do  -- ore-type filter presets: Any / Copper / Stone (matched against the ore model name)
    local rawSlot = Tabs.Farming:Section({ Title = "" })  -- spacer-section to host raw Instance frame
    local parent = rawSlot.ElementFrame.Content
    local row=Instance.new("Frame",parent); row.Size=UDim2.new(1,0,0,28); row.BackgroundTransparency=1
    local function mk(label, val, x, w)
        local b=btn(row,label); b.Size=UDim2.new(w,-3,1,0); b.Position=UDim2.new(x,0,0,0); b.TextSize=11
        b.MouseButton1Click:Connect(function()
            S.autoMineFilter=val; saveConfig()
            pushLog("info","⛏ ore filter → "..(val=="" and "any" or val))
        end)
    end
    mk("Any","",0,0.34); mk("Copper","copper",0.34,0.33); mk("Stone","stone",0.67,0.33)
end

-- ---- BUY FROM ANYWHERE (PurchaseItem exploit) ----
-- comms.PurchaseItem accepts InvokeServer(name, qty) from anywhere -- no merchant proximity
-- gate. Confirmed working 2026-06-07 on Copper Ingot, Potato, Tomato, Stone, Wheat.
-- Charges your Beli for each call. Server gracefully returns false on unknown item names.
Tabs.Production:Section({ Title = "BUY FROM ANYWHERE", Opened = true })

do
    -- buyList is stored as a comma-separated string for back-compat with saved config.
    -- UI is type-to-add (no pre-fill in the input box).
    S.buyList = S.buyList or ""
    S.buyQty  = S.buyQty or 10
    S.buyAutoOn = S.buyAutoOn or false
    S.buyAutoInterval = S.buyAutoInterval or 30
    local pendingAdd, pendingRm = "", ""

    local function parseList(text)
        local out = {}
        for chunk in tostring(text or ""):gmatch("[^,]+") do
            local n = chunk:gsub("^%s+", ""):gsub("%s+$", "")
            if n ~= "" then out[#out + 1] = n end
        end
        return out
    end

    local function buyOnce(verbose)
        local pi = game:GetService("ReplicatedStorage"):FindFirstChild("comms")
        pi = pi and pi:FindFirstChild("PurchaseItem")
        if not pi then pushLog("bad", "PurchaseItem remote missing"); return 0, 0 end
        local items = parseList(S.buyList)
        if #items == 0 then
            if verbose then pushLog("warn", "buy list is empty -- add items first") end
            return 0, 0
        end
        local qty = math.max(1, math.floor(tonumber(S.buyQty) or 1))
        local hits, misses, beliBefore = 0, 0, nil
        local stats = lp:FindFirstChild("Stats")
        local beli = stats and stats:FindFirstChild("Beli")
        if beli then beliBefore = beli.Value end
        for _, name in ipairs(items) do
            local bought, failed = 0, 0
            for i = 1, qty do
                local ok, ret = pcall(function() return pi:InvokeServer(name, 1) end)
                if ok and ret == true then bought = bought + 1
                else failed = failed + 1 end
                task.wait(0.05)
                if state.panic then break end
            end
            if bought > 0 then
                hits = hits + 1
                if verbose then pushLog("good", string.format("+%dx %s%s", bought, name,
                    failed > 0 and string.format(" (%d failed)", failed) or "")) end
            else
                misses = misses + 1
                if verbose then pushLog("warn", string.format("fail: %s", name)) end
            end
        end
        if beli and beliBefore and verbose then
            pushLog("info", string.format("done -- %d ok, %d fail, Beli %+d",
                hits, misses, beli.Value - beliBefore))
        end
        return hits, misses
    end

    -- live paragraph that shows the current buy list. Refreshed after add/remove/clear.
    local listP = Tabs.Production:Paragraph({
        Title = "Buy list",
        Desc  = S.buyList == "" and "(empty)" or S.buyList,
    })
    local function refreshList()
        pcall(function() listP:SetDesc(S.buyList == "" and "(empty)" or S.buyList) end)
    end

    Tabs.Production:Input({
        Title = "Item to add",
        Desc  = "Exact PurchaseItem name. Confirmed: Copper Ingot, Potato, Tomato, Stone, Wheat.",
        Placeholder = "Copper Ingot",
        Callback = function(t) pendingAdd = t or "" end,
    })
    Tabs.Production:Button({
        Title = "Add to list",
        Callback = function()
            local n = (pendingAdd or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if n == "" then pushLog("warn", "type a name first"); return end
            -- commas are the list delimiter; reject them in names to prevent silent corruption
            if n:find(",", 1, true) then pushLog("warn", "item names cannot contain commas"); return end
            local items = parseList(S.buyList)
            for _, ex in ipairs(items) do
                if ex:lower() == n:lower() then pushLog("info", "already in list"); return end
            end
            items[#items + 1] = n
            S.buyList = table.concat(items, ", ")
            saveConfig(); refreshList()
            pushLog("good", "added: " .. n)
        end,
    })

    Tabs.Production:Input({
        Title = "Item to remove",
        Placeholder = "(name to remove)",
        Callback = function(t) pendingRm = t or "" end,
    })
    Tabs.Production:Button({
        Title = "Remove from list",
        Callback = function()
            local n = (pendingRm or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
            if n == "" then pushLog("warn", "type a name to remove"); return end
            local items, kept, removed = parseList(S.buyList), {}, false
            for _, item in ipairs(items) do
                if item:lower() == n then removed = true
                else kept[#kept + 1] = item end
            end
            if not removed then pushLog("warn", "not in list"); return end
            S.buyList = table.concat(kept, ", ")
            saveConfig(); refreshList()
            pushLog("good", "removed")
        end,
    })

    Tabs.Production:Button({
        Title = "Clear list",
        Callback = function()
            S.buyList = ""; saveConfig(); refreshList()
            pushLog("info", "buy list cleared")
        end,
    })

    Tabs.Production:Slider({
        Title = "Quantity per item",
        Value = { Min = 1, Max = 999, Default = math.clamp(S.buyQty or 10, 1, 999) },
        Step = 1,
        Callback = function(v) S.buyQty = v; saveConfig() end,
    })

    Tabs.Production:Button({
        Title = "Buy once",
        Desc  = "Run PurchaseItem for every name in the list. Costs Beli.",
        Callback = function() task.spawn(function() buyOnce(true) end) end,
    })

    Tabs.Production:Toggle({
        Title = "Auto-buy loop",
        Value = S.buyAutoOn or false,
        Callback = function(v)
            S.buyAutoOn = v and true or false; saveConfig()
            pushLog(v and "warn" or "info", v and "auto-buy ON" or "auto-buy off")
            -- Fire one verbose buy immediately so the user sees the result instead of
            -- waiting the full interval and wondering if it's working.  Empty list / no
            -- Beli / unknown item all surface in this single log line.
            if v then task.spawn(function() buyOnce(true) end) end
        end,
    })

    Tabs.Production:Slider({
        Title = "Auto-buy interval (s)",
        Value = { Min = 5, Max = 300, Default = math.clamp(S.buyAutoInterval or 30, 5, 300) },
        Step = 1,
        Callback = function(v) S.buyAutoInterval = v; saveConfig() end,
    })

    task.spawn(function()
        while gui.Parent do
            if S.buyAutoOn and not state.panic then
                pcall(function() buyOnce(false) end)
            end
            task.wait(math.max(5, tonumber(S.buyAutoInterval) or 30))
        end
    end)

    -- ============================================================
    -- STASH FROM ANYWHERE: OpenItemStash returns the stash table from any
    -- location. Blank target = your own stash. With another player's name
    -- it MIGHT return theirs (server gating unknown).
    -- ============================================================
    local pendingStash = ""
    Tabs.Production:Input({
        Title = "Stash to dump",
        Desc  = "Blank = your own. Type a player name to try theirs.",
        Placeholder = "(blank = your own)",
        Callback = function(t) pendingStash = t or "" end,
    })
    Tabs.Production:Button({
        Title = "Dump stash",
        Desc  = "Reads stash via OpenItemStash. Writes stash_dump.log + copies to clipboard.",
        Callback = function()
            task.spawn(function()
                local ois = RS:FindFirstChild("comms") and RS.comms:FindFirstChild("OpenItemStash")
                if not ois then pushLog("bad", "OpenItemStash remote missing"); return end
                local target = (pendingStash ~= "" and pendingStash or nil)
                local ok, ret = pcall(function() return ois:InvokeServer(target) end)
                if not ok then pushLog("bad", "fail: " .. tostring(ret)); return end
                if type(ret) ~= "table" then
                    pushLog("warn", "unexpected return: " .. tostring(ret)); return
                end
                local lines = { string.format("=== stash dump %s ===", target or "(self)") }
                local function dump(t, indent)
                    for k, v in pairs(t) do
                        if type(v) == "table" then
                            lines[#lines+1] = string.format("%s%s = {", indent, tostring(k))
                            dump(v, indent .. "  ")
                            lines[#lines+1] = indent .. "}"
                        else
                            lines[#lines+1] = string.format("%s%s = %s", indent, tostring(k), tostring(v))
                        end
                    end
                end
                dump(ret, "  ")
                local text = table.concat(lines, "\n")
                if writefile then pcall(writefile, "stash_dump.log", text) end
                if setclipboard then pcall(setclipboard, text) end
                local n = 0; for _ in pairs(ret) do n = n + 1 end
                pushLog("good", string.format("stash dumped (%d top-level, %d bytes -> stash_dump.log)", n, #text))
            end)
        end,
    })

    -- ============================================================
    -- 🛡 ClearVels: zeroes velocity server-side. Likely anti-knockback.
    -- ============================================================
    Tabs.Production:Button({
        Title = "Clear velocity (anti-knockback)",
        Callback = function()
            local cv = RS:FindFirstChild("comms") and RS.comms:FindFirstChild("ClearVels")
            if not cv then pushLog("bad", "🛡 ClearVels missing"); return end
            local ok = pcall(function() cv:FireServer() end)
            pushLog(ok and "good" or "bad", "🛡 ClearVels: " .. (ok and "fired" or "failed"))
        end,
    })

    -- ============================================================
    -- 🔨 CraftRequest bulk: comms.CraftRequest accepts InvokeServer(name)
    --    from anywhere -- no workbench proximity. Returns true per craft if
    --    materials are present, false otherwise. Confirmed via decompiled
    --    HudClient:1840 (the Craft button just calls this).
    -- ============================================================
    S.craftBulkItem = S.craftBulkItem or "Copper Nail"
    S.craftBulkQty  = S.craftBulkQty or 50
    Tabs.Production:Input({
        Title = "Bulk craft item",
        Desc  = "Any recipe name (Copper Nail, Oak Plank, Caravan, Sloop, etc). Server checks materials per call.",
        Value = S.craftBulkItem,
        Placeholder = "Copper Nail",
        Callback = function(t) S.craftBulkItem = t or ""; saveConfig() end,
    })
    Tabs.Production:Slider({
        Title = "Bulk craft quantity",
        Value = { Min = 1, Max = 999, Default = math.clamp(S.craftBulkQty or 50, 1, 999) },
        Step = 1,
        Callback = function(v) S.craftBulkQty = v; saveConfig() end,
    })
    S.craftBulkParallel = S.craftBulkParallel ~= false
    Tabs.Production:Toggle({
        Title = "Parallel bulk craft (max speed)",
        Desc  = "ON = fire all N crafts simultaneously via task.spawn (fastest). OFF = sequential with 50ms gap (safer).",
        Value = S.craftBulkParallel,
        Callback = function(v) S.craftBulkParallel = v; saveConfig() end,
    })
    Tabs.Production:Button({
        Title = "Bulk craft now",
        Callback = function()
            task.spawn(function()
                local cr = RS:FindFirstChild("comms") and RS.comms:FindFirstChild("CraftRequest")
                if not cr then pushLog("bad", "🔨 CraftRequest missing"); return end
                local name = S.craftBulkItem or ""
                if name == "" then pushLog("warn", "🔨 set an item name"); return end
                local qty = math.max(1, math.floor(tonumber(S.craftBulkQty) or 1))
                local ok, fail = 0, 0
                if S.craftBulkParallel then
                    -- fire all N in parallel via task.spawn -- bottleneck becomes the server's
                    -- per-invoke processing speed, not our wait loop
                    local pending = qty
                    for i = 1, qty do
                        task.spawn(function()
                            local pcOk, ret = pcall(function() return cr:InvokeServer(name) end)
                            if pcOk and ret == true then ok = ok + 1 else fail = fail + 1 end
                            pending = pending - 1
                        end)
                    end
                    -- wait for all to settle
                    local t0 = os.clock()
                    while pending > 0 and (os.clock() - t0) < 30 do task.wait(0.05) end
                else
                    for i = 1, qty do
                        if state.panic then break end
                        local pcOk, ret = pcall(function() return cr:InvokeServer(name) end)
                        if pcOk and ret == true then ok = ok + 1 else fail = fail + 1 end
                        task.wait(0.05)
                    end
                end
                pushLog(ok > 0 and "good" or "warn",
                    string.format("🔨 crafted %d/%d %s (%d fail) %s",
                        ok, qty, name, fail, S.craftBulkParallel and "[parallel]" or "[seq]"))
            end)
        end,
    })

end

-- (AUTO-SMELT section removed)


-- ###### TAB: Survival ######
-- ============================================================
-- SURVIVE (auto-eat) TAB
-- ============================================================
state.winduiParagraphs = state.winduiParagraphs or {}

-- ============================================================
-- AUTO-TRAIN (all-in-one: meditate + every workout, one engine)
-- ============================================================
-- Replicatesignal the SELECTED TrainingFrame.List button (the proven mechanism that
-- cracked meditation). Every exercise button is a sibling wired by the same server-side
-- HUDServer, so the one engine drives all of them. Pure training loop -- if you want to
-- be fed while training, just enable auto-eat too; they coexist. Meditate is the most tested.
Tabs.Survival:Section({ Title = "AUTO-TRAIN", Opened = true })

do
    local TRAIN_OPTIONS = {
        { label = "🧘 Meditate",          btn = "Meditate" },
        { label = "💪 Push-ups",           btn = "Pushups" },
        { label = "🦵 Sit-ups",            btn = "Situps" },
        { label = "🤸 Jumping Jacks",      btn = "JumpingJacks" },
        { label = "🏋 Dumbbell (100)",     btn = "Dumbell100" },
        { label = "🏋 Dumbbell (500)",     btn = "Dumbell500" },
        { label = "🔔 Swingbell (100)",    btn = "Swingbell100" },
        { label = "🔔 Swingbell (500)",    btn = "Swingbell500" },
        { label = "🥏 Weight Plate (100)", btn = "WeightPlate100" },
        { label = "🥏 Weight Plate (500)", btn = "WeightPlate500" },
    }
    local labels, labelToBtn, btnToLabel = {}, {}, {}
    for _, o in ipairs(TRAIN_OPTIONS) do
        labels[#labels + 1] = o.label
        labelToBtn[o.label] = o.btn
        btnToLabel[o.btn] = o.label
    end

    Tabs.Survival:Toggle({
        Title = "Enable auto-train",
        Desc  = "Auto-runs the selected exercise via replicatesignal. Honors F8 panic.",
        Value = S.autoMedOn or false,
        Callback = function(v) S.autoMedOn = v and true or false; saveConfig() end,
    })

    Tabs.Survival:Dropdown({
        Title = "Training",
        Desc  = "Which exercise to run. Switching restarts with the new one.",
        Values = labels,
        Value = btnToLabel[S.autoTrainPick or "Meditate"] or "🧘 Meditate",
        Multi = false,
        Callback = function(v)
            S.autoTrainPick = (type(v) == "string" and labelToBtn[v]) or "Meditate"
            saveConfig()
        end,
    })

    state.winduiParagraphs = state.winduiParagraphs or {}
    state.winduiParagraphs.autoMedStatus = Tabs.Survival:Paragraph({
        Title = "Status",
        Desc  = "idle",
    })

end



Tabs.Survival:Section({ Title = "AUTO-EAT", Opened = true })

Tabs.Survival:Toggle({
    Title = "Enable auto-eat",
    Value = S.autoEatOn,
    Callback = function(v) S.autoEatOn=v; saveConfig() end,
})

Tabs.Survival:Slider({
    Title = "Eat when Hunger <",
    Step = 1,
    Value = { Min = 10, Max = 90, Default = S.autoEatHungerThreshold },
    Callback = function(v) S.autoEatHungerThreshold=v; saveConfig() end,
})

-- Multi-select whitelist of foods to auto-eat (apples always allowed as safety fallback).
-- Values are merged: known catalog items + anything currently in inventory tagged as food by Food.isFood.
local FOOD_CATALOG = {
    "Apple", "Green Apple", "Red Apple", "Berry", "Grape", "Banana",
    "Bread", "White Bread", "Dark Bread", "Rice",
    "Cooked Fish", "Raw Fish", "Cooked Meat", "Raw Meat", "Steak",
    "Soup", "Stew", "Deer Stew", "Ration",
    "Tomato", "Potato", "Wheat", "Sugar", "Flour",
}
local function buildFoodValues()
    local seen, out = {}, {}
    for _, n in ipairs(FOOD_CATALOG) do
        if not seen[n] then seen[n] = true; out[#out+1] = n end
    end
    for _, it in ipairs(listInventory()) do
        local rn = it.realName
        if type(rn) == "string" and rn ~= "" and Food.isFood(rn) and not Food.isDrink(rn) and not seen[rn] then
            seen[rn] = true; out[#out+1] = rn
        end
    end
    table.sort(out)
    return out
end

Tabs.Survival:Dropdown({
    Title = "Foods to auto-eat",
    Desc = "Foods the auto-eat loop may consume. Empty = keyword fallback.",
    Values = buildFoodValues(),
    Value = S.autoEatFoodAllowList or {},
    Multi = true,
    AllowNone = true,
    Callback = function(sel)
        local list = {}
        if type(sel) == "table" then
            for k, v in pairs(sel) do
                if type(v) == "string" then list[#list+1] = v
                elseif type(k) == "string" and v then list[#list+1] = k end
            end
        elseif type(sel) == "string" and sel ~= "" then
            list[#list+1] = sel
        end
        S.autoEatFoodAllowList = list
        saveConfig()
    end,
})

Tabs.Survival:Section({ Title = "RUM", Opened = false })

do  -- drink-slot stepper (now labelled rum since this triggers on stamina)
    local rawSlot = Tabs.Survival:Section({ Title = "" })
    local parent = rawSlot.ElementFrame.Content
    local row=Instance.new("Frame",parent); row.Size=UDim2.new(1,0,0,30); row.BackgroundTransparency=1
    local lab=lbl(row,"",12,C.text,Enum.Font.Code); lab.Size=UDim2.new(0.58,0,1,0); lab.Position=UDim2.new(0,6,0,0)
    local function upd() lab.Text="Rum slot: "..(S.autoEatThirstSlot==0 and "auto" or tostring(S.autoEatThirstSlot)) end
    upd()
    local m=btn(row,"◀"); m.Size=UDim2.new(0,30,0,24); m.Position=UDim2.new(0.62,0,0.5,-12)
    local pl=btn(row,"▶"); pl.Size=UDim2.new(0,30,0,24); pl.Position=UDim2.new(0.82,0,0.5,-12)
    m.MouseButton1Click:Connect(function() S.autoEatThirstSlot=math.max(0,S.autoEatThirstSlot-1); upd(); saveConfig() end)
    pl.MouseButton1Click:Connect(function() S.autoEatThirstSlot=math.min(12,S.autoEatThirstSlot+1); upd(); saveConfig() end)
end

Tabs.Survival:Toggle({
    Title = "Enable auto-rum",
    Desc  = "Drinks rum whenever the Rum buff isn't active.",
    Value = S.autoRumOn,
    Callback = function(v) S.autoRumOn = v and true or false; saveConfig() end,
})

Tabs.Survival:Slider({
    Title = "Rum re-check interval (×10ms)",
    Step = 1,
    Value = { Min = 20, Max = 300, Default = math.floor((S.autoRumInterval or 1.0) * 100) },
    Callback = function(v) S.autoRumInterval = v / 100; saveConfig() end,
})

Tabs.Survival:Slider({
    Title = "Rum min cooldown (×10ms)",
    Step = 1,
    Value = { Min = 50, Max = 600, Default = math.floor((S.autoRumCooldown or 3.0) * 100) },
    Callback = function(v) S.autoRumCooldown = v / 100; saveConfig() end,
})

do  -- rum-slot stepper (independent of the stamina/thirst slot above)
    local rawSlot = Tabs.Survival:Section({ Title = "" })
    local parent = rawSlot.ElementFrame.Content
    local row=Instance.new("Frame",parent); row.Size=UDim2.new(1,0,0,30); row.BackgroundTransparency=1
    local lab=lbl(row,"",12,C.text,Enum.Font.Code); lab.Size=UDim2.new(0.58,0,1,0); lab.Position=UDim2.new(0,6,0,0)
    local function upd() lab.Text="Auto-rum slot: "..(S.autoRumSlot==0 and "auto" or tostring(S.autoRumSlot)) end
    upd()
    local m=btn(row,"◀"); m.Size=UDim2.new(0,30,0,24); m.Position=UDim2.new(0.62,0,0.5,-12)
    local pl=btn(row,"▶"); pl.Size=UDim2.new(0,30,0,24); pl.Position=UDim2.new(0.82,0,0.5,-12)
    m.MouseButton1Click:Connect(function() S.autoRumSlot=math.max(0,(S.autoRumSlot or 0)-1); upd(); saveConfig() end)
    pl.MouseButton1Click:Connect(function() S.autoRumSlot=math.min(12,(S.autoRumSlot or 0)+1); upd(); saveConfig() end)
end


-- ============================================================
-- AUTO-DELETE ITEMS (destructive; exact realName match, list-gated)
-- Mechanism confirmed from HudClient decompile + live comms probe:
--   ReplicatedStorage.comms.DeleteRequest:FireServer(<item uuid>)
-- where uuid == the inventory item instance's Name (== UI button ID.Value).
-- ============================================================
Tabs.Character:Section({ Title = "AUTO-DELETE ITEMS", Opened = false })

do  -- scope block: keep these locals out of the main-chunk 200-local ceiling
local autoDelInfoP

-- Fire the server delete for one item uuid. Resolves the remote at call time so
-- load order / re-parenting can't break it. Returns true if the FireServer landed.
local function fireDelete(uuid)
    if type(uuid) ~= "string" or uuid == "" then return false end
    local ok = pcall(function()
        local comms = game:GetService("ReplicatedStorage"):FindFirstChild("comms")
        local dr = comms and comms:FindFirstChild("DeleteRequest")
        if dr then dr:FireServer(uuid) end
    end)
    return ok
end

-- Lowercase set of chosen names for O(1) EXACT-match lookup (no substring footguns).
local function buildDeleteSet()
    local set = {}
    for _, n in ipairs(S.autoDeleteList or {}) do
        if type(n) == "string" and n ~= "" then set[n:lower()] = true end
    end
    return set
end

-- Safety: is this uuid currently bound to a hotbar slot? (don't nuke equipped gear)
local function isBoundUuid(uuid)
    for s = 1, 12 do
        if getBindUuid(s) == uuid then return true end
    end
    return false
end

-- Dropdown options = chosen names UNION current-inventory names (so chosen items
-- stay visible even after they're deleted / not currently held).
local function buildDeletableValues()
    local seen, out = {}, {}
    for _, n in ipairs(S.autoDeleteList or {}) do
        if type(n) == "string" and n ~= "" and not seen[n] then seen[n] = true; out[#out+1] = n end
    end
    for _, it in ipairs(listInventory()) do
        local rn = it.realName
        if type(rn) == "string" and rn ~= "" and not seen[rn] then seen[rn] = true; out[#out+1] = rn end
    end
    table.sort(out)
    return out
end

-- How many inventory entries / total items currently match the delete-list.
local function autoDeleteMatchCount()
    local set = buildDeleteSet()
    if not next(set) then return 0, 0 end
    local entries, total = 0, 0
    for _, it in ipairs(listInventory()) do
        if set[tostring(it.realName):lower()] then
            entries = entries + 1
            total = total + (tonumber(it.stack) or 1)
        end
    end
    return entries, total
end

-- One-shot sweep: delete every matching, non-bound item once. Yields between fires
-- (anti-kick), so callers MUST run this inside task.spawn. Returns count deleted.
local function deleteSweep()
    local set = buildDeleteSet()
    if not next(set) then return 0 end
    local deleted = 0
    for _, it in ipairs(listInventory()) do
        local rn = tostring(it.realName):lower()
        if set[rn] then
            if S.autoDeleteSkipBound and isBoundUuid(it.uuid) then
                pushLog("warn", "auto-delete: skipped bound item "..tostring(it.realName))
            elseif fireDelete(it.uuid) then
                deleted = deleted + 1
                task.wait(S.autoDeleteCooldown or 0.35)
            end
        end
    end
    return deleted
end

local function renderAutoDelete()
    if not autoDelInfoP then return end
    local list = S.autoDeleteList or {}
    local names = #list > 0 and table.concat(list, ", ") or "(none chosen)"
    local entries, total = autoDeleteMatchCount()
    autoDelInfoP:SetDesc(string.format(
        "Delete-list: %s\nMatching in inventory now: %d entr%s (%d item%s)%s",
        names, entries, entries == 1 and "y" or "ies",
        total, total == 1 and "" or "s",
        S.autoDeleteOn and "   [AUTO ON]" or ""))
end

-- NOTE: multi-select dropdown removed (too easy to fat-finger valuable items).
-- Every list change now requires typing the exact name.

Tabs.Character:Input({
    Title = "Add item to delete-list (exact name)",
    Value = "",
    Placeholder = "e.g. Cargo Crate, Oak Plank...",
    Callback = function(text)
        if not text or text == "" then return end
        local name = text:gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then return end
        S.autoDeleteList = S.autoDeleteList or {}
        for _, ex in ipairs(S.autoDeleteList) do
            if ex:lower() == name:lower() then pushLog("warn", "auto-delete: already listed "..name); return end
        end
        table.insert(S.autoDeleteList, name)
        saveConfig()
        renderAutoDelete()
        pushLog("good", "auto-delete: added "..name)
    end,
})

Tabs.Character:Input({
    Title = "Remove item from delete-list (exact name)",
    Value = "",
    Placeholder = "type the name to remove...",
    Callback = function(text)
        if not text or text == "" then return end
        local name = text:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if name == "" then return end
        local list, removed = S.autoDeleteList or {}, false
        for i = #list, 1, -1 do
            if tostring(list[i]):lower() == name then
                table.remove(list, i); removed = true
            end
        end
        S.autoDeleteList = list
        saveConfig()
        renderAutoDelete()
        pushLog(removed and "good" or "warn",
            removed and ("auto-delete: removed "..text) or ("auto-delete: not in list -- "..text))
    end,
})

Tabs.Character:Button({
    Title = "Clear delete-list",
    Desc = "Empties the auto-delete list. Continuous toggle stays on but does nothing until you re-add items.",
    Callback = function()
        S.autoDeleteList = {}
        saveConfig()
        renderAutoDelete()
        pushLog("info", "auto-delete: list cleared")
    end,
})

autoDelInfoP = Tabs.Character:Paragraph({ Title = "Delete status", Desc = "(none chosen)" })

Tabs.Character:Button({
    Title = "Delete matching now (once)",
    Desc = "Delete matching items once. Bound hotbar items skipped.",
    Callback = function()
        local set = buildDeleteSet()
        if not next(set) then pushLog("warn", "auto-delete: list is empty -- nothing to delete"); return end
        task.spawn(function()
            local n = deleteSweep()
            pushLog(n > 0 and "good" or "info", string.format("auto-delete: swept %d item(s)", n))
            renderAutoDelete()
        end)
    end,
})

Tabs.Character:Toggle({
    Title = "Auto-delete (continuous)",
    Desc = "DESTRUCTIVE. Auto-delete matching items. Empty list does nothing. Skips bound items & F8 panic.",
    Value = S.autoDeleteOn,
    Callback = function(v)
        S.autoDeleteOn = v
        saveConfig()
        renderAutoDelete()
        pushLog(v and "warn" or "info", v and "auto-delete: CONTINUOUS ON" or "auto-delete: off")
    end,
})

renderAutoDelete()

-- continuous loop: sweep matching items on a tick while enabled. Self-contained;
-- empty list short-circuits, F8 panic halts, bound items skipped.
task.spawn(function()
    while gui.Parent do
        if S.autoDeleteOn and not state.panic then
            local set = buildDeleteSet()
            if next(set) then
                for _, it in ipairs(listInventory()) do
                    if not (S.autoDeleteOn and gui.Parent and not state.panic) then break end
                    local rn = tostring(it.realName):lower()
                    if set[rn] and not (S.autoDeleteSkipBound and isBoundUuid(it.uuid)) then
                        fireDelete(it.uuid)
                        task.wait(S.autoDeleteCooldown or 0.35)
                    end
                end
                renderAutoDelete()
            end
        end
        task.wait(S.autoDeleteInterval or 1.0)
    end
end)
end  -- end auto-delete scope block

Tabs.Character:Section({ Title = "CURRENT HOTBAR", Opened = false })

-- Hotbar live-view box: kept as raw widget because the background loop at line 3811-3826
-- writes directly to hbList.Text every 0.4s. (loop at line ~3811 updates hbList.Text -- no change needed there since hbList is still a TextLabel)
do
    local rawSlot = Tabs.Character:Section({ Title = "" })
    local parent = rawSlot.ElementFrame.Content
    local hbBox=Instance.new("Frame",parent); hbBox.Size=UDim2.new(1,0,0,200); hbBox.BackgroundColor3=C.bg2; hbBox.BorderSizePixel=0; corner(hbBox,8); pad(hbBox,8)
    hbList=lbl(hbBox,"",10,C.textDim,Enum.Font.Code); hbList.Size=UDim2.new(1,0,1,0); hbList.TextYAlignment=Enum.TextYAlignment.Top
end

-- ============================================================
-- BOAT REPAIR
-- ============================================================
Tabs.Boat:Section({ Title = "BOAT REPAIR" })

Tabs.Boat:Toggle({
    Title = "Auto-repair boat",
    Value = S.autoRepairOn,
    Callback = function(v) S.autoRepairOn=v; saveConfig() end,
})

Tabs.Boat:Slider({
    Title = "Repair every (s)",
    Step = 1,
    Value = { Min = 2, Max = 30, Default = S.autoRepairInterval },
    Callback = function(v) S.autoRepairInterval=v; saveConfig() end,
})

Tabs.Boat:Toggle({
    Title = "Nail-stall fix (deletes 1-nail stacks!)",
    Desc = "DESTRUCTIVE: while repairing, deletes orphan 1/99 copper-nail stacks so repair can pull a full stack. Only fires if you still have a 2+ stack to fall back on.",
    Value = S.autoRepairNailFix,
    Callback = function(v) S.autoRepairNailFix=v; saveConfig() end,
})


-- ###### TAB: Boat Farm ######
-- ============================================================
-- BOAT FARM MODE — sea-encounter state machine (FARM -> GRIP -> LOOT -> REPAIR).
-- Drives the existing auto-farm hover/pick/swing when S.boatFarmOn, adds water
-- avoidance, a void-NPC blacklist, post-kill gripping, chest looting and repair.
-- ============================================================
Tabs.BoatFarm:Section({ Title = "BOAT FARM (sea encounters)", Opened = true })

Tabs.BoatFarm:Toggle({
    Title = "Enable boat farm",
    Desc = "Fights NPCs near boats, stays out of water, grips downed enemies, then loots/repairs when clear.",
    Value = S.boatFarmOn,
    Callback = function(v) S.boatFarmOn = v; saveConfig() end,
})

Tabs.BoatFarm:Section({ Title = "REPAIR" })

Tabs.BoatFarm:Toggle({
    Title = "Auto-repair when clear",
    Desc = "Repairs the hull once the encounter is fully cleared (won't fight and repair at once).",
    Value = S.boatFarmAutoRepair,
    Callback = function(v) S.boatFarmAutoRepair = v; saveConfig() end,
})

Tabs.BoatFarm:Toggle({
    Title = "Nail-stall fix (deletes 1-nail stacks!)",
    Desc = "DESTRUCTIVE: deletes orphan 1/99 copper-nail stacks so repair can use a full stack. Only fires if you still have a 2+ stack.",
    Value = S.boatFarmNailFixOn,
    Callback = function(v) S.boatFarmNailFixOn = v; saveConfig() end,
})

Tabs.BoatFarm:Section({ Title = "STATUS" })
state.winduiParagraphs = state.winduiParagraphs or {}
state.winduiParagraphs.boatFarmStatus = Tabs.BoatFarm:Paragraph({ Title = "Boat farm status", Desc = "off" })


-- ###### TAB: Haki ######
-- ============================================================
-- HAKI / WILL TRACKER (read-only). The Will score is computed server-side -- the in-game
-- stats tab only DISPLAYS it (HUD UpdateStatFrame has no input handler). This mirrors it
-- live, shows the GAIN RATE, and logs every gain with a timestamp so you can do an action
-- and instantly see whether (and how much) it trains Will. Path-agnostic (Armament/Observation).
-- NOTE: the stats values only exist after you've opened the in-game Stats page once.
-- ============================================================
do
    local Tab = Tabs.Survival
    Tab:Section({ Title = "ARMAMENT WILL TRACKER", Opened = false })
    state.winduiParagraphs = state.winduiParagraphs or {}
    state.winduiParagraphs.hakiTracker = Tab:Paragraph({ Title = "Haki / Will", Desc = "reading..." })
    state.hakiTrack = { baseScore = nil }

    Tab:Button({
        Title = "Reset session counter",
        Callback = function() state.hakiTrack.baseScore = nil; pushLog("info", "haki tracker: session re-baselined") end,
    })

    Tab:Paragraph({ Title = "How to use", Desc = "Open the in-game Stats page once so the values populate, then do an action (coat/swing/block). Every Will gain prints to the log with a timestamp -- that tells us what actually trains it." })

    local function statVal(name)
        local st = lp:FindFirstChild("Stats")
        local v = st and st:FindFirstChild(name)
        if not v then return nil end
        local ok, val = pcall(function() return v.Value end)
        if ok then return val end
        return nil
    end
    -- locate the active will score/time stats (works for Armament* OR Observation* paths)
    local function willStats()
        local st = lp:FindFirstChild("Stats"); if not st then return nil, nil end
        local sV, tV
        for _, c in ipairs(st:GetChildren()) do
            if c.Name:find("WindowStartScore", 1, true) then sV = c end
            if c.Name:find("WindowStartTime", 1, true)  then tV = c end
        end
        return sV, tV
    end

    task.spawn(function()
        while gui.Parent do
            local sV, tV = willStats()
            local score
            if sV then local ok, v = pcall(function() return sV.Value end); if ok and type(v) == "number" then score = v end end
            local now = os.clock()
            local t = state.hakiTrack
            if score then
                if type(t.baseScore) ~= "number" then
                    t.baseScore, t.baseClock, t.lastScore, t.lastClock, t.peak, t.lastLogged = score, now, score, now, 0, score
                end
                -- log every gain with a timestamp (so we can correlate it to what you just did)
                if score > (t.lastLogged or score) + 0.001 then
                    pushLog("good", string.format("⚔️ Will +%.2f (now %.1f)", score - (t.lastLogged or score), score))
                    t.lastLogged = score
                end
                local sessGain = score - t.baseScore
                local elapsed  = now - (t.baseClock or now)
                local avgRate  = elapsed > 0.5 and (sessGain / (elapsed / 60)) or 0
                local instRate = 0
                if t.lastClock and (now - t.lastClock) > 0.01 then
                    instRate = (score - (t.lastScore or score)) / ((now - t.lastClock) / 60)
                end
                if instRate > (t.peak or 0) then t.peak = instRate end
                t.lastScore, t.lastClock = score, now

                local will  = statVal("Will")
                local pot   = statVal("HakiPotential")
                local path  = statVal("HakiPath") or statVal("DeterminedHakiPath")
                local wtype = statVal("WillType")
                local pathName = (path == "A" and "Armament (A)") or (path == "O" and "Observation (O)") or tostring(path)
                local winAge
                if tV then
                    local okt, ut = pcall(os.time)
                    local okv, ws = pcall(function() return tV.Value end)
                    if okt and okv and type(ws) == "number" then winAge = ut - ws end
                end

                pcall(function() state.winduiParagraphs.hakiTracker:SetDesc(string.format(
                    "Path: %s\nWill lvl %s | Potential %s | %s\nScore: %.2f\nSession: +%.2f in %.0fs (avg %.1f/min, peak %.1f/min)%s",
                    pathName, tostring(will), tostring(pot), tostring(wtype),
                    score, sessGain, elapsed, avgRate, (t.peak or 0),
                    winAge and ("\nWindow age: " .. winAge .. "s") or "")) end)
            else
                pcall(function() state.winduiParagraphs.hakiTracker:SetDesc("no Will/Haki stats yet -- open the in-game Stats page once to populate them") end)
            end
            task.wait(1)
        end
    end)
end


-- ###### TAB: Movement ######
-- ============================================================
-- MOVEMENT TAB (WindUI migration)
-- ============================================================
Tabs.Movement:Section({ Title = "MOVEMENT" })

Tabs.Movement:Slider({
    Title = "Walk Speed",
    Step = 1,
    Value = { Min = 16, Max = 300, Default = S.walkSpeed },
    Callback = function(v) S.walkSpeed = v; saveConfig() end,
})

Tabs.Movement:Slider({
    Title = "Jump Power",
    Step = 1,
    Value = { Min = 50, Max = 500, Default = S.jumpPower },
    Callback = function(v) S.jumpPower = v; saveConfig() end,
})

local togNoclip = Tabs.Movement:Toggle({
    Title = "Noclip",
    Value = S.noClip,
    Callback = function(v) S.noClip = v; saveConfig() end,
})

local togTpDeath = Tabs.Movement:Toggle({
    Title = "TP back on death",
    Value = S.tpOnDeath,
    Callback = function(v) S.tpOnDeath = v; saveConfig() end,
})

Tabs.Movement:Section({ Title = "FLY" })

local togFly = Tabs.Movement:Toggle({
    Title = "Fly",
    Value = S.flyOn,
    Callback = function(v)
        S.flyOn = v
        if v then startFly() else stopFly() end
        saveConfig()
    end,
})

Tabs.Movement:Slider({
    Title = "Fly Speed",
    Step = 1,
    Value = { Min = 20, Max = 400, Default = S.flySpeed },
    Callback = function(v) S.flySpeed = v; saveConfig() end,
})

Tabs.Movement:Slider({
    Title = "TP glide speed",
    Step = 1,
    Value = { Min = 60, Max = 500, Default = S.tpGlideSpeed },
    Callback = function(v) S.tpGlideSpeed = v; saveConfig() end,
})

Tabs.Movement:Button({
    Title = "Stop TP",
    Callback = function()
        state.tpCancel = true
        local hum = getMyHum(); if hum then pcall(function() hum.PlatformStand = false end) end
        local hrp = getMyHRP(); if hrp then pcall(function() hrp.AssemblyLinearVelocity = Vector3.zero end) end
        pushLog("info", "🛑 TP stopped")
    end,
})

Tabs.Boat:Section({ Title = "TP TO BOAT" })

Tabs.Boat:Button({
    Title = "TP to my boat",
    Callback = function()
        local ok = tpToBoat()
        pushLog(ok and "good" or "warn", ok and "🚤 TP'd to boat" or "🚤 no boat found — spawn it first")
    end,
})

Tabs.Movement:Section({ Title = "REJOIN" })

-- Smart rejoin: passes the current gating stats (LastZone/lastIsland/etc) as
-- TeleportData so the destination server can read them via player:GetJoinData()
-- BEFORE its ProfileService stat mirror has replicated.  Bypasses Sea Piece's
-- "place is restricted" kick when the stats default-nil on join.
-- Also listens to TeleportInitFailed so we always see the actual Roblox error.
do
    -- cache ZoneMap once at boot; build reverse lookup placeId -> cell name
    local PLACE_TO_ZONE = {}
    do
        local ok, zm = pcall(function()
            return require(game:GetService("ReplicatedStorage"):FindFirstChild("ZoneMap"))
        end)
        if ok and type(zm) == "table" then
            for cell, info in pairs(zm) do
                if type(info) == "table" and info.PlaceId then
                    PLACE_TO_ZONE[info.PlaceId] = cell
                end
            end
        end
    end

    local function smartRejoin(sameServer)
        pushLog("info", "🔁 smartRejoin clicked (sameServer="..tostring(sameServer)..")")
        local ok, err = pcall(function()
            local TeleportService = game:GetService("TeleportService")
            local placeId = game.PlaceId
            local jobId = game.JobId
            -- Authoritative zone via ZoneMap (current PlaceId -> cell) -- matches what
            -- the data store actually has, immune to the Stats mirror being stale right
            -- after a teleport.  Falls back to live Stats.LastZone if the placeId isn't
            -- in ZoneMap (e.g. intro/lobby places).
            local statZone = getStat("LastZone")
            local mapZone  = PLACE_TO_ZONE[placeId]
            if mapZone and statZone and mapZone ~= statZone then
                pushLog("warn", string.format("🔁 stat mirror stale: ZoneMap=%s Stats.LastZone=%s -- using ZoneMap",
                    tostring(mapZone), tostring(statZone)))
            end
            -- No marker fields -- payload looks identical to a legit cross-zone teleport.
            local td = {
                LastZone           = mapZone or statZone,
                lastIsland         = getStat("lastIsland"),
                lastIslandZone     = getStat("lastIslandZone"),
                zoneChangeLocation = getStat("zoneChangeLocation"),
                currentPlace       = getStat("currentPlace"),
            }
            pushLog("info", string.format("🔁 placeId=%d (zone=%s) jobId=%s island=%s",
                placeId, tostring(td.LastZone), tostring(jobId), tostring(td.lastIsland)))

            -- one-shot failure listener (auto-disconnects)
            local conn
            conn = TeleportService.TeleportInitFailed:Connect(function(player, result, errMsg)
                if player == lp then
                    pushLog("bad", string.format("🔁 TeleportInitFailed: result=%s err=%s",
                        tostring(result), tostring(errMsg)))
                    if conn then conn:Disconnect(); conn = nil end
                end
            end)
            table.insert(_G.ENI_HELPER.connections, conn)

            -- Roblox engine rejects client-initiated teleports without a "token".
            -- The token is implicit: it depends on caller thread identity.
            -- LocalScripts run at identity 2; CoreScript (vanilla rejoin button) runs at 7-8.
            -- Wave's UNC exposes setthreadidentity -- we elevate, call, restore.
            local oldId
            if getthreadidentity and setthreadidentity then
                local okGet, id = pcall(getthreadidentity)
                if okGet then oldId = id end
                pcall(setthreadidentity, 8)
                pushLog("info", "🔁 thread identity -> 8 (CoreScript)")
            else
                pushLog("warn", "🔁 setthreadidentity unavailable -- trying anyway")
            end

            pcall(function() TeleportService:SetTeleportSetting("ENI_REJOIN_DATA", td) end)

            local tpOk, tpErr = pcall(function()
                if sameServer and jobId and jobId ~= "" then
                    pushLog("info", "🔁 calling TeleportToPlaceInstance(same job)")
                    TeleportService:TeleportToPlaceInstance(placeId, jobId, lp)
                else
                    pushLog("info", "🔁 calling Teleport(random instance)")
                    TeleportService:Teleport(placeId, lp)
                end
            end)

            -- restore identity ASAP so unrelated calls don't run elevated
            if oldId and setthreadidentity then pcall(setthreadidentity, oldId) end

            if tpOk then
                pushLog("info", "🔁 teleport call dispatched -- waiting for server response")
            else
                pushLog("bad", "🔁 teleport call THREW: "..tostring(tpErr))
            end
        end)
        if not ok then
            pushLog("bad", "🔁 smartRejoin THREW: "..tostring(err))
        end
    end

    Tabs.Movement:Button({
        Title = "Same server",
        Callback = function() smartRejoin(true) end,
    })
    Tabs.Movement:Button({
        Title = "New server",
        Callback = function() smartRejoin(false) end,
    })
end

-- ============================================================
-- AUTO-SAIL : route cell-to-cell to a destination via the live ZoneMap (BFS), driving the
-- boat through its OWN VehicleSeat input (Engine.Throttle/Steer) -- the server reads that
-- as our input and propels the boat itself at NATURAL speed (server-validated, no anti-cheat
-- reset, works tabbed-out). Voyage state lives in its own marker file so it survives each
-- boundary crossing via the hub's auto-reload. Self-calibrates fwd/steer signs + the N/S axis.
-- ============================================================
Tabs.Boat:Section({ Title = "AUTO-SAIL" })
do
    local RunService = game:GetService("RunService")
    local Http = game:GetService("HttpService")
    local VOYAGE_FILE = "eni_sailer_voyage.json"

    local voyage = { active = false, dest = nil, zN = -1, fwd = 1, steerSign = 1, prevCell = nil, intendedDir = nil }
    do
        local okf, raw = pcall(function()
            if readfile and isfile and isfile(VOYAGE_FILE) then return readfile(VOYAGE_FILE) end
            return nil
        end)
        if okf and type(raw) == "string" and #raw > 0 then
            local okd, t = pcall(function() return Http:JSONDecode(raw) end)
            if okd and type(t) == "table" then for k, v in pairs(t) do voyage[k] = v end end
        end
    end
    local function saveVoyage() pcall(function() if writefile then writefile(VOYAGE_FILE, Http:JSONEncode(voyage)) end end) end

    -- live ZoneMap
    local ZM
    do
        local ok, zm = pcall(function() return require(game:GetService("ReplicatedStorage"):WaitForChild("ZoneMap", 5)) end)
        if ok and type(zm) == "table" then ZM = zm end
    end
    local DIRS = { "NORTH", "SOUTH", "EAST", "WEST" }
    local function cellOf(pid)
        if not ZM then return nil end
        for c, i in pairs(ZM) do if type(i) == "table" and i.PlaceId == pid then return c end end
        return nil
    end
    local function route(a, b)
        if not (ZM and a and b) then return nil end
        if a == b then return {} end
        local q = { a }; local seen = { [a] = true }; local cf, cd = {}, {}; local h = 1
        while h <= #q do
            local c = q[h]; h = h + 1; local n = ZM[c]
            if type(n) == "table" then
                for _, d in ipairs(DIRS) do
                    local nb = n[d]
                    if type(nb) == "string" and not seen[nb] then
                        seen[nb] = true; cf[nb] = c; cd[nb] = d
                        if nb == b then
                            local p = {}; local cur = b
                            while cur ~= a do table.insert(p, 1, { dir = cd[cur], cell = cur }); cur = cf[cur] end
                            return p
                        end
                        q[#q + 1] = nb
                    end
                end
            end
        end
        return nil
    end
    local function worldDir(cp)
        if cp == "WEST" then return Vector3.new(-1, 0, 0)
        elseif cp == "EAST" then return Vector3.new(1, 0, 0)
        elseif cp == "NORTH" then return Vector3.new(0, 0, voyage.zN)
        elseif cp == "SOUTH" then return Vector3.new(0, 0, -voyage.zN) end
        return nil
    end

    local function findBoat()
        local b = Workspace:FindFirstChild("Boats")
        local m = b and b:FindFirstChild(lp.Name)
        if m and m:IsA("Model") then return m end
        return nil
    end
    local function engineOf(b)
        if not (b and b.Parent) then return nil end
        local e = b:FindFirstChild("Engine")
        if e and e:IsA("VehicleSeat") then return e end
        return b:FindFirstChildWhichIsA("VehicleSeat", true)
    end
    local function rootOf(b)
        if not (b and b.Parent) then return nil end
        return b.PrimaryPart or b:FindFirstChild("ShipRoot") or b:FindFirstChildWhichIsA("BasePart", true)
    end
    local function seated()
        local ch = lp.Character; local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        return hum and hum.SeatPart ~= nil
    end

    local legDir, arrived = nil, false
    local function planLeg()
        local cur = cellOf(game.PlaceId)
        if not cur then legDir = nil; return end
        -- learn the N/S world axis: if last place we aimed N/S but didn't land on the
        -- expected neighbor, our zN sign was flipped.
        if voyage.prevCell and voyage.intendedDir and ZM and ZM[voyage.prevCell] then
            local expected = ZM[voyage.prevCell][voyage.intendedDir]
            if expected and expected ~= cur and (voyage.intendedDir == "NORTH" or voyage.intendedDir == "SOUTH") then
                voyage.zN = -voyage.zN; saveVoyage()
            end
        end
        if not voyage.dest then legDir = nil; return end
        if cur == voyage.dest then
            arrived = true; legDir = nil
            voyage.active = false; voyage.prevCell = nil; voyage.intendedDir = nil; saveVoyage()
            pushLog("good", "⛵ auto-sail: ARRIVED at " .. tostring(cur)); return
        end
        local p = route(cur, voyage.dest)
        if p and #p > 0 then
            legDir = p[1].dir; voyage.prevCell = cur; voyage.intendedDir = legDir; saveVoyage()
        else
            legDir = nil; pushLog("warn", "⛵ auto-sail: no route " .. tostring(cur) .. " -> " .. tostring(voyage.dest))
        end
    end

    -- drive loop (Heartbeat): set the seat's throttle/steer toward the leg's world direction
    if _G.__eniSailerConn then pcall(function() _G.__eniSailerConn:Disconnect() end) end
    local lastErr, errTimer, signLockUntil = nil, 0, 0
    _G.__eniSailerConn = RunService.Heartbeat:Connect(function(dt)
        if not voyage.active or arrived or not legDir or state.panic then return end
        local boat = findBoat(); local eng = engineOf(boat); local root = rootOf(boat)
        if not (eng and root and seated()) then return end
        local desired = worldDir(legDir); if not desired then return end
        local lv = root.CFrame.LookVector; local look = Vector3.new(lv.X, 0, lv.Z)
        if look.Magnitude < 1e-3 then return end; look = look.Unit
        -- forward-sign detect: only on a CLEAR sustained reverse (>8 st/s opposing), so a
        -- swaying hull at low speed can't keep flipping the throttle.
        local vel = root.AssemblyLinearVelocity; local fv = Vector3.new(vel.X, 0, vel.Z)
        if fv.Magnitude > 8 and look:Dot(fv.Unit) * voyage.fwd < -0.6 then voyage.fwd = -voyage.fwd; saveVoyage() end
        local fdir = look * voyage.fwd
        local crossY = fdir.X * desired.Z - fdir.Z * desired.X
        local dotF = fdir.X * desired.X + fdir.Z * desired.Z
        local ang = math.atan2(crossY, dotF)   -- signed heading error (radians)
        -- proportional steer with a DEADZONE: within ~8deg, hold rudder centered so the
        -- boat's wave-sway doesn't make it hunt left/right. Gentle gain + low clamp = smooth.
        local steer = 0
        if math.abs(ang) > 0.14 then
            steer = math.clamp(ang * 0.8, -0.6, 0.6) * voyage.steerSign
        end
        -- sign self-correct (handles this boat's swapped A/D): ONLY while actively steering
        -- hard; if heading error GREW over a 2s window the rudder is inverted -> flip once,
        -- then lock 3s so it can't thrash. Resets when centered (deadzone), so no per-frame flip.
        errTimer = errTimer + dt
        if math.abs(steer) > 0.3 then
            if lastErr == nil then lastErr = math.abs(ang); errTimer = 0 end
            if errTimer >= 2.0 then
                if os.clock() > signLockUntil and math.abs(ang) > lastErr + 0.20 then
                    voyage.steerSign = -voyage.steerSign; saveVoyage()
                    signLockUntil = os.clock() + 3.0
                end
                lastErr = math.abs(ang); errTimer = 0
            end
        else
            lastErr = nil; errTimer = 0
        end
        pcall(function()
            eng.SteerFloat = steer
            eng.Steer = (steer > 0.15 and 1) or (steer < -0.15 and -1) or 0
            eng.ThrottleFloat = voyage.fwd; eng.Throttle = (voyage.fwd > 0) and 1 or -1
        end)
    end)
    if _G.ENI_HELPER and _G.ENI_HELPER.connections then table.insert(_G.ENI_HELPER.connections, _G.__eniSailerConn) end

    -- UI
    local destBox = tostring(voyage.dest or (cellOf(game.PlaceId) or "G9"))
    Tabs.Boat:Input({
        Title = "Destination cell",
        Value = destBox,
        Placeholder = "e.g. G9",
        Callback = function(t) if type(t) == "string" then destBox = t end end,
    })

    local function startSail()
        local d = tostring(destBox or ""):upper():gsub("%s", "")
        if not (ZM and ZM[d]) then pushLog("bad", "⛵ unknown cell '" .. d .. "'"); return end
        voyage.active = true; voyage.dest = d; voyage.prevCell = nil; voyage.intendedDir = nil; arrived = false
        saveVoyage(); planLeg()
        pushLog("info", "⛵ auto-sail -> " .. d)
    end
    local function stopSail()
        voyage.active = false; arrived = false; legDir = nil; saveVoyage()
        local e = engineOf(findBoat())
        if e then pcall(function() e.ThrottleFloat = 0; e.Throttle = 0; e.SteerFloat = 0; e.Steer = 0 end) end
        pushLog("info", "⛵ auto-sail stopped")
    end
    _G.boat_sailer_stop = stopSail

    Tabs.Boat:Button({ Title = "Sail to destination", Callback = startSail })
    Tabs.Boat:Button({ Title = "Stop sailing", Callback = stopSail })

    -- expose to other UI sections (e.g. Movement-tab cell-grid buttons) so they can
    -- trigger auto-sail to a named cell without duplicating the routing logic.
    _G.ENI_AUTO_SAIL = {
        sailTo = function(cell)
            if not (ZM and ZM[cell]) then pushLog("bad", "⛵ unknown cell '" .. tostring(cell) .. "'"); return end
            destBox = cell
            voyage.active = true; voyage.dest = cell; voyage.prevCell = nil; voyage.intendedDir = nil; arrived = false
            saveVoyage(); planLeg()
            pushLog("info", "⛵ auto-sail -> " .. cell)
        end,
        stop = stopSail,
    }

    local sailPara = Tabs.Boat:Paragraph({ Title = "Auto-sail status", Desc = "idle" })
    state.winduiParagraphs = state.winduiParagraphs or {}
    state.winduiParagraphs.autoSail = sailPara

    task.spawn(function()
        local prevPos, prevT = nil, os.clock()
        while gui.Parent do
            local cur = ZM and cellOf(game.PlaceId) or "?"
            local boat = findBoat(); local root = rootOf(boat); local spd = 0
            if root then
                local now = os.clock(); local p = root.Position
                if prevPos and now > prevT then spd = (p - prevPos).Magnitude / (now - prevT) end
                prevPos, prevT = p, now
            end
            local desc
            if arrived or (voyage.active and voyage.dest and cur == voyage.dest) then
                desc = string.format("✓ ARRIVED at %s", tostring(cur))
            elseif voyage.active then
                local legs = voyage.dest and (function() local r = route(cur, voyage.dest); return r and #r or "?" end)() or "?"
                desc = string.format("SAILING %s -> %s | next %s | legs %s | %.0f st/s%s%s",
                    tostring(cur), tostring(voyage.dest), tostring(legDir or "?"), tostring(legs), spd,
                    seated() and "" or " | ⚠SIT", boat and "" or " | ⚠no boat")
            else
                desc = string.format("idle (in %s)", tostring(cur))
            end
            pcall(function() sailPara:SetDesc(desc .. string.format(" | cal f%d s%d z%d", voyage.fwd, voyage.steerSign, voyage.zN)) end)
            task.wait(0.3)
        end
    end)

    -- resume a voyage left in progress (the hub auto-reloads in each place after a crossing)
    if voyage.active and voyage.dest then
        planLeg(); pushLog("info", "⛵ auto-sail resumed -> " .. tostring(voyage.dest))
    end
end

Tabs.Movement:Section({ Title = "SAVED SPOTS", Opened = false })

Tabs.Movement:Button({
    Title = "Save current spot",
    Callback = function()
        local ok, err = pcall(function()
            local h = getMyHRP()
            if not h then pushLog("bad", "save spot: no HumanoidRootPart (dead or still loading?)"); return end
            if type(S.savedSpots) ~= "table" then S.savedSpots = {} end
            local n = "Spot "..(#S.savedSpots + 1)
            -- check if at known POI to use that name
            for model, e in pairs(entityCache) do
                if not e.isPlayer and e.hrp and e.hrp.Parent then
                    local okd, d = pcall(function() return (e.hrp.Position - h.Position).Magnitude end)
                    if okd and d < 15 then n = "Near "..model.Name; break end
                end
            end
            local p = h.Position
            table.insert(S.savedSpots, {name = n, pos = {p.X, p.Y, p.Z}})
            pushLog("good", string.format("saved %s @ (%.0f,%.0f,%.0f) [%d total]", n, p.X, p.Y, p.Z, #S.savedSpots))
            saveConfig()
            renderSavedSpots()
        end)
        if not ok then pushLog("bad", "save spot FAILED: "..tostring(err)) end
    end,
})

-- Saved spots dynamic list (raw frame parented to a spacer section's Frame)
local spotsSlot = Tabs.Movement:Section({ Title = "" })
local spotsBox = Instance.new("Frame")
spotsBox.Size = UDim2.new(1, 0, 0, 0)
spotsBox.AutomaticSize = Enum.AutomaticSize.Y
spotsBox.BackgroundTransparency = 1
spotsBox.Parent = spotsSlot.ElementFrame.Content
local spotsLayout = Instance.new("UIListLayout", spotsBox); spotsLayout.Padding = UDim.new(0, 4)

function renderSavedSpots()
    for _, c in ipairs(spotsBox:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    if type(S.savedSpots) ~= "table" then S.savedSpots = {} end
    for idx, spot in ipairs(S.savedSpots) do
        -- defensive: a legacy/corrupt entry (missing or short pos) must NOT throw
        -- inside string.format -- that error would kill the WHOLE render and make
        -- the list silently never appear (the real "save spot doesn't work" bug).
        local pos = (type(spot) == "table") and spot.pos or nil
        local x = (type(pos) == "table" and tonumber(pos[1])) or 0
        local y = (type(pos) == "table" and tonumber(pos[2])) or 0
        local z = (type(pos) == "table" and tonumber(pos[3])) or 0
        local nm = (type(spot) == "table" and spot.name ~= nil) and tostring(spot.name) or ("Spot " .. idx)
        local okRow, errRow = pcall(function()
            local row = Instance.new("Frame", spotsBox); row.Size = UDim2.new(1, 0, 0, 28); row.BackgroundColor3 = C.bg2; row.BorderSizePixel = 0; corner(row, 6)
            local nl = lbl(row, nm, 11, C.text, Enum.Font.GothamMedium); nl.Position = UDim2.new(0, 8, 0, 0); nl.Size = UDim2.new(0.45, 0, 1, 0)
            local pl = lbl(row, string.format("(%.0f,%.0f,%.0f)", x, y, z), 9, C.textMute, Enum.Font.Code)
            pl.Position = UDim2.new(0.4, 0, 0, 0); pl.Size = UDim2.new(0.35, 0, 1, 0)
            local gb = btn(row, "GO"); gb.Position = UDim2.new(1, -78, 0.5, -9); gb.Size = UDim2.new(0, 34, 0, 18)
            local xb = btn(row, "X"); xb.Position = UDim2.new(1, -40, 0.5, -9); xb.Size = UDim2.new(0, 28, 0, 18); xb.BackgroundColor3 = Color3.fromRGB(80, 30, 45)
            gb.MouseButton1Click:Connect(function() goToSpot(Vector3.new(x, y, z)) end)
            xb.MouseButton1Click:Connect(function() table.remove(S.savedSpots, idx); saveConfig(); renderSavedSpots() end)
        end)
        if not okRow then pushLog("bad", "render spot " .. idx .. " failed: " .. tostring(errRow)) end
    end
end
renderSavedSpots()

Tabs.Movement:Section({ Title = "QUICK TP" })

Tabs.Movement:Button({
    Title = "TP to nearest player",
    Callback = function()
        local myHrp = getMyHRP(); if not myHrp then return end
        local best, bestD = nil, math.huge
        for model, e in pairs(entityCache) do
            if e.isPlayer and e.player ~= lp and e.hrp and e.hrp.Parent then
                local d = (e.hrp.Position - myHrp.Position).Magnitude
                if d < bestD then bestD = d; best = e end
            end
        end
        if best then tpTo(best.hrp.Position + Vector3.new(0, 0, 3)); pushLog("good", "TP to "..best.name) end
    end,
})

Tabs.Movement:Button({
    Title = "TP to mouse cursor",
    Callback = function()
        local m = lp:GetMouse(); if m.Hit then tpTo(m.Hit.Position) end
    end,
})

-- permanent G9 / Monago Island farm spot (this place = PlaceId 92602684048559)
Tabs.Movement:Button({
    Title = "TP: G9 Monago (farm)",
    Callback = function()
        pushLog("info", "🏝 gliding to G9 Monago...")
        tpTo(Vector3.new(-922.66, 25.41, 790.80))
        pushLog("good", "🏝 arrived at G9 Monago")
    end,
})

-- ============================================================
-- POI section -- belongs on Move (Movement) tab, not ESP. It's nearest-NPC location
-- intel for travel decisions, not entity rendering. Re-routed to Tabs.Movement.
-- ============================================================
Tabs.Movement:Section({ Title = "POI", Opened = true })

-- POI info paragraph (updated by renderPOIs loop)
-- // renderPOIs() updates this paragraph via
-- // state.winduiParagraphs.poiInfo:SetDesc(...)
state.winduiParagraphs = state.winduiParagraphs or {}
state.winduiParagraphs.poiInfo = Tabs.Movement:Paragraph({
    Title = "POI info",
    Desc = "scanning...",
})

Tabs.Movement:Button({
    Title = "Rescan",
    Callback = function() refreshPOIs(); renderPOIs() end,
})

-- POI dynamic list container (raw frame parented to a spacer section's Frame)
local poiSlot = Tabs.Movement:Section({ Title = "" })
local poiContainer = Instance.new("Frame")
poiContainer.Size = UDim2.new(1, 0, 0, 0)
poiContainer.AutomaticSize = Enum.AutomaticSize.Y
poiContainer.BackgroundTransparency = 1
poiContainer.Parent = poiSlot.ElementFrame.Content
local poiLayout = Instance.new("UIListLayout", poiContainer); poiLayout.Padding = UDim.new(0, 4)

local poiData = {}; local poiRows = {}
function refreshPOIs()
    poiData = {}
    local myHrp = getMyHRP()
    for model, e in pairs(entityCache) do
        if not e.isPlayer and model.Parent then
            -- e.hrp can be nil/destroyed (entity cached before it had a part, or its HRP
            -- removed on death/stream-out) -- re-resolve, then guard before .Position so a
            -- single partless entity can't throw "index nil with 'Position'" and kill POIs.
            if not e.hrp or not e.hrp.Parent then
                e.hrp = model:FindFirstChild("HumanoidRootPart")
                    or model:FindFirstChild("Torso")
                    or model:FindFirstChildWhichIsA("BasePart")
            end
            local name = model.Name
            if not poiData[name] then poiData[name] = {count = 0, closest = math.huge, instances = {}} end
            poiData[name].count = poiData[name].count + 1
            table.insert(poiData[name].instances, e)
            if myHrp and e.hrp then
                local d = (e.hrp.Position - myHrp.Position).Magnitude
                if d < poiData[name].closest then poiData[name].closest = d end
            end
        end
    end
end
function renderPOIs()
    local sorted = {}
    for name, d in pairs(poiData) do table.insert(sorted, {name = name, data = d}) end
    table.sort(sorted, function(a, b) return a.data.closest < b.data.closest end)
    -- prune rows for entries that no longer exist OR whose children are missing (defensive)
    for k, row in pairs(poiRows) do
        if not poiData[k] or not row.Parent or not row:FindFirstChild("N") or not row:FindFirstChild("D") then
            pcall(function() row:Destroy() end)
            poiRows[k] = nil
        end
    end
    for i, item in ipairs(sorted) do
        local row = poiRows[item.name]
        if not row then
            row = Instance.new("Frame", poiContainer); row.Size = UDim2.new(1, 0, 0, 32); row.BackgroundColor3 = C.bg2; row.BorderSizePixel = 0; corner(row, 6)
            local n = lbl(row, "", 11, C.text, Enum.Font.GothamMedium); n.Position = UDim2.new(0, 8, 0, 2); n.Size = UDim2.new(0.55, 0, 0, 15); n.Name = "N"
            local d = lbl(row, "", 9, C.textDim, Enum.Font.Code); d.Position = UDim2.new(0, 8, 0, 16); d.Size = UDim2.new(0.55, 0, 0, 12); d.Name = "D"
            local tpb = btn(row, "TP"); tpb.Position = UDim2.new(1, -48, 0.5, -10); tpb.Size = UDim2.new(0, 42, 0, 20)
            poiRows[item.name] = row
            tpb.MouseButton1Click:Connect(function()
                local data = poiData[item.name]; if not data then return end
                local best, bestD = nil, math.huge; local myHrp = getMyHRP(); if not myHrp then return end
                for _, e in ipairs(data.instances) do
                    if e.hrp and e.hrp.Parent then
                        local dd = (e.hrp.Position - myHrp.Position).Magnitude
                        if dd < bestD then bestD = dd; best = e end
                    end
                end
                if best and tpTo(best.hrp.Position + Vector3.new(0, 0, 3)) then pushLog("good", "TP to "..item.name) end
            end)
        end
        row.LayoutOrder = i
        -- defensive lookups -- a child could've been GC'd if WindUI's tab content reset
        local nLbl = row:FindFirstChild("N")
        local dLbl = row:FindFirstChild("D")
        if nLbl then nLbl.Text = item.name.." ("..item.data.count..")" end
        if dLbl then dLbl.Text = (item.data.closest == math.huge) and "—" or (math.floor(item.data.closest).." studs") end
    end
    if state.winduiParagraphs and state.winduiParagraphs.poiInfo then
        state.winduiParagraphs.poiInfo:SetDesc(#sorted.." NPC types in cache")
    end
end


-- ###### TAB: ESP ######
-- ============================================================
-- ESP TAB (WindUI)
-- ============================================================

Tabs.Intel:Section({ Title = "TOGGLES", Opened = true })

local tEspOn = Tabs.Intel:Toggle({
    Title = "Enable ESP",
    Value = S.espOn,
    Callback = function(v) S.espOn=v; saveConfig() end,
})

local tEspPlayers = Tabs.Intel:Toggle({
    Title = "Show players",
    Value = S.espPlayers,
    Callback = function(v) S.espPlayers=v; saveConfig() end,
})

local tEspNpcs = Tabs.Intel:Toggle({
    Title = "Show NPCs",
    Value = S.espNpcs,
    Callback = function(v) S.espNpcs=v; saveConfig() end,
})

local tEspOre = Tabs.Intel:Toggle({
    Title = "Show ore / minerals",
    Value = S.espOre,
    Callback = function(v) S.espOre=v; saveConfig() end,
})

local tEspPrompts = Tabs.Intel:Toggle({
    Title = "Show prompts",
    Value = S.espPrompts,
    Callback = function(v) S.espPrompts=v; saveConfig() end,
})

local tEspShowDistance = Tabs.Intel:Toggle({
    Title = "Show distance",
    Value = S.espShowDistance,
    Callback = function(v) S.espShowDistance=v; saveConfig() end,
})

local tEspShowHealth = Tabs.Intel:Toggle({
    Title = "Show health",
    Value = S.espShowHealth,
    Callback = function(v) S.espShowHealth=v; saveConfig() end,
})

Tabs.Intel:Section({ Title = "NPC NAME FILTER" })

-- Custom block: NPC filter textbox (raw Instance.new, re-parented to a spacer-section's Frame)
local rawFilterSlot = Tabs.Intel:Section({ Title = "" })
local filterParent = rawFilterSlot.ElementFrame.Content
local filterRow=Instance.new("Frame",filterParent); filterRow.Size=UDim2.new(1,0,0,30); filterRow.BackgroundTransparency=1
local filterBox=Instance.new("TextBox",filterRow); filterBox.Size=UDim2.new(1,0,1,0); filterBox.BackgroundColor3=C.bg3; filterBox.BorderSizePixel=0
filterBox.PlaceholderText="NPC name contains..."; filterBox.PlaceholderColor3=C.textMute; filterBox.Text=S.espNpcFilter
filterBox.TextColor3=C.text; filterBox.Font=Enum.Font.Code; filterBox.TextSize=11; filterBox.ClearTextOnFocus=false
corner(filterBox,6); pad(filterBox,8)
filterBox:GetPropertyChangedSignal("Text"):Connect(function() S.espNpcFilter=filterBox.Text; saveConfig() end)

Tabs.Intel:Section({ Title = "PERFORMANCE" })

local sEspMaxDistance = Tabs.Intel:Slider({
    Title = "Max distance (studs)",
    Value = { Min = 500, Max = 50000, Default = S.espMaxDistance },
    Step = 1,
    Callback = function(v) S.espMaxDistance=v; saveConfig() end,
})

-- Update interval is stored as seconds (e.g. 0.5); slider operates in ×10ms units (20..200 == 0.20..2.00s)
local sEspUpdateInterval = Tabs.Intel:Slider({
    Title = "Update interval (×10ms)",
    Value = { Min = 20, Max = 200, Default = math.floor(S.espUpdateInterval*100) },
    Step = 1,
    Callback = function(v) S.espUpdateInterval=v/100; saveConfig() end,
})



-- ###### TAB: Settings ######
-- ============================================================
-- SETTINGS TAB (WindUI migration)
-- state.winduiParagraphs bridge: background loops call :SetDesc() on these
-- Ensure state.winduiParagraphs = state.winduiParagraphs or {} is initialized once before this block.
-- ============================================================
state.winduiParagraphs = state.winduiParagraphs or {}

-- ---------- ITEM SEARCH ----------
Tabs.Character:Section({ Title = "ITEM SEARCH", Opened = true })
do  -- live inventory counter: type a name, see total stacks + sum (fills the cut Inventory tab)
    local searchTerm = ""
    Tabs.Character:Input({
        Title = "Item name contains",
        Value = "",
        Placeholder = "item name contains... (e.g. copper)",
        Callback = function(value) searchTerm = value or "" end,
    })
    local resultP = Tabs.Character:Paragraph({ Title = "Item Search Results", Desc = "type an item name above" })
    state.winduiParagraphs.itemSearchResult = resultP
    -- background loop (was @ line 2292): updates resultP via :SetDesc() every 0.5s
    task.spawn(function()
        while gui.Parent do
            local term = searchTerm:lower()
            if term ~= "" then
                local stacks, total = 0, 0
                for _, it in ipairs(listInventory()) do
                    if tostring(it.realName):lower():find(term, 1, true) then
                        stacks = stacks + 1; total = total + (it.stack or 1)
                    end
                end
                pcall(function() resultP:SetDesc(string.format("'%s' -> %d stack(s), %d total", term, stacks, total)) end)
            else
                pcall(function() resultP:SetDesc("type an item name above") end)
            end
            task.wait(0.5)
        end
    end)
end

-- ---------- INVENTORY ORGANIZER ----------
-- Sorts the inventory UI alphabetically by realName via LayoutOrder.  Stack sizes in
-- this game are tiny so the same item piles into many slots; A-Z sort groups them.
-- Cosmetic only: server-side inventory ordering is untouched.
Tabs.Character:Section({ Title = "INVENTORY ORGANIZER" })
do
    -- find the InventoryFrame.List frame that holds the InventoryButton clones
    local function findInvList()
        local pg = lp:WaitForChild("PlayerGui", 2)
        if not pg then return nil end
        -- HudClient creates HUD > ... > InventoryFrame > List
        local hud = pg:FindFirstChild("HUD")
        if not hud then return nil end
        local invFrame = hud:FindFirstChild("InventoryFrame", true)
        if not invFrame then return nil end
        return invFrame:FindFirstChild("List", true) or invFrame
    end

    -- read display name from an InventoryButton (its realName StringValue child)
    local function nameOf(btn)
        local rn = btn:FindFirstChild("realName")
        if rn and rn.Value and rn.Value ~= "" then return tostring(rn.Value) end
        return tostring(btn.Name)
    end

    -- sort children of `list` alphabetically by realName via LayoutOrder
    local function sortNow()
        local list = findInvList()
        if not list then pushLog("warn", "📦 inventory list frame not found"); return 0 end
        local items = {}
        for _, c in ipairs(list:GetChildren()) do
            if c:IsA("GuiObject") then items[#items+1] = c end
        end
        table.sort(items, function(a, b) return nameOf(a):lower() < nameOf(b):lower() end)
        for i, c in ipairs(items) do
            -- LayoutOrder takes precedence in UIGridLayout/UIListLayout SortOrder=LayoutOrder.
            -- If the layout uses SortOrder=Name, we'd need to rename children -- but most
            -- Roblox inventory grids use LayoutOrder so this should "just work".
            pcall(function() c.LayoutOrder = i end)
        end
        -- ensure the layout actually respects LayoutOrder
        for _, layout in ipairs(list:GetChildren()) do
            if layout:IsA("UIGridLayout") or layout:IsA("UIListLayout") then
                pcall(function() layout.SortOrder = Enum.SortOrder.LayoutOrder end)
            end
        end
        return #items
    end

    Tabs.Character:Button({
        Title = "Sort inventory A-Z",
        Desc = "Sort inventory UI alphabetically.",
        Callback = function()
            local n = sortNow()
            pushLog("good", string.format("📦 sorted %d inventory item(s) A-Z", n or 0))
        end,
    })

    -- optional auto-sort: re-fire whenever a new item appears or any item changes
    local autoConn
    Tabs.Character:Toggle({
        Title = "Auto-sort on inventory change",
        Desc = "Re-sort on any inventory change (slight perf cost).",
        Value = S.autoInvSort or false,
        Callback = function(v)
            S.autoInvSort = v
            saveConfig()
            if autoConn then autoConn:Disconnect(); autoConn = nil end
            if v then
                local list = findInvList()
                if not list then pushLog("warn", "📦 auto-sort: no inv list yet -- will retry on next manual sort"); return end
                -- debounce so 5 simultaneous adds don't trigger 5 sorts
                local pending = false
                local function scheduleSort()
                    if pending then return end
                    pending = true
                    task.delay(0.25, function()
                        pending = false
                        sortNow()
                    end)
                end
                autoConn = list.ChildAdded:Connect(scheduleSort)
                -- ChildRemoved too (sort still useful when stacks shrink)
                local removed = list.ChildRemoved:Connect(scheduleSort)
                -- bundle both connections so toggling off cleans up
                local bundle = autoConn
                autoConn = { Disconnect = function() pcall(function() bundle:Disconnect() end); pcall(function() removed:Disconnect() end) end }
                pushLog("good", "📦 auto-sort armed")
                sortNow()  -- initial pass
            else
                pushLog("info", "📦 auto-sort disarmed")
            end
        end,
    })
end

-- ---------- STATS ----------
Tabs.Survival:Section({ Title = "YOUR STATS", Opened = true })
do  -- live character stats (incl. HakiPotential) — fills the cut Home tab
    local statsP = Tabs.Survival:Paragraph({ Title = "Character Stats", Desc = "loading stats..." })
    state.winduiParagraphs.charStats = statsP
    local SHOW = {"Strength","Durability","Dexterity","Stamina","Will","HakiPotential","HakiPath","Beli","Bounty","Respect"}
    local function fmt(n)
        if type(n) ~= "number" then return tostring(n) end
        if n >= 1e6 then return string.format("%.2fM", n/1e6) end
        if n >= 1e3 then return string.format("%.1fk", n/1e3) end
        return tostring(math.floor(n*10)/10)
    end
    task.spawn(function()
        while gui.Parent do
            local lines, seen = {}, {}
            -- faction auto-detect: marines carry Stats.Respect, pirates carry Stats.Bounty
            local fac = (getStat("Respect") ~= nil) and "Marine" or (getStat("Bounty") ~= nil and "Pirate" or "?")
            lines[#lines+1] = string.format("%-16s %s", "Faction", fac)
            for _, sn in ipairs(SHOW) do
                if not seen[sn] then
                    seen[sn] = true
                    local v = getStat(sn)
                    if v ~= nil then lines[#lines+1] = string.format("%-16s %s", sn, fmt(v)) end
                end
            end
            pcall(function() statsP:SetDesc(#lines > 0 and table.concat(lines, "\n") or "no Stats folder found") end)
            task.wait(1)
        end
    end)
end

-- ---------- PLAYER LOOKUP ----------
Tabs.Character:Section({ Title = "PLAYER LOOKUP" })
do
    -- Other players' Stats folders are replicated by default in most Roblox games.
    -- We just walk Players:GetPlayers(), pick one, and read p.Stats children.
    -- Auto-refreshes the player list when people join/leave; stats refresh @ 1s.
    local SHOW_OTHER = {"PirateName","Strength","Durability","Dexterity","Stamina",
                        "HakiPotential","HakiPath","WillType","Will","FightStyle",
                        "Race","Profession","Bounty","Respect","Beli","Crew","Family",
                        "LastZone","lastIsland","InCombat"}
    local fmtN = function(n)
        if type(n) ~= "number" then return tostring(n) end
        if n >= 1e6 then return string.format("%.2fM", n/1e6) end
        if n >= 1e3 then return string.format("%.1fk", n/1e3) end
        return tostring(math.floor(n*10)/10)
    end

    -- player picker: case-insensitive substring match against player names
    local query = ""
    Tabs.Character:Input({
        Title = "Player name",
        Value = "",
        Placeholder = "player name (substring, blank = list all)",
        Callback = function(value) query = value or "" end,
    })

    local outP = Tabs.Character:Paragraph({ Title = "Player Lookup Results", Desc = "looking up..." })
    state.winduiParagraphs.playerLookup = outP

    -- read a single stat value from any player's Stats folder
    local function readStat(plr, name)
        local s = plr:FindFirstChild("Stats"); if not s then return nil end
        local v = s:FindFirstChild(name); if not v then return nil end
        local ok, val = pcall(function() return v.Value end)
        return ok and val or nil
    end

    task.spawn(function()
        while gui.Parent do
            local q = query:lower()
            local matches = {}
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= lp then
                    if q == "" or p.Name:lower():find(q, 1, true) or (p.DisplayName or ""):lower():find(q, 1, true) then
                        matches[#matches+1] = p
                    end
                end
            end
            local lines = {}
            if #matches == 0 then
                lines[#lines+1] = q == "" and "(no other players in server)" or "(no match for '"..q.."')"
            elseif #matches == 1 then
                -- single match: full stat dump
                local p = matches[1]
                lines[#lines+1] = string.format("== %s (@%s) ==", p.DisplayName or p.Name, p.Name)
                local stats = p:FindFirstChild("Stats")
                if not stats then
                    lines[#lines+1] = "(no Stats folder visible -- might be hidden by game)"
                else
                    for _, sn in ipairs(SHOW_OTHER) do
                        local v = readStat(p, sn)
                        if v ~= nil then lines[#lines+1] = string.format("%-16s %s", sn, fmtN(v)) end
                    end
                end
            else
                -- multiple matches: compact one-line-per-player summary
                lines[#lines+1] = string.format("== %d players (refine query for full stats) ==", #matches)
                for _, p in ipairs(matches) do
                    local str = readStat(p, "Strength")
                    local bty = readStat(p, "Bounty")
                    local rsp = readStat(p, "Respect")
                    local rep = (bty ~= nil) and bty or rsp          -- pirate=Bounty, marine=Respect
                    local repLbl = (bty == nil and rsp ~= nil) and "RSP" or "BTY"
                    local crw = readStat(p, "Crew")
                    local zn  = readStat(p, "LastZone")
                    lines[#lines+1] = string.format("%-14s  STR %s  %s %s  %s  %s",
                        p.Name:sub(1,14), fmtN(str or "?"), repLbl, fmtN(rep or "?"),
                        tostring(crw or "—"):sub(1,12), tostring(zn or "?"))
                end
            end
            pcall(function() outP:SetDesc(table.concat(lines, "\n")) end)
            task.wait(1)
        end
    end)
end

-- ---------- PERSISTENCE (primary, open) ----------
-- PILOT of the captured-section pattern: children created THROUGH the section
-- object (sec:Button) instead of flat on the tab (Tabs.Settings:Button), so the
-- section's Opened flag actually collapses them. If this nests + collapses on
-- reload, the same refactor rolls out to all 9 tabs.
local secConfig = Tabs.Settings:Section({ Title = "Config", Icon = "cog", Opened = true })
secConfig:Button({
    Title = "Save config now",
    Callback = function()
        saveConfig(); pushLog("good","config saved")
    end,
})
secConfig:Button({
    Title = "Reset to defaults",
    Desc = "Reset all settings to defaults (including saved spots, watchdog, filters).",
    Callback = function()
        for k, v in pairs(DEFAULTS) do
            if type(v) == "table" then S[k] = {}; for kk, vv in pairs(v) do S[k][kk] = vv end
            else S[k] = v end
        end
        saveConfig(); pushLog("warn","config reset")
    end,
})

-- ---------- HOTKEYS (collapsed) ----------
local secHotkeys = Tabs.Settings:Section({ Title = "Hotkeys", Opened = true })
secHotkeys:Paragraph({
    Title = "Hotkeys",
    Desc = string.format("  Hide GUI: %s\n  Panic: %s", S.keyHideGui, S.keyPanic),
})

-- (settings Debug section removed)



-- ============================================================
-- MINIMAP  (north-up, NESW compass, rotating facing arrow, landmark scanner)
-- ============================================================
-- MINIMAP  (north-up, NESW compass, rotating facing arrow, landmark scanner)
-- Sibling of root inside the same ScreenGui so the existing teardown sweeps it
-- on reload. Render loop is in MAP RENDER section near the other ESP loops.
-- A separate spawn task scans Workspace for top-level Folders/Models every 3s
-- and computes their XZ bounding box -- those render as land-colored rectangles.
-- ============================================================
local mapFrame = Instance.new("Frame", gui)
mapFrame.Name = "Map"
mapFrame.AnchorPoint = Vector2.new(0.5, 0.5)
mapFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
mapFrame.Size = UDim2.fromOffset(S.mapSize, S.mapSize)
mapFrame.BackgroundColor3 = Color3.fromRGB(28, 60, 100)    -- water blue
mapFrame.BackgroundTransparency = 0.15
mapFrame.BorderSizePixel = 0
mapFrame.ClipsDescendants = true                          -- so landmark rects don't bleed outside
mapFrame.Visible = false
mapFrame.ZIndex = 50
corner(mapFrame, 10)
do
    local s = Instance.new("UIStroke", mapFrame)
    s.Color = Color3.fromRGB(80, 110, 140); s.Thickness = 1; s.Transparency = 0.2
end
-- crosshair guides
do
    local h = Instance.new("Frame", mapFrame); h.BackgroundColor3 = Color3.fromRGB(70,95,120)
    h.BackgroundTransparency = 0.65; h.BorderSizePixel = 0; h.ZIndex = 51
    h.AnchorPoint = Vector2.new(0.5, 0.5); h.Position = UDim2.new(0.5,0,0.5,0)
    h.Size = UDim2.new(1, -10, 0, 1)
    local v = h:Clone(); v.Size = UDim2.new(0, 1, 1, -10); v.Parent = mapFrame
end
-- NESW compass labels (north-up convention: +Z = north, top of map)
local function compassLbl(text, ax, ay, px, py)
    local l = Instance.new("TextLabel", mapFrame)
    l.AnchorPoint = Vector2.new(ax, ay)
    l.Position = UDim2.new(px, 0, py, 0)
    l.Size = UDim2.fromOffset(18, 14)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = Color3.fromRGB(220, 235, 255)
    l.TextStrokeTransparency = 0.2; l.TextStrokeColor3 = Color3.new(0,0,0)
    l.TextSize = 12
    l.Font = Enum.Font.GothamBold
    l.ZIndex = 56
end
-- Standard compass: N up, E right. The projection math negates Sea Piece's flipped
-- world axes (+X=game-west, +Z=game-south) so the rendered map matches these labels.
compassLbl("N", 0.5, 0,   0.5, 0)    -- top center
compassLbl("S", 0.5, 1,   0.5, 1)    -- bottom center
compassLbl("E", 1,   0.5, 1,   0.5)  -- right center
compassLbl("W", 0,   0.5, 0,   0.5)  -- left center
-- zone label (big, just below N) -- pulled from Stats.LastZone each frame
local mapZoneLbl = Instance.new("TextLabel", mapFrame)
mapZoneLbl.Size = UDim2.new(1, -10, 0, 18)
mapZoneLbl.Position = UDim2.new(0, 5, 0, 14)
mapZoneLbl.BackgroundTransparency = 1
mapZoneLbl.TextColor3 = Color3.fromRGB(255, 230, 130)
mapZoneLbl.TextStrokeTransparency = 0.2; mapZoneLbl.TextStrokeColor3 = Color3.new(0,0,0)
mapZoneLbl.TextSize = 16
mapZoneLbl.Font = Enum.Font.GothamBold
mapZoneLbl.TextXAlignment = Enum.TextXAlignment.Center
mapZoneLbl.Text = "--"
mapZoneLbl.ZIndex = 53
-- range / coord label (small, below zone)
local mapRangeLbl = Instance.new("TextLabel", mapFrame)
mapRangeLbl.Size = UDim2.new(1, -10, 0, 12)
mapRangeLbl.Position = UDim2.new(0, 5, 0, 32)
mapRangeLbl.BackgroundTransparency = 1
mapRangeLbl.TextColor3 = Color3.fromRGB(190, 210, 230)
mapRangeLbl.TextSize = 9
mapRangeLbl.Font = Enum.Font.Code
mapRangeLbl.TextXAlignment = Enum.TextXAlignment.Center
mapRangeLbl.ZIndex = 53
-- center player arrow (Rotation updates each frame to match LookVector)
local mapArrow = Instance.new("TextLabel", mapFrame)
mapArrow.AnchorPoint = Vector2.new(0.5, 0.5)
mapArrow.Position = UDim2.new(0.5, 0, 0.5, 0)
mapArrow.Size = UDim2.fromOffset(26, 26)
mapArrow.BackgroundTransparency = 1
mapArrow.Text = "▲"
mapArrow.TextColor3 = Color3.fromRGB(140, 255, 170)
mapArrow.TextStrokeTransparency = 0.25
mapArrow.TextStrokeColor3 = Color3.new(0,0,0)
mapArrow.TextSize = 24
mapArrow.Font = Enum.Font.GothamBold
mapArrow.ZIndex = 60
-- runtime: dot pool for entities, rect pool for landmarks, landmark cache
state.map = { dots = {}, rects = {}, landmarks = {}, frame = mapFrame }


-- ============================================================
-- WATCHDOG LOGIC  (player-flag scanner + kick fire)
-- ============================================================
-- (Test/Reset watchdog UI buttons live in the Combat WindUI chunk above; only
--  the firing logic + player scan are kept here.)

-- watchdog execution
watchdogFire = function(player, matchedName)
    pushLog("info", string.format("🚨 watchdogFire called  player=%s  match=%s  alreadyFired=%s  action=%s",
        tostring(player and player.Name), tostring(matchedName),
        tostring(state.watchdog and state.watchdog.fired), tostring(S.watchdogAction)))
    if state.watchdog and state.watchdog.fired then
        pushLog("warn", "🚨 watchdog one-shot already fired this session -- skipping")
        return
    end
    state.watchdog = {fired=true, at=os.time(), who=player.Name}

    pushLog("bad", "🚨 WATCHDOG: "..player.Name.." ("..tostring(player.DisplayName or "?")..") joined — flagged as '"..tostring(matchedName).."'")

    -- emergency stop EVERYTHING server-visible immediately, so the flagged player / dev
    -- sees nothing fishy in the moment before we bail (fly, TP-farm, boat, speed, noclip).
    pushLog("bad","🚨 watchdog killing autofarm")
    S.autoFarmOn = false
    S.autoMineOn = false
    S.autoRepairOn = false
    S.autoEatOn = false
    S.boatFarmOn = false
    S.autoClashOn = false
    S.noClip = false
    S.walkSpeed = 16            -- drop back to legit speed
    pcall(stopFly)              -- tear down fly BodyVelocity + PlatformStand right now

    -- write a flag file so chat-side can see what happened
    if writefile then
        pcall(function()
            writefile("eni_watchdog_event.json", HttpService:JSONEncode({
                ts = os.time(), placeId = game.PlaceId, jobId = game.JobId,
                trigger = matchedName, player = player.Name, displayName = player.DisplayName,
                action = S.watchdogAction,
            }))
        end)
    end

    task.wait(0.3)

    -- Modern Roblox blocks LocalScript-initiated TeleportService calls (token error),
    -- so the old "hop" path would show a "place is restricted" popup before our 4s kick
    -- fallback fired.  Both action modes now just self-Kick immediately -- cleaner UX,
    -- no popup, instant exit.  You manually rejoin from the Roblox menu after.
    pushLog("info","🚨 kicking self (LocalPlayer:Kick)")
    local reason = (S.watchdogAction == "leave" and "Solo-farm: " or "Watchdog: ") ..
                   "tripped on " .. tostring(matchedName)
    pcall(function() lp:Kick(reason) end)
end

checkPlayerAgainstFlags = function(player)
    if not S.watchdogOn then
        pushLog("info", "🚨 check "..player.Name..": skip (watchdog OFF)"); return
    end
    if player == lp then return end
    -- whitelist short-circuit: never fire on a friend/self-alt (case-insensitive exact match
    -- on both username AND DisplayName so display-name-only friends still skip).
    if S.watchdogWhitelist and #S.watchdogWhitelist > 0 then
        local un = player.Name:lower()
        local dn = (player.DisplayName or ""):lower()
        for _, wl in ipairs(S.watchdogWhitelist) do
            local w = wl:lower()
            if un == w or dn == w then
                pushLog("info","🚨 check "..player.Name..": whitelisted ("..wl..")"); return
            end
        end
    end
    -- solo-farm short-circuit: any non-self joiner fires the watchdog
    if S.watchdogAnyPlayer then
        pushLog("info","🚨 check "..player.Name..": ANY-mode -> fire")
        watchdogFire(player, "ANY"); return
    end
    if not S.watchdogTriggers or #S.watchdogTriggers == 0 then
        pushLog("info","🚨 check "..player.Name..": no triggers list"); return
    end
    local uname = player.Name:lower()
    local dname = (player.DisplayName or ""):lower()
    for _, trig in ipairs(S.watchdogTriggers) do
        local t = trig:lower()
        if uname == t or dname == t or uname:find(t, 1, true) or dname:find(t, 1, true) then
            watchdogFire(player, trig)
            return
        end
    end
end

-- scan current players
for _, p in ipairs(Players:GetPlayers()) do
    checkPlayerAgainstFlags(p)
end
-- listen for new joins
table.insert(_G.ENI_HELPER.connections, Players.PlayerAdded:Connect(checkPlayerAgainstFlags))


-- ============================================================
-- ANTI-AFK (IY-grade): a simulated keypress often does NOT reset the engine idle timer, so we use
-- VirtualUser input (CaptureController + ClickButton2) which the engine counts as REAL activity,
-- and -- if the executor exposes getconnections -- we also disconnect Roblox's own Idled idle-kick
-- handler at the source so the kick can't fire at all. Respects the S.antiAfk toggle.
-- ============================================================
do
    local VirtualUser = game:GetService("VirtualUser")
    -- PRIMARY: kill Roblox's existing Idled handlers (the idle-kicker) before we add ours.
    pcall(function()
        if getconnections and S.antiAfk then
            for _, c in ipairs(getconnections(lp.Idled)) do
                if c.Disable then c:Disable() elseif c.Disconnect then c:Disconnect() end
            end
        end
    end)
    -- RELIABLE PULSE: real simulated input on Idled (resets the engine idle timer). Belt-and-
    -- suspenders with the disconnect above; this one honors the toggle dynamically.
    table.insert(_G.ENI_HELPER.connections, lp.Idled:Connect(function()
        if S.antiAfk and not state.panic then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
            pushLog("info", "anti-afk pulse")
        end
    end))
end

-- (AUTO-CRAFT + AUTO-SMELT loops removed)

-- ============================================================
-- AUTO-REPAIR LOOP — equip the Repair Hammer + native Tool.Activate near the hull on a timer.
-- Tool.Activated replicates to the server with no remote and no mouse target (works tabbed out).
-- ============================================================
-- Copper-nail "1/99 stall" fix (shared by auto-repair AND boat-farm repair). Repair needs 2 nails
-- and the server consumes from a specific stack -- if that stack hits 1 it can never repair. No
-- merge remote exists, so we DELETE orphan 1-count nail stacks (only when a >=2 stack remains as a
-- fallback -- never your last nails) via comms.DeleteRequest. Throttled to once / 5s. The CALLER
-- gates it (S.autoRepairNailFix for auto-repair, S.boatFarmNailFixOn for boat farm).
function state.doNailFix()
    if (os.clock() - (state.nailFixLast or 0)) < 5 then return end
    state.nailFixLast = os.clock()
    local nails = {}
    for _, it in ipairs(listInventory()) do
        local rn = (it.realName or ""):lower()
        if rn:find("copper", 1, true) and rn:find("nail", 1, true) then nails[#nails + 1] = it end
    end
    local hasFull = false
    for _, it in ipairs(nails) do if (it.stack or 1) >= 2 then hasFull = true; break end end
    if not hasFull then return end   -- never delete our last nails
    local comms = game:GetService("ReplicatedStorage"):FindFirstChild("comms")
    local dr = comms and comms:FindFirstChild("DeleteRequest")
    if not dr then return end
    for _, it in ipairs(nails) do
        if (it.stack or 1) == 1 then
            pcall(function() dr:FireServer(it.uuid) end)
            pushLog("info", "🔩 nail-fix: deleted orphan 1-nail stack")
            task.wait(0.2)
        end
    end
end

task.spawn(function()
    local function boatRoot()
        local boat = currentBoat()
        if not boat then return nil end
        return boat:FindFirstChild("ShipRoot") or boat:FindFirstChildWhichIsA("BasePart", true)
    end
    -- hull HP: <currentBoat>.Engine.ShipConfig.Health (.Value/.MaxValue) with a descendant
    -- fallback. Returns (cur,max), (cur,nil) if max unknown, or nil if unreadable.
    local function getHullHP()
        local boat = currentBoat()
        if not boat then return nil end
        local eng = boat:FindFirstChild("Engine")
        local cfg = eng and eng:FindFirstChild("ShipConfig")
        local h = cfg and (cfg:FindFirstChild("Health") or cfg:FindFirstChild("HullHealth"))
        if not h then
            for _, d in ipairs(boat:GetDescendants()) do
                if (d.Name == "Health" or d.Name == "HullHealth") and d:IsA("ValueBase") then h = d; break end
            end
        end
        if not h then return nil end
        local okc, cur = pcall(function() return h.Value end)
        if not okc or type(cur) ~= "number" then return nil end
        local okm, mx = pcall(function() return h.MaxValue end)
        if okm and type(mx) == "number" and mx > 0 then return cur, mx end
        return cur, nil
    end
    local function isRepairHammer(rn) return rn:lower():find("repair", 1, true) ~= nil end
    -- equip Repair Hammer + native Activate (replicates tabbed-out, no remote/mouse). Goes
    -- through the shared equipAndActivate mutex so it never collides with auto-eat/rum.
    local function swingIfNear()
        local hrp, root = getMyHRP(), boatRoot()
        if not (hrp and root and (hrp.Position - root.Position).Magnitude < 150) then return end
        local ok, err = equipAndActivate(isRepairHammer, 1)
        if ok then
            state.repairErrLogged = nil
        elseif err ~= "pipe busy" and (not state.repairErrLogged or (os.clock() - state.repairErrLogged) > 10) then
            state.repairErrLogged = os.clock()
            pushLog("warn", "🔧 repair failed: " .. tostring(err))
        end
    end
    while gui.Parent do
        if S.autoRepairOn and not state.panic then
            local cur, max = getHullHP()
            if cur and max then
                if cur < max * 0.99 then
                    -- DAMAGED: preempt auto-train (state.repairNeeded), swing fast until full.
                    state.repairNeeded = true
                    if S.autoRepairNailFix then state.doNailFix() end
                    swingIfNear()
                    task.wait(0.6)
                else
                    -- FULL: drop the hammer (only if we'd been repairing) so hands are free for
                    -- auto-train, then idle on the slow timer. Never holds the hammer at full.
                    if state.repairNeeded then
                        local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
                        if hum then pcall(function() hum:UnequipTools() end) end
                    end
                    state.repairNeeded = false
                    task.wait(S.autoRepairInterval)
                end
            else
                -- hull HP unreadable: safety slow-repair (so it can't sink) but DON'T preempt
                -- training -- and warn once so we know to point getHullHP at the right value.
                state.repairNeeded = false
                if not state.repairHpWarned then
                    state.repairHpWarned = true
                    pushLog("warn", "🔧 can't read hull HP -- slow-repair fallback (tell me the Health path)")
                end
                swingIfNear()
                task.wait(S.autoRepairInterval)
            end
        else
            state.repairNeeded = false
            task.wait(1)
        end
    end
end)

-- ============================================================
-- BOAT FARM helpers — bundled into ONE main-chunk local (BF) to respect Luau's
-- 200-local-per-function ceiling. The auto-farm loop below calls into these when
-- S.boatFarmOn: water avoidance, boat-proximity targeting, grip, loot, repair.
-- ============================================================
-- BF is hoisted to chunk scope earlier (so AUTO-LOOT callbacks can see it).  Methods
-- below attach to the SAME table; don't redeclare local BF = {} here (would shadow).
do
    -- WATER: replicate the player's OWN swim trigger (mined from ClientCore:926-941).
    -- waterY = -1 + WaveMath.GetHeight(pos, serverTime, WaveConfig.Current); you are IN water
    -- when feetY <= waterY-1. require is pcall'd; if WaveMath is missing, water-avoid no-ops safely.
    local WaveMath, WaveConfig
    pcall(function()
        local rs = game:GetService("ReplicatedStorage")
        local wm = rs:FindFirstChild("WaveMath")   or rs:FindFirstChild("WaveMath", true)
        local wc = rs:FindFirstChild("WaveConfig") or rs:FindFirstChild("WaveConfig", true)
        if wm then WaveMath   = require(wm) end
        if wc then WaveConfig = require(wc) end
    end)
    function BF.waterY(pos)
        if not (WaveMath and WaveConfig and pos) then return nil end
        local ok, y = pcall(function()
            return -1 + WaveMath.GetHeight(pos, workspace:GetServerTimeNow(), WaveConfig.Current)
        end)
        if ok and type(y) == "number" then return y end
        return nil
    end
    function BF.isInWater()
        local hrp, hum = getMyHRP(), getMyHum()
        if not (hrp and hum) then return false end
        local wy = BF.waterY(hrp.Position)
        if not wy then return false end
        return (hrp.Position.Y - (hum.HipHeight or 2)) <= wy - 1
    end

    -- BOAT ROOTS: every boat's ShipRoot (ours + enemies') for proximity targeting.
    function BF.boatRoots()
        local roots = {}
        local boats = Workspace:FindFirstChild("Boats")
        if boats then
            for _, b in ipairs(boats:GetChildren()) do
                local r = b:FindFirstChild("ShipRoot") or b:FindFirstChildWhichIsA("BasePart", true)
                if r then roots[#roots+1] = r end
            end
        end
        return roots
    end
    function BF.nearBoat(hrp, roots, radius)
        if not (hrp and roots and #roots > 0) then return true end   -- empty table is truthy; #roots>0 needed (#6)
        radius = radius or 120
        for _, r in ipairs(roots) do
            if r.Parent and (hrp.Position - r.Position).Magnitude <= radius then return true end
        end
        return false
    end

    -- HULL HP (boat we're on) — mirrors the auto-repair loop's reader (uses currentBoat()).
    function BF.hullHP()
        local boat = currentBoat()
        if not boat then return nil end
        local eng = boat:FindFirstChild("Engine")
        local cfg = eng and eng:FindFirstChild("ShipConfig")
        local h = cfg and (cfg:FindFirstChild("Health") or cfg:FindFirstChild("HullHealth"))
        if not h then
            for _, d in ipairs(boat:GetDescendants()) do
                if (d.Name == "Health" or d.Name == "HullHealth") and d:IsA("ValueBase") then h = d; break end
            end
        end
        if not h then return nil end
        local okc, cur = pcall(function() return h.Value end)
        if not okc or type(cur) ~= "number" then return nil end
        local okm, mx = pcall(function() return h.MaxValue end)
        if okm and type(mx) == "number" and mx > 0 then return cur, mx end
        return cur, nil
    end

    -- GRIP: glide to the nearest ragdolled NPC in range and fire the Grip remote when close.
    -- Returns true while a grip target exists (encounter NOT yet clear).
    function BF.grip()
        if not S.boatFarmGripAfterKills then return false end
        local hrp = getMyHRP(); if not hrp then return false end
        state.boatFarm = state.boatFarm or {}
        local best, bestD
        for model, e in pairs(entityCache) do
            if not e.isPlayer and model.Parent and e.hrp and e.hrp.Parent then
                local cfg = model:FindFirstChild("Config")
                local rag = cfg and cfg:FindFirstChild("Ragdolled")
                if rag and rag.Value == true and e.hrp.Position.Y > (S.boatFarmVoidY or -300) then
                    local d = (e.hrp.Position - hrp.Position).Magnitude
                    if d <= (S.boatFarmGripRange or 30) and (not bestD or d < bestD) then best, bestD = e, d end
                end
            end
        end
        if not best then return false end
        state.farm.targetHrp = best.hrp                 -- reuse the hover Heartbeat to close in
        state.farm.target    = best.name or "?"
        if bestD <= 8 and not state.boatFarm.gripBusy
           and (os.clock() - (state.boatFarm.lastGrip or 0)) > 0.6 then
            state.boatFarm.gripBusy = true
            pcall(function()
                lp.Character.ClientCore["Server.cc"].comms.remotes.Grip:InvokeServer()
            end)
            state.boatFarm.lastGrip = os.clock()
            state.boatFarm.gripBusy = false
        end
        return true
    end

    -- LOOT (experimental): scan ENEMY boats (not ours) for chest models in range and pull
    -- keyword items via MoveContainerItem. Scoped to workspace.Boats so it's cheap + auto-skips
    -- our own boat (boat.Name ~= lp.Name). Exact contentsView/Move args are needs-live-test.
    -- AUTO-LOOT crates & barrels. This mirrors the game's OWN HUD container code exactly
    -- (HUD_client_extracted.lua): openable containers are Models under <boat>/PlacedStructures
    -- whose realName is a Cargo Crate / Wooden Barrel. (Chests are PICKUP-only -- press-Y
    -- PickUpStructure -- NOT openable, so they're excluded here, per how the game gates them.)
    --   OPEN  : comms.contentsView:InvokeServer(ownerName, structName)   -- ownerName = struct.Parent.Parent.Name
    --   ITEMS : children of LocalPlayer.PlayerGui.OpenStructureClone, each with .ID / .realName / .Amount
    --   TAKE  : comms.MoveContainerItem:InvokeServer("ToInventory", item.ID.Value, nil)  -- nil = whole stack
    -- opts: {verbose=true => log every step incl. skips; ignoreGate=true => bypass cooldown + toggle}
    function BF.loot(opts)
        opts = opts or {}
        local V = opts.verbose
        local function vlog(kind, msg) if V then pushLog(kind, "[loot] " .. msg) end end
        if not opts.ignoreGate and not S.boatFarmLootChests then return end
        state.boatFarm = state.boatFarm or {}
        if not opts.ignoreGate and (os.clock() - (state.boatFarm.lastLoot or 0)) < 1.5 then return end
        state.boatFarm.lastLoot = os.clock()
        local hrp = getMyHRP(); if not hrp then vlog("warn", "no HRP"); return end
        local comms = game:GetService("ReplicatedStorage"):FindFirstChild("comms")
        local cv = comms and comms:FindFirstChild("contentsView")
        local mv = comms and comms:FindFirstChild("MoveContainerItem")
        if not (cv and mv) then vlog("warn", "missing remotes (cv/mv)"); return end
        local pg = lp:FindFirstChild("PlayerGui"); if not pg then vlog("warn", "no PlayerGui"); return end
        local boats = Workspace:FindFirstChild("Boats"); if not boats then vlog("warn", "no workspace.Boats"); return end
        local kw     = (S.boatFarmLootKeyword or ""):lower()
        local radius = S.boatFarmLootRadius or 90
        vlog("info", string.format("scan start radius=%d kw=%q boats=%d", radius, kw, #boats:GetChildren()))

        -- (1) collect nearby openable containers (crate/barrel/cargo) on any non-own boat
        local targets, stats = {}, { scanned=0, container=0, ownBoat=0, ownerSkip=0, noPrim=0, outRange=0 }
        local function consider(struct)
            stats.scanned = stats.scanned + 1
            local nm = struct.Name:lower()
            local rnObj = struct:FindFirstChild("realName")
            local rnv = (rnObj and tostring(rnObj.Value):lower()) or nm
            local hay = nm .. " " .. rnv
            local isContainer = hay:find("crate", 1, true) or hay:find("barrel", 1, true)
                or hay:find("cargo", 1, true)
            if not isContainer then return end
            if hay:find("cannon", 1, true) or hay:find("chest", 1, true) then return end
            stats.container = stats.container + 1
            local prim = struct.PrimaryPart or struct:FindFirstChildWhichIsA("BasePart")
            if not prim then stats.noPrim = stats.noPrim + 1; vlog("warn", "no PrimaryPart on "..struct.Name); return end
            local d = (prim.Position - hrp.Position).Magnitude
            if d > radius then stats.outRange = stats.outRange + 1; return end
            local ps = struct.Parent
            local owner = ps and ps.Parent
            if not owner then stats.ownerSkip = stats.ownerSkip + 1; return end
            -- Own-boat skip is opt-out; default lets you loot your own ship's crates after a farm cycle.
            if owner.Name == lp.Name and not S.boatFarmLootOwnBoat then
                stats.ownBoat = stats.ownBoat + 1; return
            end
            targets[#targets + 1] = { struct = struct, prim = prim, owner = owner.Name, dist = d }
        end
        for _, boat in ipairs(boats:GetChildren()) do
            if boat.Name ~= lp.Name then
                local psf = boat:FindFirstChild("PlacedStructures", true)
                if psf then
                    for _, s in ipairs(psf:GetChildren()) do
                        if s:IsA("Model") then consider(s) end
                    end
                end
            end
        end
        vlog("info", string.format("scanned=%d containers=%d targets=%d (ownBoat=%d outRange=%d noPrim=%d)",
            stats.scanned, stats.container, #targets, stats.ownBoat, stats.outRange, stats.noPrim))
        if #targets == 0 then if V then pushLog("warn", "[loot] no targets in range") end; return end

        -- nearest first so the chain of TPs is short when standing in a fleet
        table.sort(targets, function(a, b) return a.dist < b.dist end)

        -- (2) open each + pull matching items. Opening the next auto-closes the previous (game-side).
        for _, t in ipairs(targets) do
            if t.struct and t.struct.Parent then
                if (t.prim.Position - hrp.Position).Magnitude > 14 then
                    vlog("info", string.format("snap to %s (%.0f studs) owner=%s", t.struct.Name, t.dist, t.owner))
                    tpInstant(t.prim.Position + Vector3.new(0, 5, 0))
                    task.wait(0.30)
                    hrp = getMyHRP() or hrp
                end
                -- clear any stale UI clone first so WaitForChild observes the FRESH one the server spawns
                local old = pg:FindFirstChild("OpenStructureClone")
                if old then pcall(function() old:Destroy() end) end
                local ok, err = pcall(function() cv:InvokeServer(t.owner, t.struct.Name) end)
                if not ok then vlog("warn", "contentsView fail: " .. tostring(err)) end
                if ok then
                    local clone = pg:WaitForChild("OpenStructureClone", 3)
                    if not clone then
                        vlog("warn", "OpenStructureClone never appeared for "..t.struct.Name.." (server denied? try closer)")
                    else
                        local items = clone:GetChildren()
                        vlog("info", string.format("opened %s -> %d items", t.struct.Name, #items))
                        local pulled, skipped = 0, 0
                        for _, item in ipairs(items) do
                            if item:FindFirstChild("ID") then
                                local irn = item:FindFirstChild("realName")
                                local rname = (irn and tostring(irn.Value)) or item.Name
                                if kw == "" or rname:lower():find(kw, 1, true) then
                                    local moved, merr = pcall(function() mv:InvokeServer("ToInventory", item.ID.Value, nil) end)
                                    if moved then
                                        pulled = pulled + 1
                                        pushLog("good", "📦 looted " .. rname)
                                    else
                                        vlog("warn", "MoveContainerItem fail for "..rname..": "..tostring(merr))
                                    end
                                    task.wait(0.08)
                                else
                                    skipped = skipped + 1
                                end
                            end
                        end
                        if V then pushLog("info", string.format("[loot] %s: pulled %d, kw-skip %d", t.struct.Name, pulled, skipped)) end
                    end
                end
            end
        end
    end

    -- (nail-stall fix lives at module-scope state.doNailFix() now, shared with auto-repair)

    -- REPAIR (when clear): swing the Repair Hammer if the hull is damaged and we're not in
    -- water. equipAndActivate re-equips your weapon afterward, so combat is never broken.
    local function isRepairHammerName(rn) return rn:lower():find("repair", 1, true) ~= nil end
    function BF.repair()
        if not S.boatFarmAutoRepair then return end
        local cur, max = BF.hullHP()
        if cur and max and cur < max * 0.99 then
            -- boat-farm chases NPCs AWAY from the deck, and the hammer only repairs near the hull.
            -- Glide back to the boat root first if we've wandered off, else the swing hits nothing.
            local boat = currentBoat()
            local root = boat and (boat:FindFirstChild("ShipRoot") or boat:FindFirstChildWhichIsA("BasePart", true))
            local hrp = getMyHRP()
            if root and hrp and (hrp.Position - root.Position).Magnitude > 60 then
                pushLog("info", "🔧 boat-farm: returning to boat to repair")
                tpTo(root.Position + Vector3.new(0, 6, 0))
            end
            if S.boatFarmAvoidWater and BF.isInWater() then return end
            if S.boatFarmNailFixOn then state.doNailFix() end
            local ok, err = equipAndActivate(isRepairHammerName, 1)
            if not ok and err ~= "pipe busy" and (not state.bfRepairErrAt or (os.clock() - state.bfRepairErrAt) > 10) then
                state.bfRepairErrAt = os.clock()
                pushLog("warn", "boat-farm repair failed: " .. tostring(err))
            end
        end
    end
end

-- ============================================================
-- AUTO-FARM LOOP — glide-hover above target NPC via velocity (NOT a CFrame
-- teleport; the game rejects those as "unauthorized") + Swing remote. Same velocity physics as fly.
-- ============================================================
task.spawn(function()
    state.farm = state.farm or {kills=0, target="—", status="off"}
    local locked, hovering, lockHp, lockDmgT
    local failUntil = {}   -- model -> os.clock() until which we skip it (benched for taking no damage)
    local lastStatus = "off"   -- diagnostic: only log when status string changes
    local function logStatusChange()
        if state.farm.status ~= lastStatus then
            pushLog("info", "🎯 farm: "..lastStatus.." → "..state.farm.status)
            lastStatus = state.farm.status
        end
    end
    local function endHover()
        state.farm.targetHrp = nil
        -- don't let stale range / latched altitude state carry into the next target
        state.farm.inRange, state.farm.mobDist = nil, nil
        state.farm.wfMax, state.farm.cruiseRef = nil, nil
        if not hovering then return end
        hovering = false
        pcall(function()
            if state.farm.bv then state.farm.bv:Destroy(); state.farm.bv = nil end
            if state.farm.bg then state.farm.bg:Destroy(); state.farm.bg = nil end
            -- (collision is owned by the single Stepped noclip loop now; nothing to restore here)
            local hum = getMyHum(); if hum then hum.PlatformStand = false end
            local r = getMyHRP()
            if r then
                r.Anchored = false
                r.AssemblyLinearVelocity = Vector3.zero
            end
        end)
    end
    -- GLIDE TRACKER: BodyVelocity (smooth force-based motion) + BodyGyro (lock-on facing).
    -- No anchor, no CFrame writes -- server sees real velocity. Same physics class as fly.
    -- Velocity = (hoverPos - currentPos) * smoothing, clamped to max speed. As we close in,
    -- velocity naturally tapers to zero so the player settles smoothly at the hover point.
    table.insert(_G.ENI_HELPER.connections, RunService.Heartbeat:Connect(function(dt)
        if not (S.autoFarmOn or S.boatFarmOn) or state.panic then return end
        -- pause hover while eating/repairing so PlatformStand can stay false for the consume (#4)
        if state.holdNoHover then local hh = getMyHum(); if hh and hh.PlatformStand then hh.PlatformStand = false end; return end
        local th = state.farm and state.farm.targetHrp
        if not (th and th.Parent) then return end
        local myHrp = getMyHRP(); if not myHrp then return end
        local hum = getMyHum(); if not hum then return end

        -- ── STRAIGHT-FLIGHT GLIDE ────────────────────────────────────────────────
        -- The old path chased the mob's EXACT Y every frame, so we dove diagonally toward
        -- it (porpoising up/down, dunking into the sea), and the "behind the mob" point
        -- flipped as the mob re-faced us, making us orbit. New behaviour: hold a stable
        -- CRUISE altitude, fly the straight horizontal beeline at the mob's X/Z, then descend
        -- smoothly onto the strike point only as we close. Fly straight, drop at the end.
        local mobCF      = th.CFrame
        local meleeRange = math.max(2, S.autoFarmMeleeRange or 8)
        local mobDist    = (th.Position - myHrp.Position).Magnitude
        state.farm.mobDist = mobDist                       -- expose for main-loop range gate
        local flat       = (th.Position - myHrp.Position) * Vector3.new(1, 0, 1)
        local flatDist   = flat.Magnitude                  -- horizontal-only gap drives the glide slope

        -- water floor applies to PLAIN farm too now. NOTE: during farm we noclip terrain/walls
        -- (Stepped loop), so altitude only has to respect the WATER SURFACE (the swim/stam tag
        -- triggers on being below the surface -- collision is irrelevant to it).
        local avoidWater = (S.boatFarmOn and S.boatFarmAvoidWater)
                           or ((not S.boatFarmOn) and (S.autoFarmAvoidWater ~= false))

        -- WATER FLOOR (crest-envelope): sample the sea at the mob's STABLE X/Z, then PEAK-HOLD with
        -- slow decay. WaveMath.GetHeight is time-varying so the raw surface bobs every frame; a plain
        -- low-pass can't kill a sub-1Hz swell. The peak-hold jumps up to each crest and only eases
        -- DOWN slowly, giving a steady floor near the recent crest that never chases a trough (chasing
        -- the trough -- a floor that drops then re-rises -- was the residual porpoise).
        local waterFloor = nil
        if avoidWater then
            local raw = BF.waterY(th.Position)
            if raw then
                local prev = state.farm.wfMax
                -- decay SLOW (0.05/frame ~3 stud/s) so wfMax holds near the swell PEAK across a whole
                -- trough period instead of sawtoothing down-then-up between crests.
                state.farm.wfMax = prev and math.max(raw, prev - 0.05) or raw
                waterFloor = state.farm.wfMax + 6                               -- recent crest + clearance
            else
                state.farm.wfMax = nil
            end
        else
            state.farm.wfMax = nil
        end

        -- STRIKE point: where we sit to land hits. Land mobs = behind+side+height; boat-deck mobs =
        -- straight above (no lateral offset -- that would shove the drop point off the deck edge).
        local strikePos
        if S.boatFarmOn then
            strikePos = th.Position + Vector3.new(0, math.max(tonumber(S.autoFarmHeight) or 3, 4), 0)
        else
            -- Z offset: positive = behind mob (along -LookVector), negative = in front, 0 = on top.
            -- X offset: positive = mob's right, negative = mob's left.
            local zOff = tonumber(S.autoFarmOffsetZ) or 4
            local xOff = tonumber(S.autoFarmOffsetX) or 0
            strikePos = th.Position
                      + (-mobCF.LookVector) * zOff
                      + mobCF.RightVector   * xOff
                      + Vector3.new(0, tonumber(S.autoFarmHeight) or 1, 0)
        end
        if waterFloor and strikePos.Y < waterFloor then
            strikePos = Vector3.new(strikePos.X, waterFloor, strikePos.Z)
        end

        -- glide slope: 0 while far (cruise straight at mob's X/Z), ramps to 1 at melee (settled on strike).
        local descendStart = meleeRange + 14
        local slope = math.clamp((descendStart - flatDist) / math.max(1, descendStart - meleeRange), 0, 1)

        -- CRUISE REFERENCE altitude (dual-rate deadband -- the primitive a real altitude-hold uses):
        -- the target is aimY = the strike height, floored above the steady water crest. When we're
        -- FAR from aimY (a gross descent onto a low target, or climb to a high one) we move briskly;
        -- once WITHIN the bob band (a few studs) we crawl, which averages out the swell / deck heave
        -- so the cruise altitude reads steady instead of porpoising. The final landing accuracy comes
        -- from the slope lerp using the LIVE strikePos, not from ref -- so ref lag is harmless.
        local aimY = strikePos.Y
        if waterFloor then aimY = math.max(aimY, waterFloor) end
        local ref = state.farm.cruiseRef
        if not ref then
            ref = math.max(myHrp.Position.Y, aimY)
        else
            local d = aimY - ref
            if math.abs(d) > 8 then ref = ref + math.clamp(d, -0.8, 0.8)   -- gross move: ~48 stud/s
            else                    ref = ref + math.clamp(d, -0.05, 0.05) end  -- in-band crawl: kills bob
        end
        if waterFloor and ref < waterFloor then ref = waterFloor end  -- water safety beats smoothness (never dunk)
        state.farm.cruiseRef = ref
        local cruisePos = Vector3.new(th.Position.X, ref, th.Position.Z)
        local hoverPos  = cruisePos:Lerp(strikePos, slope)

        -- MELEE BOX for the main loop: in-range when horizontally within meleeRange AND vertically
        -- close to the strike height. Pure 3D distance would read "out of range" forever whenever
        -- the water floor holds us above a low/near-water mob; the box lets the final descent count.
        state.farm.inRange = (flatDist <= meleeRange)
                             and (math.abs(myHrp.Position.Y - strikePos.Y) <= meleeRange)

        -- ensure we are UNanchored (anti-cheat & server hitbox love a moving character)
        if myHrp.Anchored then myHrp.Anchored = false end
        -- PlatformStand kills gravity so BodyVelocity can hover us at +Y offset without sag.
        if not hum.PlatformStand then hum.PlatformStand = true end

        -- (Hull/terrain noclip is owned by the single per-frame Stepped loop below -- boat farm shares
        -- the same gate as auto-farm. The old throttled 0.5s block that used to live here was redundant.)

        -- create/refresh BodyVelocity for glide motion
        local bv = state.farm.bv
        if not bv or not bv.Parent then
            if bv then bv:Destroy() end
            bv = Instance.new("BodyVelocity")
            bv.Name = "ENI_FarmBV"
            bv.MaxForce = Vector3.new(1,1,1) * 1e7
            bv.P = 1250
            bv.Velocity = Vector3.zero
            bv.Parent = myHrp
            state.farm.bv = bv
        end

        -- glide convergence (two-phase): cruise FAST while horizontally far, hover SLOW once close.
        -- Uses flatDist (horizontal) so altitude changes don't keep us in "fast cruise" forever.
        local rate = math.clamp(S.autoFarmTweenRate or 5, 1, 20)
        local maxSpeed
        if flatDist > meleeRange then
            maxSpeed = math.max(40, S.autoFarmApproachSpeed or 320)
        else
            maxSpeed = math.max(20, S.autoFarmHoverSpeed or 80)
        end
        local delta = hoverPos - myHrp.Position
        local distance = delta.Magnitude
        local desired
        if distance < 0.05 then
            desired = Vector3.zero
        else
            local speed = math.min(distance * rate, maxSpeed)
            desired = (delta / distance) * speed
        end
        bv.Velocity = desired

        -- BodyGyro for lock-on facing
        local bg = state.farm.bg
        if not bg or not bg.Parent then
            if bg then bg:Destroy() end
            bg = Instance.new("BodyGyro")
            bg.Name = "ENI_FarmBG"
            bg.MaxTorque = Vector3.new(1,1,1) * 9e9
            bg.P = 5e4
            bg.D = 1500
            bg.Parent = myHrp
            state.farm.bg = bg
        end
        bg.CFrame = CFrame.new(myHrp.Position, th.Position)
    end))
    -- diagnostic counters so when pick() returns nil we can log WHY
    local pickStats = {total=0, isPlayer=0, deadOrGone=0, benched=0, filtered=0, ok=0, sample=""}
    -- Sea Piece isHittable contract (mined from Combat_Shared.lua): a target is NOT a valid
    -- swing target if it's Ragdolled, Immune, Unsub, or has NotMoved tag (statue/unspawned).
    local function isHittable(model)
        if not model then return false end
        if model:FindFirstChild("Immune") then return false end
        if model:FindFirstChild("Unsub") then return false end
        if model:FindFirstChild("NotMoved") then return false end
        local cfg = model:FindFirstChild("Config")
        if cfg then
            local rag = cfg:FindFirstChild("Ragdolled")
            if rag and rag.Value == true then return false end
            local hpv = cfg:FindFirstChild("Health")
            if hpv and hpv.Value <= 0 then return false end
        end
        -- BOAT FARM: skip NPCs that fell into water / the void (they sink, can't be killed).
        if S.boatFarmOn then
            local e = entityCache[model]
            if e and e.hrp and e.hrp.Parent and e.hrp.Position.Y < (S.boatFarmVoidY or -300) then return false end
        end
        return true
    end
    -- MULTI-TARGET: merge the checked dropdown types (S.autoFarmTargets, array OR set depending
    -- on the WindUI build) with the comma-separated free-text box (S.autoFarmTarget) into one
    -- lowercase substring list. A mob matches if its name contains ANY term. Empty list = nearest.
    local function farmTerms()
        local terms, seen = {}, {}
        local function add(s)
            if type(s) ~= "string" then return end
            s = s:lower()
            if s == "" or s == "custom" or seen[s] then return end   -- dedup across both sources
            seen[s] = true; terms[#terms + 1] = s
        end
        local list = S.autoFarmTargets
        if type(list) == "table" then
            for k, v in pairs(list) do
                if type(v) == "string" and v ~= "" then add(v)
                elseif v == true and type(k) == "string" then add(k) end
            end
        end
        for part in (S.autoFarmTarget or ""):gmatch("[^,]+") do
            add((part:gsub("^%s+", ""):gsub("%s+$", "")))
        end
        return terms
    end
    local function nameMatchesAny(name, terms)
        local low = name:lower()
        for _, t in ipairs(terms) do
            if low:find(t, 1, true) then return true end
        end
        return false
    end
    local function pick()
        local myHrp = getMyHRP(); if not myHrp then return nil end
        local terms = farmTerms()
        local now = os.clock()
        pickStats.total, pickStats.isPlayer, pickStats.deadOrGone = 0, 0, 0
        pickStats.benched, pickStats.filtered, pickStats.ok = 0, 0, 0
        local sampleNames = {}
        local candidates = {}
        local bfRoots = S.boatFarmOn and BF.boatRoots() or nil
        for model, e in pairs(entityCache) do
            pickStats.total = pickStats.total + 1
            if e.isPlayer then
                pickStats.isPlayer = pickStats.isPlayer + 1
            elseif not (model.Parent and e.hrp and e.hrp.Parent and e.humanoid and e.humanoid.Health > 0) then
                pickStats.deadOrGone = pickStats.deadOrGone + 1
            elseif failUntil[model] and now <= failUntil[model] then
                pickStats.benched = pickStats.benched + 1
            elseif #terms > 0 and not nameMatchesAny(model.Name, terms) then
                pickStats.filtered = pickStats.filtered + 1
                if #sampleNames < 5 then sampleNames[#sampleNames+1] = model.Name end
            elseif not isHittable(model) then
                pickStats.benched = pickStats.benched + 1
                failUntil[model] = now + 2
            else
                local nearBoat = (not S.boatFarmOn) or BF.nearBoat(e.hrp, bfRoots, S.boatFarmRadius)
                if e.hrp and e.hrp.Parent and nearBoat then
                    pickStats.ok = pickStats.ok + 1
                    local d = (e.hrp.Position - myHrp.Position).Magnitude
                    candidates[#candidates+1] = {m=model, e=e, d=d, hp=e.humanoid.Health}
                elseif not nearBoat then
                    pickStats.filtered = pickStats.filtered + 1
                else
                    pickStats.deadOrGone = pickStats.deadOrGone + 1
                end
            end
        end
        pickStats.sample = table.concat(sampleNames, ",")
        -- Priority sort: lowest-HP first (one-shot the wounded), ties broken by distance.
        -- HP rounded to nearest 10 to prevent jitter-thrash between near-equal HP mobs.
        if S.autoFarmPrioLowHp then
            table.sort(candidates, function(a, b)
                local ha = math.floor(a.hp / 10)
                local hb = math.floor(b.hp / 10)
                if ha ~= hb then return ha < hb end
                return a.d < b.d
            end)
        else
            table.sort(candidates, function(a, b) return a.d < b.d end)
        end
        local top = candidates[1]
        if top then return top.m, top.e end
        return nil, nil
    end
    -- when status is "no target", drop a one-shot diag line every 5s explaining why
    local lastDiagAt = os.clock()  -- init to now so the first 5s of startup is quiet
    local function maybeDiag()
        if (os.clock() - lastDiagAt) < 5 then return end
        lastDiagAt = os.clock()
        pushLog("info", string.format(
            "🎯 pick diag: cache=%d  players=%d  dead/gone=%d  benched=%d  filtered=%d  eligible=%d%s",
            pickStats.total, pickStats.isPlayer, pickStats.deadOrGone, pickStats.benched,
            pickStats.filtered, pickStats.ok,
            (pickStats.sample ~= "" and ("  (sample filtered: "..pickStats.sample..")") or "")
        ))
    end
    while gui.Parent do
        logStatusChange()   -- diagnostic: report status string changes between iterations
        if S.boatFarmOn and state.winduiParagraphs and state.winduiParagraphs.boatFarmStatus then
            local hc, hm = BF.hullHP()
            local hp = (hc and hm and hm > 0) and math.floor(hc / hm * 100) or nil
            pcall(function() state.winduiParagraphs.boatFarmStatus:SetDesc(string.format(
                "%s | kills %d%s", state.farm.status or "?", state.farm.kills or 0,
                hp and (" | hull " .. hp .. "%") or "")) end)
        end
        if not (S.autoFarmOn or S.boatFarmOn) or state.panic then
            endHover(); locked = nil; state.farm.status = "off"; task.wait(0.3)
        else
            local hum, myHrp = getMyHum(), getMyHRP()
            if not myHrp or (hum and hum.Health <= 0) then
                endHover(); locked = nil; state.farm.status = "waiting (dead)"; task.wait(0.4)
            elseif S.autoFarmHpFloor > 0 and hum and hum.MaxHealth > 0
                   and (hum.Health / hum.MaxHealth) * 100 < S.autoFarmHpFloor then
                endHover(); state.farm.status = "paused — low HP"; task.wait(0.5)
            else
                local e = locked and entityCache[locked]
                local valid = locked and locked.Parent and e and e.humanoid
                              and e.humanoid.Health > 0 and e.hrp and e.hrp.Parent
                if not valid then
                    if locked and (not e or not locked.Parent or (e.humanoid and e.humanoid.Health <= 0)) then
                        state.farm.kills = state.farm.kills + 1
                    end
                    locked, e = pick()
                    -- reset BOTH trackers; lockDmgT lingering from the previous mob caused
                    -- HeavySwing to misfire on a fresh target if the prior one timed out (>1s no dmg).
                    lockHp = nil
                    lockDmgT = nil
                    -- clear the Heartbeat's stashed range/altitude so this iteration can't read a
                    -- STALE in-range/distance from the PREVIOUS mob (which fired one out-of-range
                    -- swing per target switch). nil forces the 3D fallback until the Heartbeat
                    -- repopulates against the new target next frame.
                    state.farm.inRange, state.farm.mobDist = nil, nil
                    state.farm.wfMax, state.farm.cruiseRef = nil, nil
                end
                if not locked then
                    if S.boatFarmOn then
                        -- ENCOUNTER CLEAR: grip downed enemies, then loot, then repair.
                        state.boatFarm = state.boatFarm or {}
                        local gripping = BF.grip()   -- sets targetHrp + glides while a ragdoll is in range
                        if gripping then
                            state.farm.status = "boat farm: gripping " .. (state.farm.target or "?")
                        else
                            endHover()
                            BF.loot()
                            BF.repair()
                            state.farm.status = "boat farm: clear"
                        end
                        task.wait(0.3)
                    else
                        endHover(); state.farm.status = "no target"
                        maybeDiag()   -- log WHY we picked nothing, throttled to once per 5s
                        task.wait(0.4)
                    end
                else
                    -- progress check: if the mob's HP isn't dropping, our M1s aren't landing —
                    -- bench it briefly and re-acquire so we never grind a mob we can't reach.
                    local hp = e.humanoid.Health
                    -- Distance to the mob. Prefer the Heartbeat-stashed value to avoid redoing
                    -- the magnitude call; fall back to a fresh calc if Heartbeat hasn't run yet.
                    local meleeRange = math.max(2, S.autoFarmMeleeRange or 8)
                    local mobDist = state.farm.mobDist
                    if not mobDist and myHrp and e.hrp and e.hrp.Parent then
                        mobDist = (myHrp.Position - e.hrp.Position).Magnitude
                    end
                    mobDist = mobDist or math.huge
                    -- prefer the Heartbeat's horizontal+vertical melee BOX (state.farm.inRange):
                    -- pure 3D distance reads "out of range" forever when the water floor holds us
                    -- above a low mob. Fall back to 3D only if the Heartbeat hasn't populated it yet.
                    local inMelee = state.farm.inRange
                    if inMelee == nil then inMelee = (mobDist <= meleeRange) end
                    if lockHp == nil or hp < lockHp - 0.5 then
                        lockHp = hp; lockDmgT = os.clock()
                    elseif not inMelee then
                        -- STILL APPROACHING — do NOT count this time toward stuck-bench.
                        -- Without this the lock dropped ~2s into a long glide and target-thrashed.
                        lockDmgT = os.clock()
                    elseif os.clock() - (lockDmgT or 0) > S.autoFarmStuckTime then
                        failUntil[locked] = os.clock() + 6
                        state.farm.status = "no dmg on " .. e.name .. " — switching"
                        locked = nil; lockHp = nil; lockDmgT = nil
                    end
                    if locked then
                        state.farm.target = e.name
                        state.farm.status = inMelee
                            and ("farming " .. e.name)
                            or  (string.format("approaching %s (%.0f studs)", e.name, mobDist))
                        hovering = true
                        state.farm.targetHrp = e.hrp
                        if not state.farm.diagFiredFor or state.farm.diagFiredFor ~= locked then
                            state.farm.diagFiredFor = locked
                            local equippedTool, distance = "(none)", -1
                            pcall(function()
                                local char = lp.Character
                                if char then
                                    local t = char:FindFirstChildOfClass("Tool")
                                    if t then equippedTool = t.Name end
                                end
                                if myHrp and e.hrp and e.hrp.Parent then
                                    distance = (myHrp.Position - e.hrp.Position).Magnitude
                                end
                            end)
                            pushLog("info", string.format(
                                "🎯 lock-on: %s  hp=%.0f  tool=%s  dist=%.1f  meleeRange=%.0f",
                                e.name, hp, equippedTool, distance, meleeRange))
                        end
                        -- RANGE GATE: only fire Swing once we're inside meleeRange. Out-of-range
                        -- swings were the root cause of the '2-second target drop' — server rejects them,
                        -- HP never moves, stuck-timer fires, target benched.
                        local hpBefore = hp
                        local ok, err = true, nil
                        if inMelee and not (S.boatFarmOn and S.boatFarmAvoidWater and BF.isInWater()) then
                            ok, err = pcall(function()
                                local events = lp.Character.ClientCore["Server.cc"].comms.events
                                events.Swing:FireServer()
                            end)
                        end
                        if not ok and not state.farm.swingErrLogged then
                            state.farm.swingErrLogged = true
                            pushLog("warn", "🎯 Swing remote failed: "..tostring(err))
                        end
                        -- damage-check (throttled): tells us if behind-hit actually lands.
                        if ok and (os.clock() - (state.farm.lastVerify or 0)) > 5 then
                            state.farm.lastVerify = os.clock()
                            task.spawn(function()
                                task.wait(0.4)
                                pcall(function()
                                    if locked and locked.Parent and e.humanoid and e.humanoid.Parent then
                                        local hpAfter = e.humanoid.Health
                                        local delta = hpBefore - hpAfter
                                        pushLog(delta > 0 and "good" or "warn",
                                            string.format("🎯 damage: hp %.1f→%.1f (Δ=%.2f) on %s",
                                                hpBefore, hpAfter, delta, e.name))
                                    end
                                end)
                            end)
                        end
                        task.wait(S.autoFarmAttackInterval)
                    end
                end
            end
        end
    end
end)

-- ============================================================
-- AUTO-MINE LOOP — glide-hover above nearest OreRoot via damped BodyPosition+BodyGyro
-- (same anti-cheat-safe force physics as auto-farm; SEPARATE movers in state.mine.* so they
-- never collide with state.farm.bp/bg) + equip pickaxe ONCE then native Tool.Activate() on a timer.
-- ============================================================
task.spawn(function()
    state.mine = state.mine or {count=0, target="—", status="off"}
    local locked, hovering          -- locked = currently targeted OreRoot BasePart
    local startT                    -- os.clock() when we locked the current node (stuck timer)
    local failUntil = {}            -- OreRoot -> os.clock() until which we skip it (benched)
    local lastStatus = "off"
    local function logStatusChange()
        if state.mine.status ~= lastStatus then
            pushLog("info", "⛏ mine: "..lastStatus.." → "..state.mine.status)
            lastStatus = state.mine.status
        end
    end
    local function endHover()
        if not hovering then return end
        hovering = false
        pcall(function()
            if state.mine.bp then state.mine.bp:Destroy(); state.mine.bp = nil end
            if state.mine.bg then state.mine.bg:Destroy(); state.mine.bg = nil end
            local h = getMyHum(); if h then h.PlatformStand = false end
            local r = getMyHRP(); if r then r.Anchored = false; r.AssemblyLinearVelocity = Vector3.zero end
        end)
    end
    -- nearest live OreRoot within range, matching the ore-type filter, skipping benched nodes
    local function pickOre()
        local myHrp = getMyHRP(); if not myHrp then return nil end
        local now = os.clock()
        local filter = (S.autoMineFilter or ""):lower()
        local bestO, bestD = nil, math.huge
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d.Name == "OreRoot" and d:IsA("BasePart") and d.Parent
               and (not failUntil[d] or now > failUntil[d])
               and (filter == "" or (d.Parent.Name:lower():find(filter, 1, true) ~= nil)) then
                local dist = (d.Position - myHrp.Position).Magnitude
                if dist <= S.autoMineRange and dist < bestD then
                    bestD = dist; bestO = d
                end
            end
        end
        return bestO
    end
    -- equip the pickaxe ONCE if not already held; returns the held Tool (or nil)
    local function ensurePickaxe()
        local char = lp.Character; if not char then return nil end
        local hum = char:FindFirstChildOfClass("Humanoid"); if not hum then return nil end
        local inv = lp:FindFirstChild("Inventory")
        local function realNameOf(t)
            local it = inv and inv:FindFirstChild(t.Name)
            local rn = it and it:FindFirstChild("realName")
            return rn and tostring(rn.Value) or t.Name
        end
        local function isPick(rn)
            local l = rn:lower()
            return l:find("pickaxe", 1, true) or l:find("drill", 1, true)
        end
        local held = char:FindFirstChildOfClass("Tool")
        if held and isPick(realNameOf(held)) then return held end
        local bp = lp:FindFirstChild("Backpack")
        if bp then
            for _, t in ipairs(bp:GetChildren()) do
                if t:IsA("Tool") and isPick(realNameOf(t)) then
                    pcall(function() hum:EquipTool(t) end); task.wait(0.15)
                    return char:FindFirstChildOfClass("Tool")
                end
            end
        end
        return nil
    end
    -- count inventory items matching the ore filter (sum of stacks) — a rise = a mined drop landed.
    -- when filter is blank, count ALL inventory stacks: any new drop counts as a hit so automine
    -- still detects completion without a specific filter (was: returned nil and grinded forever).
    local function oreCount()
        local filter = (S.autoMineFilter or ""):lower()
        local n = 0
        if filter == "" then
            for _, it in ipairs(listInventory()) do n = n + (it.stack or 1) end
            return n
        end
        for _, it in ipairs(listInventory()) do
            if tostring(it.realName):lower():find(filter, 1, true) then n = n + (it.stack or 1) end
        end
        return n
    end
    while gui.Parent do
        logStatusChange()
        if not S.autoMineOn or state.panic then
            endHover(); locked = nil; state.mine.status = "off"; task.wait(0.3)
        else
            local hum, myHrp = getMyHum(), getMyHRP()
            if not myHrp or (hum and hum.Health <= 0) then
                endHover(); locked = nil; state.mine.status = "waiting (dead)"; task.wait(0.4)
            else
                -- DONE detection: a filtered-ore item dropped into inventory OR the OreRoot was destroyed
                local gotDrop = false
                if locked then
                    local c = oreCount()
                    if c and state.mine.lastOreCount and c > state.mine.lastOreCount then gotDrop = true end
                end
                if locked and (gotDrop or not (locked.Parent and locked:IsA("BasePart"))) then
                    state.mine.count = state.mine.count + 1
                    if gotDrop then
                        failUntil[locked] = os.clock() + 3   -- don't instantly re-lock a node still here for a frame
                        state.mine.status = "got "..((S.autoMineFilter ~= "" and S.autoMineFilter) or "ore").." — next"
                    end
                    locked = nil
                end
                if not locked then
                    locked = pickOre()
                    startT = os.clock()
                    state.mine.lastOreCount = oreCount()   -- baseline the drop counter for the new node
                end
                if not locked then
                    endHover(); state.mine.target = "—"; state.mine.status = "no ore in range"; task.wait(0.5)
                else
                    -- stuck timeout: node still here but not breaking (out of reach / wrong tool) — bench + re-pick
                    if os.clock() - (startT or 0) > S.autoMineStuckTime then
                        failUntil[locked] = os.clock() + 8
                        state.mine.status = "stuck — next node"
                        locked = nil
                    end
                    if locked then
                        local label = (locked.Parent and locked.Parent.Name or "Ore"):gsub("(%l)(%u)", "%1 %2")
                        state.mine.target = label
                        state.mine.status = "mining " .. label
                        hovering = true
                        pcall(function()
                            if hum then hum.PlatformStand = true end
                            if myHrp.Anchored then myHrp.Anchored = false end   -- NEVER lock: the live mover jiggle is what lands the hit
                            if not state.mine.bp or state.mine.bp.Parent ~= myHrp then
                                if state.mine.bp then state.mine.bp:Destroy() end
                                local bp = Instance.new("BodyPosition")
                                bp.Name = "ENI_MineBP"  -- tagged so teardown can sweep on reload
                                bp.MaxForce = Vector3.new(1,1,1)*1e9; bp.P = 25000; bp.D = 1500
                                bp.Parent = myHrp; state.mine.bp = bp
                            end
                            if not state.mine.bg or state.mine.bg.Parent ~= myHrp then
                                if state.mine.bg then state.mine.bg:Destroy() end
                                local bg = Instance.new("BodyGyro")
                                bg.Name = "ENI_MineBG"
                                bg.MaxTorque = Vector3.new(1,1,1)*9e9; bg.P = 1e5; bg.D = 500
                                bg.Parent = myHrp; state.mine.bg = bg
                            end
                            local oreP = locked.Position
                            -- per-tick (un-locked) physics hover + facing at the ore + your tuned X/Y/Z offset.
                            -- the small live movement is what actually registers the pickaxe hit.
                            state.mine.bp.Position = oreP + Vector3.new(S.autoMineOffsetX, S.autoMineHeight, S.autoMineOffsetZ)
                            state.mine.bg.CFrame = CFrame.new(myHrp.Position, oreP)
                        end)
                        -- equip pickaxe once, then fire native Activate on the held tool (no swap-back)
                        local tool = ensurePickaxe()
                        if tool then
                            pcall(function() tool:Activate() end)
                        elseif not state.mine.noPickLogged then
                            state.mine.noPickLogged = true
                            pushLog("warn", "⛏ no pickaxe found in character/backpack")
                        end
                        task.wait(math.max(S.autoMineSwingInterval, 0.3))
                    end
                end
            end
        end
    end
end)

-- ============================================================
-- WALK/JUMP/NOCLIP LOOP (only set when divergent)
-- ============================================================
task.spawn(function()
    local lastChar = nil
    while gui.Parent do
        local h=getMyHum()
        local char = lp.Character
        -- skip while flying — fly manages WalkSpeed itself
        if h and not S.flyOn then
            if char ~= lastChar then
                lastChar = char
                h.WalkSpeed = S.walkSpeed; h.JumpPower = S.jumpPower
            else
                if math.abs(h.WalkSpeed - S.walkSpeed) > 0.5 then h.WalkSpeed = S.walkSpeed end
                if math.abs(h.JumpPower - S.jumpPower) > 0.5 then h.JumpPower = S.jumpPower end
            end
        end
        task.wait(0.5)
    end
end)

-- NOCLIP: clear CanCollide per-frame while noclip / auto-farm / auto-mine / boat-farm is active.
-- Per-frame is REQUIRED: the game re-asserts CanCollide between clears, so throttling let you snag
-- on terrain. No save/restore here on purpose -- the game re-solidifies the character on its own
-- once we stop forcing CanCollide=false (this is the long-proven plain-autofarm behaviour; boat farm
-- just joins the same gate). tpTo runs its own short-lived noclip and now keeps it noclipped while
-- any farm flag is set, so loot/repair detours don't re-solidify you mid-run.
table.insert(_G.ENI_HELPER.connections, RunService.Stepped:Connect(function()
    if (S.noClip or S.autoFarmOn or S.autoMineOn or S.boatFarmOn) and lp.Character then
        for _,p in ipairs(lp.Character:GetDescendants()) do
            if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
        end
    end
end))

-- DIAGNOSTIC: detect if the game forcibly resets WalkSpeed (anti-cheat movement enforcement)
do
    local watchUntil = 0
    table.insert(_G.ENI_HELPER.connections, RunService.Heartbeat:Connect(function()
        if not LIVE.trace then return end
        if S.walkSpeed <= 16 then return end           -- only meaningful when we WANT faster
        if S.flyOn then return end
        local h=getMyHum(); if not h then return end
        if os.clock() > watchUntil and math.abs(h.WalkSpeed - S.walkSpeed) > 1 then
            shipTrace(string.format("WALKSPEED reset detected: want=%d got=%.1f (game is overriding)", S.walkSpeed, h.WalkSpeed))
            watchUntil = os.clock() + 2   -- throttle: 1 line / 2s
        end
    end))
end

-- TP on death
local function setupDeathListener(char)
    if not char then return end
    local h = char:FindFirstChildOfClass("Humanoid")
    if not h then return end
    -- record last pos before death.  Loop also exits when gui.Parent goes nil so a script reload
    -- doesn't orphan one of these per reload (was leaking N zombie threads per reload).
    local lastPosTimer
    lastPosTimer = task.spawn(function()
        while char.Parent and gui.Parent do
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then S.lastDeathPos = {hrp.Position.X, hrp.Position.Y, hrp.Position.Z} end
            task.wait(2)
        end
    end)
    h.Died:Connect(function()
        if S.tpOnDeath and S.lastDeathPos then
            pushLog("warn","💀 died — will TP back on respawn")
        end
    end)
end
table.insert(_G.ENI_HELPER.connections, lp.CharacterAdded:Connect(function(char)
    task.wait(1)
    setupDeathListener(char)
    if S.flyOn then startFly() end   -- fly's BodyVelocity died with the old character (#60) — rebuild on respawn
    if S.autoFarmOn then
        pcall(function() lp.Character.ClientCore["Server.cc"].comms.remotes.FightStance:InvokeServer(true) end)
    end
    if S.tpOnDeath and type(S.lastDeathPos) == "table"
        and tonumber(S.lastDeathPos[1]) and tonumber(S.lastDeathPos[2]) and tonumber(S.lastDeathPos[3]) then
        task.wait(1)
        tpTo(Vector3.new(tonumber(S.lastDeathPos[1]), tonumber(S.lastDeathPos[2]), tonumber(S.lastDeathPos[3])))
        pushLog("good","TP'd back after death")
    end
end))
if lp.Character then setupDeathListener(lp.Character) end

-- ============================================================
-- AUTO-EAT LOOP (hunger + stamina/rum)
-- ============================================================
-- Stamina lives at workspace.Alive.<player>.Config.Stamina as a NumberConstrainedValue
-- with .Value (current) and .MaxValue.  We compute a 0-100% bar.  Rum (any drink-class
-- item per Food.isDrink) is fired when stamina_pct < threshold.
local function readStaminaPct()
    local alive = workspace:FindFirstChild("Alive")
    local char  = alive and alive:FindFirstChild(lp.Name)
    local cfg   = char and char:FindFirstChild("Config")
    local stam  = cfg and cfg:FindFirstChild("Stamina")
    if not stam then return nil end
    local ok1, cur = pcall(function() return stam.Value end)
    local ok2, mx  = pcall(function() return stam.MaxValue end)
    if not (ok1 and ok2 and type(cur) == "number" and type(mx) == "number" and mx > 0) then return nil end
    return math.clamp((cur / mx) * 100, 0, 100)
end

task.spawn(function()
    while gui.Parent do
        if S.autoEatOn and not state.panic then
            local hunger    = getStat("Hunger")          -- 0-100 fullness (from Config.Hunger.Value)
            local stamPct   = readStaminaPct()           -- 0-100% of MaxValue
            local now = os.clock()
            if not state.autoEat.debugged then
                state.autoEat.debugged = true
                pushLog("info", string.format("auto-eat read: hunger=%s stamPct=%s (thresh hunger<%d, stam<%d%%)",
                    tostring(hunger), tostring(stamPct), S.autoEatHungerThreshold, S.autoEatThirstThreshold))
            end
            if now - state.autoEat.lastEatTime > S.autoEatCooldown then
                -- FULLNESS CHECK: only eat/drink when below threshold. Threshold IS the "I'm full" line.
                if type(hunger) == "number" and hunger < S.autoEatHungerThreshold then
                    eatFromSlot(S.autoEatHungerSlot, string.format("hunger=%d", math.floor(hunger)))
                elseif type(stamPct) == "number" and stamPct < S.autoEatThirstThreshold then
                    -- isThirst=true matches any Food.isDrink including rum/grog/ale/etc.
                    eatFromSlot(S.autoEatThirstSlot, string.format("thirst=stam%d%%", math.floor(stamPct)))
                end
            end
        end
        task.wait(S.autoEatInterval)
    end
end)

-- ============================================================
-- AUTO-RUM LOOP (independent of auto-eat; buff-presence gated)
-- ============================================================
-- Buff lives at Players.LocalPlayer.Stats.StatusEffects.Rum (NumberValue created by CreateStatus,
-- removed when duration expires). Presence == buff active, regardless of remaining duration.
state.autoRum = state.autoRum or { lastDrink = 0, count = 0 }

-- Candidate buff names: actual server-side identifier is unverified (the credit script
-- lives behind FilteringEnabled). The configured name is tried first; on miss we scan
-- every StatusEffects child for a rum/drunk/tipsy-class token. On hit, cache into
-- S.autoRumBuffName so the fast path wins forever after.
local RUM_BUFF_ALIASES = {
    "Rum", "Drunk", "Drunkenness", "Drunken", "RumBuff", "Rum_Buff",
    "Tipsy", "Intoxicated", "Intoxication", "Alcohol", "Alcoholic",
    "Buzzed", "Grog", "Liquor", "Booze", "Wasted",
}
local RUM_BUFF_TOKENS = { "rum", "drunk", "tipsy", "intox", "alcohol", "booze", "grog", "liquor", "buzz", "wasted" }

local function _rumBuffActiveInstance(b)
    if not b then return false end
    if b:IsA("ValueBase") then
        local ok, val = pcall(function() return b.Value end)
        if ok and type(val) == "number" then return val > 0 end
        return true
    end
    return true
end

local function isRumBuffActive()
    local stats = lp:FindFirstChild("Stats")
    if not stats then return false end
    local se = stats:FindFirstChild("StatusEffects")
    if not se then return false end

    -- 1) configured/cached name (fast path)
    local configured = S.autoRumBuffName
    if type(configured) == "string" and configured ~= "" then
        local b = se:FindFirstChild(configured)
        if b and _rumBuffActiveInstance(b) then return true end
    end

    -- 2) static alias list
    for _, n in ipairs(RUM_BUFF_ALIASES) do
        if n ~= configured then
            local b = se:FindFirstChild(n)
            if b and _rumBuffActiveInstance(b) then
                if S.autoRumBuffName ~= n then
                    S.autoRumBuffName = n
                    pushLog("info", "auto-rum: discovered buff name '" .. n .. "' (cached)")
                end
                return true
            end
        end
    end

    -- 3) substring-token scan over every StatusEffects child
    for _, child in ipairs(se:GetChildren()) do
        local cn = child.Name
        if type(cn) == "string" then
            local lc = cn:lower()
            for _, tok in ipairs(RUM_BUFF_TOKENS) do
                if lc:find(tok, 1, true) and _rumBuffActiveInstance(child) then
                    if S.autoRumBuffName ~= cn then
                        S.autoRumBuffName = cn
                        pushLog("info", "auto-rum: discovered buff name '" .. cn .. "' (cached)")
                    end
                    return true
                end
            end
        end
    end

    return false
end

-- rum-only name predicate. Accepts "Rum", "OldRum", "DarkRum", "Rum_Bottle", etc.
-- Deliberately does NOT delegate to Food.isDrink (which would match juice/water/tea/
-- coffee/ale/grog/sake/milk/potion/canteen/flask) -- consuming a non-rum drink leaves
-- the rum buff inactive and re-fires the loop every autoRumCooldown seconds = SPAM.
local function isRumLikeName(s)
    if type(s) ~= "string" then return false end
    return s:lower():find("rum", 1, true) ~= nil
end

local function drinkRum()
    -- prefer the configured slot's item ONLY if its realName is rum-like
    local wantName
    local slot = S.autoRumSlot or 0
    if slot > 0 then
        local u = getBindUuid(slot)
        if u and u ~= "None" and u ~= "" then
            local it = itemByUuid(u)
            local rn = it and it.realName
            if rn and isRumLikeName(rn) then wantName = rn end
        end
    end
    local ok = false
    local usedLabel
    if wantName then
        ok = equipAndActivate(function(rn) return rn == wantName end, 1)
        usedLabel = wantName
    else
        -- rum-only fallback: any tool whose realName contains "rum" (case-insensitive)
        ok = equipAndActivate(isRumLikeName, 1)
        usedLabel = "rum"
    end
    state.autoRum.lastDrink = os.clock()
    if ok then
        state.autoRum.count = state.autoRum.count + 1
        pushLog("good", string.format("🥃 rum -- %s (buff refresh)", usedLabel or "rum"))
    else
        pushLog("warn", "auto-rum: no rum in hotbar or inventory (bind a slot via Auto-rum slot to use a specific drink)")
    end
    return ok
end

task.spawn(function()
    while gui.Parent do
        if S.autoRumOn and not state.panic then
            local now = os.clock()
            if (now - (state.autoRum.lastDrink or 0)) > (S.autoRumCooldown or 3.0) then
                if not isRumBuffActive() then
                    drinkRum()
                end
            end
        end
        task.wait(S.autoRumInterval or 1.0)
    end
end)

-- ============================================================
-- AUTO-TRAIN engine (auto-med state + helpers; drives every exercise via replicatesignal)
-- ============================================================
-- SPEC: while hungry, eat to the HIGH cutoff (prefer Deer Stew). While fed, meditate.
-- Stop is the DUAL of start (same tier replays) so we don't pick a different replication
-- path on the way out. Watchers (StatusEffects + Animator.AnimationPlayed) arm only while
-- .enabled is true so toggle-off cleanly disconnects everything.
-- enabled    = master UI toggle is on
-- channeling = currently in the meditation/training pose
state.autoMed = state.autoMed or {
    enabled = false,
    channeling = false, channelSince = 0,
    busy = false,
    startTier = 0,
    lastStartAt = 0, lastStopAt = 0,
    startGraceUntil = 0, stopGraceUntil = 0,
    skillNameTried = {},
    confirmedSkillName = nil,
    statusName = nil,
    statusConn = nil, statusFolderConn = nil,
    animConn = nil, animCharConn = nil,
    stunConn = nil, stunCharConn = nil,   -- Config.Stuns watcher (universal "training active" signal)
    lastActiveAt = 0,                     -- last time a stun/anim confirmed we're training (debounces the ~3s pulse)
    activePick = nil,                     -- which exercise the loop currently has running (detect pick-switch)
    switchForceUntil = 0,                 -- window after a pick-switch where we start the new exercise despite the old's residual stun
    count = 0, last = "(idle)", lastError = "",
    debugged = false,
}

local MED_STATUS_TOKENS = { "medit", "channel" }
local MED_ANIM_ID = "rbxassetid://110205419950391"
local MED_SKILL_CANDIDATES = { "Meditation", "Meditate", "Meditating" }
-- Stun names that mean "locked doing an in-place exercise" (training / channeling).
-- "Disabled" is the confirmed in-place lock (StunService decompile + med_diff_report.txt show
-- meditate parents Config.Stuns.Disabled). Combat/dodge stuns (Damaged/Weave/Deflect/DashBack/
-- NoDash/NoJump/Low/High) are EXCLUDED so a fight or dash never reads as "training". The keyword
-- fallback future-proofs against an exercise that names its lock differently.
local TRAIN_STUN_NAMES = { ["Disabled"] = true }
local function _isTrainStun(name)
    if type(name) ~= "string" then return false end
    if TRAIN_STUN_NAMES[name] then return true end
    local l = name:lower()
    return (l:find("medit", 1, true) or l:find("train", 1, true) or l:find("channel", 1, true)
        or l:find("exercis", 1, true) or l:find("workout", 1, true)) ~= nil
end

local function _statusLooksLikeMed(name)
    if type(name) ~= "string" then return false end
    local low = name:lower()
    for _, tk in ipairs(MED_STATUS_TOKENS) do
        if low:find(tk, 1, true) then return true end
    end
    return false
end

local function _resolveMedSkillName()
    if state.autoMed.confirmedSkillName then return state.autoMed.confirmedSkillName end
    if type(S.autoMedCastName) == "string" and S.autoMedCastName ~= "" then
        return S.autoMedCastName
    end
    local skills = lp:FindFirstChild("Skills")
    if skills then
        for _, n in ipairs(MED_SKILL_CANDIDATES) do
            if skills:FindFirstChild(n) then return n end
        end
        for _, c in ipairs(skills:GetChildren()) do
            if c.Name:lower():find("medit", 1, true) then return c.Name end
        end
    end
    local best, bestN = MED_SKILL_CANDIDATES[1], math.huge
    for _, n in ipairs(MED_SKILL_CANDIDATES) do
        local t = state.autoMed.skillNameTried[n] or 0
        if t < bestN then best, bestN = n, t end
    end
    return best
end

-- workspace.Alive.<me>.Config.Stuns -- the server adds a movement-lock stun here
-- while you're doing ANY in-place exercise (meditate/pushups/dumbbell/...). It's the
-- universal "training active" marker across all exercises.
local function _meStunsFolder()
    local alive = workspace:FindFirstChild("Alive")
    local me = alive and alive:FindFirstChild(lp.Name)
    local cfg = me and me:FindFirstChild("Config")
    return cfg and cfg:FindFirstChild("Stuns")
end

-- isTrainingActive (kept name isMeditating for the loop): true if we're channeling/
-- stunned/animating any exercise. Meditate uses its looping animation (rock-solid);
-- other exercises use the Config.Stuns pulse, debounced so the ~3s on/off gap doesn't
-- read as "stopped" (which would make the loop re-click and toggle the exercise off).
local function isMeditating()
    if state.autoMed.channeling then return true end
    local stats = lp:FindFirstChild("Stats")
    local se = stats and stats:FindFirstChild("StatusEffects")
    if se then
        if state.autoMed.statusName and se:FindFirstChild(state.autoMed.statusName) then return true end
        for _, c in ipairs(se:GetChildren()) do
            if _statusLooksLikeMed(c.Name) then
                state.autoMed.statusName = c.Name
                return true
            end
        end
    end
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if animator then
        local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
        if ok and tracks then
            for _, tr in ipairs(tracks) do
                local anim = tr.Animation
                if anim and tostring(anim.AnimationId) == MED_ANIM_ID then return true end
            end
        end
    end
    -- universal exercise signal: a TRAINING stun ("Disabled") present now -> active (refresh
    -- the debounce). Combat/dash stuns are ignored. Stuns PULSE, so we also stay "active" if a
    -- training stun fired within the last 8s -- generous so a slow-repping heavy lift's gap
    -- between pulses never reads as "stopped" (which would make the loop re-click and toggle off).
    local st = _meStunsFolder()
    if st then
        for _, c in ipairs(st:GetChildren()) do
            if _isTrainStun(c.Name) then
                state.autoMed.lastActiveAt = os.clock()
                return true
            end
        end
    end
    if (os.clock() - (state.autoMed.lastActiveAt or 0)) < 8.0 then return true end
    return false
end

local function _bindMedStatusFolder(se)
    if state.autoMed.statusConn then pcall(function() state.autoMed.statusConn:Disconnect() end) end
    state.autoMed.statusConn = se.ChildAdded:Connect(function(c)
        if _statusLooksLikeMed(c.Name) then
            state.autoMed.statusName = c.Name
            state.autoMed.channeling = true
            state.autoMed.channelSince = os.clock()
            local removedConn
            removedConn = c.AncestryChanged:Connect(function(_, parent)
                if not parent then
                    state.autoMed.channeling = false
                    if removedConn then removedConn:Disconnect() end
                end
            end)
        end
    end)
end

local function _bindMedAnimator(animator)
    if state.autoMed.animConn then pcall(function() state.autoMed.animConn:Disconnect() end) end
    state.autoMed.animConn = animator.AnimationPlayed:Connect(function(track)
        local anim = track.Animation
        if anim and tostring(anim.AnimationId) == MED_ANIM_ID then
            state.autoMed.channeling = true
            state.autoMed.channelSince = os.clock()
            local stoppedConn
            stoppedConn = track.Stopped:Connect(function()
                state.autoMed.channeling = false
                if stoppedConn then stoppedConn:Disconnect() end
            end)
        end
    end)
end

local function armMedWatchers()
    local stats = lp:FindFirstChild("Stats")
    local se = stats and stats:FindFirstChild("StatusEffects")
    if se then _bindMedStatusFolder(se) end
    if stats and not state.autoMed.statusFolderConn then
        state.autoMed.statusFolderConn = stats.ChildAdded:Connect(function(c)
            if c.Name == "StatusEffects" then _bindMedStatusFolder(c) end
        end)
    end
    local function hookChar(char)
        local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
        local animator = hum and (hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5))
        if animator then _bindMedAnimator(animator) end
    end
    -- universal exercise detector: stamp lastActiveAt on every Config.Stuns pulse edge
    -- (catches pulses too brief for the loop's ~0.5s poll to land inside).
    local function hookStuns()
        local st = _meStunsFolder()
        if not st then return end
        if state.autoMed.stunConn then pcall(function() state.autoMed.stunConn:Disconnect() end) end
        state.autoMed.stunConn = st.ChildAdded:Connect(function(c)
            if _isTrainStun(c.Name) then state.autoMed.lastActiveAt = os.clock() end
        end)
        for _, c in ipairs(st:GetChildren()) do
            if _isTrainStun(c.Name) then state.autoMed.lastActiveAt = os.clock(); break end
        end
    end
    if lp.Character then hookChar(lp.Character); hookStuns() end
    if state.autoMed.animCharConn then pcall(function() state.autoMed.animCharConn:Disconnect() end) end
    state.autoMed.animCharConn = lp.CharacterAdded:Connect(function(c)
        state.autoMed.channeling = false
        state.autoMed.lastActiveAt = 0
        task.wait(0.5)
        hookChar(c); hookStuns()
    end)
end

local function disarmMedWatchers()
    for _, key in ipairs({"statusConn", "statusFolderConn", "animConn", "animCharConn", "stunConn"}) do
        local c = state.autoMed[key]
        if c then pcall(function() c:Disconnect() end) end
        state.autoMed[key] = nil
    end
    state.autoMed.channeling = false
    state.autoMed.lastActiveAt = 0
end

-- Resolves the Meditate GuiButton inside the training menu. Probe (2026-06-02)
-- confirmed the path: PlayerGui.HUD.Menu.TrainingFrame.List.Meditate.
-- The OLD code looked for "HudClient" -- that name doesn't exist; this is why
-- the legacy Tier-2 fallback also failed silently. Candidates list keeps the
-- legacy name as a safety net in case build labels diverge.
-- Find the TrainingFrame.List button for the given exercise (defaults to the
-- currently-picked training). Every exercise button lives here and is wired by the
-- same server-side HUDServer, so replicatesignal works on any of them identically.
local function _findMedTrainingButton(wantName)
    local pg = lp:FindFirstChild("PlayerGui"); if not pg then return nil end
    local target = (type(wantName) == "string" and wantName ~= "" and wantName)
                or S.autoTrainPick or "Meditate"
    local candidates = {
        {"HUD",       "Menu", "TrainingFrame", "List", target},
        {"HudClient", "Menu", "TrainingFrame", "List", target},
    }
    for _, path in ipairs(candidates) do
        local node = pg
        for _, name in ipairs(path) do
            node = node and node:FindFirstChild(name)
            if not node then break end
        end
        if node and node:IsA("GuiButton") then return node end
    end
    -- Resilience: scan descendants for a GuiButton whose name matches the target
    -- (case-insensitive) inside a Training-named ancestor. Catches re-skins/drift.
    local tl = target:lower()
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("GuiButton") and type(d.Name) == "string" and d.Name:lower() == tl then
            local p = d.Parent
            while p and p ~= pg do
                if type(p.Name) == "string" and p.Name:lower():find("train", 1, true) then
                    return d
                end
                p = p.Parent
            end
        end
    end
    return nil
end

-- PRIMARY trigger (probe-confirmed 2026-06-02 via med_replicate.lua):
-- replicatesignal pushes the click through the engine REPLICATION channel, which
-- reaches the server-side HUDServer Script that actually owns the Meditate button.
-- firesignal / getconnections:Fire are client-VM-local Lua calls and CANNOT reach a
-- server Script -- replicatesignal is the only primitive that does. Winning signal:
-- Meditate.MouseButton1Click. (No window focus needed, unlike VirtualInputManager.)
local function _medReplicate(btn)
    if type(replicatesignal) ~= "function" then return false, "no replicatesignal" end
    local sig
    pcall(function() sig = btn.MouseButton1Click end)
    if not sig then return false, "no MouseButton1Click signal" end
    local ok, err = pcall(function() replicatesignal(sig) end)
    if not ok then return false, "replicatesignal threw: " .. tostring(err) end
    return true, "replicatesignal " .. btn:GetFullName()
end

-- Tier 1 -- UI button click. Toggle behavior -- the same click both starts AND stops,
-- so this is used by both start and stop. replicatesignal is the working primitive;
-- firesignal/getconnections remain only as last-resort fallback for other executors.
local function _medTier1_uiClick()
    local btn = _findMedTrainingButton()
    if not btn then
        if not state.autoMed.debugged then
            state.autoMed.debugged = true
            pushLog("warn", "auto-med: Meditate button not found in PlayerGui")
        end
        return false, "no Meditate button"
    end
    -- PRIMARY: replicatesignal (reaches server-side HUDServer). Return on success so
    -- the dead client-VM fallbacks below never run on Wave.
    local repOk, repInfo = _medReplicate(btn)
    if repOk then return true, repInfo end
    local fired = false
    -- Wave-native: firesignal invokes all listeners as if engine triggered.
    if firesignal then
        for _, sigName in ipairs({"Activated", "MouseButton1Click"}) do
            local sig
            pcall(function() sig = btn[sigName] end)
            if sig then
                local ok = pcall(function() firesignal(sig) end)
                if ok then fired = true end
            end
        end
    end
    -- Fallback: iterate connected handlers and Fire them directly.
    if (not fired) and type(getconnections) == "function" then
        pcall(function()
            for _, sigName in ipairs({"MouseButton1Click", "Activated", "MouseButton1Down"}) do
                local sig
                pcall(function() sig = btn[sigName] end)
                if sig then
                    local conns = getconnections(sig)
                    if conns then
                        for _, conn in ipairs(conns) do
                            pcall(function() conn:Fire(); fired = true end)
                        end
                    end
                end
            end
        end)
    end
    if not fired then return false, "firesignal/getconnections unavailable" end
    return true, "UI click " .. btn:GetFullName()
end

-- Tier 2 -- Cast remote (FALLBACK ONLY). The probe proved this place has
-- no Cast event, but keeping this as insurance: if a future build wires
-- meditation through comms, we'll start using it transparently. In the
-- current training place it returns false immediately at the no-events check.
local function _medTier2_castRemote()
    local char = lp.Character; if not char then return false, "no character" end
    local cc = char:FindFirstChild("ClientCore"); if not cc then return false, "no ClientCore" end
    local server = cc:FindFirstChild("Server.cc"); if not server then return false, "no Server.cc" end
    local comms = server:FindFirstChild("comms"); if not comms then return false, "no comms" end
    local events = comms:FindFirstChild("events"); if not events then return false, "no events folder" end
    local cast = events:FindFirstChild("Cast") or events:FindFirstChild("CastSkill")
              or events:FindFirstChild("UseSkill") or events:FindFirstChild("Skill")
    if not cast then return false, "no Cast event" end
    local name = _resolveMedSkillName()
    local ok, err = pcall(function() cast:FireServer(name) end)
    if not ok then return false, "FireServer failed: "..tostring(err) end
    state.autoMed.skillNameTried[name] = (state.autoMed.skillNameTried[name] or 0) + 1
    local cnt = 0; for _ in pairs(state.autoMed.skillNameTried) do cnt = cnt + 1 end
    if cnt > 8 then state.autoMed.skillNameTried = {} end
    return true, name
end

local function startMeditation()
    if state.autoMed.busy then return false, "busy" end
    state.autoMed.busy = true
    -- already going? grace + bail -- respecting it avoids a click that would TOGGLE OFF.
    -- EXCEPTION: during a pick-switch force-window, a residual stun from the just-stopped
    -- exercise would otherwise block starting the newly-picked one, so we skip this guard.
    if isMeditating() and not (os.clock() < (state.autoMed.switchForceUntil or 0)) then
        state.autoMed.startTier = 0
        state.autoMed.lastStartAt = os.clock()
        state.autoMed.startGraceUntil = os.clock() + 0.5
        state.autoMed.last = "start: already meditating"
        state.autoMed.lastError = ""
        state.autoMed.busy = false
        return true
    end
    local okTier1, info1 = _medTier1_uiClick()
    if okTier1 then
        state.autoMed.startTier = 1
        state.autoMed.lastStartAt = os.clock()
        -- 1.5s grace: after a replicatesignal toggle, block re-attempts long enough for
        -- the meditation animation/Stuns pulse to register so the loop's next tick sees
        -- isMeditating()=true and does NOT fire the toggle again (which would stop it).
        state.autoMed.startGraceUntil = os.clock() + 1.5
        state.autoMed.last = "start tier 1 (replicatesignal)"
        state.autoMed.lastError = ""
        state.autoMed.busy = false
        return true
    end
    local okTier2, info2 = _medTier2_castRemote()
    if okTier2 then
        state.autoMed.startTier = 2
        state.autoMed.lastStartAt = os.clock()
        state.autoMed.startGraceUntil = os.clock() + 0.8
        state.autoMed.last = "start tier 2 (Cast "..tostring(info2)..")"
        state.autoMed.lastError = ""
        state.autoMed.busy = false
        return true
    end
    state.autoMed.lastError = string.format("tier1=%s tier2=%s", tostring(info1), tostring(info2))
    state.autoMed.busy = false
    return false, state.autoMed.lastError
end

local function stopMeditation()
    if state.autoMed.busy then return false, "busy" end
    state.autoMed.busy = true
    -- Already stopped? grace + bail. Otherwise a stale click could TOGGLE ON.
    if not isMeditating() then
        state.autoMed.lastStopAt = os.clock()
        state.autoMed.stopGraceUntil = os.clock() + 0.3
        state.autoMed.last = "stop: was not meditating"
        state.autoMed.lastError = ""
        state.autoMed.busy = false
        return true
    end
    -- Probe-confirmed: the same button toggles. Fire the click again to stop.
    local tier = state.autoMed.startTier or 1
    local ok, info
    if tier == 2 then
        ok, info = _medTier2_castRemote()
        if not ok then ok, info = _medTier1_uiClick() end
    else
        ok, info = _medTier1_uiClick()
        if not ok then ok, info = _medTier2_castRemote() end
    end
    if ok then
        state.autoMed.lastStopAt = os.clock()
        state.autoMed.stopGraceUntil = os.clock() + 0.8
        state.autoMed.last = string.format("stop tier %d (%s)", tier, tostring(info))
        state.autoMed.lastError = ""
        state.autoMed.busy = false
        return true
    end
    state.autoMed.lastError = "stop failed: "..tostring(info)
    state.autoMed.busy = false
    return false, state.autoMed.lastError
end

-- ============================================================
-- AUTO-TRAIN LOOP (pure training; hunger is auto-eat's job)
-- ============================================================
-- Only job: keep the selected TrainingFrame.List button toggled ON. If the user picks
-- a different exercise mid-run, toggle the OLD one off and open a force-window so the
-- new pick can start despite the old's residual stun. Eating is NOT this loop's concern --
-- enable auto-eat separately if you want hunger handled (the two loops coexist; the game
-- lets you eat while training without breaking the channel).
task.spawn(function()
    while gui.Parent do
        local am = state.autoMed
        -- auto-repair preempts auto-train: while the hull is being repaired (state.repairNeeded),
        -- this falls into the OFF branch -> stops the channel + frees the hands for the hammer.
        -- When the hull is full again the flag clears and training auto-resumes.
        if S.autoMedOn and not state.panic and not state.repairNeeded then
            if not am.enabled then
                am.enabled = true
                armMedWatchers()
            end
            if not am.statusConn and not am.animConn then armMedWatchers() end

            local channeling = isMeditating()

            -- (0) handle exercise switch: if the user picked a different training while
            -- one is running, toggle the OLD one off, then open a force-window so the new
            -- pick starts even though the old exercise's stun lingers for a moment.
            local pick = S.autoTrainPick or "Meditate"
            if am.activePick == nil then am.activePick = pick end
            if channeling and am.activePick ~= pick and os.clock() >= (am.startGraceUntil or 0) then
                local oldBtn = _findMedTrainingButton(am.activePick)
                if oldBtn then _medReplicate(oldBtn) end
                am.activePick = pick
                am.channeling = false
                channeling = false
                am.switchForceUntil = os.clock() + 3.0   -- start new pick despite residual old stun
                am.startGraceUntil = os.clock() + 0.4    -- brief settle so the off-click lands first
            end

            -- (1) keep the selected training running: (re)start when not active (or during
            -- a switch force-window) and past the post-start grace.
            local forceStart = os.clock() < (am.switchForceUntil or 0)
            if ((not channeling) or forceStart) and os.clock() >= (am.startGraceUntil or 0) then
                if startMeditation() then
                    am.activePick = pick
                    am.switchForceUntil = 0
                end
            end
        else
            if am.enabled then
                am.enabled = false
                -- stop the exercise the loop ACTUALLY started (am.activePick), not whatever the
                -- dropdown currently shows -- they can differ if the pick changed this same tick.
                if isMeditating() then
                    local stopName = am.activePick or S.autoTrainPick or "Meditate"
                    local sb = _findMedTrainingButton(stopName)
                    if sb then _medReplicate(sb) else pcall(stopMeditation) end
                end
                am.activePick = nil
                am.switchForceUntil = 0
                disarmMedWatchers()
                am.startTier = 0
            end
        end
        task.wait(S.autoMedInterval or 0.5)
    end
end)

-- Auto-train status paragraph updater.
task.spawn(function()
    while gui.Parent do
        local para = state.winduiParagraphs and state.winduiParagraphs.autoMedStatus
        if para then
            local am = state.autoMed or {}
            local stateStr
            if not S.autoMedOn then
                stateStr = "OFF"
            else
                local pickName = S.autoTrainPick or "Meditate"
                stateStr = isMeditating() and (pickName .. " ✓") or ("starting " .. pickName)
            end
            pcall(function()
                para:SetDesc(string.format(
                    "%s | last: %s | tier=%d",
                    stateStr, tostring(am.last or "?"):sub(1, 50), am.startTier or 0))
            end)
        end
        task.wait(0.5)
    end
end)

-- ============================================================
-- ESP LOOP
-- ============================================================
-- module-scope so the Heartbeat updater below can call it too. (Previously this
-- lived inside the task.spawn closure, which silently nil'd the Heartbeat reads.)
local function getEntityHP(model, hum)
        local cur, max
        local function readCfgHealth(m)
            if not m then return nil end
            local cfg = m:FindFirstChild("Config")
            local ch = cfg and cfg:FindFirstChild("Health")
            if not ch then return nil end
            local okc, v = pcall(function() return ch.Value end)
            if not (okc and type(v) == "number") then return nil end
            local okm, vm = pcall(function() return ch.MaxValue end)
            return v, (okm and type(vm) == "number" and vm > 0) and vm or nil
        end
        -- live HP is at <entity>.Config.Health. The cached model is usually right, but fall
        -- back to its counterpart under workspace.Alive (where the authoritative, REPLICATING
        -- Health lives) so the bar tracks damage instead of freezing on a stale humanoid.
        cur, max = readCfgHealth(model)
        if not cur then
            local alive = Workspace:FindFirstChild("Alive")
            local am = alive and alive:FindFirstChild(model.Name)
            if am and am ~= model then cur, max = readCfgHealth(am) end
        end
        -- legacy top-level Health NumberValue (some NPCs)
        if not cur then
            local hv = model:FindFirstChild("Health")
            if hv then
                local ok, v   = pcall(function() return hv.Value    end); if ok and type(v) =="number" then cur = v end
                if not max then
                    local okM, vm = pcall(function() return hv.MaxValue end); if okM and type(vm)=="number" and vm > 0 then max = vm end
                end
            end
        end
        -- last resort: Humanoid.  reject obviously-bogus MaxHealth (sea piece sometimes
        -- leaves it at math.huge, 0, or 1e18 sentinels) so the display doesn't print "?????"
        -- from an unrenderable scientific-notation string.
        if not cur and hum then local ok,v = pcall(function() return hum.Health    end); if ok and type(v)=="number" then cur = v end end
        if not max and hum then
            local ok, v = pcall(function() return hum.MaxHealth end)
            if ok and type(v) == "number" and v > 0 and v < 1e6 then max = v end
        end
        if max and (max == math.huge or max <= 0 or max > 1e6) then max = nil end
    if cur and max and cur > max then max = cur end   -- keep the bar sane if current exceeds max briefly
    return cur, max
end

task.spawn(function()
    while gui.Parent do
        local interval=S.espUpdateInterval or 0.5
        local _espOk, _espErr = pcall(function()
        if S.espOn and not state.panic then
            local myHrp=getMyHRP(); local seen={}; local visibleCount=0
            if myHrp then
                local filter=S.espNpcFilter:lower()
                for model, e in pairs(entityCache) do
                    -- refresh stale hrp (respawn) + reclassify players misread as NPCs
                    if not e.hrp or not e.hrp.Parent or not e.isPlayer then refreshEntityPlayer(model) end
                    if model.Parent and e.hrp and e.hrp.Parent then
                        local isP = e.isPlayer and e.player and e.player ~= lp
                        local isNpc = not e.isPlayer
                        local show = (isP and S.espPlayers)
                                  or (isNpc and S.espNpcs and (filter=="" or model.Name:lower():find(filter,1,true)))
                        if show then
                            local d=(e.hrp.Position-myHrp.Position).Magnitude
                            if d < S.espMaxDistance then
                                seen[model]=true; visibleCount=visibleCount+1
                                local rec=_G.ENI_HELPER.espGuis[model]
                                if not rec then
                                    local col = isP and C.player or C.npc
                                    -- compact billboard ANCHORED TO THE BODY'S SIDE (not above the head).
                                    -- StudsOffset is CAMERA-space, so the +X offset always sits to screen-right
                                    -- of the chest regardless of which side you view from. Layout: name (top),
                                    -- thin HP bar, info line (HP num + distance). Smaller footprint than the
                                    -- old above-head bar that blocked half the body.
                                    local bg=Instance.new("BillboardGui"); bg.Adornee=e.hrp; bg.AlwaysOnTop=true
                                    bg.Size=UDim2.new(0,120,0,38); bg.StudsOffset=Vector3.new(-2.6,0.2,0); bg.MaxDistance=1e9
                                    local nl=Instance.new("TextLabel",bg); nl.Size=UDim2.new(1,0,0,13); nl.BackgroundTransparency=1
                                    nl.Text=e.name; nl.TextColor3=col; nl.TextSize=12; nl.Font=Enum.Font.GothamBold
                                    nl.TextStrokeTransparency=0; nl.TextStrokeColor3=Color3.new(0,0,0)
                                    nl.TextXAlignment=Enum.TextXAlignment.Right
                                    -- HP bar: slim (3px), tucked just under the name
                                    local bb=Instance.new("Frame",bg); bb.Size=UDim2.new(1,0,0,3); bb.Position=UDim2.new(0,0,0,15)
                                    bb.BackgroundColor3=Color3.fromRGB(15,15,18); bb.BorderSizePixel=0
                                    bb.BackgroundTransparency=0.25
                                    local bf=Instance.new("Frame",bb); bf.Size=UDim2.new(1,0,1,0); bf.BorderSizePixel=0
                                    local il=Instance.new("TextLabel",bg); il.Size=UDim2.new(1,0,0,12); il.Position=UDim2.new(0,0,0,21)
                                    il.BackgroundTransparency=1; il.TextColor3=C.text; il.TextSize=11; il.Font=Enum.Font.Code
                                    il.TextStrokeTransparency=0.4; il.TextStrokeColor3=Color3.new(0,0,0)
                                    il.TextXAlignment=Enum.TextXAlignment.Right
                                    -- Highlight: outline only, very faint fill (was 0.7 fill / 0.1 outline -- too painty)
                                    local hl=Instance.new("Highlight"); hl.FillTransparency=0.92; hl.OutlineTransparency=0; hl.Adornee=model
                                    bg.Parent=gui; hl.Parent=gui
                                    rec={gui=bg,nameLbl=nl,infoLbl=il,hl=hl,bar=bf,col=col,model=model,humanoid=e.humanoid}
                                    _G.ENI_HELPER.espGuis[model]=rec
                                end
                                -- re-attach if the entity respawned (e.hrp re-resolved to a new part)
                                if rec.gui.Adornee ~= e.hrp then rec.gui.Adornee = e.hrp end
                                rec.humanoid = e.humanoid   -- keep fresh ref for the Heartbeat updater
                                rec.dist = d                 -- last-known distance; Heartbeat shows this between scans
                                rec.hl.FillColor=rec.col; rec.hl.OutlineColor=rec.col
                            end
                        end
                    end
                end
            end
            for model,rec in pairs(_G.ENI_HELPER.espGuis) do
                if not seen[model] then
                    pcall(function() rec.gui:Destroy() end); pcall(function() rec.hl:Destroy() end)
                    _G.ENI_HELPER.espGuis[model]=nil
                end
            end
            state.espVisibleCount=visibleCount
        else
            for m,rec in pairs(_G.ENI_HELPER.espGuis) do
                pcall(function() rec.gui:Destroy() end); pcall(function() rec.hl:Destroy() end)
                _G.ENI_HELPER.espGuis[m]=nil
            end
            state.espVisibleCount=0
        end
        end)  -- pcall: one bad entity can't kill the ESP loop
        if not _espOk then state.espLoopErr = tostring(_espErr) end
        task.wait(interval)
    end
end)

-- ============================================================
-- ESP HEARTBEAT UPDATER: bar + text refresh every frame so HP loss is visible
-- in real-time. The scan loop above only runs every espUpdateInterval (~0.5s) which
-- is enough for entity discovery / lifecycle, but health damage in combat needs
-- to track at frame rate, not lurch in half-second steps.
-- ============================================================
table.insert(_G.ENI_HELPER.connections, RunService.Heartbeat:Connect(function()
    if not S.espOn or state.panic then return end
    local myHrp = getMyHRP()
    for model, rec in pairs(_G.ENI_HELPER.espGuis) do
        if rec.gui and rec.gui.Parent and rec.bar and rec.infoLbl and rec.model and rec.model.Parent then
            local hpCur, hpMax = getEntityHP(rec.model, rec.humanoid)
            local hpFrac = 1
            if hpCur and hpMax and hpMax > 0 then hpFrac = math.clamp(hpCur / hpMax, 0, 1) end
            rec.bar.Size = UDim2.new(hpFrac, 0, 1, 0)
            rec.bar.BackgroundColor3 = Color3.fromRGB(
                math.floor(235 * (1 - hpFrac)) + 20,
                math.floor(200 * hpFrac) + 20,
                50)
            -- live distance so the number doesn't freeze between scan ticks
            local liveD = rec.dist or 0
            if myHrp and rec.gui.Adornee and rec.gui.Adornee.Parent then
                liveD = (rec.gui.Adornee.Position - myHrp.Position).Magnitude
            end
            local info = ""
            if S.espShowHealth and hpCur then
                info = info .. math.floor(hpCur)
                if hpMax and hpMax > 0 and hpMax < 1e6 then
                    info = info .. "/" .. math.floor(hpMax)
                end
            end
            if S.espShowDistance then
                if info ~= "" then info = info .. " · " end
                info = info .. math.floor(liveD) .. "m"
            end
            rec.infoLbl.Text = info
        end
    end
end))

-- ============================================================
-- ORE ESP LOOP (independent of entity ESP; anchors on OreRoot parts so it
-- works for any deposit type. Own oreGuis table — can't touch player/NPC ESP.)
-- ============================================================
task.spawn(function()
    local oreCol = Color3.fromRGB(216,150,84)  -- copper
    while gui.Parent do
        if S.espOn and S.espOre and not state.panic then
            local myHrp = getMyHRP(); local seen = {}
            if myHrp then
                for _, d in ipairs(Workspace:GetDescendants()) do
                    if d.Name == "OreRoot" and d:IsA("BasePart") then
                        local dist = (d.Position - myHrp.Position).Magnitude
                        if dist < S.espMaxDistance then
                            seen[d] = true
                            local rec = _G.ENI_HELPER.oreGuis[d]
                            if not rec then
                                local model = d.Parent
                                local label = (model and model.Name or "Ore"):gsub("(%l)(%u)", "%1 %2")
                                local bg = Instance.new("BillboardGui"); bg.Adornee = d; bg.AlwaysOnTop = true
                                bg.Size = UDim2.new(0,150,0,34); bg.StudsOffset = Vector3.new(0,2,0); bg.MaxDistance = 1e9
                                local nl = Instance.new("TextLabel", bg); nl.Size = UDim2.new(1,0,0,18); nl.BackgroundTransparency = 1
                                nl.Text = "⛏ "..label; nl.TextColor3 = oreCol; nl.TextSize = 14; nl.Font = Enum.Font.GothamBold
                                nl.TextStrokeTransparency = 0; nl.TextStrokeColor3 = Color3.new(0,0,0)
                                local il = Instance.new("TextLabel", bg); il.Size = UDim2.new(1,0,0,12); il.Position = UDim2.new(0,0,0,18)
                                il.BackgroundTransparency = 1; il.TextColor3 = C.text; il.TextSize = 11; il.Font = Enum.Font.Code
                                il.TextStrokeTransparency = 0.4; il.TextStrokeColor3 = Color3.new(0,0,0)
                                local hl = Instance.new("Highlight"); hl.FillTransparency = 0.6; hl.OutlineTransparency = 0
                                hl.FillColor = oreCol; hl.OutlineColor = oreCol
                                hl.Adornee = (model and model:IsA("Model")) and model or d
                                bg.Parent = gui; hl.Parent = gui
                                rec = {gui = bg, hl = hl, infoLbl = il}; _G.ENI_HELPER.oreGuis[d] = rec
                            end
                            rec.infoLbl.Text = math.floor(dist) .. "m"
                        end
                    end
                end
            end
            for part, rec in pairs(_G.ENI_HELPER.oreGuis) do
                if not seen[part] then
                    pcall(function() rec.gui:Destroy() end); pcall(function() rec.hl:Destroy() end)
                    _G.ENI_HELPER.oreGuis[part] = nil
                end
            end
        else
            for part, rec in pairs(_G.ENI_HELPER.oreGuis) do
                pcall(function() rec.gui:Destroy() end); pcall(function() rec.hl:Destroy() end)
                _G.ENI_HELPER.oreGuis[part] = nil
            end
        end
        task.wait(math.max(S.espUpdateInterval, 0.75))
    end
end)

-- ============================================================
-- DEER-AUTOLOOT LOOP  (no UI -- tied to autofarm: on when autofarm is on)
-- Pairs with autofarm: kill deer -> body drops the F-to-collect prompt -> we fire it.
-- ONLY fires prompts whose ancestor chain contains one of AUTO_LOOT_TARGETS.
-- Shares state.promptCache with the user-facing AUTO-LOOT ground-loot loop.
-- ============================================================
local AUTO_LOOT_TARGETS = { "deer" }
local AUTO_LOOT_RANGE = 30
task.spawn(function()
    local lastFired = {}
    setmetatable(lastFired, {__mode = "k"})
    while gui.Parent do
        task.wait(0.4)
        if S.autoFarmOn and not state.panic and type(fireproximityprompt) == "function" then
            local hrp = getMyHRP()
            if hrp then
                local pos = hrp.Position
                local rangeSq = AUTO_LOOT_RANGE * AUTO_LOOT_RANGE
                local now = os.clock()
                for d, _ in pairs(state.promptCache) do
                    if d.Parent and d.Enabled then
                        -- whitelist check: walk up from prompt, match ANY ancestor name
                        local matched = false
                        local cur = d.Parent
                        while cur and cur ~= Workspace do
                            local lname = cur.Name:lower()
                            for _, t in ipairs(AUTO_LOOT_TARGETS) do
                                if lname:find(t, 1, true) then matched = true; break end
                            end
                            if matched then break end
                            cur = cur.Parent
                        end
                        if matched then
                            local parent = d.Parent
                            local pp
                            if parent and parent:IsA("BasePart") then
                                pp = parent.Position
                            elseif parent and parent:IsA("Model") then
                                local pr = parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart", true)
                                pp = pr and pr.Position
                            end
                            if pp then
                                local dx, dy, dz = pp.X - pos.X, pp.Y - pos.Y, pp.Z - pos.Z
                                if (dx*dx + dy*dy + dz*dz) < rangeSq then
                                    local last = lastFired[d] or 0
                                    if now - last > 1.5 then
                                        pcall(fireproximityprompt, d)
                                        lastFired[d] = now
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ============================================================
-- PROXIMITY-PROMPT ESP LOOP (chests, doors, NPCs, interactables; own promptGuis table)
-- ============================================================
task.spawn(function()
    local promptCol = Color3.fromRGB(120, 230, 150)
    while gui.Parent do
        if S.espOn and S.espPrompts and not state.panic then
            local myHrp = getMyHRP(); local seen = {}
            if myHrp then
                for _, d in ipairs(Workspace:GetDescendants()) do
                    if d:IsA("ProximityPrompt") then
                        local p = d.Parent
                        local anchor
                        if p then
                            if p:IsA("BasePart") then anchor = p
                            elseif p:IsA("Attachment") then anchor = p.Parent
                            else anchor = p:FindFirstChildWhichIsA("BasePart") end
                        end
                        if anchor and anchor:IsA("BasePart") then
                            local dist = (anchor.Position - myHrp.Position).Magnitude
                            if dist < S.espMaxDistance then
                                seen[d] = true
                                local rec = _G.ENI_HELPER.promptGuis[d]
                                if not rec then
                                    -- best-effort name: ObjectText -> ancestor Model name -> parent name -> the prompt's own Name
                                    local obj = d.ObjectText
                                    if obj == "" then
                                        local m = d:FindFirstAncestorWhichIsA("Model")
                                        obj = (m and m.Name) or (d.Parent and d.Parent.Name) or d.Name
                                    end
                                    local act = (d.ActionText ~= "" and d.ActionText) or d.Name
                                    local bg = Instance.new("BillboardGui"); bg.Adornee = anchor; bg.AlwaysOnTop = true
                                    bg.Size = UDim2.new(0,180,0,34); bg.StudsOffset = Vector3.new(0,2.2,0); bg.MaxDistance = 1e9
                                    local nl = Instance.new("TextLabel", bg); nl.Size = UDim2.new(1,0,0,18); nl.BackgroundTransparency = 1
                                    nl.Text = "❲ "..obj.." ❳"; nl.TextColor3 = promptCol; nl.TextSize = 14; nl.Font = Enum.Font.GothamBold
                                    nl.TextStrokeTransparency = 0; nl.TextStrokeColor3 = Color3.new(0,0,0)
                                    local il = Instance.new("TextLabel", bg); il.Size = UDim2.new(1,0,0,12); il.Position = UDim2.new(0,0,0,18)
                                    il.BackgroundTransparency = 1; il.TextColor3 = C.text; il.TextSize = 11; il.Font = Enum.Font.Code
                                    il.TextStrokeTransparency = 0.4; il.TextStrokeColor3 = Color3.new(0,0,0)
                                    local hl = Instance.new("Highlight"); hl.FillTransparency = 0.7; hl.OutlineTransparency = 0
                                    hl.FillColor = promptCol; hl.OutlineColor = promptCol; hl.Adornee = anchor
                                    bg.Parent = gui; hl.Parent = gui
                                    rec = {gui = bg, hl = hl, infoLbl = il, act = act}; _G.ENI_HELPER.promptGuis[d] = rec
                                end
                                rec.infoLbl.Text = rec.act .. "  ·  " .. math.floor(dist) .. "m"
                            end
                        end
                    end
                end
            end
            for k, rec in pairs(_G.ENI_HELPER.promptGuis) do
                if not seen[k] then
                    pcall(function() rec.gui:Destroy() end); pcall(function() rec.hl:Destroy() end)
                    _G.ENI_HELPER.promptGuis[k] = nil
                end
            end
        else
            for k, rec in pairs(_G.ENI_HELPER.promptGuis) do
                pcall(function() rec.gui:Destroy() end); pcall(function() rec.hl:Destroy() end)
                _G.ENI_HELPER.promptGuis[k] = nil
            end
        end
        task.wait(math.max(S.espUpdateInterval, 0.75))
    end
end)

-- ============================================================
-- ENTITY RECONCILE — catch NPCs the DescendantAdded race missed.
-- (Humanoid replicated before the root part, so registerEntity bailed.)
-- Scans every top-level Workspace folder/model every 1.5s, not just
-- Workspace.Alive — island NPCs / vendors live in their own folders, and
-- restricting to Alive made them invisible to ESP/POI on most islands.
-- ============================================================
task.spawn(function()
    while gui.Parent do
        task.wait(1.5)
        for _, container in ipairs(Workspace:GetChildren()) do
            if container:IsA("Folder") or container:IsA("Model") then
                for _, m in ipairs(container:GetChildren()) do
                    if m:IsA("Model") and not entityCache[m] and m ~= lp.Character then
                        local h = m:FindFirstChildOfClass("Humanoid")
                        if h and h.Health > 0 then registerEntity(m) end
                    end
                end
            end
        end
    end
end)

-- ============================================================
-- MINIMAP LANDMARK SCANNER  (every 3s; XZ bounding boxes of top-level
-- Workspace containers, filtered by name + size heuristic so we render
-- islands/structures but not effects/scripts/the whole-world envelope)
-- ============================================================
local LANDMARK_SKIP = { Alive=true, Camera=true, Terrain=true, Effects=true, Debris=true,
                       Lighting=true, ReplicatedStorage=true, Sounds=true, ["Sound"]=true,
                       Players=true, Workspace=true }
task.spawn(function()
    while gui.Parent do
        task.wait(3)
        if S.mapOn then
        local marks = {}
        for _, container in ipairs(Workspace:GetChildren()) do
            if (container:IsA("Folder") or container:IsA("Model"))
               and not LANDMARK_SKIP[container.Name] then
                local minX, maxX = math.huge, -math.huge
                local minZ, maxZ = math.huge, -math.huge
                local partCount = 0
                -- Yield every 200 parts inside the inner scan; islands can be 100-800 parts
                -- and on Sea Piece-sized worlds even short walks can stutter the render.
                for idx, d in ipairs(container:GetDescendants()) do
                    if d:IsA("BasePart") then
                        local p, s = d.Position, d.Size
                        local sx, sz = s.X * 0.5, s.Z * 0.5
                        if p.X - sx < minX then minX = p.X - sx end
                        if p.X + sx > maxX then maxX = p.X + sx end
                        if p.Z - sz < minZ then minZ = p.Z - sz end
                        if p.Z + sz > maxZ then maxZ = p.Z + sz end
                        partCount = partCount + 1
                        if partCount > 800 then break end
                    end
                    if idx % 200 == 0 then task.wait() end
                end
                if minX ~= math.huge then
                    local w, h = maxX - minX, maxZ - minZ
                    -- size filter: skip tiny (single-prop) and huge (everything-envelope)
                    if w > 30 and w < 4000 and h > 30 and h < 4000 then
                        marks[#marks+1] = {
                            name = container.Name,
                            cx = (minX + maxX) * 0.5, cz = (minZ + maxZ) * 0.5,
                            w = w, h = h,
                        }
                    end
                end
            end
        end
        state.map.landmarks = marks
        end -- if S.mapOn
    end
end)

-- ============================================================
-- MINIMAP RENDER LOOP  (Heartbeat; NORTH-UP projection so NESW labels mean
-- what they say. Player arrow center, rotates to show facing direction.
-- Dots from entityCache + oreGuis; rects from the landmark scanner above.)
-- ============================================================
-- module-level Color3 constants so we don't allocate per-frame (60+ allocs/sec otherwise)
local DOT_COLOR_PLAYER = Color3.fromRGB(80, 180, 255)
local DOT_COLOR_NPC    = Color3.fromRGB(255, 100, 100)
local DOT_COLOR_ORE    = Color3.fromRGB(216, 150, 84)
-- frame-counter + cached rotation: skip property writes when the value didn't move
local mapFrameCounter, mapPrevRot, mapPrevSize = 0, nil, nil
table.insert(_G.ENI_HELPER.connections, RunService.Heartbeat:Connect(function()
    if not S.mapOn or state.panic then
        if mapFrame.Visible then mapFrame.Visible = false end
        return
    end
    if not mapFrame.Visible then mapFrame.Visible = true end
    -- only resize when slider value changes (was unconditionally re-asserting Size each frame)
    if mapPrevSize ~= S.mapSize then
        mapFrame.Size = UDim2.fromOffset(S.mapSize, S.mapSize)
        mapPrevSize = S.mapSize
    end
    mapFrameCounter = mapFrameCounter + 1
    local hrp = getMyHRP(); if not hrp then return end
    local pos  = hrp.Position
    local look = hrp.CFrame.LookVector
    local size = S.mapSize
    local range = math.max(50, S.mapRange)
    local scale = (size * 0.5) / range
    local cx, cy = size * 0.5, size * 0.5

    -- player-centered, standard-compass projection (N up, E right).
    -- Sea Piece convention: game-east = +X, game-north = -Z.  Z still flipped vs
    -- screen because screen-Y grows downward; X is direct.
    local function w2m(wx, wz)
        local mx = (wx - pos.X) * scale + cx      -- +X (game-east) -> right of map
        local my = (wz - pos.Z) * scale + cy      -- +Z (game-south) -> bottom of map
        return mx, my
    end

    -- arrow rotation: facing game-north (-Z) -> 0deg (up).  atan2(look.X, -look.Z)
    -- maps look=(0,0,-1) to 0, look=(1,0,0) to 90deg (right), etc.
    -- skip the write if rotation hasn't changed by >0.5deg (UI layout cost).  Position is
    -- a hardcoded (0.5,0.5) anchor at creation -- no need to re-assign per frame.
    local newRot = math.deg(math.atan2(look.X, -look.Z))
    if not mapPrevRot or math.abs(newRot - mapPrevRot) > 0.5 then
        mapArrow.Rotation = newRot
        mapPrevRot = newRot
    end

    -- current grid zone (e.g. "F9", "H8") -- updates live from Players.LP.Stats.LastZone
    mapZoneLbl.Text = tostring(getStat("LastZone") or "--")
    mapRangeLbl.Text = string.format("RNG %d   %.0f,%.0f,%.0f", range, pos.X, pos.Y, pos.Z)

    -- --- LANDMARKS (rectangles from scanner cache) ---
    local lm = state.map.landmarks
    local rects = state.map.rects
    while #rects < #lm do
        local r = Instance.new("Frame", mapFrame)
        r.AnchorPoint = Vector2.new(0.5, 0.5)
        r.BorderSizePixel = 0
        r.BackgroundColor3 = Color3.fromRGB(170, 140, 90)
        r.BackgroundTransparency = 0.15
        r.ZIndex = 52
        local s = Instance.new("UIStroke", r); s.Color = Color3.fromRGB(120,95,55); s.Thickness = 1
        rects[#rects + 1] = r
    end
    for i, rect in ipairs(rects) do
        local m = lm[i]
        if m then
            local mx, my = w2m(m.cx, m.cz)
            local rw = m.w * scale
            local rh = m.h * scale
            -- cull if completely off-screen
            if mx + rw*0.5 > 0 and mx - rw*0.5 < size
               and my + rh*0.5 > 0 and my - rh*0.5 < size then
                rect.Position = UDim2.fromOffset(mx, my)
                rect.Size = UDim2.fromOffset(math.max(2, rw), math.max(2, rh))
                rect.Visible = true
            else
                rect.Visible = false
            end
        elseif rect.Visible then
            rect.Visible = false
        end
    end

    -- --- ENTITY DOTS (NPCs / players / ores) ---
    -- reuse module-level Color3 constants instead of fromRGB() per item (was ~30 allocs/frame)
    local rangeSq = range * range
    local items, n = {}, 0
    for _, e in pairs(entityCache) do
        local h = e.hrp
        if h and h.Parent and (not e.humanoid or e.humanoid.Health > 0) then
            local d = h.Position - pos
            local m2 = d.X*d.X + d.Z*d.Z
            if m2 < rangeSq and m2 > 1 then
                n = n + 1
                items[n] = { wx = h.Position.X, wz = h.Position.Z, m2 = m2,
                    color = e.isPlayer and DOT_COLOR_PLAYER or DOT_COLOR_NPC, sz = 6 }
            end
        end
    end
    for part, _ in pairs(_G.ENI_HELPER.oreGuis) do
        if part.Parent then
            local p = part.Position
            local d = p - pos
            local m2 = d.X*d.X + d.Z*d.Z
            if m2 < rangeSq then
                n = n + 1
                items[n] = { wx = p.X, wz = p.Z, m2 = m2, color = DOT_COLOR_ORE, sz = 5 }
            end
        end
    end
    -- depth sort only every 4 frames (~15Hz) -- dots barely move per frame, full re-sort
    -- at 60Hz is wasted work.  In-between frames keep last sort order.
    if mapFrameCounter % 4 == 0 then
        table.sort(items, function(a,b) return a.m2 > b.m2 end)
    end

    local pool = state.map.dots
    while #pool < n do
        local d = Instance.new("Frame", mapFrame)
        d.AnchorPoint = Vector2.new(0.5, 0.5)
        d.BorderSizePixel = 0
        d.ZIndex = 54
        local c = Instance.new("UICorner", d); c.CornerRadius = UDim.new(1, 0)
        pool[#pool + 1] = d
    end
    for i, dot in ipairs(pool) do
        local it = items[i]
        if it then
            local mx, my = w2m(it.wx, it.wz)
            dot.Position = UDim2.fromOffset(mx, my)
            dot.Size = UDim2.fromOffset(it.sz, it.sz)
            dot.BackgroundColor3 = it.color
            dot.Visible = true
        elseif dot.Visible then
            dot.Visible = false
        end
    end
end))

-- ============================================================
-- MINIMAP DRAG  (click + drag anywhere on the map frame to reposition)
-- Tracks the InputObject so multitouch / mouse don't fight each other.
-- ============================================================
do
    local dragInput, dragStart, startPos
    mapFrame.Active = true
    mapFrame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
            dragStart = input.Position
            startPos = mapFrame.Position
        end
    end)
    mapFrame.InputEnded:Connect(function(input)
        if input == dragInput then dragInput = nil end
    end)
    table.insert(_G.ENI_HELPER.connections, UIS.InputChanged:Connect(function(input)
        if dragInput and (input.UserInputType == Enum.UserInputType.MouseMovement
                          or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            mapFrame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
end

-- ============================================================
-- POI AUTO-REFRESH (every 4s, regardless of tab)
-- ============================================================
task.spawn(function()
    while gui.Parent do
        task.wait(4)
        refreshPOIs()
        renderPOIs()   -- always (WindUI doesn't expose an active-tab flag; cost is negligible)
    end
end)

-- ============================================================
-- PACKET COUNTER  (one-shot install across the process — re-running this on each
-- reload would pile up dozens of OnClientEvent handlers per remote.)
-- ============================================================
if not _G.ENI_PACKET_COUNTER_INSTALLED then
    _G.ENI_PACKET_COUNTER_INSTALLED = true
    _G.ENI_PACKET_COUNT = _G.ENI_PACKET_COUNT or {RECV = 0}
    task.spawn(function()
        task.wait(2)
        for _,r in ipairs(RS:GetDescendants()) do
            if r:IsA("RemoteEvent") or r:IsA("UnreliableRemoteEvent") then
                r.OnClientEvent:Connect(function()
                    _G.ENI_PACKET_COUNT.RECV = _G.ENI_PACKET_COUNT.RECV + 1
                end)
            end
        end
    end)
end
-- mirror the shared counter into local state for the render loop to display
task.spawn(function()
    while gui.Parent do
        state.packetCount.RECV = (_G.ENI_PACKET_COUNT and _G.ENI_PACKET_COUNT.RECV) or 0
        task.wait(0.4)
    end
end)

-- ============================================================
-- MAIN RENDER LOOP
-- ============================================================

task.spawn(function()
    while gui.Parent do
        -- session timer (mins consumed by footer below)
        local mins = math.floor((os.time() - state.started) / 60)

        -- hotbar live view
        local hbLines = {}
        for slot = 1, 12 do
            local uuid = getBindUuid(slot)
            local item = itemByUuid(uuid)
            local marker = ""
            if slot == S.autoEatHungerSlot then marker = "  ← hunger" end
            if slot == S.autoEatThirstSlot then marker = "  ← thirst" end
            table.insert(hbLines, string.format("%2d: %s%s", slot, item and item.realName or "(empty)", marker))
        end
        hbList.Text = table.concat(hbLines, "\n")

        -- combat status -> WindUI paragraph on Combat tab
        local cbText = string.format(
            "InCombat: %s\nAuto-farm: %s\nTarget: %s    Kills: %d\nAuto-mine: %s    Node: %s    Mined: %d",
            tostring(getStat("InCombat")),
            (state.farm and state.farm.status) or "off",
            (state.farm and state.farm.target) or "—",
            (state.farm and state.farm.kills) or 0,
            (state.mine and state.mine.status) or "off",
            (state.mine and state.mine.target) or "—",
            (state.mine and state.mine.count) or 0)
        if state.winduiParagraphs and state.winduiParagraphs.cbStatus then
            pcall(function() state.winduiParagraphs.cbStatus:SetDesc(cbText) end)
        end

        -- log + footer were old hand-rolled UI -- WindUI doesn't have an in-tab
        -- log viewer or footer right now. (TODO: surface state.log via a Settings
        -- paragraph if you want it visible in the new UI.)

        task.wait(0.4)
    end
end)

-- ============================================================
-- DISK STATE DUMP (every 5s)
-- ============================================================
task.spawn(function()
    while gui.Parent do
        task.wait(5)
        if writefile then
            local snap={ts=os.time(), version="5.0", placeId=game.PlaceId, player=lp.Name,
                position=(function() local h=getMyHRP() return h and {x=h.Position.X,y=h.Position.Y,z=h.Position.Z} or nil end)(),
                health=(function() local h=getMyHum() return h and {hp=h.Health,max=h.MaxHealth} or nil end)(),
                settings=S, packetCount=state.packetCount,
                autoEat={count=state.autoEat.eatCount, lastEat=state.autoEat.lastEatTime},
                stats=(function() local r = state.statsRef or findStatsFolder()
                    if not r then return nil end
                    local t={}
                    for _,c in ipairs(r:GetChildren()) do
                        local ok, v = pcall(function() return c.Value end)
                        if ok and (type(v) == "number" or type(v) == "boolean" or type(v) == "string") then t[c.Name]=v end
                    end
                    return t
                end)(),
                hotbar=(function() local t={}; for i=1,12 do
                    local uuid = getBindUuid(i)
                    local item = itemByUuid(uuid)
                    t[tostring(i)] = item and item.realName or nil
                end; return t end)(),
                log_tail=(function() local t={}; for i=math.max(1,#state.log-30),#state.log do table.insert(t,state.log[i]) end; return t end)(),
            }
            local ok,j=pcall(function() return HttpService:JSONEncode(snap) end)
            if ok then pcall(writefile,"helper_state.json",j) end
        end
    end
end)

-- ============================================================
-- HOTKEYS
-- ============================================================
table.insert(_G.ENI_HELPER.connections, UIS.InputBegan:Connect(function(input, processed)
    local kn = input.KeyCode.Name
    -- Hide GUI hotkey: do NOT honor `processed` -- WindUI consumes events when its
    -- window has focus, which made this fire never.  Toggle bypasses that filter.
    if kn == S.keyHideGui then
        pushLog("info", "🪟 hide-GUI hotkey ("..tostring(kn)..") -- toggling window")
        local ok, err = pcall(function()
            if Window then
                if Window.Toggle then Window:Toggle()
                elseif Window.Open and Window.Close then
                    if state.windowClosed then Window:Open(); state.windowClosed = false
                    else Window:Close(); state.windowClosed = true end
                else
                    pushLog("bad", "🪟 Window has neither Toggle nor Open/Close -- WindUI API changed?")
                end
            else
                pushLog("bad", "🪟 Window is nil -- WindUI never loaded?")
            end
        end)
        if not ok then pushLog("bad", "🪟 toggle err: "..tostring(err)) end
        return
    end
    if processed then return end
    if kn == S.keyPanic then
        state.panic = not state.panic
        if state.panic then
            pushLog("bad","🚨 PANIC key pressed — killing autofarm")
            S.autoFarmOn=false; S.autoMineOn=false; S.autoEatOn=false; S.autoRepairOn=false; S.noClip=false; S.espOn=false; S.autoMedOn=false
            S.boatFarmOn=false; S.autoClashOn=false; S.autoRumOn=false; S.autoDeleteOn=false
            S.flyOn=false; S.buyAutoOn=false; S.autoLootOn=false; S.watchdogOn=false
            pushLog("bad", "🚨 PANIC — everything disabled")
        else
            pushLog("good", "panic cleared")
        end
    end
end))

-- ============================================================
-- BOOT
-- ============================================================
-- (loadConfig() now runs early -- right after its definition -- so the UI builds from saved values)
initialEntityScan()
setupCacheListeners()
state.statsRef = findStatsFolder()
task.wait(1)
refreshPOIs()
renderSavedSpots()
-- (setTab dropped -- WindUI Window:SelectTab(1) above already picked Combat)
pushLog("good", "v5 booted")
if state.statsRef then
    pushLog("info", "stats: "..state.statsRef:GetFullName())
end
local inv = findInventoryFolder()
if inv then pushLog("info", "inventory: "..inv:GetFullName().." ("..(#inv:GetChildren())..")") end

-- (silent load)

-- ============================================================
-- PERSIST ACROSS TELEPORTS (queue_on_teleport)
-- Re-inject from _G.HUB_URL if set, else does nothing. Set the URL in
-- your autoexec to enable: _G.HUB_URL = "https://.../main/script.lua"
-- ============================================================
do
    local q = queue_on_teleport or (syn and syn.queue_on_teleport)
    if q and _G.HUB_URL then
        pcall(q, string.format([[
            task.wait(0.5)
            if not _G.ENI_HELPER then
                local ok, src = pcall(function() return game:HttpGet(%q) end)
                if ok and src then local fn = loadstring(src); if fn then pcall(fn) end end
            end
        ]], _G.HUB_URL))
        pushLog("good", "🛰️ teleport-persist armed")
    end
end
