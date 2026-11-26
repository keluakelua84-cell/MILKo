--[[
  Rusty Rafts helper | Delta
  Written without access to the game's internals.
  Detection is heuristic (names/keywords). Edit CFG below if something is missed.
]]

local cloneref = cloneref or function(o) return o end
local function svc(n) return cloneref(game:GetService(n)) end
local Players = svc("Players")
local RunService = svc("RunService")
local UIS = svc("UserInputService")
local CoreGui = svc("CoreGui")
local VirtualUser = svc("VirtualUser")
local RepStorage = svc("ReplicatedStorage")
local WS = cloneref(workspace)
local WS_REAL = workspace -- real ref, needed for == comparisons inside hooks
local Terrain = WS.Terrain
local LP = Players.LocalPlayer

local CFG = {
	DISASTER_WORDS = { "tsunami", "storm", "bermuda", "whirlpool", "hurricane", "tornado", "disaster" },
	VALUE_EXTRA_WORDS = { "event", "weather", "hazard" }, -- only for Value objects
	LOOT_WORDS = { "pick", "collect", "grab", "take", "loot", "salvage", "open", "crate", "chest", "scrap" },
	STAMINA_WORDS = { "stamina", "energy", "sprint" },
	AIM_PARTS = { "Head", "HumanoidRootPart" },
	ENEMY_EXCLUDE = {}, -- model-name words to ignore (friendly NPCs)
	MAX_ESP_DIST = 1500,
	LOOT_RANGE_CAP = 20,
	AFTER_DISASTER_DELAY = 3,
	MAX_LOCK_SECONDS = 180,
}

local env = (getgenv and getgenv()) or _G
if env.__RR_UNLOAD then pcall(env.__RR_UNLOAD) end

