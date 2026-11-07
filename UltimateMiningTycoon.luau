local env = (typeof(getgenv) == "function" and getgenv()) or _G

local old = env.MineAura
if old then
    if old.Stop then pcall(old.Stop) else
        old.running = false
        pcall(function() if old.win then old.win:Kill() end end)
    end
end

local Players         = game:GetService("Players")
local RS              = game:GetService("ReplicatedStorage")
local WS              = game:GetService("Workspace")
local RunService      = game:GetService("RunService")
local UserInputService= game:GetService("UserInputService")
local HttpService     = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local lp    = Players.LocalPlayer
local mouse = lp:GetMouse()
local ControlsLib = require(lp.PlayerScripts.ControlsLib)

if game.PlaceId ~= 18680867089 then
    warn("[MineAura] This script targets Ultimate Mining Tycoon.")
    return
end

local VehicleController  = require(RS.Packages.InnoVehicles.VehicleController)
local ToolBase           = require(RS.Packages.InnoTools.ToolBase)
local Backpack           = require(RS.Packages.InnoTools.Backpack)
local MineTerrain        = require(RS.Packages.Mining.MineTerrain)
local BlockDefinitions   = require(RS.Definitions.BlockDefinitions)
local MiningUtils        = require(RS.Packages.Mining.MiningUtils)
local MiningTime         = require(RS.Packages.Mining.MiningTimeFunction)
local RockDepthFinder    = require(RS.RockDepthFinder)

local state = {
    alive = true, running = false, connections = {},
    busy = false, selling = false, cancelVersion = 0,
    status = "Ready", currentOre = nil,
    nextSell = 0, manualSell = false, mineGeneration = 0,
    nextVehicleSell = 0,
    pendingAction = old and old.pendingAction or nil,
    cellsCache = nil, cellsCacheTime = 0,
    openPosCache = {},
    cfg = {
        AutoSell = false, AutoDriveForward = false, AutoEquip = true,
        SellPercent = 100, SellInterval = 3, SellTimeout = 25,
        ReturnAfterSell = true, VehicleSellDelay = 3,
        ScanDelay = 0.03, CacheTTL = 0.6, ActionTimeout = 8,
        MineReplicationWait = 0.2, MineMoveSettle = 0.12,
        MineMaxAttempts = 3, MineRetryCooldown = 20,
        CargoIdleTime = 20, ReturnToVehicle = true,
        ExplosionCooldownBypass = false,
        ExplosionScanScale = 100,
        ShowExplosionArea = true,
        HopPriorityFull = true, AutoRequeue = true,
    },

    flyEnabled = false,
    flySpeed = 50,
    flyCoordinate = nil,
    flyHRP = nil,
    moveDirection = {
        forward = Vector3.zero, backward = Vector3.zero,
        left = Vector3.zero, right = Vector3.zero,
        up = Vector3.zero, down = Vector3.zero
    },
    ctrlClickTP = false,
    ctrlDelete = false,
    walkSpeed = 16,
    jumpHeight = 50,
    lastJobId = nil,
    hopping = false,
}
env.MineAura = state

local function alive() return state.alive and env.MineAura == state end

local noclipParts={}
local noclipCharacter,noclipAdded
local function restoreNoclip()
    if noclipAdded then noclipAdded:Disconnect();noclipAdded=nil end
    for part,original in pairs(noclipParts) do
        if part.Parent then part.CanCollide=original end
    end
    table.clear(noclipParts)
    noclipCharacter=nil
end
local function trackNoclipPart(part)
    if part:IsA("BasePart") then
        if noclipParts[part]==nil then noclipParts[part]=part.CanCollide end
        part.CanCollide=false
    end
end
function state.SetNoclip(on)
    state.noclipEnabled=on==true and alive()
    if not state.noclipEnabled then restoreNoclip() end
end
local function noclipStep()
    if not alive() or not state.noclipEnabled then return end
    local character=lp.Character
    if character~=noclipCharacter then
        restoreNoclip()
        noclipCharacter=character
        if character then
            noclipAdded=character.DescendantAdded:Connect(trackNoclipPart)
            for _,part in ipairs(character:GetDescendants()) do trackNoclipPart(part) end
        end
    end
    for part in pairs(noclipParts) do
        if part:IsDescendantOf(character) then
            part.CanCollide=false
        else
            if part.Parent then part.CanCollide=noclipParts[part] end
            noclipParts[part]=nil
        end
    end
end
table.insert(state.connections,RunService.Stepped:Connect(noclipStep))

function state.SetExplosionCooldownBypass(on)
    state.cfg.ExplosionCooldownBypass = on == true and alive()
    state.explosionResetStatus = state.explosionReset and "Finishing current respawn and return"
        or (state.cfg.ExplosionCooldownBypass and "Waiting for empty C4/TNT charges" or "Reset bypass: off")
end

local function notify(text)
    state.status = tostring(text)
    if state.win and alive() then state.win:Notify(tostring(text), 4) end
end

local function characterRoot()
    local c = lp.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    local r = c and c:FindFirstChild("HumanoidRootPart")
    if h and h.Health > 0 and r then return c, r, h end
end

local function waitUntil(seconds, predicate)
    local finish = os.clock() + seconds
    repeat
        if not alive() or (predicate and not predicate()) then return false end
        task.wait(0.02)
    until os.clock() >= finish
    return alive() and (not predicate or predicate())
end

local function getUnitDirection()
    local sum = Vector3.zero
    for _, v in pairs(state.moveDirection) do sum = sum + v end
    return sum.Magnitude > 0 and sum.Unit or sum
end

local function resetFlyCoordinate()
    local _, root = characterRoot()
    if not root then return end
    local cam = workspace.CurrentCamera
    state.flyHRP = root
    state.flyCoordinate = CFrame.new(root.Position, cam.CFrame.LookVector + root.Position)
end

local function updateFlyDirection(keyCode, begin)
    local d = begin and 1 or 0
    if keyCode == Enum.KeyCode.W then
        state.moveDirection.forward = Vector3.new(0, 0, -d)
    elseif keyCode == Enum.KeyCode.S then
        state.moveDirection.backward = Vector3.new(0, 0, d)
    elseif keyCode == Enum.KeyCode.A then
        state.moveDirection.left = Vector3.new(-d, 0, 0)
    elseif keyCode == Enum.KeyCode.D then
        state.moveDirection.right = Vector3.new(d, 0, 0)
    elseif keyCode == Enum.KeyCode.Space then
        state.moveDirection.up = Vector3.new(0, d, 0)
    elseif keyCode == Enum.KeyCode.LeftShift then
        state.moveDirection.down = Vector3.new(0, -d, 0)
    end
end

local function flyTeleport(cf, token)
    if state.Legit and state.Legit.enabled then return false,"Disable Legit before teleporting" end
    if token and token ~= state.cancelVersion then return false, "Cancelled" end
    local char, root, humanoid = characterRoot()
    if not root then return false, "Character unavailable" end
    if state.isDriving and state.isDriving() then return false, "Exit the vehicle first" end

    state.flyEnabled = true
    if state.flyToggle then pcall(function() state.flyToggle:Set(true) end) end

    state.flyHRP = root
    state.flyCoordinate = cf

    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.Anchored = false
    root.CFrame = cf
    if char.PivotTo then pcall(function() char:PivotTo(cf) end) end

    return true
end

table.insert(state.connections, UserInputService.InputBegan:Connect(function(input, gp)
    if not alive() or gp then return end
    if not state.flyEnabled then return end
    updateFlyDirection(input.KeyCode, true)
end))

table.insert(state.connections, UserInputService.InputEnded:Connect(function(input)
    if not alive() then return end
    updateFlyDirection(input.KeyCode, false)
end))

table.insert(state.connections, RunService.Heartbeat:Connect(function(dt)
    if not alive() or not state.flyEnabled or state.explosionReset
        or (state.Legit and state.Legit.enabled) then return end
    if state.isDriving and state.isDriving() then return end
    local _, root, humanoid = characterRoot()
    if not root or not humanoid or humanoid.Health <= 0 then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    if not state.flyCoordinate then
        state.flyCoordinate = CFrame.new(root.Position, cam.CFrame.LookVector + root.Position)
    end
    state.flyHRP = root

    local direction = getUnitDirection()
    if direction.Magnitude > 0 then
        state.flyCoordinate = CFrame.fromMatrix(
            state.flyCoordinate.Position,
            cam.CFrame.XVector, cam.CFrame.YVector, cam.CFrame.ZVector
        ) * CFrame.new(direction * state.flySpeed * dt)
    else
        state.flyCoordinate = CFrame.fromMatrix(
            state.flyCoordinate.Position,
            cam.CFrame.XVector, cam.CFrame.YVector, cam.CFrame.ZVector
        )
    end

    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.CFrame = cam.CFrame.Rotation + state.flyCoordinate.Position
end))

table.insert(state.connections, mouse.Button1Down:Connect(function()
    if not alive() or state.explosionReset then return end
    if state.Legit and state.Legit.enabled then return end
    if not UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then return end
    if not mouse.Target then return end

    if state.ctrlClickTP and not (state.isDriving and state.isDriving()) then
        local targetPosition = mouse.Hit.Position + Vector3.new(0, 3, 0)
        local lookVector = workspace.CurrentCamera.CFrame.LookVector
        local targetCFrame = CFrame.new(targetPosition, targetPosition + lookVector)
        local _, root = characterRoot()
        if root then
            root.CFrame = targetCFrame
            if state.flyEnabled then
                state.flyHRP = root
                state.flyCoordinate = targetCFrame
            end
            notify("Teleported to clicked location")
        end
    end

    if state.ctrlDelete then
        mouse.Target:Destroy()
        notify("Object deleted!")
    end
end))

table.insert(state.connections, lp.CharacterAdded:Connect(function()
    task.wait(0.5)
    if not alive() then return end
    if state.flyEnabled then resetFlyCoordinate() end
    local _, _, humanoid = characterRoot()
    if humanoid then
        if state.Legit and state.Legit.enabled then
            state.walkSpeed,state.jumpHeight=humanoid.WalkSpeed,humanoid.JumpPower
        else
            humanoid.WalkSpeed = state.walkSpeed
            humanoid.JumpPower = state.jumpHeight
        end
    end
    state.openPosCache = {}
    state.cellsCache = nil
end))

local function releaseAutoDrive()
    if state.stopAutodrive then state.stopAutodrive() end
end
state.releaseAutoDrive = releaseAutoDrive

function state.Stop()
    if state.Legit then state.Legit.SetEnabled(false) state.Legit.Release() end
    state.SetNoclip(false)
    state.SetExplosionCooldownBypass(false)
    if state.CancelExplosionReset then state.CancelExplosionReset() end
    state.alive = false
    if state.ClearExplosionAreaVisual then state.ClearExplosionAreaVisual() end
    state.cfg.AutoDriveForward = false
    releaseAutoDrive()
    if state.cancelAction then state.cancelAction() end
    if state.stopAutodrive then state.stopAutodrive() end
    state.running = false
    state.cancelVersion += 1
    for _, c in ipairs(state.connections) do c:Disconnect() end
    if state.win then pcall(function() state.win:Kill() end) end
end

----------------------------------------------------------------
-- WALL GUARD
----------------------------------------------------------------

local terrainRay = RaycastParams.new()
terrainRay.FilterType = Enum.RaycastFilterType.Include
terrainRay.FilterDescendantsInstances = {WS.Terrain}

----------------------------------------------------------------
-- SERVER HOP (FIXED v22)
----------------------------------------------------------------

local HOP_FILE = "mineaura_lastjob.txt"

local function persistLastJob(jobId)
    state.lastJobId = jobId
    pcall(function()
        if writefile then writefile(HOP_FILE, jobId or "") end
    end)
end

local function loadLastJob()
    if state.lastJobId then return state.lastJobId end
    local id
    pcall(function()
        if readfile and isfile and isfile(HOP_FILE) then
            id = readfile(HOP_FILE)
        end
    end)
    if type(id) ~= "string" or id == "" then id = nil end
    state.lastJobId = id
    return id
end

local function serverHop(manual)
    if state.hopping then return end
    state.hopping = true

    local currentJob  = game.JobId
    local previousJob = state.lastJobId
    persistLastJob(currentJob)

    notify("Fetching server list…")

    local placeId = game.PlaceId
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(placeId)
    local ok, response = pcall(function() return game:HttpGet(url) end)
    if not ok or type(response) ~= "string" then
        state.hopping = false
        notify("Server hop: could not fetch server list")
        return
    end
    local decoded
    ok, decoded = pcall(function() return HttpService:JSONDecode(response) end)
    if not ok or not decoded or not decoded.data then
        state.hopping = false
        notify("Server hop: bad response")
        return
    end

    local blocked = { [currentJob] = true }
    if previousJob and previousJob ~= "" then blocked[previousJob] = true end

    local function collect(requireSpace)
        local out = {}
        for _, srv in ipairs(decoded.data) do
            local id = srv.id
            if id and not blocked[id] then
                local playing = srv.playing or 0
                local maxP    = srv.maxPlayers or 0
                if (not requireSpace) or (playing < maxP) then
                    table.insert(out, srv)
                end
            end
        end
        return out
    end

    local candidates = collect(state.cfg.HopPriorityFull)
    if #candidates == 0 then candidates = collect(false) end
    if #candidates == 0 then
        for _, srv in ipairs(decoded.data) do
            if srv.id and not blocked[srv.id] then
                table.insert(candidates, srv)
            end
        end
    end

    if #candidates == 0 then
        state.hopping = false
        notify("Server hop: no eligible servers")
        return
    end

    table.sort(candidates, function(a, b)
        local pa = (a.playing or 0) / math.max(1, a.maxPlayers or 1)
        local pb = (b.playing or 0) / math.max(1, b.maxPlayers or 1)
        return pa < pb
    end)

    local attempts = math.min(#candidates, 5)
    local queue = {}
    for i = 1, attempts do table.insert(queue, candidates[i]) end

    if state.cfg.AutoRequeue then
        pcall(function()
            if queue_on_teleport then
                local src = debug.getinfo(1, "S").source
                if type(src) == "string" and src:sub(1, 1) == "@" then
                    local path = src:sub(2)
                    if readfile and isfile and isfile(path) then
                        queue_on_teleport(readfile(path))
                    end
                end
            end
        end)
    end

    local hopFailedConn
    hopFailedConn = TeleportService.TeleportInitFailed:Connect(function(_, result, errMsg)
        if not state.hopping then return end
        if result == Enum.TeleportResult.Flooded
            or result == Enum.TeleportResult.Failure
            or result == Enum.TeleportResult.GameFull
            or result == Enum.TeleportResult.GameNotFound then
            table.remove(queue, 1)
            if #queue > 0 then
                local nextPick = queue[1]
                notify("Teleport failed, retrying next server…")
                local opts = Instance.new("TeleportOptions")
                opts.ServerInstanceId = nextPick.id
                pcall(function()
                    TeleportService:TeleportAsync(placeId, {lp}, opts)
                end)
            else
                notify("Teleport failed: "..tostring(errMsg))
                state.hopping = false
                if hopFailedConn then hopFailedConn:Disconnect() end
            end
        end
    end)

    task.wait(0.2)
    local pick = queue[1]
    notify(("Hopping to %s (1/%d)…"):format(tostring(pick.id):sub(1, 8), #queue))

    local opts = Instance.new("TeleportOptions")
    opts.ServerInstanceId = pick.id

    local okTp = pcall(function()
        TeleportService:TeleportAsync(placeId, {lp}, opts)
    end)
    if not okTp then
        okTp = pcall(function()
            TeleportService:TeleportToPlaceInstance(placeId, pick.id, lp)
        end)
    end
    if not okTp then
        state.hopping = false
        notify("Server hop failed (teleport call errored)")
    end
end

do
    local startJob = game.JobId
    local previous = loadLastJob()
    if previous and previous ~= "" and previous == startJob then
        warn("[MineAura] Joined the same server as last time.")
        notify("Joined the same server as last time")
    end
end

----------------------------------------------------------------
-- CARGO CACHE
----------------------------------------------------------------

local cargoCache = {}
local function readCargo(kind)
    local folder = RS.Packages.Mining.CargoVolume
    local value = folder:FindFirstChild(tostring(lp.UserId).."_"..kind)
    if not value then cargoCache[kind] = nil return end
    local raw = value.Value
    local cached = cargoCache[kind]
    if cached and cached.object == value and cached.raw == raw then
        return cached.count, cached.capacity
    end
    local ok, data = pcall(HttpService.JSONDecode, HttpService, raw)
    if not ok or type(data) ~= "table" or type(data.Size) ~= "table"
        or type(data.OreIds) ~= "table" then return end
    local x, y, z = tonumber(data.Size.X), tonumber(data.Size.Y), tonumber(data.Size.Z)
    if not x or not y or not z then return end
    local capacity = x * y * z
    if capacity <= 0 then return end
    local count = #data.OreIds
    cargoCache[kind] = {object=value, raw=raw, count=count, capacity=capacity}
    return count, capacity
end
local function cargoStatus() return readCargo("Backpack") end
local function vehicleCargoStatus() return readCargo("Vehicle") end
local function getOwnedVehicle() return VehicleController.VehiclesByOwnerId[lp.UserId] end

function state.isDriving()
    local _, root, humanoid = characterRoot()
    if humanoid and humanoid.SeatPart then return true end
    local vehicle = getOwnedVehicle()
    local assembly = root and root.AssemblyRootPart
    if assembly and vehicle and vehicle.Model and assembly:IsDescendantOf(vehicle.Model) then return true end
    local driven = VehicleController.CurrentDrivenVehicle
    local interface = driven and driven.Components and driven.Components.PlayerVehicleInterface
    return interface and interface.ControlsActive == true or false
end

----------------------------------------------------------------
-- AUTO DRIVE FORWARD
----------------------------------------------------------------

local function exitVehicle(valid)
    if not state.isDriving() then return true end
    state.status="Exiting vehicle automatically"
    local controls=ControlsLib
    local event=controls.BindingStartEvents.EnterExitSeat
    if not event or not event:IsA("BindableEvent") then return false end
    local deadline,lastTry=os.clock()+5,0
    while valid() and state.isDriving() and os.clock()<deadline do
        if os.clock()-lastTry>=1 then event:Fire() lastTry=os.clock() end
        task.wait(0.1)
    end
    return valid() and not state.isDriving()
end

local function pointOf(v)
    if not v or not v.Parent then return end
    if v:IsA("Attachment") then return v.WorldCFrame end
    if v:IsA("BasePart") then return v.CFrame end
    for _, name in ipairs({"PlayerSpot","ActivationPoint","SpawnPoint","Spawn","BuildPlot"}) do
        local p = v:FindFirstChild(name, true)
        if p and p:IsA("BasePart") then return p.CFrame end
    end
    if v:IsA("Model") and v:FindFirstChildWhichIsA("BasePart", true) then return v:GetPivot() end
end

local function unloaderPrompt()
    local folder = WS:FindFirstChild("FactoryGridItemsServer")
    folder = folder and folder:FindFirstChild(lp.Name)
    local volume = folder and folder:FindFirstChild("CargoVolume")
    if volume and tostring(volume:GetAttribute("OwnerId")) == tostring(lp.UserId) then
        return volume:FindFirstChild("CargoPrompt", true)
    end
end

local function vehicleCargoPrompt(vehicle)
    local model = vehicle and vehicle.Model
    local volume = model and model:FindFirstChild("CargoVolume")
    return volume and volume:FindFirstChild("CargoPrompt", true)
end

local function cancelAction()
    local pending = state.pendingAction
    if not pending then return end
    -- Cancelling a local coroutine/Promise cannot recall an InvokeServer.
    -- Retain its slot until the original response settles, including reload.
    pending.abandoned=true
    if pending.done then state.pendingAction=nil end
end
state.cancelAction = cancelAction

local function performAction(factory, valid)
    if state.pendingAction and state.pendingAction.done then state.pendingAction=nil end
    if state.pendingAction then return false, "Action already pending" end
    if not valid() then return false,"Cancelled" end
    local pending = {started=os.clock()}
    state.pendingAction = pending
    pending.thread = task.spawn(function()
        local ok, result = pcall(function()
            if not valid() then return false end
            local p = factory()
            if type(p) == "table" and type(p.await) == "function" then
                pending.promise = p
                local success, value, detail = p:await()
                pending.detail = detail
                if not success then error(tostring(value)) end
                return value
            end
            return p
        end)
        pending.ok, pending.result, pending.done = ok, result, true
        if pending.abandoned and state.pendingAction==pending then state.pendingAction=nil end
    end)
    while not pending.done and valid() and os.clock()-pending.started < state.cfg.ActionTimeout do
        task.wait(0.03)
    end
    local validNow = valid()
    if state.pendingAction == pending then cancelAction() end
    if not validNow then return false, "Cancelled" end
    if not pending.done then return false, "Server response timed out" end
    return pending.ok and pending.result ~= false, pending.result, pending.detail
end

-- MineBlock predicts Air and swallows rejection; await server acceptance first.
local function mineConfirmed(client, terrain, pos, valid)
    if not valid() then return false, "Cancelled" end
    if not client.ActivateRemote then return false, "Pickaxe remote not ready" end
    local ok, accepted, correction = performAction(function()
        if not valid() then return false end
        return client.ActivateRemote:InvokeServer(pos)
    end, valid)
    if not ok or accepted ~= true then
        if not valid() then return false, "Cancelled" end
        state.mineRejected = (state.mineRejected or 0) + 1
        state.lastMineReject = type(correction)=="table"
            and tostring(correction.Ore or correction.Block) or tostring(correction or accepted)
        -- The game returns its authoritative cell with a rejection. Refresh
        -- stale/generated cells, but never count this correction as mining.
        if valid() and type(correction)=="table" and type(correction.Block)=="string" then
            pcall(function() terrain:Set(pos,correction) end)
            state.loadedTerrainCells=nil
            state.openPosCache={}
        end
        return false, accepted == false and "Server rejected mining" or tostring(accepted)
    end
    pcall(function()
        terrain:Set(pos, {Block="Air"})
        terrain:GenerateAround(pos)
    end)
    state.cellsCache=nil
    state.loadedTerrainCells=nil
    state.failedTargets={}
    state.openPosCache={}
    return true
end

local function invalidateMining()
    state.mineGeneration += 1
    state.cellsCache = nil
    state.openPosCache = {}
    state.failedTargets = {}
    state.currentOre = nil
    state.targetPrice,state.targetDistance=nil,nil
end

local function atPrompt(prompt, valid)
    if not valid() then return false, "Cancelled" end
    if not prompt or not prompt.Parent then return false, "Cargo prompt unavailable" end
    local cf = pointOf(prompt.Parent)
    if not cf then return false, "Cargo position unavailable" end
    local _, root = characterRoot()
    if not root then return false, "Character unavailable" end
    local distance = (root.Position-cf.Position).Magnitude
    if distance > math.max(1, prompt.MaxActivationDistance-1) then
        local offset = math.min(3, math.max(0.5, prompt.MaxActivationDistance*0.4))
        local ok, why = flyTeleport(cf*CFrame.new(0,0,offset), state.cancelVersion)
        if not ok then return false, why end
        if not waitUntil(0.2, valid) then return false, "Cancelled" end
    end
    return true
end

local function triggerCargo(prompt, expectedAction, valid)
    local ok, why=atPrompt(prompt,valid)
    if not ok then error(why) end
    if not valid() or not prompt.Enabled or prompt.ActionText~=expectedAction then return false end
    if typeof(fireproximityprompt)=="function" then
        local fired=performAction(function() fireproximityprompt(prompt) return true end,valid)
        return fired
    end
    local began,err=pcall(function() prompt:InputHoldBegin() end)
    if not began then error(err) end
    local held=waitUntil(math.min(prompt.HoldDuration+0.2,state.cfg.ActionTimeout),valid)
    pcall(function() prompt:InputHoldEnd() end)
    return held
end

local function resumeVehicle(vehicle, valid)
    if not vehicle or getOwnedVehicle()~=vehicle or not vehicle.Model.Parent then return false end
    local seat=vehicle.DriversSeat
    local prompt=seat and seat:FindFirstChildWhichIsA("ProximityPrompt",true)
    if not prompt then return false end
    local deadline=os.clock()+4
    while valid() and not state.isDriving() and os.clock()<deadline do
        triggerCargo(prompt,"Drive",valid)
        local untilTime=os.clock()+0.7
        repeat task.wait(0.1) until state.isDriving() or os.clock()>=untilTime or not valid()
    end
    return state.isDriving()
end
local function unloadBackpack(valid)
    local deadline, stalled, lastCount, lastTrigger = os.clock()+state.cfg.SellTimeout, os.clock(), nil, 0
    while valid() and os.clock()<deadline do
        local count = cargoStatus()
        if count == nil then error("Backpack unavailable") end
        if count == 0 then return true end
        if lastCount == nil or count < lastCount then stalled = os.clock() end
        lastCount = count
        if os.clock()-stalled > 6 then error("Unloader has made no progress; retrying later") end
        local prompt = unloaderPrompt()
        local ok, why = atPrompt(prompt, valid)
        if not ok then error(why) end
        state.status = "Unloading backpack: "..count
        if os.clock()-lastTrigger >= 0.6 then
            lastTrigger = os.clock()
            triggerCargo(prompt, "Add Items", valid)
        end
        waitUntil(0.1, valid)
    end
    error(valid() and "Unloader timed out" or "Cancelled")
end

local function sellCargo(kind, manual)
    if state.Legit and state.Legit.enabled then
        state.status="Legit: use automatic physical backpack unloading or disable Legit"
        return false
    end
    if state.busy then return false end
    local count
    if kind == "Vehicle" then count=vehicleCargoStatus() else count=cargoStatus() end
    if not count or count == 0 then state.status=kind.." cargo is empty/unavailable" return false end
    local wasDriving=state.isDriving()
    local exitToken=state.cancelVersion
    local function active()
        return alive() and exitToken==state.cancelVersion and (manual or state.cfg.AutoSell)
    end
    if not exitVehicle(active) then state.status="Vehicle exit pending; retrying" return false end
    local char, root = characterRoot()
    if not root then return false end
    local token, back, wasFlying = state.cancelVersion, root.CFrame, state.flyEnabled
    local vehicle = getOwnedVehicle()
    local function valid()
        local c, r, h = characterRoot()
        return alive() and c == char and r == root and h.Health > 0
            and token == state.cancelVersion and not state.isDriving()
            and (manual or state.cfg.AutoSell)
    end
    state.busy, state.selling = true, true
    invalidateMining()
    local ok, err = pcall(function()
        if kind == "Backpack" then unloadBackpack(valid) return end
        assert(vehicle and vehicle.Model and vehicle.Model.Parent, "Vehicle unavailable")
        local started, trips = os.clock(), 0
        while valid() do
            local remaining, capacity = vehicleCargoStatus()
            assert(remaining ~= nil and getOwnedVehicle() == vehicle, "Vehicle changed/unavailable")
            if remaining == 0 then return end
            assert(os.clock()-started < 180 and trips < 100, "Vehicle unload trip limit reached")
            unloadBackpack(valid)
            local prompt = vehicleCargoPrompt(vehicle)
            local ready, why = atPrompt(prompt, valid)
            assert(ready, why)
            state.status = "Taking vehicle cargo: "..remaining
            local deadline, lastTrigger = os.clock()+7, 0
            while valid() and os.clock()<deadline do
                local backpack = cargoStatus()
                if backpack and backpack > 0 then break end
                if os.clock()-lastTrigger>=0.75 then
                    lastTrigger=os.clock()
                    triggerCargo(prompt,"Take Items",valid)
                end
                waitUntil(0.1, valid)
            end
            local backpack = cargoStatus()
            assert(backpack and backpack > 0, "Vehicle cargo transfer made no progress")
            unloadBackpack(valid)
            local after = vehicleCargoStatus()
            assert(after ~= nil and after < remaining, "Vehicle cargo did not decrease")
            trips += 1
        end
        error("Cancelled")
    end)
    if alive() and lp.Character == char and root.Parent and not state.isDriving() then
        if state.cfg.ReturnAfterSell then pcall(flyTeleport, back, state.cancelVersion) end
        state.flyEnabled = wasFlying
        if state.flyToggle then pcall(function() state.flyToggle:Set(wasFlying) end) end
    end
    if wasDriving and state.cfg.ReturnToVehicle and not state.running and valid() then
        local resumed,result=pcall(resumeVehicle,vehicle,valid)
        state.lastResumeError=(not resumed or not result) and "Driver seat re-entry pending" or nil
    end
    if alive() and lp.Character==char then
        state.flyEnabled=wasFlying
        if state.flyToggle then pcall(function() state.flyToggle:Set(wasFlying) end) end
    end
    state.busy, state.selling = false, false
    invalidateMining()
    if ok then state.sellCycles=(state.sellCycles or 0)+1 end
    state.status = ok and (kind.." cargo unloaded") or ("Unload retry: "..tostring(err))
    return ok
end

local function pickaxeClient()
    local char = lp.Character
    if not char then return end

    for _, model in ipairs(char:GetChildren()) do
        local tool = ToolBase.ToolsByModel[model]
        local client = tool and tool:FindComponentByName("PickaxeClient")
        if client and tool.Equipped then
            return client, tool
        end
    end

    if state.cfg.AutoEquip then
        for _, bag in pairs(Backpack.ByFolder) do
            if bag.Folder and bag.Folder:IsDescendantOf(lp) and not bag.Disabled then
                for tool in pairs(bag.ContainedTools) do
                    local client = tool:FindComponentByName("PickaxeClient")
                    if client then
                        if not tool.Equipped then
                            bag:EquipTool(tool)
                        end
                        local deadline = os.clock() + 2
                        while alive() and lp.Character == char and not tool.Equipped and os.clock() < deadline do
                            task.wait(0.03)
                        end
                        if tool.Equipped and tool.Model.Parent == char then
                            return client, tool
                        end
                    end
                end
            end
        end
    end
end
local function pickaxeStrength()
    local ok, n = pcall(MiningUtils.GetPlayerPickaxeHardnessClient)
    return ok and tonumber(n) or 0
end
local function cellAt(position)
    local c = WS.Terrain:WorldToCell(position)
    return Vector3int16.new(c.X,c.Y,c.Z)
end
local function worldAt(c) return WS.Terrain:CellCenterToWorld(c.X,c.Y,c.Z) end
local function targetKey(t) return tostring(t.pos)..":"..t.id end

local function placedWorldPosition(obj)
    if not obj or not obj.Parent then return end
    if obj:IsA("BasePart") then return obj.Position end
    if obj:IsA("Attachment") then return obj.WorldPosition end
    if obj:IsA("Model") then
        local ok,pivot=pcall(function() return obj:GetPivot() end)
        if ok and pivot then return pivot.Position end
    end
    local part=obj:FindFirstChildWhichIsA("BasePart",true)
    return part and part.Position
end

local function generatedCellAt(terrain,pos)
    local generator=terrain and terrain._MineGeneration
    local origin=terrain and terrain._MineOrigin
    if not generator or not origin then return end
    local ok,result=pcall(function()
        return generator:ComputeMaterial(pos-origin)
    end)
    if not ok or type(result)~="table" or result.BoundaryIssue=="Front" then return end
    if not result.Block and not result.Ore then return end
    return {Block=result.Block,Ore=result.Ore}
end

local function resolvePlacedOreCell(terrain,world)
    local pos=cellAt(world)
    local cell=terrain:Get(pos)
    if cell then
        if cell.Ore then return pos,cell,false end
        return
    end
    cell=generatedCellAt(terrain,pos)
    if cell and cell.Ore then return pos,cell,true end
end
local function visibleFace(from, target)
    local delta = target-from
    if delta.Magnitude < 0.1 then return false end
    local hit = WS:Raycast(from, delta.Unit*(delta.Magnitude+2), terrainRay)
    return hit and cellAt(hit.Position-hit.Normal*0.5) == cellAt(target)
end
local function openPosition(terrain, position)
    local key = tostring(cellAt(position))
    local cached = state.openPosCache[key]
    if cached and os.clock()-cached.time < 0.5 then return cached.open end
    local _, root, h = characterRoot()
    if not root then return false end
    local below = math.max(3,h.HipHeight+root.Size.Y/2)+0.1
    local low, high = position-Vector3.new(1.2,below,1.2),position+Vector3.new(1.2,2.8,1.2)
    local a,b = cellAt(low),cellAt(high)
    local open,unknown = true,false
    for x=a.X,b.X do for y=a.Y,b.Y do for z=a.Z,b.Z do
        local cell = terrain:Get(Vector3int16.new(x,y,z))
        if not cell then unknown=true
        elseif cell.Block ~= "Air" or cell.Ore then open=false break end
    end end end
    if open and unknown then
        local _,occupancy=WS.Terrain:ReadVoxels(Region3.new(low,high):ExpandToGrid(4),4)
        for _,xs in ipairs(occupancy) do for _,ys in ipairs(xs) do for _,value in ipairs(ys) do
            if value>0 then open=false break end
        end end end
    end
    state.openPosCache[key]={time=os.clock(),open=open}
    return open
end
local function insideMine(terrain,position)
    local generator=terrain and terrain._MineGeneration
    local origin=terrain and terrain._MineOrigin
    if not generator or not origin then return false,"Mine boundaries are unavailable" end
    local cell=terrain:Get(cellAt(position))
    if not cell or cell.Block~="Air" or cell.Ore then
        return false,"Player position is not confirmed as open space in the mine"
    end
    local _,root,h=characterRoot()
    if not root or not h then return false,"Character unavailable" end
    local below=math.max(3,h.HipHeight+root.Size.Y/2)+0.1
    local low=cellAt(position-Vector3.new(1.2,below,1.2))
    local high=cellAt(position+Vector3.new(1.2,2.8,1.2))
    local cached=state.mineInteriorCache
    if cached and cached.terrain==terrain and cached.generator==generator
        and cached.origin==origin and cached.low==low and cached.high==high
        and os.clock()-cached.time<0.2 then return true end
    -- Check the full standing volume, not just the root at a mine edge.
    for x=low.X,high.X do for y=low.Y,high.Y do for z=low.Z,high.Z do
        local ok,result=pcall(function()
            return generator:ComputeMaterial(Vector3int16.new(x,y,z)-origin)
        end)
        if not ok or type(result)~="table" or (not result.Block and not result.Ore) then
            return false,"Could not verify mine boundaries"
        end
        local def=BlockDefinitions[result.Ore or result.Block]
        if result.InBounds==false or result.BoundaryIssue
            or (def and def.Types and def.Types.Boundary) then
            return false,"Player is outside the mine interior"
        end
    end end end
    state.mineInteriorCache={terrain=terrain,generator=generator,origin=origin,
        low=low,high=high,time=os.clock()}
    return true
end
function state.IsInsideMine(position)
    local _,root=characterRoot()
    if not position and not root then return false,"Character unavailable" end
    return insideMine(MineTerrain.GetInstance(),position or root.Position)
end

local function getTerrainCells(terrain, valid)
    local cells,seen={},{}
    local folder=WS:FindFirstChild("PlacedOre")
    local children=folder and folder:GetChildren() or {}
    local resolved,syntheticCount=0,0
    local sliceStart=os.clock()
    for i,obj in ipairs(children) do
        local world=placedWorldPosition(obj)
        if world then
            local pos,cell,synthetic=resolvePlacedOreCell(terrain,world)
            if pos and cell then
                resolved+=1
                if synthetic then syntheticCount+=1 end
                local key=tostring(pos)
                if not seen[key] then
                    seen[key]=true
                    cells[#cells+1]={pos=pos,cell=cell,fromPlaced=true,
                        source="PlacedOre",synthetic=synthetic,instance=obj}
                end
            end
        end
        if i%64==0 and os.clock()-sliceStart>=0.003 then
            task.wait()
            if not valid() then return {} end
            sliceStart=os.clock()
        end
    end
    state.placedOreSeen=#children
    state.placedOreResolved=resolved
    state.placedOreSynthetic=syntheticCount
    -- PlacedOre is streamed visual content, not the complete loaded ore store.
    local cached=state.loadedTerrainCells
    if not cached or cached.terrain~=terrain or os.clock()-cached.time>=(state.cfg.CacheTTL or 0.6) then
        local loaded,airBuckets={},{}
        local store=terrain and terrain._Cells
        local list=store and type(store.List)=="function" and store:List() or {}
        local scanned,airCount,airBucketCount=0,0,0
        sliceStart=os.clock()
        for pos,cell in pairs(list) do
            scanned+=1
            if typeof(pos)=="Vector3int16" and type(cell)=="table" and cell.Block=="Air" and not cell.Ore then
                airCount+=1
                local x,y,z=math.floor(pos.X/8),math.floor(pos.Y/8),math.floor(pos.Z/8)
                local key=x..":"..y..":"..z
                local bucket=airBuckets[key]
                if not bucket then
                    bucket={x=x,y=y,z=z,cells={}};airBuckets[key]=bucket;airBucketCount+=1
                end
                bucket.cells[#bucket.cells+1]=pos
            end
            if typeof(pos)=="Vector3int16" and type(cell)=="table" and cell.Ore then
                loaded[#loaded+1]={pos=pos,cell=cell,source="Terrain"}
            end
            if scanned%2048==0 and os.clock()-sliceStart>=0.003 then
                task.wait()
                if not valid() then return {} end
                sliceStart=os.clock()
            end
        end
        cached={terrain=terrain,time=os.clock(),cells=loaded,airBuckets=airBuckets,airBucketCount=airBucketCount}
        if state.lastTerrainAirCount and (state.lastTerrainAirCount~=airCount
            or state.lastTerrainCellCount~=scanned) then state.failedTargets={} end
        state.lastTerrainAirCount,state.lastTerrainCellCount=airCount,scanned
        state.loadedTerrainCells=cached
        state.terrainCellsSeen=scanned
    end
    state.terrainOreSeen=#cached.cells
    for _,entry in ipairs(cached.cells) do
        local key=tostring(entry.pos)
        if not seen[key] then
            seen[key]=true
            cells[#cells+1]=entry
        end
    end
    return cells
end

local function hasHigherPricedOre(terrain,target,valid,reachable)
    valid=valid or function() return true end
    if not valid() or type(reachable)~="function" then return false end
    local strength,speed=pickaxeStrength(),MiningUtils.GetPlayerPickaxeSpeedClient()
    local now=os.clock()
    for _,entry in ipairs(getTerrainCells(terrain,valid)) do
        local pos=entry.pos
        local cell=terrain:Get(pos) or (entry.instance and entry.instance.Parent and entry.cell)
        if cell then
            local id=cell and cell.Ore
            local def=id and BlockDefinitions[id]
            if def and (tonumber(def.Value) or 0)>target.value
                and def.Hardness and def.Hardness<=strength and not def.ExplosiveOnly
                and not (def.Types and (def.Types.Terrain or def.Types.Boundary)) then
                local expiry=state.failedTargets and state.failedTargets[tostring(pos)..":"..id]
                local duration=MiningTime(speed,strength,def.Hardness)
                if (not expiry or expiry<=now) and duration and duration<999 then
                    -- Retry expiry only makes a target eligible for another probe.
                    -- It must have a usable position before interrupting a mining hit.
                    local candidate={pos=pos,world=worldAt(pos),id=id,def=def,
                        value=tonumber(def.Value) or 0,isOre=true}
                    local accessible=reachable(candidate)
                    if not valid() then return false end
                    if accessible then return true end
                    state.failedTargets=state.failedTargets or {}
                    state.failedTargets[tostring(pos)..":"..id]=os.clock()+4
                end
            end
        end
    end
    return false
end
local function targetBefore(a,b)
    if a.isOre~=b.isOre then return a.isOre end
    if a.value~=b.value then return a.value>b.value end
    if a.fromPlaced~=b.fromPlaced then return a.fromPlaced end
    if not a.isOre and a.depth~=b.depth then return a.depth>b.depth end
    if a.distance~=b.distance then return a.distance<b.distance end
    return targetKey(a)<targetKey(b)
end

local function findMiningStand(terrain,target,root,range,strength,valid)
    -- Search actual loaded air across the tool's entire live reach. No fixed
    -- compass offsets: newly excavated/streamed cells participate immediately.
    local stands={}
    local checked,sliceStart=0,os.clock()
    if not valid() then return end
    local cached=state.loadedTerrainCells
    if not cached or cached.terrain~=terrain or not cached.airBuckets
        or os.clock()-cached.time>=(state.cfg.CacheTTL or 0.6) then
        getTerrainCells(terrain,valid)
        cached=state.loadedTerrainCells
    end
    if not valid() or not cached or not cached.airBuckets then return end
    local radius=(range+2)/4
    local lowX,highX=math.floor((target.pos.X-radius)/8),math.floor((target.pos.X+radius)/8)
    local lowY,highY=math.floor((target.pos.Y-radius)/8),math.floor((target.pos.Y+radius)/8)
    local lowZ,highZ=math.floor((target.pos.Z-radius)/8),math.floor((target.pos.Z+radius)/8)
    local nearby={}
    local bucketCount=cached.airBucketCount
    local volume=(highX-lowX+1)*(highY-lowY+1)*(highZ-lowZ+1)
    -- Bound wide tool queries by occupied buckets, never an enormous empty cube.
    if volume<=bucketCount then
        for x=lowX,highX do for y=lowY,highY do for z=lowZ,highZ do
            local bucket=cached.airBuckets[x..":"..y..":"..z]
            if bucket then nearby[#nearby+1]=bucket end
        end end end
    else
        for _,bucket in pairs(cached.airBuckets) do
            if bucket.x>=lowX and bucket.x<=highX and bucket.y>=lowY and bucket.y<=highY
                and bucket.z>=lowZ and bucket.z<=highZ then nearby[#nearby+1]=bucket end
        end
    end
    for _,bucket in ipairs(nearby) do for _,pos in ipairs(bucket.cells) do
        local cell=terrain:Get(pos)
        if cell and cell.Block=="Air" and not cell.Ore
            and math.abs(pos.X-target.pos.X)*4<=range+2
            and math.abs(pos.Y-target.pos.Y)*4<=range+2
            and math.abs(pos.Z-target.pos.Z)*4<=range+2 then
            local base=worldAt(pos)
            for _,lift in ipairs({0,2}) do
                local stand=base+Vector3.new(0,lift,0)
                local distance=(stand-target.world).Magnitude
                if distance<=range-0.5 and insideMine(terrain,stand)
                    and openPosition(terrain,stand) then
                    stands[#stands+1]={stand=stand,distance=distance,
                        travel=(stand-root.Position).Magnitude}
                end
            end
        end
        checked+=1
        if checked%128==0 then
            if os.clock()-sliceStart>=0.003 then task.wait();sliceStart=os.clock() end
            if not valid() then return end
        end
    end end
    state.standCellsChecked=checked
    table.sort(stands,function(a,b)
        if a.distance~=b.distance then return a.distance<b.distance end
        if a.travel~=b.travel then return a.travel<b.travel end
        return tostring(a.stand)<tostring(b.stand)
    end)
    local access
    for _,entry in ipairs(stands) do
        if not valid() then return end
        -- Ore requests are accepted from an interior, in-range open stand even
        -- when the center ray hits the host rock. Keep ray checks for stone.
        if target.isOre then return entry.stand,false end
        if visibleFace(entry.stand,target.world) then return entry.stand,false end
        local delta=target.world-entry.stand
        local hit=WS:Raycast(entry.stand,delta.Unit*(delta.Magnitude+2),terrainRay)
        local cell=hit and terrain:Get(cellAt(hit.Position-hit.Normal*0.5))
        local def=cell and not cell.Ore and BlockDefinitions[cell.Block]
        if not access and def and def.Types and def.Types.Stone
            and not def.Types.Boundary and not def.ExplosiveOnly
            and def.Hardness and def.Hardness<=strength then access=entry.stand end
    end
    return access,access~=nil
end

local function chooseTarget(client, terrain, root, valid)
    local strength=pickaxeStrength()
    local speed=MiningUtils.GetPlayerPickaxeSpeedClient()
    local range=tonumber(client.Tool.Definition.Stats.Range) or 12
    local candidates,now={},os.clock()
    local durations={}
    state.failedTargets=state.failedTargets or {}
    for key,expiry in pairs(state.failedTargets) do if expiry<=now then state.failedTargets[key]=nil end end
    for i,entry in ipairs(getTerrainCells(terrain,valid)) do
        if i%1500==0 then task.wait() if not valid() then return end end
        local cell=terrain:Get(entry.pos) or (entry.instance and entry.instance.Parent and entry.cell)
        local id=cell and cell.Ore
        local def=id and BlockDefinitions[id]
        if def and def.Hardness and not def.ExplosiveOnly and def.Hardness<=strength
            and not (def.Types and (def.Types.Terrain or def.Types.Boundary)) then
            local world=worldAt(entry.pos)
            local duration=durations[def.Hardness]
            if duration==nil then
                duration=MiningTime(speed,strength,def.Hardness) or false
                durations[def.Hardness]=duration
            end
            local target={pos=entry.pos,world=world,id=id,def=def,duration=duration,
                distance=(world-root.Position).Magnitude,isOre=not not cell.Ore,
                value=tonumber(def.Value) or 0,depth=0,
                fromPlaced=entry.fromPlaced==true,synthetic=entry.synthetic==true,
                cellSnapshot={Block=cell.Block,Ore=cell.Ore},instance=entry.instance}
            if duration and duration<999 and not state.failedTargets[targetKey(target)] then
                table.insert(candidates,target)
            end
        end
    end
    table.sort(candidates,targetBefore)
    for i,target in ipairs(candidates) do
        if not valid() then return end
        if target.distance<=range and insideMine(terrain,root.Position)
            and (target.isOre or visibleFace(root.Position,target.world)) then return target,range end
        local stand,access=findMiningStand(terrain,target,root,range,strength,valid)
        if stand then
            target.stand,target.needsAccess=stand,access
            return target,range
        end
        state.failedTargets[targetKey(target)]=now+4
        if i%8==0 then task.wait() end

    end
end


local drive
local function driveAxis()
    local settings=require(RS.Settings)
    return Vector3.fromAxis(settings.MineDigAxis)*(settings.MineDigDirection or -1)
end
local function inDriveCorridor(world,center,direction,width,height,front,rear)
    local side=direction:Cross(Vector3.yAxis).Unit
    local up=side:Cross(direction).Unit
    local delta=world-center
    local along=delta:Dot(direction)
    return along>=-rear and along<=front
        and math.abs(delta:Dot(side))<=width and math.abs(delta:Dot(up))<=height,along
end
local function driveBlockKind(cell,strength)
    local def=cell and BlockDefinitions[cell.Ore or cell.Block]
    if not def then return end
    if def.Material==Enum.Material.Air then return end
    if def.Types and def.Types.Boundary then return "boundary" end
    local id=cell.Ore or cell.Block
    if id=="Obsidian" and def.ExplosiveOnly then return "explosive" end
    if def.ExplosiveOnly then return "blocked" end
    if def.Hardness and def.Hardness>strength then return "pickaxe" end
end

local function driveDrillZone(d)
    local model=d and d.vehicle and d.vehicle.Model
    if not model or not model.Parent then return end

    local powerDrill=model:FindFirstChild("PowerDrill",true)
    local body=powerDrill and powerDrill:FindFirstChild("Body")
    local zone=body and body:FindFirstChild("DrillZone")

    if not (zone and zone:IsA("BasePart")) then
        zone=model:FindFirstChild("DrillZone",true)
    end
    return zone and zone:IsA("BasePart") and zone or nil
end

local function explosionAreaSize(zone)
    local scale=math.clamp(tonumber(state.cfg.ExplosionScanScale) or 100,0,100)/100
    if scale==0 then return Vector3.zero end
    -- Include the same two-stud voxel overlap on every face in the preview.
    return zone.Size*scale+Vector3.new(4,4,4)
end
local function inDriveDrillZone(d,world)
    if (tonumber(state.cfg.ExplosionScanScale) or 100)<=0 then return false end
    local zone=driveDrillZone(d)
    if not zone then return false end
    local p=zone.CFrame:PointToObjectSpace(world)
    local half=explosionAreaSize(zone)*0.5
    return math.abs(p.X)<=half.X
        and math.abs(p.Y)<=half.Y
        and math.abs(p.Z)<=half.Z
end
function state.SetExplosionScanScale(value)
    local number=tonumber(value)
    if not number or number~=number then return false end
    number=math.clamp(number,0,100)
    if state.cfg.ExplosionScanScale==number then return true end
    state.cfg.ExplosionScanScale=number
    if state.UpdateExplosionAreaVisual then state.UpdateExplosionAreaVisual() end
    state.driveClearUntil=0
    if state.cfg.AutoDriveForward or state.driveClearing then
        state.cancelVersion+=1
        cancelAction()
        state.status="Autodrive: explosive scan area changed; rescanning"
    end
    return true
end
local function brakeVehicle(vehicle)
    vehicle:ForwardInput(0)
    vehicle:BackwardInput(0)
    vehicle:LeftInput(0)
    vehicle:RightInput(0)
    vehicle:HandbrakeInput(true)
end
function state.ClearExplosionAreaVisual()
    if state.explosionAreaVisual then
        state.explosionAreaVisual:Destroy()
        state.explosionAreaVisual=nil
    end
end
function state.UpdateExplosionAreaVisual()
    local vehicle=getOwnedVehicle()
    local zone=vehicle and driveDrillZone({vehicle=vehicle})
    local gui=lp:FindFirstChildOfClass("PlayerGui")
    if not alive() or not state.cfg.ShowExplosionArea or state.cfg.ExplosionScanScale<=0
        or not zone or not gui then
        state.ClearExplosionAreaVisual()
        return
    end
    local box=state.explosionAreaVisual
    if not box or not box.Parent then
        box=Instance.new("BoxHandleAdornment")
        box.Name="MineAuraExplosionArea"
        box.Color3=Color3.fromRGB(255,150,35)
        box.Transparency=0.8
        box.AlwaysOnTop=true
        box.ZIndex=3
        box.CFrame=CFrame.new()
        box.Parent=gui
        state.explosionAreaVisual=box
    end
    -- Adornee automatically follows the position and rotation of DrillZone.
    if box.Parent~=gui then box.Parent=gui end
    box.Adornee=zone
    box.Size=explosionAreaSize(zone)
end
local explosionVisualRefresh=0
table.insert(state.connections,RunService.Heartbeat:Connect(function(dt)
    explosionVisualRefresh+=dt
    if explosionVisualRefresh<0.1 then return end
    explosionVisualRefresh=0
    state.UpdateExplosionAreaVisual()
end))
function state.stopAutodrive()
    state.driveClearUntil=0
    if not drive then return end
    local d=drive
    drive=nil
    if d.vehicle.DriverStep==d.wrapper then d.vehicle.DriverStep=d.ownStep end

    if d.antiLift then d.antiLift:Destroy() end
    if d.align then d.align:Destroy() end
    if d.attachment then d.attachment:Destroy() end

    pcall(brakeVehicle,d.vehicle)
    local controls=require(lp.PlayerScripts.ControlsLib)
    controls.InputState.Forward=0
    controls.InputState.Backward=0
    controls.InputState.Left=0
    controls.InputState.Right=0
end
local function setupDrive(vehicle)
    if drive and drive.vehicle==vehicle then return drive end
    state.stopAutodrive()
    local part=vehicle.Model.PrimaryPart
    if not part then return end
    local d={vehicle=vehicle,part=part,axis=driveAxis(),lane=part.Position,throttle=0,steer=0,steerCurrent=0}
    d.direction=d.axis
    d.groundUp=Vector3.yAxis

    d.attachment=Instance.new("Attachment")
    d.attachment.Name="MineAuraDriveAttachment"
    d.attachment.Position=Vector3.zero
    d.attachment.Parent=part

    d.align=Instance.new("AlignOrientation")
    d.align.Name="MineAuraDriveAlignment"
    d.align.Mode=Enum.OrientationAlignmentMode.OneAttachment
    d.align.Attachment0=d.attachment
    d.align.MaxTorque=0
    d.align.Enabled=false
    d.align.Parent=part

    d.antiLift=Instance.new("VectorForce")
    d.antiLift.Name="MineAuraGroundLoad"
    d.antiLift.Attachment0=d.attachment
    d.antiLift.RelativeTo=Enum.ActuatorRelativeTo.World
    d.antiLift.ApplyAtCenterOfMass=true
    d.antiLift.Force=Vector3.zero
    d.antiLift.Parent=part

    d.originalStep,d.ownStep=vehicle.DriverStep,rawget(vehicle,"DriverStep")
    d.wrapper=function(self,dt)
        local active=alive() and state.cfg.AutoDriveForward and getOwnedVehicle()==self
        local interface=self.Components.PlayerVehicleInterface
        local go=active and interface and interface.ControlsActive and not state.busy
            and not state.manualSell and not state.driveClearing
            and os.clock()<(state.driveClearUntil or 0)

        d.align.Enabled=false

        local noseUp=math.max(0,d.part.CFrame.RightVector.Y)
        local targetThrottle=go and math.clamp(1-noseUp*2.5,0.25,1) or 0
        local throttleRate=go and 2.5 or 8.0
        local maxStep=math.max(0,dt)*throttleRate
        d.throttle=d.throttle+math.clamp(targetThrottle-d.throttle,-maxStep,maxStep)
        if not active then d.throttle=0 end

        local targetSteer=go and (d.steer or 0) or 0
        local steerStep=math.max(0,dt)*3.5
        d.steerCurrent=d.steerCurrent+math.clamp(targetSteer-d.steerCurrent,-steerStep,steerStep)

        if go then
            local downforceScale=math.clamp(0.15+noseUp*1.25,0.15,0.45)
            d.antiLift.Force=Vector3.new(0,-d.part.AssemblyMass*WS.Gravity*downforceScale,0)
        else
            d.antiLift.Force=Vector3.zero
        end

        if active then
            self:ForwardInput(go and d.throttle or 0)
            self:BackwardInput(0)
            if d.steerCurrent>0 then
                self:LeftInput(d.steerCurrent)
                self:RightInput(0)
            else
                self:LeftInput(0)
                self:RightInput(-d.steerCurrent)
            end
            self:HandbrakeInput(not go)
        end
        return d.originalStep(self,dt)
    end
    vehicle.DriverStep=d.wrapper
    drive=d
    return d
end
local function centerDrive(d)
    local up=Vector3.yAxis
    local forward=d.axis-up*d.axis:Dot(up)
    if forward.Magnitude<0.001 then
        d.steer=0
        d.direction=d.axis
        state.driveLaneError=0
        return
    end
    forward=forward.Unit
    local side=forward:Cross(up).Unit
    local error=(d.part.Position-d.lane):Dot(side)

    local desired=(forward-side*math.clamp(error*0.055,-0.28,0.28)).Unit
    local current=d.part.CFrame.RightVector
    current=current-up*current:Dot(up)
    if current.Magnitude>0.001 then
        current=current.Unit
        local headingError=current:Cross(desired):Dot(up)
        d.steer=math.clamp(headingError*2.2,-0.65,0.65)
    else
        d.steer=0
    end

    d.groundUp=up
    d.direction=forward
    state.driveLaneError=error
end
local function orderDriveObstacles(found)
    table.sort(found,function(a,b) return a.along<b.along end)
    local explosives={}
    for _,target in ipairs(found) do
        if target.kind=="explosive" then explosives[#explosives+1]=target end
    end
    table.sort(explosives,function(a,b)
        if a.centerDistance~=b.centerDistance then return a.centerDistance<b.centerDistance end
        if a.along~=b.along then return a.along<b.along end
        return tostring(a.pos)<tostring(b.pos)
    end)
    local index=1
    for i,target in ipairs(found) do
        if target.kind=="explosive" then
            found[i]=explosives[index]
            index+=1
        end
    end
end
local function scanDriveObstacles(d,valid)
    local terrain=MineTerrain.GetInstance()
    local performance=d.vehicle.Definition.Performance
    local massSize=performance.MassSize
    local box,size=d.vehicle.Model:GetBoundingBox()
    local width=math.max(massSize.Z,size.Z)/2+2
    local height=math.max(massSize.Y,size.Y)/2+2
    local rear=math.max(massSize.X,size.X)/2
    local front=rear+math.max(10,d.part.AssemblyLinearVelocity.Magnitude*1.5)
    local drill=d.vehicle.Components.MiningDrillClient
    local strength=pickaxeStrength()*(drill and drill.HardnessPct or 1)
    local found,seen={},{}
    local center,direction=box.Position,d.direction
    local zone=driveDrillZone(d)
    local blastCenter=zone and zone.Position or center
    local function add(pos,cell)
        local kind=driveBlockKind(cell,strength)
        if not kind then return end
        local world=worldAt(pos)

        local inside,along
        if kind=="explosive" then
            inside=inDriveDrillZone(d,world)
            along=(world-center):Dot(direction)
        else
            inside,along=inDriveCorridor(world,center,direction,width,height,front,rear)
            inside=inside or inDriveCorridor(world,center,d.part.CFrame.RightVector,width,height,front,rear)
        end
        local key=tostring(pos)
        if inside and not seen[key] then
            seen[key]=true
            local delta=world-blastCenter
            found[#found+1]={pos=pos,world=world,kind=kind,along=along,
                centerDistance=delta:Dot(delta),id=cell.Ore or cell.Block}
        end
    end
    local n=0
    for pos,cell in terrain._Cells:List() do
        add(pos,cell)
        n+=1
        if n%4000==0 then task.wait() if not valid() then return end end
    end
    local folder=WS:FindFirstChild("PlacedOre")
    for _,obj in ipairs(folder and folder:GetChildren() or {}) do
        local world=placedWorldPosition(obj)
        if world then
            local pos,cell=resolvePlacedOreCell(terrain,world)
            if pos then add(pos,cell) end
        end
    end
    orderDriveObstacles(found)
    state.driveObstacles=#found
    return found
end
local function findDriveExplosive()
    local char=lp.Character
    for _,model in ipairs(char and char:GetChildren() or {}) do
        local tool=ToolBase.ToolsByModel[model]
        local client=tool and tool:FindComponentByName("ExplosiveClient")
        if client and tool.Equipped then return tool,client end
    end
    for _,bag in pairs(Backpack.ByFolder) do
        if bag.Folder and bag.Folder:IsDescendantOf(lp) then
            for tool in pairs(bag.ContainedTools) do
                local client=tool:FindComponentByName("ExplosiveClient")
                if client then return tool,client,bag end
            end
        end
    end
end
local function explosiveStand(terrain,target,range)
    local normals={Vector3.yAxis,-Vector3.yAxis,Vector3.xAxis,-Vector3.xAxis,Vector3.zAxis,-Vector3.zAxis}
    for _,normal in ipairs(normals) do
        for distance=6,range-1,4 do
            local stand=target.world+normal*distance
            if openPosition(terrain,stand) then
                local delta=target.world-stand
                local hit=WS:Raycast(stand,delta.Unit*(delta.Magnitude+2),terrainRay)
                if hit and cellAt(hit.Position-hit.Normal*0.5)==target.pos then
                    local face,best=Enum.NormalId.Top,-math.huge
                    for _,id in ipairs(Enum.NormalId:GetEnumItems()) do
                        local dot=Vector3.fromNormalId(id):Dot(hit.Normal)
                        if dot>best then face,best=id,dot end
                    end
                    return stand,face
                end
            end
        end
    end
end
local function emptyExplosiveForReset()
    for model,tool in pairs(ToolBase.ToolsByModel) do
        local owned = model:IsDescendantOf(lp)
            or (lp.Character and model:IsDescendantOf(lp.Character))
        if owned and (tool.Equipped or state.cfg.AutoDriveForward) then
            local client = tool:FindComponentByName("ExplosiveClient")
            local charges = client and client.ExplosiveCharges
            if charges and charges.Owner == lp and charges.Name ~= "Nuke" then
                charges:Update()
                local age = charges._Workspace:GetServerTimeNow() - charges.LastActivateTime
                if charges.CurrentChargers <= 0 and age >= (charges.Cooldown or 2) then
                    return tool,charges
                end
            end
        end
    end
end

function state.CancelExplosionReset()
    local reset = state.explosionReset
    if not reset then return end
    state.explosionReset = nil
    if reset.thread and coroutine.status(reset.thread) ~= "dead" then
        pcall(task.cancel,reset.thread)
    end
    local cam = WS.CurrentCamera
    if cam and reset.cameraDirection then
        pcall(function()
            cam.CFrame = CFrame.new(cam.CFrame.Position, cam.CFrame.Position + reset.cameraDirection)
        end)
    end
end

function state.ExplosionResetStep()
    if not alive() or not state.cfg.ExplosionCooldownBypass or state.explosionReset
        or state.pendingAction or state.selling or state.manualSell or state.hopping then return false end
    local tool,charges = emptyExplosiveForReset()
    local char,root,humanoid = characterRoot()
    local camera = WS.CurrentCamera
    if not tool or not root or not camera then return false end
    local reset = {
        character = char,
        rootCFrame = root.CFrame,
        cameraDirection = camera.CFrame.LookVector,
        toolId = tool.Definition.Id,
        vehicle = getOwnedVehicle(),
        returnToSeat = state.isDriving(),
        started = os.clock(),
        serverStarted = WS:GetServerTimeNow(),
        before = charges.CurrentChargers,
        lastBefore = charges.LastActivateTime,
    }
    state.explosionReset = reset
    state.explosionResetStatus = "Resetting empty "..reset.toolId
    state.cancelVersion += 1
    invalidateMining()
    cancelAction()
    releaseAutoDrive()
    reset.thread = task.spawn(function()
        local function active() return alive() and state.explosionReset == reset end
        local ok,why = xpcall(function()
            char:BreakJoints()

            local deadline = os.clock()+math.max(15,Players.RespawnTime+10)
            local newChar,newRoot,newHumanoid
            repeat
                task.wait()
                if not active() then return end
                newChar,newRoot,newHumanoid = characterRoot()
            until (newChar and newChar ~= char and newRoot) or os.clock() >= deadline
            assert(newChar and newChar ~= char and newRoot and newHumanoid,"Respawn timed out")

            task.wait(0.5)
            if not active() then return end

            newChar,newRoot,newHumanoid = characterRoot()
            assert(newRoot and newHumanoid and newChar and newChar ~= char,
                "New character vanished during settle")

            local assembly = newRoot.AssemblyRootPart
            local attached = assembly and reset.vehicle and reset.vehicle.Model
                and assembly:IsDescendantOf(reset.vehicle.Model)
            assert(not newHumanoid.SeatPart and not attached,
                "New character is still attached to a vehicle")

            newRoot.CFrame = reset.rootCFrame
            newRoot.AssemblyLinearVelocity = Vector3.zero
            newRoot.AssemblyAngularVelocity = Vector3.zero

            local cam = WS.CurrentCamera
            if cam and reset.cameraDirection then
                cam.CFrame = CFrame.new(cam.CFrame.Position, cam.CFrame.Position + reset.cameraDirection)
            end

            state.flyHRP,state.flyCoordinate = newRoot,reset.rootCFrame
            reset.returnError = (newRoot.Position-reset.rootCFrame.Position).Magnitude
            reset.respawnSeconds = os.clock()-reset.started
            state.explosionResetStatus = "Returned; checking explosive charges"

            local freshCharges
            deadline = os.clock()+3
            repeat
                if not active() then return end
                for model,newTool in pairs(ToolBase.ToolsByModel) do
                    if newTool.Definition.Id == reset.toolId
                        and (model:IsDescendantOf(lp) or model:IsDescendantOf(newChar)) then
                        local client = newTool:FindComponentByName("ExplosiveClient")
                        freshCharges = client and client.ExplosiveCharges
                        if freshCharges then break end
                    end
                end
                if freshCharges then
                    freshCharges:Update()
                    if freshCharges.CurrentChargers > 0 then break end
                end
                task.wait(0.05)
            until os.clock() >= deadline
            reset.after = freshCharges and freshCharges.CurrentChargers
            reset.lastAfter = freshCharges and freshCharges.LastActivateTime
            reset.elapsed = WS:GetServerTimeNow()-reset.serverStarted
            if not freshCharges or freshCharges.CurrentChargers <= 0 then
                state.SetExplosionCooldownBypass(false)
                if state.explosionCooldownToggle then state.explosionCooldownToggle:Set(false) end
                state.explosionResetStatus = "Reset did not refill charges; reset bypass disabled"
            else
                state.explosionResetStatus = "Returned with "..freshCharges.CurrentChargers.." charges"
            end
            if reset.returnToSeat and state.cfg.AutoDriveForward and active() then
                reset.returnedToSeat = resumeVehicle(reset.vehicle,function()
                    return active() and state.cfg.AutoDriveForward and lp.Character == newChar
                end)
            end
        end,debug.traceback)
        if state.explosionReset ~= reset then return end
        state.explosionReset = nil
        reset.ok,reset.error = ok,why
        state.explosionResetReport = reset
        if not ok then
            state.SetExplosionCooldownBypass(false)
            if state.explosionCooldownToggle then state.explosionCooldownToggle:Set(false) end
            state.explosionResetStatus = "Reset stopped: "..tostring(why)
        end
    end)
    return true
end

local STONE_FALLBACK_OFFSETS = {
    Vector3int16.new( 1, 0, 0),
    Vector3int16.new(-1, 0, 0),
    Vector3int16.new( 0, 1, 0),
    Vector3int16.new( 0,-1, 0),
    Vector3int16.new( 0, 0, 1),
    Vector3int16.new( 0, 0,-1),
}

local function clearStoneAroundOre(terrain, orePos, client, tool, range, valid, prefix)
    local cleared = 0
    local strength = pickaxeStrength()
    local speed = MiningUtils.GetPlayerPickaxeSpeedClient()

    state.openPosCache = {}

    for _, offset in ipairs(STONE_FALLBACK_OFFSETS) do
        if not valid() then break end

        local count, capacity = cargoStatus()
        if count and capacity and count >= capacity then
            state.status = (prefix or "Fallback")..": backpack full while clearing stone"
            break
        end

        local pos = orePos + offset
        local cell = terrain:Get(pos)
        local id = cell and not cell.Ore and cell.Block or nil
        local def = id and BlockDefinitions[id]

        if def
            and def.Types and def.Types.Stone
            and not (def.Types and def.Types.Boundary)
            and not def.ExplosiveOnly
            and def.Material ~= Enum.Material.Air
            and def.Hardness and def.Hardness <= strength then

            local world = worldAt(pos)
            local _, root = characterRoot()

            if root and (root.Position - world).Magnitude <= range + 0.5 then
                local duration = MiningTime(speed, strength, def.Hardness)
                if duration and duration < 999 then
                    state.status = (prefix or "Fallback")..": clearing "..(def.Name or id).." around ore"

                    local finish = os.clock() + math.max(0.05, duration)
                    while os.clock() < finish do
                        if not valid() then return cleared end
                        task.wait(0.02)
                    end

                    if not valid() then return cleared end

                    local before = terrain:Get(pos)
                    if before and not before.Ore and before.Block == id then
                        local ok = mineConfirmed(client,terrain,pos,valid)

                        if not valid() then return cleared end

                        local deadline = os.clock() + 1.0
                        while valid() and os.clock() < deadline do
                            local fresh = terrain:Get(pos)
                            if not fresh or fresh.Ore or fresh.Block ~= id then break end
                            task.wait(0.05)
                        end

                        local after = terrain:Get(pos)
                        if ok and after and (after.Ore or after.Block ~= id) then
                            cleared += 1
                        elseif not ok then
                            task.wait(0.03)
                        end
                    end
                end
            end
        end
    end

    state.openPosCache = {}
    return cleared
end

local function clearOreAccess(terrain,target,client,tool,range,valid)
    local cleared=0
    local deadline=os.clock()+30
    while valid() and cleared<math.ceil(range/4)+2 and os.clock()<deadline do
        local _,root=characterRoot()
        if not root or not insideMine(terrain,root.Position) then return false,cleared end
        if visibleFace(root.Position,target.world) then return true,cleared end
        local delta=target.world-root.Position
        local hit=WS:Raycast(root.Position,delta.Unit*(delta.Magnitude+2),terrainRay)
        if not hit then return false,cleared end
        local pos=cellAt(hit.Position-hit.Normal*0.5)
        local cell=terrain:Get(pos)
        if cell and cell.Block=="Air" and not cell.Ore then
            if not waitUntil(0.05,valid) then return false,cleared end
        else
            local id=cell and not cell.Ore and cell.Block
            local def=id and BlockDefinitions[id]
            if not def or not def.Types or not def.Types.Stone or def.Types.Boundary
                or def.ExplosiveOnly or not def.Hardness or def.Hardness>pickaxeStrength()
                or (root.Position-worldAt(pos)).Magnitude>range+0.5 then return false,cleared end
            local duration=MiningTime(MiningUtils.GetPlayerPickaxeSpeedClient(),pickaxeStrength(),def.Hardness)
            if not duration or duration>=999 then return false,cleared end
            state.status="Access to "..(target.def.Name or target.id)..": clearing "..(def.Name or id)
            if not waitUntil(math.max(0.05,duration),valid) then return false,cleared end
            local accepted=mineConfirmed(client,terrain,pos,function()
                local fresh=terrain:Get(pos)
                return valid() and tool.Equipped and tool.Model.Parent==lp.Character
                    and fresh and not fresh.Ore and fresh.Block==id
                    and insideMine(terrain,root.Position)
                    and (root.Position-worldAt(pos)).Magnitude<=range+0.5
            end)
            if not accepted then return false,cleared end
            cleared+=1
            state.accessBlocks=(state.accessBlocks or 0)+1
            state.openPosCache={}
            if not waitUntil(0.05,valid) then return false,cleared end
        end
    end
    local _,root=characterRoot()
    return root and valid() and visibleFace(root.Position,target.world) or false,cleared
end

local function findDrivePickaxe()
    local char=lp.Character
    for _,model in ipairs(char and char:GetChildren() or {}) do
        local tool=ToolBase.ToolsByModel[model]
        local client=tool and tool:FindComponentByName("PickaxeClient")
        if client and tool.Equipped then return tool,client end
    end
    for _,bag in pairs(Backpack.ByFolder) do
        if bag.Folder and bag.Folder:IsDescendantOf(lp) then
            for tool in pairs(bag.ContainedTools) do
                local client=tool:FindComponentByName("PickaxeClient")
                if client then return tool,client,bag end
            end
        end
    end
end

local function clearDriveObstacle(d,target,valid)
    state.driveClearUntil=0
    brakeVehicle(d.vehicle)
    d.align.Enabled=false

    local terrain=MineTerrain.GetInstance()
    local drill=d.vehicle.Components.MiningDrillClient
    local strength=pickaxeStrength()*(drill and drill.HardnessPct or 1)

    local cell=terrain:Get(target.pos)
    if not cell then
        state.status="Autodrive: waiting for obstacle replication"
        return false
    end

    local id=cell.Ore or cell.Block
    local kind=driveBlockKind(cell,strength)
    if not kind then return true end

    if kind=="explosive" and not inDriveDrillZone(d,target.world) then
        state.status="Autodrive: Obsidian not in DrillZone; continuing forward"
        return true
    end

    if kind=="boundary" or kind=="blocked" then
        state.status="Autodrive: cannot clear "..tostring(id).."; waiting"
        return false
    end

    local def=BlockDefinitions[id]
    local tool,client,bag

    if kind=="explosive" then
        tool,client,bag=findDriveExplosive()
    else
        if not def.Hardness or def.Hardness>pickaxeStrength() then
            state.status="Autodrive: stronger pickaxe needed for "..id
            return false
        end

        local count,capacity=cargoStatus()
        if not count or count>=capacity then
            state.status="Autodrive: backpack full/unavailable; waiting for unloading"
            return false
        end

        tool,client,bag=findDrivePickaxe()
    end

    if not client then
        state.status="Autodrive: missing "..kind.." tool; waiting"
        return false
    end

    local function unchanged()
        local fresh=terrain:Get(target.pos)
        return fresh and (fresh.Ore or fresh.Block)==id
    end

    state.driveClearing=true
    state.busy=true

    local ok,why=xpcall(function()
        assert(exitVehicle(valid),"Vehicle exit pending")

        if kind=="explosive" then
            tool,client,bag=findDriveExplosive()
            assert(client,"Explosive tool unavailable")
            assert(unchanged(),"Obsidian changed")
            assert(inDriveDrillZone(d,target.world),"Obsidian left DrillZone")
        end

        if not tool.Equipped then
            assert(bag,"Backpack unavailable for "..kind)
            bag:EquipTool(tool)
        end

        local equipDeadline=os.clock()+3
        while valid() and not tool.Equipped and os.clock()<equipDeadline do
            task.wait(0.05)
        end
        assert(valid() and tool.Equipped,"Waiting for "..kind.." equip")

        if not unchanged() then return end

        local range=kind=="explosive" and (tool.Definition.Stats.PlacementRange or 18)
            or (tool.Definition.Stats.Range or 12)

        local stand,face=explosiveStand(terrain,target,range)
        assert(stand,"No exposed safe mining position; retrying")

        if kind=="explosive" then
            assert(inDriveDrillZone(d,target.world),"Obsidian left DrillZone before teleport")
            state.driveDrillZoneTarget=tostring(target.pos)
        end

        local moved=flyTeleport(CFrame.lookAt(stand,target.world),state.cancelVersion)
        assert(moved,"Could not move to mining position")
        assert(waitUntil(0.15,valid),"Cancelled")

        local function actionValid()
            local _,root=characterRoot()
            return valid()
                and unchanged()
                and (kind~="explosive" or inDriveDrillZone(d,target.world))
                and tool.Equipped
                and tool.Model.Parent==lp.Character
                and root
                and (root.Position-target.world).Magnitude<=range+0.5
        end

        if kind=="explosive" then
            state.status="Autodrive: placing C4 on Obsidian"
            local charges=client.ExplosiveCharges
            local chargeDeadline=os.clock()+(tool.Definition.Stats.ChargeRefreshTime or 20)+3

            while actionValid() and not charges:CanAttemptUse() and os.clock()<chargeDeadline do
                if state.ExplosionResetStep() then return end
                state.status="Autodrive: waiting for explosive charge"
                task.wait(0.1)
            end

            assert(actionValid(),"Explosive target changed")
            assert(charges:CanAttemptUse(),"Explosive recharge pending")

            local placed,err=performAction(function()
                if not actionValid() or id~="Obsidian" then return false end
                if not charges:AttemptUse() then return false end
                return client.ActivateRemote:InvokeServer(target.pos,face)
            end,actionValid)

            assert(placed,err or "Explosive placement rejected")
            state.driveExplosives=(state.driveExplosives or 0)+1
        else
            local attempts=0
            while valid() and unchanged() do
                attempts+=1
                state.status="Autodrive: mining "..id.." | hit "..attempts

                local duration=MiningTime(
                    MiningUtils.GetPlayerPickaxeSpeedClient(),
                    pickaxeStrength(),
                    def.Hardness
                )
                assert(duration and duration<999,"Pickaxe too weak")

                local finish=os.clock()+math.max(0.05,duration)
                while os.clock()<finish do
                    if not actionValid() then return end
                    task.wait(0.03)
                end
                if not actionValid() then return end

                local mined,err=performAction(function()
                    if not actionValid() then return false end
                    return client:MineBlock(target.pos)
                end,valid)

                if not valid() then return end

                local replicateDeadline=os.clock()+1.5
                while valid() and unchanged() and os.clock()<replicateDeadline do
                    task.wait(0.05)
                end

                if not valid() then return end
                if unchanged() then
                    if attempts % 5 == 0 then
                        state.status="Autodrive fallback: clearing stone around "..id
                        local cleared=clearStoneAroundOre(
                            terrain,target.pos,client,tool,range,actionValid,"Autodrive fallback"
                        )
                        if not valid() then return end
                        state.status="Autodrive fallback: cleared "..cleared.." stone block(s); retrying "..id
                        task.wait(0.05)
                    else
                        state.status=(mined and "Autodrive: target still present; mining again"
                            or "Autodrive: mining retry: "..tostring(err))
                        task.wait(0.05)
                    end
                end
            end

            if not valid() then return end
        end

        local fresh=terrain:Get(target.pos)
        if not fresh or (fresh.Ore or fresh.Block)~=id then
            state.openPosCache={}
            state.driveLastCleared={
                id=id,
                pos=tostring(target.pos),
                after=fresh and (fresh.Ore or fresh.Block) or "removed",
                method=kind
            }
            if kind=="pickaxe" then
                state.drivePickaxeMined=(state.drivePickaxeMined or 0)+1
            end
            return
        end

        local deadline=os.clock()+8
        repeat
            if not valid() then error("Cancelled") end
            task.wait(0.05)
            fresh=terrain:Get(target.pos)
            if not fresh or (fresh.Ore or fresh.Block)~=id then
                state.openPosCache={}
                state.driveLastCleared={
                    id=id,
                    pos=tostring(target.pos),
                    after=fresh and (fresh.Ore or fresh.Block) or "removed",
                    method=kind
                }
                return
            end
        until os.clock()>=deadline

        error("Obstacle still present; rescan and retry")
    end,debug.traceback)

    state.busy=false
    state.driveClearing=false

    if not ok then
        state.status="Autodrive retry: "..tostring(why)
    end

    return ok
end
local function autodriveStep()
    if state.explosionReset then return end
    if state.ExplosionResetStep and state.ExplosionResetStep() then return end
    local vehicle=getOwnedVehicle()
    if not vehicle or not vehicle.Model or not vehicle.Model.Parent then
        state.stopAutodrive()
        state.status="Autodrive: no car spawned; waiting"
        return
    end
    local d=setupDrive(vehicle)
    if not d then return end
    local token=state.cancelVersion
    local function valid()
        local _,root,h=characterRoot()
        return alive() and state.cfg.AutoDriveForward and token==state.cancelVersion
            and getOwnedVehicle()==vehicle and vehicle.Model.Parent~=nil
            and root~=nil and h.Health>0 and not state.manualSell
    end
    if not valid() then return end
    centerDrive(d)
    local obstacles=scanDriveObstacles(d,valid)
    if not obstacles or not valid() then state.driveClearUntil=0 return end
    if #obstacles>0 then
        state.driveClearUntil=0
        clearDriveObstacle(d,obstacles[1],valid)
        return
    end
    if not state.isDriving() then
        state.driveClearUntil=0
        state.status="Autodrive: path clear; returning to driver seat"
        if not resumeVehicle(vehicle,valid) then return end
        state.driveReturns=(state.driveReturns or 0)+1
        return
    end
    if VehicleController.CurrentDrivenVehicle~=vehicle then
        state.driveClearUntil=0
        state.status="Autodrive: enter your own car"
        return
    end
    state.flyEnabled=false
    state.driveClearUntil=os.clock()+1.5
    state.status="Autodrive: centered downhill"
end
state.AutodriveStep=autodriveStep
state.ScanDriveObstacles=function()
    local vehicle=getOwnedVehicle()
    if not vehicle then return {} end
    local d=setupDrive(vehicle)
    centerDrive(d)
    return scanDriveObstacles(d,function() return alive() end)
end

local function mineOnce()
    if not exitVehicle(function() return alive() and state.running end) then
        state.status="Waiting to exit vehicle"
        return
    end

    local count, capacity = cargoStatus()
    if not count then
        state.status="Waiting for backpack"
        return
    end
    if count>=capacity then
        state.status="Backpack full"
        return
    end

    local char, root, humanoid = characterRoot()
    local client, pickTool = pickaxeClient()
    if not root or not client or not pickTool then
        state.status="Waiting for pickaxe/character"
        return
    end

    local generation, token = state.mineGeneration,state.cancelVersion

    local function valid(ignoreCapacity)
        local count,capacity=cargoStatus()
        local vc,vmax=vehicleCargoStatus()

        local sellDue=state.cfg.AutoSell and count and capacity and count>0
            and count>=math.ceil(capacity*state.cfg.SellPercent/100)
            and os.clock()>=state.nextSell

        local vehicleDue=state.cfg.AutoSell and vc and vmax and vc>0
            and (vc>=vmax or state.running)
            and os.clock()>=state.nextVehicleSell

        return (ignoreCapacity or (not sellDue and not vehicleDue
                and count and capacity and count<capacity))
            and alive()
            and state.running
            and not state.busy
            and not state.manualSell
            and generation==state.mineGeneration
            and token==state.cancelVersion
            and lp.Character==char
            and root.Parent~=nil
            and humanoid.Health>0
            and not state.isDriving()
    end

    local terrain = MineTerrain.GetInstance()
    local target, range = chooseTarget(client,terrain,root,valid)

    if not valid() then return end
    if not target then
        state.currentOre=nil
        state.status="No accessible loaded ore; waiting for streaming or mine reset"
        return
    end

    local function reachableHigher(candidate)
        if not valid() or not pickTool.Equipped or pickTool.Model.Parent~=char then return false end
        if (root.Position-candidate.world).Magnitude<=range
            and insideMine(terrain,root.Position)
            and (candidate.isOre or visibleFace(root.Position,candidate.world)) then return true end
        return findMiningStand(terrain,candidate,root,range,pickaxeStrength(),valid)~=nil
    end

    if hasHigherPricedOre(terrain,target,valid,reachableHigher) then
        return
    end

    if target.stand then
        local moved = flyTeleport(CFrame.lookAt(target.stand,target.world),token)
        if not moved or not waitUntil(state.cfg.MineMoveSettle,valid) then
            return
        end
    end

    state.targetPrice,state.targetDistance=target.value,target.distance
    state.currentOre = target.def.Name or target.id
    state.status = "Mining: "..state.currentOre..(target.fromPlaced and " [PlacedOre]" or "")

    local function unchanged()
        local cell = terrain:Get(target.pos)
        if not cell and target.synthetic and target.instance and target.instance.Parent then
            cell=generatedCellAt(terrain,target.pos)
        end
        return cell and (
            (target.isOre and cell.Ore==target.id)
            or
            (not target.isOre and not cell.Ore and cell.Block==target.id)
        )
    end

    local function targetValidCheap()
        local interior,reason=insideMine(terrain,root.Position)
        if not interior then state.status="Automine: "..reason end
        return valid()
            and interior
            and pickTool.Equipped
            and pickTool.Model.Parent==char
            and (root.Position-target.world).Magnitude<=range+0.5
            and unchanged()
    end

    if not targetValidCheap() then
        local interior,reason=insideMine(terrain,root.Position)
        state.status=interior and "Mining target changed before hit; rescanning"
            or ("Automine: "..reason.."; looking for a position inside the mine")
        state.failedTargets[targetKey(target)]=os.clock()+4
        return
    end

    if not target.isOre and not visibleFace(root.Position,target.world) then
        local exposed,cleared=clearOreAccess(terrain,target,client,pickTool,range,targetValidCheap)
        if not valid() then return end
        if not exposed then
            state.failedTargets[targetKey(target)]=os.clock()+state.cfg.MineRetryCooldown
            state.status="Ore blocked; trying another target (cleared "..cleared..")"
            return
        end
    end

    local attempts=0

    while valid() and unchanged() and attempts<state.cfg.MineMaxAttempts do
        attempts+=1
        state.status="Mining: "..state.currentOre.." | hit "..attempts

        local cell=terrain:Get(target.pos)
        local currentId=cell and (cell.Ore or cell.Block)
        local currentDef=currentId and BlockDefinitions[currentId]
        local hardness=currentDef and currentDef.Hardness or target.def.Hardness
        local duration=MiningTime(
            MiningUtils.GetPlayerPickaxeSpeedClient(),
            pickaxeStrength(),
            hardness
        )
        if not duration or duration>=999 then
            state.status="Mining stopped: pickaxe too weak for "..state.currentOre
            return
        end

        local finish=os.clock()+math.max(0.05,duration)
        local nextPriorityCheck=os.clock()+0.5
        local nextStatusUpdate=0
        while os.clock()<finish do
            if not targetValidCheap() then
                return
            end
            if os.clock()>=nextPriorityCheck then
                if hasHigherPricedOre(terrain,target,valid,reachableHigher) then
                    state.status="Higher-priced ore appeared; selecting again"
                    return
                end
                nextPriorityCheck=os.clock()+0.5
            end
            if os.clock()>=nextStatusUpdate then
                state.status=("Mining: %s | %.1fs remaining | hit %d"):format(
                    state.currentOre,math.max(0,finish-os.clock()),attempts)
                nextStatusUpdate=os.clock()+0.2
            end
            task.wait(0.02)
        end

        if not targetValidCheap() then
            return
        end

        state.status="Mining hit: "..state.currentOre.." | #"..attempts

        local ok, why = mineConfirmed(client,terrain,target.pos,function()
            return valid(true) and insideMine(terrain,root.Position)
                and pickTool.Equipped and pickTool.Model.Parent==char
                and (root.Position-target.world).Magnitude<=range+0.5
        end)

        if ok then
            state.minedBlocks=(state.minedBlocks or 0)+1
            state.lastProgress=os.clock()
            state.failedTargets[targetKey(target)]=nil
            state.status="Mined: "..state.currentOre.." (server confirmed)"
            return
        end

        if not valid() then
            return
        end

        local deadline=os.clock()+state.cfg.MineReplicationWait
        while valid() and unchanged() and os.clock()<deadline do
            task.wait()
        end

        if not valid() then
            return
        end

        if unchanged() then
            if attempts == state.cfg.MineMaxAttempts then
                state.status="Fallback: clearing stone around "..state.currentOre
                local cleared=clearStoneAroundOre(
                    terrain,target.pos,client,pickTool,range,targetValidCheap,"Fallback"
                )
                if not valid() then return end
                state.status="Fallback: cleared "..cleared.." stone block(s); moving to another ore"
                task.wait(0.05)
            else
                state.status="Mining retry on same ore: "..tostring(why)
                task.wait(0.05)
            end
        end
    end

    if not valid() then
        return
    end

    if unchanged() then
        state.failedTargets[targetKey(target)]=os.clock()+state.cfg.MineRetryCooldown
        state.mineSkipped=(state.mineSkipped or 0)+1
        state.status="Target rejected repeatedly; trying another ore"
    end
end

----------------------------------------------------------------
-- LEGIT: physical routes and native-speed, visible pickaxe hits
----------------------------------------------------------------
do
    local PathfindingService=game:GetService("PathfindingService")
    local L={enabled=false,excluded={},regions={},phase="Off",confirmed=0,skipped=0,
        delivery=old and old.Legit and old.Legit.delivery or nil,
        transfers=0,deliveries=0,confirmedValue=0,
        cfg={Radius=3000,SkipSeconds=90,ClusterRadius=8,TryVehicle=true,WalkRadius=160,DigAccess=true}}
    state.Legit=L

    local function flat(v) return Vector3.new(v.X,0,v.Z) end
    local function currentVehicle(v)
        return v and getOwnedVehicle()==v and v.Model and v.Model.Parent and v.Model.PrimaryPart
    end
    local function sameCell(terrain,t)
        local c=terrain:Get(t.pos)
        return c and (c.Ore==t.id or (t.isAccess and not c.Ore and c.Block==t.id))
    end
    function L.ClearSkipped()
        L.excluded,L.regions={},{}
        L.plans={}
    end
    function L.IsSkipped(t,now)
        now=now or os.clock()
        local key=targetKey(t)
        if (L.excluded[key] or 0)>now then return true end
        L.excluded[key]=nil
        for i=#L.regions,1,-1 do
            local r=L.regions[i]
            if r.expires<=now then table.remove(L.regions,i)
            elseif r.id==t.id and (t.world-r.world).Magnitude<=L.cfg.ClusterRadius
                and t.world.Y>=r.world.Y-4 then return true end
        end
        return false
    end
    function L.Skip(t,cluster,reason)
        local expiry=os.clock()+L.cfg.SkipSeconds
        L.excluded[targetKey(t)]=expiry
        if cluster then
            L.regions[#L.regions+1]={id=t.id,world=t.world,expires=expiry}
            if #L.regions>64 then table.remove(L.regions,1) end
        end
        L.skipped+=1
        L.lastSkip=reason
        state.status="Legit: "..reason.."; trying another ore"
    end

    -- Own only native input and this exact character. Legit never writes
    -- position, CFrame, velocity, collision or anchoring on character/vehicle.
    function L.Release()
        local motion=L.motion
        L.motion=nil
        if motion then
            if motion.vehicle then
                local v=motion.vehicle
                if v.DriverStep==motion.wrapper then
                    v.DriverStep=motion.ownStep
                    pcall(brakeVehicle,v)
                    pcall(function() v:HandbrakeInput(false) end)
                end
            elseif motion.root and motion.root.Parent and motion.humanoid.Parent then
                motion.humanoid:MoveTo(motion.root.Position)
                motion.humanoid:Move(Vector3.zero)
            end
            if motion.controls and motion.restoreControls and motion.controls.controlsEnabled==false then
                motion.controls:Enable()
            end
        end
        if L.swing then
            pcall(function() L.swing:Stop() end)
            L.swing=nil
        end
        if L.path then L.path:Destroy() L.path=nil end
    end

    function L.SetEnabled(on)
        on=on==true and alive()
        if on and not state.uiReady then return end
        if on==L.enabled then return end
        L.enabled=on
        state.cancelVersion+=1
        L.Release()
        cancelAction()
        L.target=nil
        L.accessTarget=nil
        L.nextWork=0
        if on then
            state.running=false
            state.cfg.AutoDriveForward=false
            state.cfg.AutoSell=false
            state.cfg.AutoEquip=true
            state.manualSell=false
            releaseAutoDrive()
            state.SetExplosionCooldownBypass(false)
            if state.CancelExplosionReset then state.CancelExplosionReset() end
            state.SetNoclip(false)
            state.flyEnabled=false
            state.flyCoordinate=nil
            state.ctrlClickTP,state.ctrlDelete=false,false
            for _,name in ipairs({"mineToggle","autoDriveToggle","autoSellToggle","flyToggle",
                "noclipToggle","explosionCooldownToggle","ctrlClickToggle","ctrlDeleteToggle"}) do
                if state[name] then state[name]:Set(false) end
            end
            local _,_,h=characterRoot()
            if h then
                local defaults=game:GetService("StarterPlayer")
                h.WalkSpeed=math.min(h.WalkSpeed,defaults.CharacterWalkSpeed)
                if h.UseJumpPower then h.JumpPower=math.min(h.JumpPower,defaults.CharacterJumpPower)
                else h.JumpHeight=math.min(h.JumpHeight,defaults.CharacterJumpHeight) end
                state.walkSpeed,state.jumpHeight=h.WalkSpeed,h.JumpPower
            end
            invalidateMining()
            L.ClearSkipped()
        end
        L.phase=on and "Searching" or "Off"
        state.status=on and "Legit: looking for the highest-value mineable ore" or "Legit stopped"
        if state.legitToggle then state.legitToggle:Set(on) end
    end

    local function params(vehicle,includeVehicle)
        local p=RaycastParams.new()
        p.FilterType=Enum.RaycastFilterType.Exclude
        p.FilterDescendantsInstances=includeVehicle and {lp.Character} or {lp.Character,vehicle and vehicle.Model}
        p.RespectCanCollide=true
        return p
    end
    local function floorAt(world,vehicle,rise,drop)
        local hit=WS:Raycast(world+Vector3.new(0,rise or 12,0),
            Vector3.new(0,-(drop or 90),0),params(vehicle))
        if hit and hit.Normal.Y>=0.65 and hit.Material~=Enum.Material.Water then return hit.Position end
    end
    local function route(start,goal,vehicle,valid)
        if not valid() then return nil,"Cancelled" end
        local radius,height=2,5
        if vehicle then
            local _,size=vehicle.Model:GetBoundingBox()
            radius,height=math.max(3,math.min(size.X,size.Z)/2+0.5),math.max(5,size.Y)
        end
        local path=PathfindingService:CreatePath({AgentRadius=radius,AgentHeight=height,
            AgentCanJump=vehicle==nil,WaypointSpacing=vehicle and 8 or 4,Costs={Water=math.huge}})
        L.path=path
        local result={}
        -- ComputeAsync cannot be cancelled. Keep one slot until it settles;
        -- a late path never starts movement for a cancelled generation.
        if L.computing then path:Destroy() L.path=nil return nil,"Path computation pending" end
        L.computing=result
        task.spawn(function()
            result.ok,result.error=pcall(function() path:ComputeAsync(start,goal) end)
            result.done=true
            if L.computing==result then L.computing=nil end
        end)
        local deadline=os.clock()+5
        while valid() and not result.done and os.clock()<deadline do task.wait(0.05) end
        local waypoints
        if valid() and result.done and result.ok and path.Status==Enum.PathStatus.Success then
            waypoints=path:GetWaypoints()
        end
        if L.path==path then L.path=nil end
        path:Destroy()
        if not waypoints or #waypoints==0 then return nil,"No physical path" end
        if vehicle then
            for _,w in ipairs(waypoints) do
                if w.Action==Enum.PathWaypointAction.Jump then return nil,"Vehicle route needs a jump" end
            end
        end
        return waypoints
    end

    function L.DirectWalkPoints(start,goal,vehicle,valid,followFloor)
        local _,root,h=characterRoot()
        if not root or not valid() then return end
        local lift=h.HipHeight+root.Size.Y/2+0.15
        local destination=goal+Vector3.new(0,lift,0)
        local steps=math.max(1,math.ceil(flat(destination-start).Magnitude/4))
        if steps>50 then return end
        local points,previous={},start
        for i=1,steps do
            if not valid() then return end
            local projected=start+(destination-start)*(i/steps)
            local sample=Vector3.new(projected.X,previous.Y,projected.Z)
            local floor=floorAt(sample,vehicle,2,14)
            if not floor then return end
            local standing=floor+Vector3.new(0,lift,0)
            if math.abs(standing.Y-previous.Y)>2.5 then return end
            local delta=standing-previous
            if delta.Magnitude>0.05 and WS:Blockcast(CFrame.new(previous+Vector3.new(0,0.5,0)),
                Vector3.new(2.4,4,2.4),delta,params(vehicle)) then return end
            points[#points+1]={Position=floor}
            previous=standing
        end
        if not followFloor and math.abs(previous.Y-destination.Y)>2.5 then return end
        return points
    end

    local function walkSegment(goal,valid,seconds,jump)
        local char,root,h=characterRoot()
        if not root or state.isDriving() or not valid() then return false,"Cannot walk now" end
        local points=L.DirectWalkPoints(root.Position,goal,getOwnedVehicle(),valid)
        local why
        if not points then points,why=route(root.Position,goal,nil,valid) end
        if not points then return false,why end
        if not valid() then return false,"Cancelled" end
        local controls=require(lp.PlayerScripts.PlayerModule):GetControls()
        local motion={root=root,humanoid=h,controls=controls,restoreControls=controls.controlsEnabled==true}
        L.motion=motion
        if motion.restoreControls then controls:Disable() end
        local deadline=os.clock()+(seconds or 18)
        local ok=true
        for _,w in ipairs(points) do
            if not valid() then ok=false break end
            if w.Action==Enum.PathWaypointAction.Jump or jump then h.Jump=true end
            h:MoveTo(w.Position)
            local best,stalled=math.huge,os.clock()
            while valid() and os.clock()<deadline do
                local distance=(root.Position-w.Position).Magnitude
                -- Waypoints lie on the floor, the root is above it.
                if flat(root.Position-w.Position).Magnitude<2 and math.abs(root.Position.Y-w.Position.Y)<5 then break end
                if distance<best-0.3 then best,stalled=distance,os.clock() end
                if os.clock()-stalled>2.5 then ok=false break end
                task.wait(0.05)
            end
            if not ok or not valid() or os.clock()>=deadline then ok=false break end
        end
        if L.motion==motion then L.Release() end
        local reached=ok and valid() and flat(root.Position-goal).Magnitude<3
            and math.abs(root.Position.Y-goal.Y)<5
        return reached,not reached and "Walking route blocked" or nil
    end
    local function walk(goal,valid,seconds,jump)
        local _,root,h=characterRoot()
        if not root or not valid() then return false,"Cancelled" end
        local distance=flat(root.Position-goal).Magnitude
        if distance<=200 then return walkSegment(goal,valid,seconds,jump) end
        local deadline=os.clock()+math.min(600,math.max(seconds or 18,distance/math.max(4,h.WalkSpeed*0.65)+20))
        while valid() and os.clock()<deadline do
            local start=root.Position
            local delta=flat(goal-start)
            if delta.Magnitude<=200 then return walkSegment(goal,valid,math.max(seconds or 18,delta.Magnitude/math.max(4,h.WalkSpeed)+12),jump) end
            local forward=delta.Unit
            local side=Vector3.new(-forward.Z,0,forward.X)
            local progressed=false
            for _,angle in ipairs({0,0.35,-0.35}) do
                if not valid() then return false,"Cancelled" end
                local point=start+(forward*math.cos(angle)+side*math.sin(angle))*160
                local y=start.Y+(goal.Y-start.Y)*math.min(1,160/delta.Magnitude)
                -- Follow the floor from the player, instead of casting from
                -- above a guessed ramp height and selecting a cave's roof.
                local lane=L.DirectWalkPoints(start,point,getOwnedVehicle(),valid,true)
                local ground=lane and lane[#lane].Position
                    or floorAt(Vector3.new(point.X,y,point.Z),getOwnedVehicle(),2,18)
                if ground and flat(ground-goal).Magnitude<delta.Magnitude-40 then
                    local reached=walkSegment(ground,valid,math.max(seconds or 18,160/math.max(4,h.WalkSpeed)+12),jump)
                    if reached or flat(root.Position-start).Magnitude>15 then progressed=true break end
                    if L.computing then return false,"Path computation pending" end
                end
            end
            if not progressed then return false,"Walking route blocked" end
        end
        return false,valid() and "Walking journey timed out" or "Cancelled"
    end
    L.Walk=walk

    local function promptAt(prompt,action,vehicle,valid)
        if not valid() or not prompt or not prompt.Parent or not prompt.Enabled
            or prompt.ActionText~=action then
            L.promptError=not valid() and "Cancelled" or ("Prompt: "..tostring(prompt and prompt.ActionText)..", enabled="..tostring(prompt and prompt.Enabled))
            return false
        end
        local cf=pointOf(prompt.Parent)
        local _,root=characterRoot()
        if not cf or not root or (root.Position-cf.Position).Magnitude>prompt.MaxActivationDistance-0.5 then
            L.promptError="Prompt distance: "..tostring(cf and root and (root.Position-cf.Position).Magnitude)
            return false
        end
        -- Use exactly one trigger mechanism. InputHoldBegin/End followed by
        -- fireproximityprompt can transfer twice and reverse an Add into Take.
        local helper=typeof(fireproximityprompt)=="function"
        if not helper then prompt:InputHoldBegin() end
        local held=waitUntil(prompt.HoldDuration+0.15,valid)
        if not helper then pcall(function() prompt:InputHoldEnd() end)
        elseif held and valid() and prompt.Enabled and prompt.ActionText==action
            and (root.Position-cf.Position).Magnitude<=prompt.MaxActivationDistance-0.5 then
            fireproximityprompt(prompt)
        else held=false end
        L.promptError=not held and "Prompt hold cancelled" or nil
        return held and valid() and currentVehicle(vehicle)~=nil
    end
    local function board(vehicle,valid)
        if not currentVehicle(vehicle) or not valid() then return false end
        if state.isDriving() then return VehicleController.CurrentDrivenVehicle==vehicle end
        local seat=vehicle.DriversSeat
        local prompt=seat and seat:FindFirstChildWhichIsA("ProximityPrompt",true)
        if not prompt then return false end
        local _,root=characterRoot()
        local cf=pointOf(prompt.Parent)
        if not root or not cf then return false end
        if (root.Position-cf.Position).Magnitude>prompt.MaxActivationDistance-1 then
            -- Approach either side, rather than pathfinding into the solid car.
            local reached=false
            for _,side in ipairs({1,-1}) do
                if not valid() then return false end
                local goal=floorAt(seat.Position+seat.CFrame.RightVector*side*5,vehicle,4,30)
                if goal and walk(goal,valid,25) then reached=true break end
            end
            if not reached then return false end
        end
        for _=1,2 do
            if not valid() then return false end
            promptAt(prompt,"Drive",vehicle,valid)
            if not waitUntil(0.4,valid) then return false end
            if VehicleController.CurrentDrivenVehicle==vehicle and state.isDriving() then return true end
        end
        return false
    end

    function L.Steering(cf,goal,speed)
        local delta=flat(goal-cf.Position)
        if delta.Magnitude<0.01 then return 0,0,true end
        local forward=flat(cf.RightVector).Unit -- Verified InnoVehicles forward axis.
        local desired=delta.Unit
        local dot=forward:Dot(desired)
        local steer=math.clamp(forward:Cross(desired).Y*2.5,-1,1)
        -- A bounded reverse turn handles a waypoint behind the vehicle.
        local reverse=dot< -0.25
        if reverse then steer=-steer end
        if math.abs(steer)<0.05 and dot<0 then steer=1 end
        local limit=reverse and 8 or math.clamp(38-math.abs(steer)*26,12,38)
        local throttle=math.abs(speed)<limit and (reverse and 0.4 or 1) or 0
        return steer,throttle,false,reverse
    end
    function L.DirectDrivePoints(vehicle,goal,valid)
        if not valid() then return end
        local part=vehicle.Model.PrimaryPart
        local _,size=vehicle.Model:GetBoundingBox()
        local previous=floorAt(part.Position,vehicle,0,30)
        if not previous then return end
        local start=previous
        local delta=flat(goal-start)
        local steps=math.max(1,math.ceil(delta.Magnitude/8))
        if steps>40 then return end
        local points={}
        for i=1,steps do
            if not valid() then return end
            local p=start+delta*(i/steps)
            local floor=floorAt(Vector3.new(p.X,previous.Y,p.Z),vehicle,6,22)
            if not floor or math.abs(floor.Y-previous.Y)>5 then return end
            local lift=Vector3.new(0,size.Y/2+0.5,0)
            local body=CFrame.new(previous+lift)*part.CFrame.Rotation
            local hit=WS:Blockcast(body,Vector3.new(size.X,math.max(3,size.Y-0.5),size.Z),floor-previous,params(vehicle))
            -- Wheels following a rounded road can make the swept bounding box
            -- touch its support. Treat upward floor contact as support, while
            -- still checking the cabin's centre and edges for walls/objects.
            if hit and not (hit.Normal and hit.Normal.Y>=0.65
                and hit.Position.Y<=math.max(previous.Y,floor.Y)+2) then return end
            if hit then
                local side=flat(part.CFrame.LookVector).Unit
                for _,offset in ipairs({0,-size.Z/2,size.Z/2}) do
                    local from=previous+side*offset+Vector3.new(0,2.5,0)
                    if WS:Raycast(from,floor-previous,params(vehicle)) then return end
                end
            end
            points[#points+1]={Position=floor}
            previous=floor
        end
        if math.abs(previous.Y-goal.Y)>5 then return end
        return points
    end
    local function driveSegment(vehicle,goal,valid)
        if not board(vehicle,valid) then return false,"Driver seat unreachable" end
        if not valid() then return false,"Cancelled" end
        local part=vehicle.Model.PrimaryPart
        if flat(part.Position-goal).Magnitude<8 and math.abs(part.Position.Y-goal.Y)<12 then return true end
        local start=floorAt(part.Position,vehicle,0,30)
        if not start then return false,"Vehicle has no ground" end
        local points=L.DirectDrivePoints(vehicle,goal,valid)
        local why
        local _,size=vehicle.Model:GetBoundingBox()
        -- The car itself occupies its navmesh start. Begin at a physically
        -- clear point just beyond its footprint, without changing collisions.
        for _,sign in ipairs({1,-1}) do
            if points then break end
            if not valid() then return false,"Cancelled" end
            local offset=part.CFrame.RightVector*sign*(size.X/2+size.Z/2+3)
            local first=floorAt(part.Position+offset,vehicle,2,25)
            local clear=not WS:Raycast(part.Position+Vector3.new(0,1,0),offset,params(vehicle))
            if first and clear and math.abs(first.Y-start.Y)<5 then
                points,why=route(first,goal,vehicle,valid)
                if points then break end
            end
        end
        if not points then return false,why or "Vehicle exit path blocked" end
        local motion={vehicle=vehicle,ownStep=rawget(vehicle,"DriverStep"),originalStep=vehicle.DriverStep,
            throttle=0,steer=0,reverse=false,go=false}
        motion.wrapper=function(self,dt)
            if L.motion==motion and valid() and VehicleController.CurrentDrivenVehicle==vehicle then
                self:ForwardInput(motion.go and not motion.reverse and motion.throttle or 0)
                self:BackwardInput(motion.go and motion.reverse and motion.throttle or 0)
                self:LeftInput(motion.go and math.max(0,motion.steer) or 0)
                self:RightInput(motion.go and math.max(0,-motion.steer) or 0)
                self:HandbrakeInput(not motion.go)
            else brakeVehicle(self) end
            return motion.originalStep(self,dt)
        end
        L.motion=motion
        vehicle.DriverStep=motion.wrapper
        local deadline=os.clock()+math.clamp((start-goal).Magnitude/8+20,20,480)
        local index=1
        local best,stalled=math.huge,os.clock()
        local ok=false
        while valid() and os.clock()<deadline do
            if VehicleController.CurrentDrivenVehicle~=vehicle or not state.isDriving() then break end
            if flat(part.Position-goal).Magnitude<6 and math.abs(part.Position.Y-goal.Y)<12 then ok=true break end
            local w=points[index]
            if not w then break end
            local distance=flat(part.Position-w.Position).Magnitude
            local tolerance=index==#points and 5 or 8
            if distance<tolerance and math.abs(part.Position.Y-w.Position.Y)<12 then
                index+=1 best,stalled=math.huge,os.clock()
            else
                if distance<best-0.4 then best,stalled=distance,os.clock() end
                if os.clock()-stalled>6 then break end
                local steer,throttle,_,reverse=L.Steering(part.CFrame,w.Position,part.AssemblyLinearVelocity.Magnitude)
                motion.steer,motion.throttle,motion.reverse,motion.go=steer,throttle,reverse,true
            end
            task.wait(0.05)
        end
        motion.go=false
        if L.motion==motion then
            pcall(brakeVehicle,vehicle)
            waitUntil(0.35,valid)
            L.Release()
        end
        local reached=ok and valid()
        return reached,not reached and "Vehicle path blocked or stalled" or nil
    end
    local function driveTo(vehicle,goal,valid)
        if not valid() or not currentVehicle(vehicle) then return false,"Cancelled" end
        local deadline=os.clock()+math.clamp((vehicle.Model.PrimaryPart.Position-goal).Magnitude/7+30,30,600)
        local legs=0
        while valid() and os.clock()<deadline and legs<32 do
            local position=vehicle.Model.PrimaryPart.Position
            local delta=flat(goal-position)
            if delta.Magnitude<=320 then return driveSegment(vehicle,goal,valid) end
            L.phase=L.delivery and "Driving delivery route" or L.phase
            local forward=delta.Unit
            local side=Vector3.new(-forward.Z,0,forward.X)
            local progressed=false
            -- Large navmesh searches can exhaust their node budget on an open
            -- road too. Plan short, supported legs; detour left/right if needed.
            for _,angle in ipairs({0,0.35,-0.35,0.7,-0.7,1.2,-1.2,1.5,-1.5}) do
                if not valid() then return false,"Cancelled" end
                local point=position+(forward*math.cos(angle)+side*math.sin(angle))*280
                local y=position.Y+(goal.Y-position.Y)*math.min(1,280/delta.Magnitude)
                local ground=floorAt(Vector3.new(point.X,y,point.Z),vehicle,4,35)
                if ground and flat(ground-goal).Magnitude<delta.Magnitude-10 then
                    local reached=driveSegment(vehicle,ground,valid)
                    if reached then progressed=true break end
                    if L.computing then return false,"Path computation pending" end
                    if flat(vehicle.Model.PrimaryPart.Position-position).Magnitude>40 then progressed=true break end
                end
            end
            if not progressed then return false,"Vehicle route segment blocked" end
            legs+=1
        end
        return false,valid() and "Vehicle journey timed out" or "Cancelled"
    end
    L.DriveTo=driveTo

    -- Sample real floor around the ore at the car's local floor level.
    -- This avoids driving onto a wall-top above an unreachable ceiling ore.
    local function parking(t,vehicle)
        local part=vehicle.Model.PrimaryPart
        local base=floorAt(part.Position,vehicle,0,35)
        if not base then return {} end
        local _,size=vehicle.Model:GetBoundingBox()
        local distance=math.max(8,size.Z/2+5)
        local points={}
        local anchor=t.plan and t.plan.goals[1]
        for i=0,7 do
            local angle=i*math.pi/4
            for _,offset in ipairs({distance,distance+7}) do
                -- The mine ramp rises when travelling toward its entrance.
                -- Casting only from the car's old Y starts below uphill floor.
                local y=anchor and anchor.Y or math.max(base.Y,t.world.Y+4)
                local center=anchor or t.world
                local world=Vector3.new(center.X,y,center.Z)+Vector3.new(math.cos(angle)*offset,0,math.sin(angle)*offset)
                local floor=floorAt(world,vehicle,anchor and 5 or 8,anchor and 20 or math.max(55,y-base.Y+40))
                if floor and math.abs(floor.Y-t.world.Y)<=math.max(18,L.range or 12) then points[#points+1]=floor end
            end
        end
        table.sort(points,function(a,b) return (a-part.Position).Magnitude<(b-part.Position).Magnitude end)
        return points
    end
    L.Parking=parking

    local function visible(t,root,vehicle,range)
        if (root.Position-t.world).Magnitude>range then return false end
        -- Check a small set of points on the cell; an adjacent stone never
        -- counts as the requested ore. No through-wall ore requests.
        for _,offset in ipairs({Vector3.zero,Vector3.new(0,1.4,0),Vector3.new(0,-1.4,0),
            Vector3.new(1.4,0,0),Vector3.new(-1.4,0,0),Vector3.new(0,0,1.4),Vector3.new(0,0,-1.4)}) do
            local delta=t.world+offset-root.Position
            local hit=WS:Raycast(root.Position,delta.Unit*(delta.Magnitude+2),params(vehicle,true))
            if hit and hit.Instance==WS.Terrain then
                local c=cellAt(hit.Position-hit.Normal*0.1)
                if c==t.pos then return true end
            end
        end
        return false
    end
    L.Visible=visible

    local function hitOre(t,terrain,vehicle,valid)
        if not valid() or not sameCell(terrain,t) then return false,"Target changed" end
        local client,tool=pickaxeClient()
        if not valid() or not client or not tool then return false,"Pickaxe unavailable" end
        local char,root=characterRoot()
        local range=tonumber(client.Tool.Definition.Stats.Range) or 12
        local function ready()
            local count,capacity=cargoStatus()
            return valid() and lp.Character==char and not state.isDriving() and tool.Equipped
                and tool.Model.Parent==char and count~=nil and capacity~=nil and count<capacity
                and pickaxeStrength()>=t.def.Hardness and sameCell(terrain,t) and visible(t,root,vehicle,range)
        end
        if not ready() then return false,"Ore out of physical reach" end
        local duration=MiningTime(MiningUtils.GetPlayerPickaxeSpeedClient(),pickaxeStrength(),t.def.Hardness)
        if not duration or duration>=999 or t.def.Hardness>pickaxeStrength() then return false,"Pickaxe too weak" end
        L.swing=client.SwingAnimTrack
        if L.swing then L.swing:Play(nil,nil,2.4) end
        local finish=os.clock()+math.max(0.05,duration)
        while ready() and os.clock()<finish do
            state.status=("Legit: mining %s | %.1fs"):format(t.id,math.max(0,finish-os.clock()))
            task.wait(0.05)
        end
        local accepted,why=false,"Lost physical reach"
        if ready() then
            accepted,why=mineConfirmed(client,terrain,t.pos,function()
                -- Replication may replace the cell with Air before the RPC
                -- resolves. Retain physical ownership, not the old cell here.
                return valid() and lp.Character==char and not state.isDriving()
                    and tool.Equipped and tool.Model.Parent==char
                    and (root.Position-t.world).Magnitude<=range
            end)
        end
        if L.swing then L.swing:Stop() L.swing=nil end
        if accepted then
            L.plans={}
            if t.isAccess and not t.isOre then
                state.accessBlocks=(state.accessBlocks or 0)+1
            else
                L.confirmed+=1
                L.confirmedValue+=(tonumber(t.def.Value) or 0)
                state.minedBlocks=(state.minedBlocks or 0)+1
            end
            state.lastProgress=os.clock()
            L.lastResult=t.id.." (server confirmed)"
            state.status="Legit: mined "..L.lastResult
        end
        return accepted,why
    end
    L.HitOre=hitOre

    -- Dig only the actual obstruction or the next standing volume, never a
    -- radius of arbitrary stone. One accepted block at a time, then replan.
    function L.AccessBlock(terrain,pos,root,range)
        local cell=terrain:Get(pos)
        local id=cell and (cell.Ore or cell.Block)
        local def=id and BlockDefinitions[id]
        if not def or id=="Air" or not def.Hardness or def.Hardness>pickaxeStrength()
            or def.ExplosiveOnly or (def.Types and def.Types.Boundary)
            or not (cell.Ore or (def.Types and def.Types.Stone)) then return end
        local world=worldAt(pos)
        if (root.Position-world).Magnitude>range then return end
        return {pos=pos,world=world,id=id,def=def,isAccess=true,isOre=cell.Ore~=nil,value=tonumber(def.Value) or 0}
    end

    local function walkingClear(stand,terrain,vehicle)
        local _,root=characterRoot()
        for _,lift in ipairs({0,2}) do
            local cell=terrain:Get(cellAt(stand+Vector3.new(0,lift,0)))
            if not cell or cell.Block~="Air" or cell.Ore then return false end
        end
        local delta=stand-root.Position
        return delta.Magnitude<0.05 or not WS:Blockcast(CFrame.new(root.Position+Vector3.new(0,0.5,0)),
            Vector3.new(2.4,4,2.4),delta,params(vehicle))
    end
    local function directStep(goal,terrain,vehicle,valid)
        local _,root,h=characterRoot()
        local stand=goal+Vector3.new(0,h.HipHeight+root.Size.Y/2+0.15,0)
        if not valid() or not walkingClear(stand,terrain,vehicle) then return false end
        local controls=require(lp.PlayerScripts.PlayerModule):GetControls()
        local motion={root=root,humanoid=h,controls=controls,restoreControls=controls.controlsEnabled==true}
        L.motion=motion
        if motion.restoreControls then controls:Disable() end
        h:MoveTo(goal)
        local deadline=os.clock()+2
        while valid() and os.clock()<deadline and flat(root.Position-goal).Magnitude>1.5 do task.wait(0.05) end
        if L.motion==motion then L.Release() end
        return valid() and flat(root.Position-goal).Magnitude<=1.5 and math.abs(root.Position.Y-goal.Y)<5
    end

    local function accessAttempt(t,terrain,vehicle,valid)
        if not L.cfg.DigAccess then return false,"Access digging disabled" end
        L.phase="Digging access to "..t.id
        local deadline,cleared=os.clock()+20,0
        while valid() and sameCell(terrain,t) and os.clock()<deadline and cleared<10 do
            local count,capacity=cargoStatus()
            if not count or not capacity then return false,"Cargo state unavailable" end
            if count>=capacity then return false,"Backpack full" end
            local _,root,h=characterRoot()
            if visible(t,root,vehicle,L.range) then return hitOre(t,terrain,vehicle,valid) end
            local delta=t.world-root.Position
            local horizontal=flat(delta)
            local obstruction
            if delta.Magnitude>0.01 then
                local hit=WS:Raycast(root.Position,delta.Unit*math.min(delta.Magnitude+2,L.range),params(vehicle,true))
                if hit and hit.Instance==WS.Terrain then
                    obstruction=L.AccessBlock(terrain,cellAt(hit.Position-hit.Normal*0.1),root,L.range)
                end
            end
            -- A real, supported next step. Never remove the floor below the
            -- player or walk into unknown cells / a shaft to reach an ore.
            if horizontal.Magnitude>3 then
                local nextPoint=root.Position+horizontal.Unit*3.5
                local feet=root.Position.Y-h.HipHeight-root.Size.Y/2
                -- Clear a standing-height corridor even when the next ray
                -- starts inside a wall and cannot find its floor yet.
                local low=cellAt(nextPoint-Vector3.new(1.1,h.HipHeight+root.Size.Y/2-0.5,1.1))
                local high=cellAt(nextPoint+Vector3.new(1.1,2.6,1.1))
                local bodyBlock
                for x=low.X,high.X do for y=low.Y,high.Y do for z=low.Z,high.Z do
                    local block=L.AccessBlock(terrain,Vector3int16.new(x,y,z),root,L.range)
                    if block and block.world.Y>feet+0.5 and visible(block,root,vehicle,L.range)
                        and (not bodyBlock or (block.world-root.Position).Magnitude<(bodyBlock.world-root.Position).Magnitude) then bodyBlock=block end
                end end end
                if bodyBlock then obstruction=bodyBlock end
                local floor=floorAt(nextPoint,vehicle,1,10)
                if floor and floor.Y>=feet-4 and floor.Y<=feet+2 then
                    local stand=floor+Vector3.new(0,h.HipHeight+root.Size.Y/2+0.15,0)
                    if walkingClear(stand,terrain,vehicle) then
                        if directStep(floor,terrain,vehicle,valid) then continue end
                    elseif not obstruction then
                        local low=cellAt(stand-Vector3.new(1.1,h.HipHeight+root.Size.Y/2-0.1,1.1))
                        local high=cellAt(stand+Vector3.new(1.1,2.6,1.1))
                        for x=low.X,high.X do for y=low.Y,high.Y do for z=low.Z,high.Z do
                            local block=L.AccessBlock(terrain,Vector3int16.new(x,y,z),root,L.range)
                            if block and block.world.Y>feet+0.5 and visible(block,root,vehicle,L.range)
                                and (not obstruction or (block.world-root.Position).Magnitude<(obstruction.world-root.Position).Magnitude) then obstruction=block end
                        end end end
                    end
                end
            end
            if not obstruction or obstruction.pos==t.pos or obstruction.world.Y<root.Position.Y-h.HipHeight-root.Size.Y/2
                or not visible(obstruction,root,vehicle,L.range) then
                return false,cleared>0 and "Access progress" or "No mineable access route"
            end
            state.status="Legit: clearing "..obstruction.id.." for "..t.id
            local accepted,why=hitOre(obstruction,terrain,vehicle,valid)
            if not accepted then return false,why end
            cleared+=1
            if not waitUntil(0.12,valid) then return false,"Cancelled" end
        end
        return false,cleared>0 and "Access progress" or "No mineable access route"
    end
    L.AccessAttempt=accessAttempt

    local function groundAttempt(t,terrain,vehicle,valid)
        L.phase="Ground approach"
        local _,root=characterRoot()
        if visible(t,root,vehicle,L.range) then return hitOre(t,terrain,vehicle,valid) end
        local plan=L.Plan(t,terrain,root,vehicle,valid)
        local goals=plan and plan.goals or {}
        for i=1,math.min(3,#goals) do
            if not valid() then return false,"Cancelled" end
            local seconds=math.clamp((goals[i]-root.Position).Magnitude/math.max(4,select(3,characterRoot()).WalkSpeed)*1.5+5,8,45)
            if walk(goals[i],valid,seconds) then
                if plan.access and not visible(t,root,vehicle,L.range) then return false,"Dig access" end
                local ok,why=hitOre(t,terrain,vehicle,valid)
                if ok then return true end
                if why=="Pickaxe unavailable" or why=="Higher-priced ore available" then return false,why end
            end
        end
        return false,"Ground reach failed"
    end

    local function roofAttempt(t,terrain,vehicle,valid)
        L.phase="Climbing vehicle"
        local _,root,h=characterRoot()
        local model=vehicle.Model
        local cf,size=model:GetBoundingBox()
        local include=RaycastParams.new()
        include.FilterType=Enum.RaycastFilterType.Include
        include.FilterDescendantsInstances={model}
        include.RespectCanCollide=true
        local supports={}
        -- Raycasts find actual collidable roofs/steps, not a model's empty box.
        for _,x in ipairs({-0.3,0,0.3}) do
            for _,z in ipairs({-0.25,0,0.25}) do
                local origin=cf:PointToWorldSpace(Vector3.new(size.X*x,size.Y/2+4,size.Z*z))
                local hit=WS:Raycast(origin,Vector3.new(0,-size.Y-8,0),include)
                if hit and hit.Normal.Y>0.7 then supports[#supports+1]=hit.Position end
            end
        end
        table.sort(supports,function(a,b) return a.Y<b.Y end)
        local jumpHeight=h.UseJumpPower and h.JumpPower^2/(2*math.max(1,WS.Gravity)) or h.JumpHeight
        for _,goal in ipairs(supports) do
            if not valid() then return false,"Cancelled" end
            local feet=root.Position.Y-h.HipHeight-root.Size.Y/2
            if goal.Y-feet<=jumpHeight+0.5 and (goal+Vector3.new(0,3,0)-t.world).Magnitude<=L.range then
                -- Native jump and MoveTo can climb surfaces omitted by navmesh.
                local controls=require(lp.PlayerScripts.PlayerModule):GetControls()
                local motion={root=root,humanoid=h,controls=controls,restoreControls=controls.controlsEnabled==true}
                L.motion=motion
                if motion.restoreControls then controls:Disable() end
                h.Jump=true
                h:MoveTo(goal+Vector3.new(0,h.HipHeight+root.Size.Y/2,0))
                local deadline=os.clock()+2.5
                local stood=false
                while valid() and os.clock()<deadline do
                    local under=WS:Raycast(root.Position,Vector3.new(0,-6,0),include)
                    if under and h.FloorMaterial~=Enum.Material.Air and flat(root.Position-goal).Magnitude<3 then stood=true break end
                    task.wait(0.05)
                end
                if L.motion==motion then L.Release() end
                if stood and waitUntil(0.2,valid) then
                    local ok,why=hitOre(t,terrain,vehicle,valid)
                    if ok then return true end
                    if why=="Pickaxe unavailable" or why=="Higher-priced ore available" then return false,why end
                end
            end
        end
        return false,"Ground and vehicle reach failed"
    end

    -- Build once, then update only replicated cells. A swing/search must not
    -- rebuild the mine's hundreds of thousands of air/stone cells each time.
    function L.Ores(terrain,valid)
        if not valid() then return {} end
        local registry=L.registry
        if not registry or registry.terrain~=terrain then
            if L.oreConnection then L.oreConnection:Disconnect() L.oreConnection=nil end
            registry={terrain=terrain,entries={},pending={},time=0}
            L.registry=registry
            local ok,connection=pcall(function()
                local event=require(RS.MadComm):GetModule("MineTerrain"):GetEvent("CellsChanged")
                return event.OnClientEvent:Connect(function(data)
                    if not alive() or L.registry~=registry then return end
                    -- Native Deserialize uses 14-byte changed records followed
                    -- by 12-byte removals. Read state after that callback settles.
                    local count=buffer.readu32(data,0)
                    local offset=4+count*14
                    local removed=buffer.readu32(data,offset)
                    if removed>4096 and removed>count*8 then
                        registry.entries,registry.pending={},{}
                        registry.built=false
                        registry.revision=(registry.revision or 0)+1
                        L.epoch=(L.epoch or 0)+1
                        L.ClearSkipped()
                        L.target,L.accessTarget=nil,nil
                        if L.delivery then
                            L.delivery.returnPoint,L.delivery.via=nil,nil
                            L.delivery.returnVia,L.delivery.outboundVia=nil,nil
                        end
                        state.status="Legit: mine reset; replanning from the new terrain"
                        return
                    end
                    for i=0,count-1 do
                        local offset=4+i*14
                        local pos=Vector3int16.new(buffer.readi32(data,offset),buffer.readi32(data,offset+4),buffer.readi32(data,offset+8))
                        registry.pending[tostring(pos)]=pos
                    end
                    for i=0,removed-1 do
                        local at=offset+4+i*12
                        local pos=Vector3int16.new(buffer.readi32(data,at),buffer.readi32(data,at+4),buffer.readi32(data,at+8))
                        registry.pending[tostring(pos)]=pos
                    end
                    registry.revision=(registry.revision or 0)+1
                end)
            end)
            if ok then L.oreConnection=connection table.insert(state.connections,connection) end
        end
        if not registry.built or (not L.oreConnection and os.clock()-registry.time>2) then
            local entries={}
            local store=terrain._Cells
            if store and type(store.List)=="function" then
                local count,slice=0,os.clock()
                for pos,cell in pairs(store:List()) do
                    if cell.Ore then entries[tostring(pos)]={pos=pos} end
                    count+=1
                    if count%2048==0 and os.clock()-slice>0.003 then
                        task.wait() slice=os.clock()
                        if not valid() then return {} end
                    end
                end
                state.terrainCellsSeen=count
            else
                for _,entry in ipairs(getTerrainCells(terrain,valid)) do entries[tostring(entry.pos)]=entry end
            end
            if not valid() then return {} end
            registry.entries,registry.built,registry.time=entries,true,os.clock()
            registry.builds=(registry.builds or 0)+1
            registry.revision=(registry.revision or 0)+1
        end
        for key,pos in pairs(registry.pending) do
            local cell=terrain:Get(pos)
            registry.entries[key]=cell and cell.Ore and {pos=pos} or nil
            registry.pending[key]=nil
            registry.updates=(registry.updates or 0)+1
        end
        return registry.entries
    end

    -- Enumerate loaded air next to real support throughout the tool's reach.
    -- An ore behind hard rock has no feasible stand even if its own hardness
    -- is low. Never spend a drive/path search discovering that distinction.
    function L.Plan(t,terrain,root,vehicle,valid)
        if not valid() then return end
        local range=L.range or 12
        if visible(t,root,vehicle,range) then return {goals={},direct=true} end
        L.plans=L.plans or {}
        local key=targetKey(t)
        local cached=L.plans[key]
        local revision=L.registry and L.registry.revision or 0
        if cached and cached.revision==revision and os.clock()-cached.time<4 then return cached.plan end
        local _,_,h=characterRoot()
        if not h then return end
        local lift=h.HipHeight+root.Size.Y/2+0.15
        local goals,access,seen={},{},{}
        local radius=math.ceil(range/4)
        local slice=os.clock()
        local function bodyOpen(stand,floor)
            local low=cellAt(Vector3.new(stand.X-1.1,floor.Y+0.4,stand.Z-1.1))
            local high=cellAt(stand+Vector3.new(1.1,2,1.1))
            for x=low.X,high.X do for y=low.Y,high.Y do for z=low.Z,high.Z do
                local c=terrain:Get(Vector3int16.new(x,y,z))
                if not c or c.Block~="Air" or c.Ore then return false end
            end end end
            return true
        end
        for x=-radius,radius do
            if os.clock()-slice>0.004 then task.wait() slice=os.clock() end
            if not valid() then return end
            for z=-radius,radius do for y=-radius,radius do
                local pos=Vector3int16.new(t.pos.X+x,t.pos.Y+y,t.pos.Z+z)
                local c=terrain:Get(pos)
                if not c or c.Block~="Air" or c.Ore then continue end
                local below=terrain:Get(Vector3int16.new(pos.X,pos.Y-1,pos.Z))
                if not below or (below.Block=="Air" and not below.Ore) then continue end
                local base=worldAt(pos)
                if (base-t.world).Magnitude>range+3 then continue end
                local floor=floorAt(base,vehicle,0,7)
                if not floor then continue end
                local stand=floor+Vector3.new(0,lift,0)
                if (stand-t.world).Magnitude>range-0.5 or not bodyOpen(stand,floor) then continue end
                local floorKey=tostring(cellAt(floor+Vector3.new(0,0.5,0)))
                if seen[floorKey] then continue end
                seen[floorKey]=true
                if visible(t,{Position=stand},vehicle,range-0.5) then
                    goals[#goals+1]=floor
                elseif L.cfg.DigAccess then
                    local delta=t.world-stand
                    local hit=WS:Raycast(stand,delta.Unit*(delta.Magnitude+2),params(vehicle,true))
                    if hit and hit.Instance==WS.Terrain then
                        local block=L.AccessBlock(terrain,cellAt(hit.Position-hit.Normal*0.1),{Position=stand},range)
                        if block and block.pos~=t.pos and block.world.Y>floor.Y+0.5
                            and (block.world-t.world).Magnitude<=12
                            and visible(block,{Position=stand},vehicle,range) then access[#access+1]=floor end
                    end
                end
            end end
        end
        -- Immediately after a mine reset, the exterior of the entrance is
        -- real walkable ground but is intentionally absent from MineTerrain.
        -- Approach that front face and dig a short, tool-compatible entrance;
        -- movement still has to pass native path/body checks before any hit.
        if #goals==0 and #access==0 and L.cfg.DigAccess and terrain._MineOrigin then
            local origin=worldAt(terrain._MineOrigin)
            local axis=flat(driveAxis()).Unit
            local depth=(t.world-origin):Dot(axis)
            local playerDepth=(root.Position-origin):Dot(axis)
            if depth>=0 and depth<=range+8 and playerDepth<20 then
                local side=Vector3.new(-axis.Z,0,axis.X)
                local center=t.world-axis*(depth+5)
                for _,offset in ipairs({0,4,-4}) do
                    if not valid() then return end
                    local p=center+side*offset
                    local floor=floorAt(Vector3.new(p.X,root.Position.Y,p.Z),vehicle,2,14)
                    if not floor then continue end
                    local stand=floor+Vector3.new(0,lift,0)
                    local delta=t.world-stand
                    if delta.Magnitude>range+8 then continue end
                    if visible(t,{Position=stand},vehicle,range-0.5) then goals[#goals+1]=floor
                    else
                        local hit=WS:Raycast(stand,delta.Unit*math.min(delta.Magnitude+2,range),params(vehicle,true))
                        local block=hit and hit.Instance==WS.Terrain
                            and L.AccessBlock(terrain,cellAt(hit.Position-hit.Normal*0.1),{Position=stand},range)
                        if block and block.world.Y>floor.Y+0.5 and visible(block,{Position=stand},vehicle,range) then
                            access[#access+1]=floor
                        end
                    end
                end
            end
        end
        local function closest(a,b) return (a-root.Position).Magnitude<(b-root.Position).Magnitude end
        table.sort(goals,closest) table.sort(access,closest)
        local plan=#goals>0 and {goals=goals} or (#access>0 and {goals=access,access=true} or nil)
        L.plans[key]={time=os.clock(),revision=revision,plan=plan}
        return plan
    end

    function L.Select(terrain,root,valid)
        local started=os.clock()
        local strength,speed=pickaxeStrength(),MiningUtils.GetPlayerPickaxeSpeedClient()
        local candidates={}
        for _,entry in pairs(L.Ores(terrain,valid)) do
            if not valid() then return end
            -- Unknown/generated cells are not exposed physical mining targets.
            local cell=terrain:Get(entry.pos)
            local id=cell and cell.Ore
            local def=id and BlockDefinitions[id]
            if def and def.Hardness and def.Hardness<=strength and not def.ExplosiveOnly
                and not (def.Types and (def.Types.Terrain or def.Types.Boundary)) then
                local world=worldAt(entry.pos)
                local duration=MiningTime(speed,strength,def.Hardness)
                local t={pos=entry.pos,world=world,id=id,def=def,value=tonumber(def.Value) or 0,
                    distance=(root.Position-world).Magnitude}
                if duration and duration<999 and t.distance<=L.cfg.Radius and not L.IsSkipped(t) then
                    candidates[#candidates+1]=t
                end
            end
        end
        table.sort(candidates,function(a,b)
            if a.value~=b.value then return a.value>b.value end
            if a.distance~=b.distance then return a.distance<b.distance end
            return targetKey(a)<targetKey(b)
        end)
        local vehicle=getOwnedVehicle()
        for _,t in ipairs(candidates) do
            if not valid() then return end
            t.plan=L.Plan(t,terrain,root,vehicle,valid)
            if t.plan then L.selectMs=(os.clock()-started)*1000 return t end
        end
        L.selectMs=(os.clock()-started)*1000
    end

    -- A trip starts only with BOTH capacities full. Once started, finish the
    -- entire batch (including a partial last shuttle) before returning to mine.
    function L.CargoPlan(count,capacity,vc,vmax,delivery)
        if not count or not capacity or capacity<=0 or not vc or not vmax or vmax<=0 then return "Unknown" end
        if delivery then return delivery.phase=="Return" and "Return" or "Deliver" end
        if count>=capacity then return vc>=vmax and "Deliver" or "Load vehicle" end
        return "Mine"
    end

    function L.VehicleSubmerged(vehicle)
        local part=vehicle.Model.PrimaryPart
        local hit=WS:Raycast(part.Position+Vector3.new(0,20,0),Vector3.new(0,-35,0),params(vehicle))
        return hit and hit.Material==Enum.Material.Water and hit.Position.Y>part.Position.Y+1 or false
    end

    local function approachPrompt(prompt,vehicle,valid)
        if not valid() or not prompt or not prompt.Parent then return false end
        local cf=pointOf(prompt.Parent)
        local _,root=characterRoot()
        if not cf or not root then return false end
        local distance=math.max(0.5,prompt.MaxActivationDistance-0.8)
        if (root.Position-cf.Position).Magnitude<=distance then return true end
        local goals={}
        for i=0,7 do
            local a=i*math.pi/4
            local offset=math.max(2,math.min(6,distance-2))
            local near=floorAt(cf.Position+Vector3.new(math.cos(a)*offset,0,math.sin(a)*offset),vehicle,5,35)
            if near and (near+Vector3.new(0,3,0)-cf.Position).Magnitude<=distance then goals[#goals+1]=near end
        end
        table.sort(goals,function(a,b) return (a-root.Position).Magnitude<(b-root.Position).Magnitude end)
        for i=1,math.min(4,#goals) do
            if not valid() then return false end
            if walk(goals[i],valid,18) and (root.Position-cf.Position).Magnitude<=distance then return true end
            if L.computing then return false end
        end
        return false
    end

    -- Count changes are read from replicated cargo serializations, never from
    -- local CargoVolume:PullFrom/Pop or prompt dispatch alone.
    local function transfer(vehicle,action,valid)
        if not exitVehicle(valid) or not valid() then return false,"Cannot exit vehicle" end
        local prompt=vehicleCargoPrompt(vehicle)
        if not approachPrompt(prompt,vehicle,valid) then return false,"Vehicle cargo is out of reach" end
        local count,capacity=cargoStatus()
        local vc,vmax=vehicleCargoStatus()
        if not count or not vc then return false,"Cargo state unavailable" end
        local adding=action=="Add Items"
        if adding and (count==0 or vc>=vmax) then return true end
        if not adding and (vc==0 or count>=capacity) then return true end
        local beforeCount,beforeVC=count,vc
        -- One dispatch in flight. Do not retry an unconfirmed transfer and
        -- accidentally reverse it when the prompt switches to Take Items.
        if not promptAt(prompt,action,vehicle,valid) then return false,"Waiting for "..action.." prompt" end
        local deadline=os.clock()+4
        while valid() and os.clock()<deadline do
            count,capacity=cargoStatus()
            vc,vmax=vehicleCargoStatus()
            if count and vc then
                local moved=adding and beforeCount-count or count-beforeCount
                local other=adding and vc-beforeVC or beforeVC-vc
                if moved>0 and moved==other then
                    if adding then L.transfers+=1 end
                    L.lastResult=("%s: backpack %d -> %d, vehicle %d -> %d"):format(action,beforeCount,count,beforeVC,vc)
                    return true
                end
            end
            task.wait(0.05)
        end
        return false,"Cargo transfer not confirmed"
    end
    L.Transfer=transfer

    local function unloadBackpackHere(vehicle,valid)
        local prompt=unloaderPrompt()
        if not approachPrompt(prompt,vehicle,valid) then return false,"Own unloader is out of reach" end
        local count=cargoStatus()
        if count==nil then return false,"Backpack state unavailable" end
        local initial=count
        local deadline,lastProgress=os.clock()+state.cfg.SellTimeout,os.clock()
        while valid() and count>0 and os.clock()<deadline do
            if os.clock()-lastProgress>5 then return false,"Unloader made no progress" end
            local before=count
            if prompt.ActionText~="Add Items" then
                state.status="Legit: waiting for factory to make room in the unloader"
                if not waitUntil(0.2,valid) then return false,"Cancelled" end
                continue
            end
            if not promptAt(prompt,"Add Items",vehicle,valid) then return false,L.promptError or "Unloader prompt not ready" end
            local untilTime=os.clock()+1
            repeat
                if not waitUntil(0.05,valid) then return false,"Cancelled" end
                count=cargoStatus()
            until count==nil or count<before or os.clock()>=untilTime
            if count==nil then return false,"Backpack state unavailable" end
            if count<before then lastProgress=os.clock() end
        end
        if valid() and count==0 then
            if initial>0 then
                state.sellCycles=(state.sellCycles or 0)+1
                L.lastResult=("Backpack unloaded (%d -> 0)"):format(initial)
            end
            return true
        end
        return false,"Backpack unload timed out"
    end

    local function tripVia(vehicle)
        local terrain=MineTerrain.GetInstance()
        if not terrain or not terrain._MineOrigin then return end
        local origin=worldAt(terrain._MineOrigin)
        local axis=driveAxis()
        local part=vehicle.Model.PrimaryPart
        if (part.Position-origin):Dot(axis)<200 then return end
        local side=axis:Cross(Vector3.new(0,1,0))
        local lateral=(part.Position-origin):Dot(side)
        -- Preserve the current mine lane while crossing its entrance. Splits
        -- deep mine -> surface -> factory into bounded navmesh requests.
        return floorAt(origin+side*lateral-axis*24,vehicle,20,100)
    end

    local function deliveryStep(vehicle,valid)
        local job=L.delivery
        if not job or job.vehicle~=vehicle then return false,"Delivery vehicle changed; cargo retained" end
        if job.phase=="Return" then
            L.phase="Returning to mine"
            state.status="Legit: full batch delivered; returning to mining area"
            if job.via and not job.returnVia then
                if not driveTo(vehicle,job.via,valid) then return false,"Mine entrance return route blocked" end
                if not valid() then return false,"Cancelled" end
                job.returnVia=true
            end
            if not job.returnPoint or driveTo(vehicle,job.returnPoint,valid) then
                if not valid() then return false,"Cancelled" end
                L.delivery=nil
                L.deliveries+=1
                return true
            end
            return false,"Mine return route blocked"
        end
        local prompt=unloaderPrompt()
        local cf=prompt and pointOf(prompt.Parent)
        if not cf then return false,"Own unloader unavailable" end
        L.phase="Delivering full load"
        state.status="Legit: backpack and vehicle full; driving to own unloader"
        if job.phase=="Outbound" then
            if not job.via then job.via=tripVia(vehicle) end
            if job.via and not job.outboundVia then
                if not driveTo(vehicle,job.via,valid) then return false,"Mine exit route blocked" end
                if not valid() then return false,"Cancelled" end
                job.outboundVia=true
            end
            local part=vehicle.Model.PrimaryPart
            if flat(part.Position-cf.Position).Magnitude>23 then
                local goals={}
                local _,size=vehicle.Model:GetBoundingBox()
                local offset=math.max(14,size.X/2+size.Z/2+6)
                for i=0,7 do
                    local a=i*math.pi/4
                    local goal=floorAt(cf.Position+Vector3.new(math.cos(a)*offset,0,math.sin(a)*offset),vehicle,8,60)
                    if goal then goals[#goals+1]=goal end
                end
                table.sort(goals,function(a,b) return (a-part.Position).Magnitude<(b-part.Position).Magnitude end)
                local parked=false
                for i=1,math.min(3,#goals) do
                    if not valid() then return false,"Cancelled" end
                    if driveTo(vehicle,goals[i],valid) then parked=true break end
                    if L.computing then break end
                end
                if not parked then return false,"Unloader driving route blocked" end
            end
            if not valid() then return false,"Cancelled" end
            job.phase="Shuttle"
        end
        L.phase="Unloading full batch"
        state.status="Legit: unloading batch at own factory"
        if not exitVehicle(valid) then return false,"Cannot exit vehicle" end
        local count,capacity=cargoStatus()
        local vc,vmax=vehicleCargoStatus()
        if not count or not vc then return false,"Cargo state unavailable" end
        -- Exactly one shuttle per scheduler step; job survives a failed walk,
        -- Stop/off-on and character respawn without requiring full cargo again.
        if count>0 then
            local ok,why=unloadBackpackHere(vehicle,valid)
            if not ok then return false,why end
        end
        if not valid() then return false,"Cancelled" end
        vc=vehicleCargoStatus()
        if vc==nil then return false,"Vehicle cargo state unavailable" end
        if vc>0 then return transfer(vehicle,"Take Items",valid) end
        count=cargoStatus()
        if count==0 and valid() then
            job.phase="Return"
            L.lastResult="Full batch unloaded; returning to mine"
            return true
        end
        return false,"Waiting for empty cargo confirmation"
    end
    L.DeliveryStep=deliveryStep
    -- Kept as a diagnostics entry point, with the same full-load gate.
    function L.Unload(vehicle,valid)
        local count,capacity=cargoStatus()
        local vc,vmax=vehicleCargoStatus()
        if L.CargoPlan(count,capacity,vc,vmax,L.delivery)~="Deliver" then return false,"Both capacities must be full" end
        if not L.delivery then
            L.delivery={vehicle=vehicle,phase="Outbound",
                via=tripVia(vehicle),
                returnPoint=floorAt(vehicle.Model.PrimaryPart.Position,vehicle,0,35)}
        end
        return deliveryStep(vehicle,valid)
    end
    L.RoofAttempt=roofAttempt

    local function ensureVehicle(valid)
        local vehicle=getOwnedVehicle()
        if currentVehicle(vehicle) then return vehicle end
        if L.delivery then
            state.status="Legit: delivery vehicle unavailable; waiting to preserve its cargo"
            return
        end
        if not valid() or os.clock()<(L.nextSpawn or 0) then return end
        L.nextSpawn=os.clock()+10
        -- Only spawn an already owned vehicle; never buy or replace a live car.
        local data=require(RS.Controllers.PlayerDataController).LocalPlayerData
        local definitions=require(RS.Definitions.VehicleDefinitions)
        local definition
        for id,owned in pairs(data.OwnedVehicles or {}) do
            local d=owned and definitions[id]
            if d and (not definition or (tonumber(d.Cost) or 0)>(tonumber(definition.Cost) or 0)
                or (d.Cost==definition.Cost and tostring(d.Id)<tostring(definition.Id))) then definition=d end
        end
        if not definition then state.status="Legit: no owned vehicle available" return end
        local grid=require(RS.Packages.Factory.FactoryGrid).ForPlayer(lp)
        local spawner
        for _,slot in pairs(grid:GetAllSlots()) do
            if slot.Type=="VehicleSpawner" and slot.Owner==lp and not slot.Destroyed then spawner=slot break end
        end
        if not spawner then state.status="Legit: own vehicle spawner unavailable" return end
        if not valid() or getOwnedVehicle() then return getOwnedVehicle() end
        state.status="Legit: spawning owned "..tostring(definition.Name or definition.Id)
        VehicleController:CreateVehicleAtSpawner(definition,spawner.Position)
        local deadline=os.clock()+6
        while valid() and os.clock()<deadline do
            vehicle=getOwnedVehicle()
            if currentVehicle(vehicle) then return vehicle end
            task.wait(0.1)
        end
    end
    L.EnsureVehicle=ensureVehicle

    function L.Step()
        if not L.enabled or L.working or not alive() then return end
        if L.computing then state.status="Legit: waiting for previous path computation" return end
        if state.pendingAction and not state.pendingAction.done then state.status="Legit: waiting for previous server response" return end
        if os.clock()<(L.nextWork or 0) then return end
        local char,root,h=characterRoot()
        local terrain=MineTerrain.GetInstance()
        if not root or not terrain then state.status="Legit: waiting for character/terrain" return end
        local token=state.cancelVersion
        local epoch=L.epoch
        local function sessionValid()
            return alive() and L.enabled and token==state.cancelVersion and lp.Character==char
                and epoch==L.epoch
                and root.Parent~=nil and h.Health>0 and MineTerrain.GetInstance()==terrain
        end
        L.working=true
        local ok,err=pcall(function()
            local vehicle=ensureVehicle(sessionValid)
            if not sessionValid() then return end
            if not currentVehicle(vehicle) then
                state.status="Legit: waiting for owned vehicle/spawner"
                L.nextWork=os.clock()+2
                return
            end
            local function valid() return sessionValid() and currentVehicle(vehicle)~=nil end
            local strength=pickaxeStrength()
            local context=L.context
            if not context or context.terrain~=terrain or context.vehicle~=vehicle or context.strength~=strength
                or context.char~=char then
                L.ClearSkipped()
                L.context={terrain=terrain,vehicle=vehicle,strength=strength,char=char,range=L.range}
                if L.delivery and L.delivery.vehicle~=vehicle then L.delivery=nil end
            end
            local count,capacity=cargoStatus()
            local vc,vmax=vehicleCargoStatus()
            local plan=L.CargoPlan(count,capacity,vc,vmax,L.delivery)
            if plan~="Mine" and plan~="Unknown" and L.VehicleSubmerged(vehicle) then
                L.SetEnabled(false)
                L.phase="Vehicle needs recovery"
                state.status="Legit paused: vehicle submerged. Move it to dry ground, then enable Legit to resume the retained cargo trip."
                return
            end
            if plan=="Unknown" then
                L.phase="Waiting for cargo"
                state.status="Legit: waiting for replicated backpack and vehicle capacity"
                L.nextWork=os.clock()+0.5
                return
            end
            if plan=="Load vehicle" then
                L.phase="Loading vehicle"
                state.status="Legit: full backpack -> vehicle cargo"
                local loaded,why=transfer(vehicle,"Add Items",valid)
                if not loaded and valid() then state.status="Legit: "..tostring(why) L.nextWork=os.clock()+2 end
                return
            end
            if plan=="Deliver" or plan=="Return" then
                if not L.delivery then
                    L.delivery={vehicle=vehicle,phase="Outbound",
                        via=tripVia(vehicle),
                        returnPoint=floorAt(vehicle.Model.PrimaryPart.Position,vehicle,0,35)}
                end
                local delivered,why=deliveryStep(vehicle,valid)
                if not delivered and valid() then state.status="Legit: "..tostring(why).."; retrying" L.nextWork=os.clock()+3 end
                return
            end
            -- Driving disables the native backpack. Cargo delivery must run
            -- before attempting to equip a tool, including after a reload.
            if not exitVehicle(valid) or not valid() then return end
            local client=pickaxeClient()
            if not valid() then return end
            if not client then state.status="Legit: waiting for a pickaxe" L.nextWork=os.clock()+1 return end
            L.range=tonumber(client.Tool.Definition.Stats.Range) or 12
            if L.context.range~=L.range then L.ClearSkipped() L.context.range=L.range end
            L.phase="Searching"
            local t=L.Select(terrain,root,valid)
            local access=L.accessTarget
            if access and access.def.Hardness<=strength and sameCell(terrain,access) and not L.IsSkipped(access)
                and (root.Position-access.world).Magnitude<=L.cfg.Radius and (not t or access.value>=t.value) then
                access.distance=(root.Position-access.world).Magnitude
                t=access
            else L.accessTarget=nil end
            if not valid() then return end
            if not t then
                L.target=nil
                state.status="Legit: no reachable mineable ore in the loaded search radius"
                if terrain._MineOrigin and os.clock()>=(L.nextExplore or 0) then
                    local origin=worldAt(terrain._MineOrigin)
                    if flat(root.Position-origin).Magnitude>250 then
                        L.phase="Travelling to mine"
                        state.status="Legit: driving to the mine to load ore"
                        local goal=floorAt(origin,vehicle,16,80)
                        if goal then driveTo(vehicle,goal,valid) end
                    end
                    L.nextExplore=os.clock()+10
                end
                L.nextWork=os.clock()+0.5
                return
            end
            L.target=t
            state.currentOre,state.targetPrice,state.targetDistance=t.id,t.value,t.distance
            -- Stay on foot for a local cluster. No seat round-trip after each
            -- confirmed ore; the car moves only for travel or a full batch.
            local part=vehicle.Model.PrimaryPart
            local nearby=visible(t,root,vehicle,L.range) or t.distance<=L.cfg.WalkRadius
            if not nearby then
                L.phase="Driving to "..t.id
                local parked=false
                for i,goal in ipairs(parking(t,vehicle)) do
                    if not valid() then return end
                    if i>3 then break end
                    state.status="Legit: driving to "..t.id
                    if driveTo(vehicle,goal,valid) then parked=true break end
                    if L.computing then break end
                end
                if not valid() or not sameCell(terrain,t) then return end
                if not parked then
                    if L.computing then state.status="Legit: waiting for path computation"
                    elseif not L.cfg.DigAccess or t.distance>600 then L.Skip(t,false,"No vehicle route") return
                    else state.status="Legit: vehicle route blocked; digging access on foot" end
                    if L.computing then return end
                end
            end
            if not exitVehicle(valid) or not valid() then return end
            local client=pickaxeClient()
            if not valid() then return end
            if not client then state.status="Legit: equip a pickaxe" return end
            L.range=tonumber(client.Tool.Definition.Stats.Range) or 12
            local mined,why=groundAttempt(t,terrain,vehicle,valid)
            if not valid() or mined or not sameCell(terrain,t) then return end
            if why=="Higher-priced ore available" then return end
            if why~="Pickaxe unavailable" and L.cfg.DigAccess and (t.world-root.Position).Magnitude<=L.range+4 then
                mined,why=accessAttempt(t,terrain,vehicle,valid)
                if not valid() or mined or not sameCell(terrain,t) then return end
                if why=="Higher-priced ore available" then return end
                if why=="Access progress" or why=="Backpack full" or why=="Cargo state unavailable" then
                    L.accessTarget=t
                    return
                end
            end
            if not mined and why~="Pickaxe unavailable" and L.cfg.TryVehicle
                and flat(root.Position-vehicle.Model.PrimaryPart.Position).Magnitude<20 then
                mined,why=roofAttempt(t,terrain,vehicle,valid)
            end
            if not valid() then return end
            if why=="Higher-priced ore available" then return end
            if not mined and sameCell(terrain,t) and why~="Pickaxe unavailable" then
                L.Skip(t,true,why or "Ore unreachable")
            end
            L.phase="Searching"
        end)
        L.Release()
        L.working=false
        if not ok and sessionValid() then
            state.status="Legit retry: "..tostring(err)
            L.nextWork=os.clock()+2
        end
    end
end


----------------------------------------------------------------
-- GUI
----------------------------------------------------------------

local Library
for _, url in ipairs({
    "https://raw.githubusercontent.com/Xa3ro5/LifeIsRoblox/refs/heads/main/SmugLibCoreV2.lua",
    "https://pastebin.com/raw/CkVW0eJZ",
}) do
    local ok, result = pcall(function() return loadstring(game:HttpGet(url))() end)
    if ok and type(result) == "table" then Library = result break end
end

if not Library then state.Stop() warn("[MineAura] SmugLib load failed") return end

local win = Library:CreateWindow("Ultimate Mining | Control Center", {
    Width = 640, Height = 500, ToggleKey = Enum.KeyCode.RightShift,
    ConfigKey = "ultimate_mining_v29", ConfigAutoSave = false,
})
state.win = win
win:SetOnClose(function() if state.alive then state.Stop() end end)
state.gui = (type(win.GetGui) == "function" and win:GetGui()) or win.Gui or win.gui

local main = win:Folder("Automation")
local statusSection = main:Section("Status")
state.miningLabel = statusSection:Label("Ready")
state.cargoLabel = statusSection:Label("Backpack: loading")
state.vehicleLabel = statusSection:Label("Vehicle: loading")
state.perfLabel = statusSection:Label("Mined: 0")
local mining = main:Section("Mining")
state.mineToggle = mining:Toggle("Automine",function(on)
    if on and not state.uiReady then return end
    if on then state.Legit.SetEnabled(false) end
    state.running=on
    invalidateMining()
    if not on then cancelAction() end
end,false,Enum.KeyCode.P)
mining:Label("Loaded terrain + PlacedOre: highest price first; new expensive ore interrupts mining.")
mining:Label("Server-confirmed mining; blocked targets are skipped temporarily.")
mining:Button("Stop all automation",function()
    state.Legit.SetEnabled(false)
    state.running=false
    state.cfg.AutoSell=false
    state.cfg.AutoDriveForward=false
    releaseAutoDrive()
    state.manualSell=false
    state.cancelVersion+=1
    cancelAction()
    invalidateMining()
    state.mineToggle:Set(false)
    state.autoSellToggle:Set(false)
    if state.autoDriveToggle then state.autoDriveToggle:Set(false) end
    state.SetExplosionCooldownBypass(false)
    if state.explosionCooldownToggle then state.explosionCooldownToggle:Set(false) end
    state.status="Automation stopped"
end)
local selling = main:Section("Unloading")
state.autoSellToggle=selling:Toggle("Autosell (backpack + vehicle)",function(on)
    if on and not state.uiReady then return end
    if on then state.Legit.SetEnabled(false) end
    state.cfg.AutoSell=on
end,false)
selling:Slider("Unload backpack at (%)",25,100,state.cfg.SellPercent,function(v) state.cfg.SellPercent=v end,5)
selling:Button("Sell backpack now",function() state.manualSell="Backpack" end)
state.autoDriveToggle=selling:Toggle("Auto drive forward",function(on)
    if on and not state.uiReady then return end
    if on then state.Legit.SetEnabled(false) end
    state.cfg.AutoDriveForward=on
    state.cancelVersion+=1
    invalidateMining()
    cancelAction()
    state.driveClearUntil=0
    if not on then releaseAutoDrive() end
    state.status=on and "Autodrive: scanning ahead" or "Autodrive disabled"
end,false)
selling:Button("Sell vehicle cargo now",function() state.manualSell="Vehicle" end)
selling:Label("Automatically exits, transfers cargo and unloads. Vehicle stays in place.")
selling:Toggle("Return after unloading",function(on) state.cfg.ReturnAfterSell=on end,true)
selling:Toggle("Return to driver seat after unloading",function(on) state.cfg.ReturnToVehicle=on end,true)
local vehicleSection = main:Section("Vehicle behavior")
vehicleSection:Label("Keeps a straight downhill lane. Uses C4 for Obsidian and a pickaxe for hard ore before resuming.")

local explosiveSection = main:Section("Explosives")
state.explosionScanSlider=explosiveSection:Slider("Explosive scan area (%)",0,100,
    state.cfg.ExplosionScanScale,state.SetExplosionScanScale,10)
explosiveSection:Label("100% = DrillZone; adjusts the Obsidian search area around the drill center.")
explosiveSection:Label("0% = explosive placement search disabled.")
explosiveSection:Toggle("Show explosive scan area",function(on)
    state.cfg.ShowExplosionArea=on
    state.UpdateExplosionAreaVisual()
end,true)
explosiveSection:Label("The orange box shows the exact scan area, including voxel overlap.")
state.explosionCooldownToggle = explosiveSection:Toggle("Cooldown bypass (Humanoid reset)",function(on)
    if on and state.Legit.enabled then
        if state.explosionCooldownToggle then state.explosionCooldownToggle:Set(false) end
        notify("Disable Legit before enabling reset bypass")
        return
    end
    state.SetExplosionCooldownBypass(on)
end,false)
explosiveSection:Label("At 0 charges: reset, hold camera, return after respawn. Also works with Auto drive forward.")
explosiveSection:Label("Returns to the driver seat if reset started there. Disables itself if charges stay empty.")
state.explosionResetLabel = explosiveSection:Label("Reset bypass: off")

local legitFolder=win:Folder("Legit")
local legitSection=legitFolder:Section("Complete mining cycle")
state.legitToggle=legitSection:Toggle("Legit automine",state.Legit.SetEnabled,false)
legitSection:Label("Highest value first, within pickaxe strength and physical reach. Walk nearby; drive for longer trips.")
legitSection:Slider("Search radius (studs)",100,3000,state.Legit.cfg.Radius,function(v)
    state.Legit.cfg.Radius=v
    state.cancelVersion+=1
    state.Legit.Release()
end,25)
legitSection:Toggle("Try standing on vehicle",function(on) state.Legit.cfg.TryVehicle=on end,true)
legitSection:Toggle("Dig stone access to valuable ore",function(on) state.Legit.cfg.DigAccess=on end,true)
legitSection:Label("Full-load delivery is automatic. Unknown capacity waits; partial loads stay in the mine.")
local legitSkip=legitFolder:Section("Unreachable ore")
legitSkip:Slider("Skip duration (seconds)",15,300,state.Legit.cfg.SkipSeconds,function(v)
    state.Legit.cfg.SkipSeconds=v
end,15)
legitSkip:Slider("Skip nearby same ore (studs)",0,60,state.Legit.cfg.ClusterRadius,function(v)
    state.Legit.cfg.ClusterRadius=v
end,4)
legitSkip:Label("After reach failure, nearby same ore at the same height or higher is skipped temporarily.")
legitSkip:Button("Clear skipped targets",state.Legit.ClearSkipped)
legitSkip:Button("Stop Legit",function() state.Legit.SetEnabled(false) end)
state.legitStatus=legitSkip:Label("Legit: Off")
state.legitResult=legitSkip:Label("Confirmed: 0 | Skipped: 0")

----------------------------------------------------------------
-- TELEPORT
----------------------------------------------------------------

local tpFolder = win:Folder("Teleport")
local tpSection = tpFolder:Section("Quick travel")

local function ownPlot()
    local plots = WS:FindFirstChild("Plots")
    if not plots then return end
    for _, v in ipairs(plots:GetChildren()) do
        if tostring(v:GetAttribute("OwnerId")) == tostring(lp.UserId)
            or v.Name == tostring(lp:GetAttribute("PlotId")) then return v end
    end
end

local function guiOrPartPoint(v)
    if not v then return end
    if v:IsA("BillboardGui") or v:IsA("SurfaceGui") then
        local adornee = v.Adornee
        return adornee and pointOf(adornee)
    end
    return pointOf(v)
end

local teleportDestinations = {
    "My base", "My car", "Backpack store", "Pickaxe store",
    "Explosives store", "Prestige store", "Mine",
}

local function resolveTeleport(name)
    if name == "My base" then
        return guiOrPartPoint(ownPlot())
    elseif name == "My car" then
        local vehicle=getOwnedVehicle()
        local model=vehicle and vehicle.Model
        if not model or not model:IsDescendantOf(WS) then
            return nil,"You don't have a car spawned."
        end
        return model:GetPivot()
    elseif name == "Backpack store" then
        return guiOrPartPoint(WS:FindFirstChild("Backpack Store"))
    elseif name == "Pickaxe store" then
        return guiOrPartPoint(WS:FindFirstChild("Pickaxe Store"))
    elseif name == "Explosives store" then
        return guiOrPartPoint(WS:FindFirstChild("Explosives Store"))
    elseif name == "Prestige store" then
        return guiOrPartPoint(WS:FindFirstChild("Prestige Store"))
    elseif name == "Mine" then
        local cs = WS:FindFirstChild("CollapseStuff")
        local sign = cs and cs:FindFirstChild("CollapseSignGui")
        return guiOrPartPoint(sign)
    end
end

local function teleportToCF(cf, reason)
    if state.Legit.enabled then state.Legit.SetEnabled(false) end
    if not cf then notify(reason or "Location not found") return end
    if state.isDriving() then notify("Exit the vehicle first") return end
    local _, root = characterRoot()
    if not root then notify("Character not ready") return end
    cf = cf + Vector3.new(0, 4, 0)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.CFrame = cf
    if state.flyEnabled then
        state.flyCoordinate = cf
        state.flyHRP = root
    end
    notify("Teleported")
end

local selectedTeleport = teleportDestinations[1]
tpSection:Dropdown("Destination", teleportDestinations, function(v)
    selectedTeleport = v
    teleportToCF(resolveTeleport(v))
end, teleportDestinations[1])

tpSection:Button("Teleport to selected", function()
    teleportToCF(resolveTeleport(selectedTeleport))
end)

----------------------------------------------------------------
-- PLAYER + FLIGHT
----------------------------------------------------------------

local playerFolder = win:Folder("Player")
local movSection = playerFolder:Section("Movement & Controls")

state.noclipToggle=movSection:Toggle("Noclip",function(on)
    if on and not state.uiReady then return end
    if on and state.Legit.enabled then state.noclipToggle:Set(false) return end
    state.SetNoclip(on)
end,false)

state.ctrlClickToggle=movSection:Checkbox("Ctrl + Click Teleport", function(on)
    state.ctrlClickTP = on and not state.Legit.enabled
    if on and state.Legit.enabled and state.ctrlClickToggle then state.ctrlClickToggle:Set(false) end
end, false)
state.ctrlDeleteToggle=movSection:Checkbox("Ctrl + Delete (delete object)", function(on)
    state.ctrlDelete = on and not state.Legit.enabled
    if on and state.Legit.enabled and state.ctrlDeleteToggle then state.ctrlDeleteToggle:Set(false) end
end, false)

movSection:Slider("Walk Speed", 16, 500, state.walkSpeed, function(v)
    if state.Legit.enabled then notify("Disable Legit before changing movement stats") return end
    state.walkSpeed = v
    local _, _, h = characterRoot()
    if h then h.WalkSpeed = v end
end, 1)

movSection:Slider("Jump Height", 50, 500, state.jumpHeight, function(v)
    if state.Legit.enabled then notify("Disable Legit before changing movement stats") return end
    state.jumpHeight = v
    local _, _, h = characterRoot()
    if h then h.JumpPower = v end
end, 1)

local flySection = playerFolder:Section("Flight")
state.flyToggle = flySection:Toggle("Fly", function(on)
    if on and state.Legit.enabled then state.flyToggle:Set(false) return end
    state.flyEnabled = on
    if on then resetFlyCoordinate() end
end, false, Enum.KeyCode.X)
flySection:Slider("Fly Speed", 1, 500, state.flySpeed, function(v) state.flySpeed = v end, 1)
flySection:Label("Controls: W/A/S/D move, Space up, LeftShift down")

----------------------------------------------------------------
-- SERVER HOP
----------------------------------------------------------------

local hopFolder = win:Folder("Network")
local hopSection = hopFolder:Section("Server hop")

hopSection:Label("Never rejoins the server you just left.")
state.hopStatusLabel = hopSection:Label("Last server: "..(loadLastJob() and tostring(loadLastJob()):sub(1, 12) or "none"))

hopSection:Checkbox("Prefer non-full servers", function(on) state.cfg.HopPriorityFull = on end, true)
hopSection:Checkbox("Try to requeue script after teleport", function(on) state.cfg.AutoRequeue = on end, true)

hopSection:Button("Server Hop (leave & join other)", function()
    if state.hopping then return end
    state.Legit.SetEnabled(false)
    notify("Server hop requested…")
    state.running = false
    if state.mineToggle then pcall(function() state.mineToggle:Set(false) end) end
    if state.autoSellToggle then pcall(function() state.autoSellToggle:Set(false) end) end
    if state.autoDriveToggle then pcall(function() state.autoDriveToggle:Set(false) end) end
    state.cfg.AutoSell = false
    state.cfg.AutoDriveForward = false
    releaseAutoDrive()
    invalidateMining()
    task.wait(0.3)
    serverHop(true)
end)

hopSection:Button("Rejoin current server", function()
    state.Legit.SetEnabled(false)
    notify("Rejoining current server…")
    state.cfg.AutoDriveForward = false
    releaseAutoDrive()
    if state.autoDriveToggle then pcall(function() state.autoDriveToggle:Set(false) end) end
    pcall(function()
        local opts = Instance.new("TeleportOptions")
        opts.ServerInstanceId = game.JobId
        TeleportService:TeleportAsync(game.PlaceId, {lp}, opts)
    end)
end)

----------------------------------------------------------------
-- HELP
----------------------------------------------------------------

local help = win:Folder("Game guide"):Section("Automation")
help:Label("Enable Automine + Autosell for the complete mining/unloading cycle.")
help:Label("Loaded terrain and PlacedOre are rescanned and mined by descending price.")
help:Label("Blocks requiring explosives or a stronger pickaxe are skipped.")
help:Label("Unloading uses your backpack and never moves the vehicle.")
help:Label("Unloader needs free capacity and a working conveyor/Seller.")
help:Button("Unload script",state.Stop)

----------------------------------------------------------------
-- CLEANUP HOOKS
----------------------------------------------------------------

table.insert(state.connections, lp.CharacterRemoving:Connect(function()
    state.Legit.Release()
    state.Legit.target=nil
    state.Legit.ClearSkipped()
    restoreNoclip()
    releaseAutoDrive()
    state.cancelVersion += 1
    invalidateMining()
    state.manualSell = false
    cancelAction()
    cargoCache = {}
end))

if state.gui and typeof(state.gui) == "Instance" then
    table.insert(state.connections, state.gui.Destroying:Connect(function()
        if state.alive then state.Stop() end
    end))
end

----------------------------------------------------------------
-- BACKGROUND LOOPS
----------------------------------------------------------------

state.mineToggle:Set(false)
state.autoSellToggle:Set(false)
state.autoDriveToggle:Set(false)
state.legitToggle:Set(false)
state.noclipToggle:Set(false)
state.uiReady=true

table.insert(state.connections,lp.Idled:Connect(function()
    if not alive() or not (state.running or state.cfg.AutoSell or state.cfg.AutoDriveForward or state.Legit.enabled) then return end
    local ok,err=pcall(function()
        local vu=game:GetService("VirtualUser")
        vu:CaptureController()
        vu:ClickButton2(Vector2.zero)
    end)
    if not ok then state.lastIdleError=tostring(err) end
end))

task.spawn(function()
    while alive() do
        local ok,err = pcall(state.ExplosionResetStep)
        if not ok then
            state.SetExplosionCooldownBypass(false)
            state.CancelExplosionReset()
            if state.explosionCooldownToggle then state.explosionCooldownToggle:Set(false) end
            state.explosionResetStatus = "Reset stopped: "..tostring(err)
        end
        task.wait(0.1)
    end
end)
task.spawn(function()
    while alive() do
        local ok, err = pcall(function()
            if state.explosionReset then return end
            if state.Legit.enabled then
                state.manualSell=false
                state.Legit.Step()
                return
            end
            local now = os.clock()
            local count, capacity = cargoStatus()
            local vCount, vCapacity = vehicleCargoStatus()
            local kind, manual = state.manualSell, state.manualSell ~= false and state.manualSell ~= nil
            if vCount~=state.lastVehicleCount then state.lastVehicleCount=vCount state.vehicleChangedAt=now end
            if count~=state.lastBackpackCount then state.lastBackpackCount=count state.backpackChangedAt=now end
            if not kind and state.cfg.AutoSell and vCount and vCapacity and vCount>0
                and (vCount>=vCapacity or state.running or now-(state.vehicleChangedAt or now)>=state.cfg.CargoIdleTime)
                and now>=state.nextVehicleSell then kind="Vehicle" end
            if not kind and state.cfg.AutoSell and count and capacity and count>0
                and (count>=math.ceil(capacity*state.cfg.SellPercent/100)
                    or now-(state.backpackChangedAt or now)>=state.cfg.CargoIdleTime)
                and now>=state.nextSell then kind="Backpack" end
            if kind then
                state.driveClearUntil=0
                state.manualSell=false
                sellCargo(kind,manual)
                if kind=="Vehicle" then state.nextVehicleSell=os.clock()+state.cfg.VehicleSellDelay
                else state.nextSell=os.clock()+state.cfg.SellInterval end
            elseif state.cfg.AutoDriveForward then autodriveStep()
            elseif state.running then mineOnce() end
        end)
        if not ok then
            cancelAction()
            state.Legit.Release()
            state.driveClearUntil=0
            state.busy,state.selling=false,false
            state.nextSell,state.nextVehicleSell=os.clock()+3,os.clock()+3
            state.status="Automation retry: "..tostring(err)
        end
        task.wait(state.cfg.ScanDelay)
    end
end)
task.spawn(function()
    while alive() do
        local ok, err = pcall(function()
            local count,capacity=cargoStatus()
            local vc,vmax=vehicleCargoStatus()
            state.miningLabel:SetText(state.status)
            local legit=state.Legit
            state.legitStatus:SetText("Legit: "..legit.phase..(legit.enabled and " | "..state.status or ""))
            state.legitResult:SetText("Confirmed: "..legit.confirmed.." | Skipped: "..legit.skipped
                .." | Loads: "..legit.transfers.." | Deliveries: "..legit.deliveries
                ..(legit.lastResult and " | "..legit.lastResult or ""))
            state.explosionResetLabel:SetText(state.explosionResetStatus
                or (state.cfg.ExplosionCooldownBypass and "Reset bypass: waiting for empty charges" or "Reset bypass: off"))
            state.cargoLabel:SetText(count and ("Backpack: "..count.." / "..capacity) or "Backpack: unavailable")
            state.vehicleLabel:SetText(vc and ("Vehicle: "..vc.." / "..vmax) or "Vehicle: unavailable")
            state.perfLabel:SetText("Mined: "..(state.minedBlocks or 0).." | Unloads: "..(state.sellCycles or 0)
                .." | PlacedOre: "..(state.placedOreResolved or 0).."/"..(state.placedOreSeen or 0)
                .." | Terrain ore: "..(state.terrainOreSeen or 0)
                ..((state.placedOreSynthetic or 0)>0 and (" (generated "..state.placedOreSynthetic..")") or ""))
        end)
        if not ok then warn("[MineAura] Status: "..tostring(err)) end
        task.wait(0.5)
    end
end)
function state.Diagnose()
    local count,capacity=cargoStatus()
    local vc,vmax=vehicleCargoStatus()
    return {status=state.status,running=state.running,busy=state.busy,selling=state.selling,
        legit=state.Legit.enabled,legitPhase=state.Legit.phase,legitConfirmed=state.Legit.confirmed,
        legitSkipped=state.Legit.skipped,legitLastSkip=state.Legit.lastSkip,legitResult=state.Legit.lastResult,
        legitTransfers=state.Legit.transfers,legitDeliveries=state.Legit.deliveries,
        legitValue=state.Legit.confirmedValue,legitDelivery=state.Legit.delivery and state.Legit.delivery.phase,
        legitSelectMs=state.Legit.selectMs,
        legitIndexBuilds=state.Legit.registry and state.Legit.registry.builds,
        legitIndexUpdates=state.Legit.registry and state.Legit.registry.updates,
        pending=state.pendingAction~=nil,backpack=count,capacity=capacity,vehicleCargo=vc,
        mineRejected=state.mineRejected or 0,mineSkipped=state.mineSkipped or 0,
        accessBlocks=state.accessBlocks or 0,
        lastMineReject=state.lastMineReject,
        explosionScanScale=state.cfg.ExplosionScanScale,
        placedOreSeen=state.placedOreSeen,placedOreResolved=state.placedOreResolved,
        terrainCellsSeen=state.terrainCellsSeen,terrainOreSeen=state.terrainOreSeen,
        explosionResetActive=state.explosionReset~=nil,explosionResetEnabled=state.cfg.ExplosionCooldownBypass,
        explosionResetStatus=state.explosionResetStatus,
        vehicleCapacity=vmax,mined=state.minedBlocks or 0,sellCycles=state.sellCycles or 0,driving=state.isDriving(),
        autodrive=state.cfg.AutoDriveForward,driveObstacles=state.driveObstacles,driveExplosives=state.driveExplosives,
        driveDrillZoneTarget=state.driveDrillZoneTarget,driveLaneError=state.driveLaneError,driveLastCleared=state.driveLastCleared,
        driveReturns=state.driveReturns,drivePickaxeMined=state.drivePickaxeMined,ore=state.currentOre,price=state.targetPrice,targetDistance=state.targetDistance,resumeError=state.lastResumeError}
end
notify("Ready. v40 | Reachable ore, highest value first")