local alive = true
local conns, objs = {}, {}
local function track(c) conns[#conns + 1] = c return c end

local S = {
	EnemyLabel = false, EnemyBox = false, EnemyTracer = false,
	LootLabel = false, LootBox = false, LootTracer = false,
	AutoAim = false, ShowFOV = true, FOV = 150,
	InfStamina = false, WaterWalk = false, AutoLoot = false,
	AntiAFK = true, AutoLock = false, ManualLock = false, RemoteSpy = false,
}

----------------------------------------------------------------- utils
local function rnd()
	local t = {}
	for i = 1, 10 do t[i] = string.char(math.random(97, 122)) end
	return table.concat(t)
end

local function hasWord(str, list)
	str = string.lower(tostring(str))
	for _, w in ipairs(list) do
		if string.find(str, w, 1, true) then return true end
	end
	return false
end

local function myRoot()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function pickPart(m)
	for _, n in ipairs(CFG.AIM_PARTS) do
		local p = m:FindFirstChild(n)
		if p and p:IsA("BasePart") then return p end
	end
	return m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
end

local function promptPart(pr)
	local p = pr.Parent
	if not p then return nil end
	if p:IsA("BasePart") then return p end
	if p:IsA("Attachment") then return p.Parent:IsA("BasePart") and p.Parent or nil end
	if p:IsA("Model") then return p.PrimaryPart or p:FindFirstChildWhichIsA("BasePart", true) end
	return nil
end

----------------------------------------------------------------- gui base
local gui = Instance.new("ScreenGui")
gui.Name = rnd()
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
local okParent = pcall(function() gui.Parent = (gethui and gethui()) or CoreGui end)
if not okParent or not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end
objs[#objs + 1] = gui

local overlay = Instance.new("Frame")
overlay.BackgroundTransparency = 1
overlay.Size = UDim2.fromScale(1, 1)
overlay.Active = false
overlay.Parent = gui

local fovCircle = Instance.new("Frame")
fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
fovCircle.BackgroundTransparency = 1
fovCircle.Visible = false
fovCircle.Parent = overlay
do
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = fovCircle
	local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(255, 255, 255); s.Thickness = 1.5; s.Parent = fovCircle
end

----------------------------------------------------------------- esp
local function makeEntry(color)
	local e = {}
	e.box = Instance.new("Frame")
	e.box.BackgroundTransparency = 1; e.box.BorderSizePixel = 0; e.box.Visible = false; e.box.Parent = overlay
	local st = Instance.new("UIStroke"); st.Color = color; st.Thickness = 1.5; st.Parent = e.box
	e.label = Instance.new("TextLabel")
	e.label.BackgroundTransparency = 1; e.label.TextColor3 = color; e.label.TextSize = 13
	e.label.Font = Enum.Font.GothamBold; e.label.TextStrokeTransparency = 0.4
	e.label.Size = UDim2.fromOffset(220, 16); e.label.AnchorPoint = Vector2.new(0.5, 1)
	e.label.Visible = false; e.label.Parent = overlay
	e.line = Instance.new("Frame")
	e.line.BorderSizePixel = 0; e.line.BackgroundColor3 = color
	e.line.AnchorPoint = Vector2.new(0.5, 0.5); e.line.Visible = false; e.line.Parent = overlay
	return e
end

local function hideEntry(e)
	e.box.Visible = false; e.label.Visible = false; e.line.Visible = false
end

local function destroyEntry(e)
	e.box:Destroy(); e.label:Destroy(); e.line:Destroy()
end

local function projectBox(cam, rec, part)
	local cf, size = part.CFrame, part.Size
	if rec.kind == "enemy" then
		local ok, c, s = pcall(rec.inst.GetBoundingBox, rec.inst)
		if ok and s.Magnitude < 60 then cf, size = c, s end
	end
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local any = false
	for x = -1, 1, 2 do
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local p = cam:WorldToViewportPoint(cf:PointToWorldSpace(Vector3.new(size.X / 2 * x, size.Y / 2 * y, size.Z / 2 * z)))
				if p.Z > 0 then
					any = true
					if p.X < minX then minX = p.X end
					if p.Y < minY then minY = p.Y end
					if p.X > maxX then maxX = p.X end
					if p.Y > maxY then maxY = p.Y end
				end
			end
		end
	end
	if not any then return nil end
	if maxX - minX < 14 then local c = (maxX + minX) / 2; minX, maxX = c - 7, c + 7 end
	if maxY - minY < 14 then local c = (maxY + minY) / 2; minY, maxY = c - 7, c + 7 end
	return minX, minY, maxX, maxY
end

local function drawLine(frame, a, b)
	local d = b - a
	frame.Size = UDim2.fromOffset(d.Magnitude, 1.5)
	frame.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	frame.Rotation = math.deg(math.atan2(d.Y, d.X))
	frame.Visible = true
end

local enemies, loot = {}, {}
local ENEMY_COLOR = Color3.fromRGB(255, 70, 70)
local LOOT_COLOR = Color3.fromRGB(80, 220, 255)

local function partOf(rec)
	if rec.kind == "enemy" then return pickPart(rec.inst) end
	if rec.kind == "prompt" then return promptPart(rec.obj) end
	return rec.obj:FindFirstChild("Handle") or rec.obj:FindFirstChildWhichIsA("BasePart")
end

local function render(rec, color, wantLabel, wantBox, wantTracer, cam, rootPos, from)
	local e = rec.e
	local shown = false
	if wantLabel or wantBox or wantTracer then
		local part = partOf(rec)
		local dead = rec.kind == "enemy" and rec.hum.Health <= 0
		if part and part.Parent and not dead then
			local dist = rootPos and (part.Position - rootPos).Magnitude or 0
			if dist <= CFG.MAX_ESP_DIST then
				local p = cam:WorldToViewportPoint(part.Position)
				if p.Z > 0 then
					shown = true
					if not e then e = makeEntry(color); rec.e = e end
					local minX, minY, maxX, maxY = projectBox(cam, rec, part)
					if wantBox and minX then
						e.box.Position = UDim2.fromOffset(minX, minY)
						e.box.Size = UDim2.fromOffset(maxX - minX, maxY - minY)
						e.box.Visible = true
					else
						e.box.Visible = false
					end
					if wantLabel then
						local txt = rec.name .. " [" .. math.floor(dist) .. "m]"
						if rec.kind == "enemy" then
							txt = txt .. " HP " .. math.floor(rec.hum.Health)
						end
						e.label.Text = txt
						e.label.Position = UDim2.fromOffset(p.X, (minY or p.Y) - 2)
						e.label.Visible = true
					else
						e.label.Visible = false
					end
					if wantTracer then
						drawLine(e.line, from, Vector2.new(p.X, p.Y))
					else
						e.line.Visible = false
					end
				end
			end
		end
	end
	if not shown and e then hideEntry(e) end
end

----------------------------------------------------------------- scanning
local disasterInst, disasterVals = {}, {}

local function lootOk(pr)
	local parentName = pr.Parent and pr.Parent.Name or ""
	return hasWord(pr.ActionText .. " " .. pr.ObjectText .. " " .. parentName, CFG.LOOT_WORDS)
end

local function lootName(pr)
	if pr.ObjectText ~= "" then return pr.ObjectText end
	local m = pr:FindFirstAncestorWhichIsA("Model")
	if m and m ~= WS_REAL then return m.Name end
	return pr.Parent and pr.Parent.Name or "item"
end

local function consider(inst)
	if inst:IsA("Humanoid") then
		local m = inst.Parent
		if m and m:IsA("Model") and not enemies[m] and not Players:GetPlayerFromCharacter(m)
			and not hasWord(m.Name, CFG.ENEMY_EXCLUDE ~= nil and #CFG.ENEMY_EXCLUDE > 0 and CFG.ENEMY_EXCLUDE or { "\0" }) then
			enemies[m] = { kind = "enemy", inst = m, hum = inst, name = m.Name }
		end
	elseif inst:IsA("ProximityPrompt") then
		if not loot[inst] then
			loot[inst] = { kind = "prompt", obj = inst, name = lootName(inst), ok = lootOk(inst) }
		end
	elseif inst:IsA("Tool") and inst.Parent == WS_REAL then
		loot[inst] = { kind = "tool", obj = inst, name = inst.Name, ok = true }
	end
	if inst:IsA("ValueBase") then
		if hasWord(inst.Name, CFG.DISASTER_WORDS) or hasWord(inst.Name, CFG.VALUE_EXTRA_WORDS) then
			disasterVals[inst] = true
		end
	elseif hasWord(inst.Name, CFG.DISASTER_WORDS) then
		disasterInst[inst] = true
	end
end

local function unconsider(inst)
	local r = enemies[inst]
	if r then if r.e then destroyEntry(r.e) end enemies[inst] = nil end
	if inst:IsA("Humanoid") and inst.Parent then
		local r2 = enemies[inst.Parent]
		if r2 then if r2.e then destroyEntry(r2.e) end enemies[inst.Parent] = nil end
	end
	local l = loot[inst]
	if l then if l.e then destroyEntry(l.e) end loot[inst] = nil end
	disasterInst[inst] = nil
	disasterVals[inst] = nil
end

task.spawn(function()
	local n = 0
	for _, d in ipairs(WS:GetDescendants()) do
		if not alive then return end
		pcall(consider, d)
		n += 1
		if n % 400 == 0 then task.wait() end
	end
	for _, d in ipairs(RepStorage:GetDescendants()) do
		if not alive then return end
		if d:IsA("ValueBase") and (hasWord(d.Name, CFG.DISASTER_WORDS) or hasWord(d.Name, CFG.VALUE_EXTRA_WORDS)) then
			disasterVals[d] = true
		end
		n += 1
		if n % 400 == 0 then task.wait() end
	end
end)
track(WS.DescendantAdded:Connect(function(d) pcall(consider, d) end))
track(WS.DescendantRemoving:Connect(function(d) pcall(unconsider, d) end))
track(RepStorage.DescendantAdded:Connect(function(d)
	if d:IsA("ValueBase") and (hasWord(d.Name, CFG.DISASTER_WORDS) or hasWord(d.Name, CFG.VALUE_EXTRA_WORDS)) then
		disasterVals[d] = true
	end
end))
track(RepStorage.DescendantRemoving:Connect(function(d) disasterVals[d] = nil end))

-- refresh loot filter / names (prompt texts can change)
task.spawn(function()
	while alive do
		task.wait(3)
		for inst, rec in pairs(loot) do
			if rec.kind == "prompt" and inst.Parent then
				rec.ok = lootOk(inst)
				rec.name = lootName(inst)
			end
		end
	end
end)

----------------------------------------------------------------- auto aim
local aimPart = nil

local function updateAim()
	aimPart = nil
	if not S.AutoAim then return end
	local cam = WS.CurrentCamera
	if not cam then return end
	local vs = cam.ViewportSize
	local center = Vector2.new(vs.X / 2, vs.Y / 2)
	local best = S.FOV
	for m, rec in pairs(enemies) do
		if rec.hum.Parent and rec.hum.Health > 0 then
			local part = pickPart(m)
			if part then
				local p, on = cam:WorldToViewportPoint(part.Position)
				if on then
					local d = (Vector2.new(p.X, p.Y) - center).Magnitude
					if d < best then best = d; aimPart = part end
				end
			end
		end
	end
end

----------------------------------------------------------------- hooks (aim redirect + remote spy)
local ncc = newcclosure or function(f) return f end
local oldNC, oldIdx
local spyLog, spyOrder = {}, {}

local function short(v)
	local t = typeof(v)
	if t == "string" then return '"' .. string.sub(v, 1, 40) .. '"' end
	if t == "Instance" then return v.ClassName .. ":" .. v.Name end
	if t == "table" then return "{table}" end
	return tostring(v)
end

local function logRemote(self, method, ...)
	if typeof(self) ~= "Instance" then return end
	local path = self:GetFullName()
	local rec = spyLog[path]
	if not rec then
		rec = { n = 0, method = method, class = self.ClassName }
		spyLog[path] = rec
		spyOrder[#spyOrder + 1] = path
	end
	rec.n += 1
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = short((select(i, ...)))
		if i >= 8 then break end
	end
	rec.args = table.concat(parts, ", ")
end

local function installHooks()
	if oldNC or not hookmetamethod then return end
	oldNC = hookmetamethod(game, "__namecall", ncc(function(self, ...)
		if alive and not (checkcaller and checkcaller()) then
			local m = getnamecallmethod()
			if m == "Raycast" and S.AutoAim and aimPart and self == WS_REAL then
				local n = select("#", ...)
				local a = { ... }
				if typeof(a[1]) == "Vector3" and typeof(a[2]) == "Vector3" and a[2].Magnitude > 0 then
					a[2] = (aimPart.Position - a[1]).Unit * a[2].Magnitude
					return oldNC(self, table.unpack(a, 1, n))
				end
			elseif S.RemoteSpy and (m == "FireServer" or m == "InvokeServer") then
				pcall(logRemote, self, m, ...)
			end
		end
		return oldNC(self, ...)
	end))
	local mouse = LP:GetMouse()
	oldIdx = hookmetamethod(game, "__index", ncc(function(self, k)
		if alive and S.AutoAim and aimPart and self == mouse and not (checkcaller and checkcaller()) then
			if k == "Hit" then return CFrame.new(aimPart.Position) end
			if k == "Target" then return aimPart end
		end
		return oldIdx(self, k)
	end))
end

----------------------------------------------------------------- stamina
local stam = {}

local function scanStamina()
	local list = {}
	local skip = { "regen", "rate", "cost", "drain", "max" }
	for _, r in ipairs({ LP, LP.Character }) do
		if r then
			for k, v in pairs(r:GetAttributes()) do
				if type(v) == "number" and hasWord(k, CFG.STAMINA_WORDS) and not hasWord(k, skip) then
					local mx = r:GetAttribute("Max" .. k)
					list[#list + 1] = { o = r, attr = k, max = type(mx) == "number" and mx or v }
				end
			end
			for _, d in ipairs(r:GetDescendants()) do
				if (d:IsA("NumberValue") or d:IsA("IntValue")) and hasWord(d.Name, CFG.STAMINA_WORDS) and not hasWord(d.Name, skip) then
					local mxv = d.Parent and d.Parent:FindFirstChild("Max" .. d.Name)
					list[#list + 1] = { o = d, max = (mxv and mxv:IsA("ValueBase") and tonumber(mxv.Value)) or d.Value }
				end
			end
		end
	end
	stam = list
end

local function stamStep()
	for _, ref in ipairs(stam) do
		if ref.o and ref.o.Parent then
			local cur
			if ref.attr then cur = ref.o:GetAttribute(ref.attr) else cur = ref.o.Value end
			if type(cur) == "number" then
				if cur > ref.max then ref.max = cur end
				if cur < ref.max then
					if ref.attr then ref.o:SetAttribute(ref.attr, ref.max) else ref.o.Value = ref.max end
				end
			end
		end
	end
end

task.spawn(function()
	while alive do
		pcall(scanStamina)
		task.wait(5)
	end
end)

----------------------------------------------------------------- water walk
local platform = Instance.new("Part")
platform.Name = rnd()
platform.Anchored = true
platform.CanCollide = true
platform.Transparency = 1
platform.Size = Vector3.new(60, 1, 60)
objs[#objs + 1] = platform

local origWave = { Terrain.WaterWaveSize, Terrain.WaterWaveSpeed }
local waterY = nil

local function waterStep()
	local root = myRoot()
	if not root then return end
	local cam = WS.CurrentCamera
	if cam and platform.Parent ~= cam then platform.Parent = cam end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.IgnoreWater = false
	local ex = { platform }
	if LP.Character then ex[2] = LP.Character end
	rp.FilterDescendantsInstances = ex
	local r = WS:Raycast(root.Position, Vector3.new(0, -80, 0), rp)
	local pos = root.Position
	if r and r.Material == Enum.Material.Water then
		waterY = r.Position.Y
		platform.CFrame = CFrame.new(pos.X, waterY - 0.5, pos.Z)
	elseif waterY and pos.Y < waterY and pos.Y > waterY - 12 then
		platform.CFrame = CFrame.new(pos.X, waterY - 0.5, pos.Z)
		root.CFrame = root.CFrame + Vector3.new(0, waterY + 3 - pos.Y, 0)
	else
		platform.CFrame = CFrame.new(0, -1e4, 0)
	end
end

local function setWater(on)
	if on then
		Terrain.WaterWaveSize = 0
		Terrain.WaterWaveSpeed = 0
	else
		Terrain.WaterWaveSize = origWave[1]
		Terrain.WaterWaveSpeed = origWave[2]
		platform.Parent = nil
	end
end

----------------------------------------------------------------- ship lock (disasters)
local lock = { on = false, part = nil, off = nil, mode = nil, since = 0, cool = 0, releaseAt = nil }
local disasterName = nil

local function findShipPart()
	local root = myRoot()
	if not root then return nil end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local ex = { platform }
	if LP.Character then ex[2] = LP.Character end
	rp.FilterDescendantsInstances = ex
	local r = WS:Raycast(root.Position, Vector3.new(0, -15, 0), rp)
	if r and r.Instance and r.Instance:IsA("BasePart") and r.Instance ~= Terrain then return r.Instance end
	return nil
end

local function startLock(mode)
	local root, part = myRoot(), findShipPart()
	if not (root and part) then return false end
	lock.on = true; lock.mode = mode; lock.part = part
	lock.off = part.CFrame:ToObjectSpace(root.CFrame)
	lock.since = tick(); lock.releaseAt = nil
	return true
end

local function stopLock()
	lock.on = false; lock.part = nil; lock.mode = nil
end

local function truthy(v, nameMatch)
	local t = type(v)
	if t == "boolean" then return v and nameMatch end
	if t == "number" then return v > 0 and nameMatch end
	if t == "string" then
		local l = string.lower(v)
		if hasWord(l, CFG.DISASTER_WORDS) then return true end
		return nameMatch and l ~= "" and l ~= "none" and l ~= "false" and l ~= "0" and l ~= "calm" and l ~= "clear"
	end
	return false
end

local function disasterActive()
	for inst in pairs(disasterInst) do
		if inst.Parent then return true, inst.Name end
	end
	for inst in pairs(disasterVals) do
		if inst.Parent then
			local nm = hasWord(inst.Name, CFG.DISASTER_WORDS)
			if truthy(inst.Value, nm) then return true, inst.Name .. "=" .. tostring(inst.Value) end
		end
	end
	for _, r in ipairs({ WS_REAL, RepStorage }) do
		for k, v in pairs(r:GetAttributes()) do
			if truthy(v, hasWord(k, CFG.DISASTER_WORDS) or hasWord(k, CFG.VALUE_EXTRA_WORDS)) then
				return true, k .. "=" .. tostring(v)
			end
		end
	end
	return false, nil
end

task.spawn(function()
	while alive do
		task.wait(0.4)
		if S.AutoLock then
			local active, who = disasterActive()
			disasterName = active and who or nil
			if active then
				lock.releaseAt = nil
				if not lock.on then
					if tick() > lock.cool then startLock("auto") end
				elseif lock.mode == "auto" and tick() - lock.since > CFG.MAX_LOCK_SECONDS then
					stopLock(); lock.cool = tick() + 30
				end
			elseif lock.on and lock.mode == "auto" then
				if not lock.releaseAt then
					lock.releaseAt = tick() + CFG.AFTER_DISASTER_DELAY
				elseif tick() >= lock.releaseAt then
					stopLock()
				end
			end
		else
			disasterName = nil
			if lock.on and lock.mode == "auto" then stopLock() end
		end
	end
end)

track(LP.CharacterAdded:Connect(function() stopLock() end))

----------------------------------------------------------------- auto loot
task.spawn(function()
	while alive do
		task.wait(0.3)
		if S.AutoLoot then
			local root = myRoot()
			if root then
				for inst, rec in pairs(loot) do
					if rec.ok and inst.Parent then
						local part = partOf(rec)
						if part then
							local d = (part.Position - root.Position).Magnitude
							if rec.kind == "prompt" then
								if inst.Enabled and fireproximityprompt and d <= math.min(inst.MaxActivationDistance, CFG.LOOT_RANGE_CAP) then
									pcall(fireproximityprompt, inst)
								end
							elseif firetouchinterest and d <= 25 then
								pcall(function()
									firetouchinterest(root, part, 0)
									firetouchinterest(root, part, 1)
								end)
							end
						end
					end
				end
			end
		end
	end
end)

----------------------------------------------------------------- anti afk
track(LP.Idled:Connect(function()
	if S.AntiAFK then
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end
end))

----------------------------------------------------------------- main loops
track(RunService.RenderStepped:Connect(function()
	if not alive then return end
	updateAim()
	local cam = WS.CurrentCamera
	if not cam then return end
	local vs = cam.ViewportSize
	fovCircle.Visible = S.AutoAim and S.ShowFOV
	fovCircle.Size = UDim2.fromOffset(S.FOV * 2, S.FOV * 2)
	fovCircle.Position = UDim2.fromOffset(vs.X / 2, vs.Y / 2)
	local root = myRoot()
	local rootPos = root and root.Position
	local from = Vector2.new(vs.X / 2, vs.Y)
	for _, rec in pairs(enemies) do
		render(rec, ENEMY_COLOR, S.EnemyLabel, S.EnemyBox, S.EnemyTracer, cam, rootPos, from)
	end
	for _, rec in pairs(loot) do
		if rec.ok then
			render(rec, LOOT_COLOR, S.LootLabel, S.LootBox, S.LootTracer, cam, rootPos, from)
		elseif rec.e then
			hideEntry(rec.e)
		end
	end
end))

local lastSlow = 0
track(RunService.Heartbeat:Connect(function()
	if not alive then return end
	if lock.on then
		local root = myRoot()
		if root and lock.part and lock.part.Parent then
			root.CFrame = lock.part.CFrame * lock.off
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		elseif root then
			local part = findShipPart()
			if part then lock.part = part; lock.off = part.CFrame:ToObjectSpace(root.CFrame) end
		end
	end
	if S.WaterWalk then pcall(waterStep) end
	local now = tick()
	if now - lastSlow >= 0.1 then
		lastSlow = now
		if S.InfStamina then pcall(stamStep) end
		if S.WaterWalk then
			Terrain.WaterWaveSize = 0
			Terrain.WaterWaveSpeed = 0
		end
	end
end))

----------------------------------------------------------------- menu
local BG = Color3.fromRGB(24, 24, 28)
local OFFC = Color3.fromRGB(48, 48, 56)
local ONC = Color3.fromRGB(46, 160, 100)
local WHITE = Color3.fromRGB(235, 235, 240)

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(250, 380)
panel.Position = UDim2.fromOffset(60, 70)
panel.BackgroundColor3 = BG
panel.BorderSizePixel = 0
panel.Parent = gui
do
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = panel
end

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
title.BorderSizePixel = 0
title.Text = "Rusty Rafts"
title.TextColor3 = WHITE
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = panel

local scroll = Instance.new("ScrollingFrame")
scroll.Position = UDim2.fromOffset(0, 34)
scroll.Size = UDim2.new(1, 0, 1, -38)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new()
scroll.Parent = panel
do
	local l = Instance.new("UIListLayout"); l.Padding = UDim.new(0, 4); l.HorizontalAlignment = Enum.HorizontalAlignment.Center; l.Parent = scroll
end

local rows = {}

local function header(text)
	local t = Instance.new("TextLabel")
	t.Size = UDim2.new(1, -8, 0, 20)
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextColor3 = Color3.fromRGB(150, 150, 165)
	t.Font = Enum.Font.GothamBold
	t.TextSize = 12
	t.Parent = scroll
	return t
end

local function mkBtn(text)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -8, 0, 30)
	b.BackgroundColor3 = OFFC
	b.BorderSizePixel = 0
	b.TextColor3 = WHITE
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 13
	b.Text = text
	b.Parent = scroll
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = b
	return b
end

local function toggle(text, key, onChange)
	local b = mkBtn(text)
	local function refresh()
		b.Text = text .. (S[key] and "   [ON]" or "   [OFF]")
		b.BackgroundColor3 = S[key] and ONC or OFFC
	end
	rows[key] = refresh
	refresh()
	track(b.MouseButton1Click:Connect(function()
		S[key] = not S[key]
		refresh()
		if onChange then pcall(onChange, S[key]) end
	end))
end

header("ESP - Enemies")
toggle("Name / dist / HP", "EnemyLabel")
toggle("Box", "EnemyBox")
toggle("Tracers", "EnemyTracer")
header("ESP - Items")
toggle("Item names", "LootLabel")
toggle("Box", "LootBox")
toggle("Tracers", "LootTracer")
header("Combat")
toggle("Auto aim (FOV)", "AutoAim", function(on) if on then installHooks() end end)
toggle("Show FOV circle", "ShowFOV")
do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -8, 0, 30); row.BackgroundTransparency = 1; row.Parent = scroll
	local minus = Instance.new("TextButton"); minus.Size = UDim2.new(0.25, -2, 1, 0); minus.Text = "-"
	local plus = Instance.new("TextButton"); plus.Size = UDim2.new(0.25, -2, 1, 0); plus.Position = UDim2.new(0.75, 2, 0, 0); plus.Text = "+"
	local lab = Instance.new("TextLabel"); lab.Size = UDim2.new(0.5, 0, 1, 0); lab.Position = UDim2.new(0.25, 0, 0, 0)
	for _, b in ipairs({ minus, plus }) do
		b.BackgroundColor3 = OFFC; b.TextColor3 = WHITE; b.Font = Enum.Font.GothamBold; b.TextSize = 16; b.BorderSizePixel = 0; b.Parent = row
	end
	lab.BackgroundTransparency = 1; lab.TextColor3 = WHITE; lab.Font = Enum.Font.GothamMedium; lab.TextSize = 13; lab.Parent = row
	local function upd() lab.Text = "FOV " .. S.FOV end
	upd()
	track(minus.MouseButton1Click:Connect(function() S.FOV = math.max(40, S.FOV - 10); upd() end))
	track(plus.MouseButton1Click:Connect(function() S.FOV = math.min(500, S.FOV + 10); upd() end))
end
header("Player")
toggle("Infinite stamina", "InfStamina")
toggle("Walk on sea / no waves", "WaterWalk", setWater)
toggle("Auto loot", "AutoLoot")
toggle("Anti-AFK", "AntiAFK")
header("Disasters")
toggle("Auto lock to ship", "AutoLock")
toggle("Lock to ship (manual)", "ManualLock", function(on)
	if on then
		if not startLock("manual") then S.ManualLock = false; rows.ManualLock() end
	else
		if lock.mode == "manual" then stopLock() end
	end
end)
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -8, 0, 32)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(170, 170, 185)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextWrapped = true
status.Text = ""
status.Parent = scroll
header("Debug")
toggle("Remote spy", "RemoteSpy", function(on) if on then installHooks() end end)

local copyBtn = mkBtn("Copy remote log")
track(copyBtn.MouseButton1Click:Connect(function()
	local lines = {}
	for _, path in ipairs(spyOrder) do
		local r = spyLog[path]
		lines[#lines + 1] = string.format("[%d] %s (%s:%s) args: %s", r.n, path, r.class, r.method, r.args or "")
	end
	local txt = table.concat(lines, "\n")
	if setclipboard then pcall(setclipboard, txt) end
	if writefile then pcall(writefile, "rr_remotes.txt", txt) end
	copyBtn.Text = "Copied (" .. #lines .. ")"
	task.delay(1.5, function() if alive then copyBtn.Text = "Copy remote log" end end)
end))

local unloadBtn = mkBtn("Unload")
unloadBtn.BackgroundColor3 = Color3.fromRGB(150, 50, 50)

track(RunService.Heartbeat:Connect(function()
	if not alive then return end
	status.Text = "disaster: " .. (disasterName or "none") .. "\nlock: " .. (lock.on and ("on (" .. tostring(lock.mode) .. ")") or "off")
end))

-- drag
local dragging, dragStart, startPos
track(title.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging = true; dragStart = i.Position; startPos = panel.Position
		i.Changed:Connect(function()
			if i.UserInputState == Enum.UserInputState.End then dragging = false end
		end)
	end
end))
track(UIS.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - dragStart
		panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end))

-- floating show/hide button
local fab = Instance.new("TextButton")
fab.Size = UDim2.fromOffset(40, 40)
fab.Position = UDim2.fromOffset(10, 70)
fab.BackgroundColor3 = BG
fab.BorderSizePixel = 0
fab.Text = "RR"
fab.TextColor3 = WHITE
fab.Font = Enum.Font.GothamBold
fab.TextSize = 14
fab.Parent = gui
do
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = fab
end
track(fab.MouseButton1Click:Connect(function() panel.Visible = not panel.Visible end))

----------------------------------------------------------------- unload
local function unload()
	alive = false
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for _, o in ipairs(objs) do pcall(function() o:Destroy() end) end
	pcall(function()
		Terrain.WaterWaveSize = origWave[1]
		Terrain.WaterWaveSpeed = origWave[2]
	end)
	stopLock()
	env.__RR_UNLOAD = nil
end
env.__RR_UNLOAD = unload
track(unloadBtn.MouseButton1Click:Connect(unload))
