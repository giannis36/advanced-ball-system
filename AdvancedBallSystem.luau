--[[
	Advanced Server Ball System

	This script controls a complete ball spawning and throwing system.
	It handles:
	- Server-side ball spawning
	- Player inventory limits
	- Ball pickup tools
	- Throw cooldowns
	- Projectile landing prediction
	- Bounce charging
	- Shockwave physics
	- Floating text feedback
	- Temporary visual effects
	- Player leaderstats

	Most gameplay logic is handled on the server so players cannot easily
	exploit the system by creating fake balls, skipping cooldowns, or giving
	themselves extra inventory.
]]

--// Services
-- Services are stored at the top so the script is organized and easy to maintain.
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

--// Spawner References
-- The script is expected to be placed inside the ball spawner part.
local spawnerPart = script.Parent
local spawnerPrompt = spawnerPart:WaitForChild("ProximityPrompt")

--// Configuration
-- These constants control gameplay balance and make the script easier to adjust later.
local MAX_BALLS = 10
local THROW_POWER = 105
local BALL_LIFETIME = 25
local PICKUP_DISTANCE = 9
local SHOCKWAVE_RADIUS = 18
local MAX_BOUNCE_CHARGE = 5
local COOLDOWN_TIME = 0.35

--// Remote Event
-- The remote event allows clients to request a throw direction while the server keeps authority.
local throwEvent = ReplicatedStorage:FindFirstChild("ThrowBallEvent")

if not throwEvent then
	throwEvent = Instance.new("RemoteEvent")
	throwEvent.Name = "ThrowBallEvent"
	throwEvent.Parent = ReplicatedStorage
end

--// Ball System Class
-- The system is stored in a table to keep related functions and state grouped together.
local BallSystem = {}
BallSystem.__index = BallSystem

function BallSystem.new()
	local self = setmetatable({}, BallSystem)

	-- Tracks active world balls so the visual heartbeat only updates valid balls.
	self.ActiveBalls = {}

	-- Tracks player cooldowns to prevent throwing spam.
	self.Cooldowns = {}

	-- Used to give each spawned ball a unique spawn index.
	self.SpawnedCount = 0

	return self
end

local system = BallSystem.new()

-- Checks if a player is still inside the throw cooldown window.
function BallSystem:IsCoolingDown(player)
	local lastUse = self.Cooldowns[player] or 0
	return os.clock() - lastUse < COOLDOWN_TIME
end

-- Stores the current time as the players latest throw time.
function BallSystem:SetCooldown(player)
	self.Cooldowns[player] = os.clock()
end

-- Creates leaderstats if they do not exist yet.
-- This keeps stats creation centralized instead of repeating it in multiple places.
function BallSystem:GetPlayerStats(player)
	local stats = player:FindFirstChild("leaderstats")

	if stats then
		return stats
	end

	stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	stats.Parent = player

	local throws = Instance.new("IntValue")
	throws.Name = "Throws"
	throws.Parent = stats

	local pickups = Instance.new("IntValue")
	pickups.Name = "Pickups"
	pickups.Parent = stats

	local powerHits = Instance.new("IntValue")
	powerHits.Name = "PowerHits"
	powerHits.Parent = stats

	return stats
end

-- Safely adds to a leaderstat value if the stat exists.
function BallSystem:AddStat(player, statName, amount)
	local stats = self:GetPlayerStats(player)
	local stat = stats:FindFirstChild(statName)

	if stat then
		stat.Value += amount
	end
end

-- Counts all ball tools the player currently owns.
-- Both Backpack and Character are checked because equipped tools move into the character.
function BallSystem:CountBalls(player)
	local count = 0

	for _, item in player.Backpack:GetChildren() do
		if item.Name == "Ball" then
			count += 1
		end
	end

	local character = player.Character

	if character then
		for _, item in character:GetChildren() do
			if item.Name == "Ball" then
				count += 1
			end
		end
	end

	return count
end

-- Creates a temporary sound and cleans it up automatically.
function BallSystem:PlaySound(parent, soundId, volume, pitch)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 1
	sound.PlaybackSpeed = pitch or 1
	sound.Parent = parent
	sound:Play()

	-- Debris prevents unused sound instances from building up in the workspace.
	Debris:AddItem(sound, 4)

	return sound
end

-- Applies the shared visual style used by both tool balls and world balls.
function BallSystem:ApplyToonLook(ball)
	ball.Material = Enum.Material.SmoothPlastic
	ball.Color = Color3.fromRGB(105, 145, 255)
	ball.Reflectance = 0

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 0
	highlight.OutlineColor = Color3.fromRGB(180, 225, 255)
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = ball

	-- Attachments are used as endpoints for the trail effect.
	local attachment0 = Instance.new("Attachment")
	attachment0.Name = "TrailStart"
	attachment0.Position = Vector3.new(0, 0.6, 0)
	attachment0.Parent = ball

	local attachment1 = Instance.new("Attachment")
	attachment1.Name = "TrailEnd"
	attachment1.Position = Vector3.new(0, -0.6, 0)
	attachment1.Parent = ball

	local trail = Instance.new("Trail")
	trail.Name = "EnergyTrail"
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	trail.Lifetime = 0.25
	trail.MinLength = 0.1
	trail.FaceCamera = true
	trail.Enabled = true
	trail.Parent = ball
end

-- Creates an expanding forcefield sphere to show the shockwave area visually.
function BallSystem:CreatePulseEffect(position, radius)
	local pulse = Instance.new("Part")
	pulse.Name = "ShockwavePulse"
	pulse.Shape = Enum.PartType.Ball
	pulse.Size = Vector3.new(1, 1, 1)
	pulse.Anchored = true
	pulse.CanCollide = false
	pulse.CanTouch = false
	pulse.CanQuery = false
	pulse.Material = Enum.Material.ForceField
	pulse.Transparency = 0.45
	pulse.Color = Color3.fromRGB(120, 190, 255)
	pulse.CFrame = CFrame.new(position)
	pulse.Parent = workspace

	local tween = TweenService:Create(
		pulse,
		TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{
			Size = Vector3.new(radius, radius, radius),
			Transparency = 1
		}
	)

	tween:Play()
	Debris:AddItem(pulse, 0.55)
end

-- Displays short feedback above a position, such as pickup or inventory messages.
function BallSystem:CreateFloatingText(position, text)
	local holder = Instance.new("Part")
	holder.Name = "FloatingTextHolder"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.Transparency = 1
	holder.Position = position
	holder.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "FloatingTextGui"
	billboard.Size = UDim2.fromOffset(180, 55)
	billboard.StudsOffset = Vector3.new(0, 2, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Parent = holder

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(200, 235, 255)
	label.TextStrokeTransparency = 0.25
	label.Parent = billboard

	local moveTween = TweenService:Create(
		holder,
		TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = position + Vector3.new(0, 4, 0) }
	)

	local fadeTween = TweenService:Create(
		label,
		TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			TextTransparency = 1,
			TextStrokeTransparency = 1
		}
	)

	moveTween:Play()
	fadeTween:Play()

	fadeTween.Completed:Once(function()
		holder:Destroy()
	end)

	Debris:AddItem(holder, 1.2)
end

-- Predicts where a thrown ball will land using projectile motion and raycasts.
-- This gives the player visual feedback before the actual ball lands.
function BallSystem:PredictLandingPoint(startPosition, velocity)
	local gravity = workspace.Gravity
	local timeStep = 0.08
	local lastPosition = startPosition

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	-- Pickup balls are ignored so the prediction checks the map instead of other balls.
	rayParams.FilterDescendantsInstances = CollectionService:GetTagged("PickupBall")

	for step = 1, 40 do
		local t = step * timeStep

		-- Projectile formula: position + velocity*time + gravity effect.
		local nextPosition = startPosition + velocity * t + Vector3.new(0, -0.5 * gravity * t * t, 0)
		local direction = nextPosition - lastPosition

		local result = workspace:Raycast(lastPosition, direction, rayParams)

		if result then
			return result.Position, result.Normal
		end

		lastPosition = nextPosition
	end

	return lastPosition, Vector3.yAxis
end

-- Creates a temporary ring showing the predicted landing point.
function BallSystem:ShowLandingMarker(position, normal)
	local marker = Instance.new("Part")
	marker.Name = "PredictedLandingMarker"
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanTouch = false
	marker.CanQuery = false
	marker.Shape = Enum.PartType.Cylinder
	marker.Size = Vector3.new(0.08, 4, 4)
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.fromRGB(120, 190, 255)
	marker.Transparency = 0.35

	-- Aligns the marker to the surface normal so it sits correctly on slopes.
	marker.CFrame = CFrame.lookAt(position, position + normal) * CFrame.Angles(0, math.rad(90), 0)
	marker.Parent = workspace

	local tween = TweenService:Create(
		marker,
		TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Transparency = 1,
			Size = Vector3.new(0.08, 7, 7)
		}
	)

	tween:Play()
	Debris:AddItem(marker, 0.9)
end

-- Applies an area impulse to nearby physics objects and characters.
-- Charge increases both the range and strength of the shockwave.
function BallSystem:ApplyShockwave(center, owner, charge)
	local radius = SHOCKWAVE_RADIUS + charge * 2

	self:CreatePulseEffect(center, radius)

	for _, part in workspace:GetPartBoundsInRadius(center, radius) do
		if part:IsA("BasePart") and not part.Anchored then
			local offset = part.Position - center
			local distance = math.max(offset.Magnitude, 1)
			local direction = offset.Unit

			-- Objects closer to the center receive more force.
			local strength = (radius - distance) / radius
			local impulse = direction * strength * part.AssemblyMass * (80 + charge * 30)

			part:ApplyImpulse(impulse)
		end

		local model = part:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		local root = model and model:FindFirstChild("HumanoidRootPart")

		-- Characters are handled separately so their root part receives clean knockback.
		if humanoid and root and owner and model ~= owner.Character then
			local offset = root.Position - center
			local direction = offset.Magnitude > 0 and offset.Unit or Vector3.yAxis

			root:ApplyImpulse((direction + Vector3.new(0, 0.35, 0)) * root.AssemblyMass * (85 + charge * 20))
		end
	end

	if owner then
		self:AddStat(owner, "PowerHits", 1)
	end
end

-- Creates the ball tool that the player can hold and activate.
function BallSystem:CreateTool(player)
	local tool = Instance.new("Tool")
	tool.Name = "Ball"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute("CreatedBySpawner", true)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Shape = Enum.PartType.Ball
	handle.Size = Vector3.new(1.5, 1.5, 1.5)
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	self:ApplyToonLook(handle)

	local activatedConnection

	activatedConnection = tool.Activated:Connect(function()
		local character = player.Character

		if not character then
			return
		end

		local root = character:FindFirstChild("HumanoidRootPart")

		if not root then
			return
		end

		-- The server throws using the characters current look direction.
		self:ThrowBall(player, root.CFrame.LookVector)
	end)

	-- Disconnecting prevents old connections from staying alive after the tool is destroyed.
	tool.Destroying:Connect(function()
		if activatedConnection then
			activatedConnection:Disconnect()
		end
	end)

	return tool
end

-- Converts a world ball into a tool if the player has inventory space.
function BallSystem:PickupBall(player, ball)
	if not ball or not ball.Parent then
		return
	end

	if self:CountBalls(player) >= MAX_BALLS then
		self:CreateFloatingText(ball.Position, "Inventory Full")
		self:PlaySound(ball, "rbxassetid://138090596", 0.55, 0.8)
		return
	end

	local tool = self:CreateTool(player)
	tool.Parent = player.Backpack

	self:AddStat(player, "Pickups", 1)
	self:CreateFloatingText(ball.Position, "+ Ball")
	self:PlaySound(ball, "rbxassetid://121434237134952", 1, 1)

	ball:Destroy()
end

-- Creates a physical ball in the world.
-- This is used both by the spawner and by thrown tools.
function BallSystem:MakeWorldBall(position, velocity, owner)
	self.SpawnedCount += 1

	local ball = Instance.new("Part")
	ball.Name = "PickupBall"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(2, 2, 2)
	ball.Anchored = false
	ball.CanCollide = true
	ball.CanTouch = true
	ball.Position = position
	ball:SetAttribute("OwnerUserId", owner and owner.UserId or 0)
	ball:SetAttribute("BounceCharge", 0)
	ball:SetAttribute("SpawnIndex", self.SpawnedCount)
	ball.Parent = workspace

	CollectionService:AddTag(ball, "PickupBall")
	self:ApplyToonLook(ball)

	ball.AssemblyLinearVelocity = velocity or Vector3.new(
		math.random(-8, 8),
		18,
		math.random(-8, 8)
	)

	ball.AssemblyAngularVelocity = Vector3.new(
		math.random(-6, 6),
		math.random(-6, 6),
		math.random(-6, 6)
	)

	local pickupPrompt = Instance.new("ProximityPrompt")
	pickupPrompt.ActionText = "Pick Up"
	pickupPrompt.ObjectText = "Charged Ball"
	pickupPrompt.KeyboardKeyCode = Enum.KeyCode.E
	pickupPrompt.HoldDuration = 0
	pickupPrompt.MaxActivationDistance = PICKUP_DISTANCE
	pickupPrompt.Parent = ball

	pickupPrompt.Triggered:Connect(function(player)
		self:PickupBall(player, ball)
	end)

	local lastHit = 0

	ball.Touched:Connect(function(hit)
		-- Small debounce prevents one collision from rapidly charging the ball multiple times.
		if os.clock() - lastHit < 0.12 then
			return
		end

		if not hit or hit:IsDescendantOf(ball) then
			return
		end

		lastHit = os.clock()

		local charge = ball:GetAttribute("BounceCharge") or 0
		charge = math.clamp(charge + 1, 0, MAX_BOUNCE_CHARGE)
		ball:SetAttribute("BounceCharge", charge)

		-- The ball grows and brightens as it becomes more charged.
		local scale = 1 + charge * 0.08
		ball.Size = Vector3.new(2, 2, 2) * scale
		ball.Color = Color3.fromRGB(math.clamp(105 + charge * 20, 0, 255), 145, 255)

		self:PlaySound(ball, "rbxassetid://12221967", 0.45, 1 + charge * 0.06)

		-- Once fully charged, the ball releases a shockwave and resets.
		if charge >= MAX_BOUNCE_CHARGE then
			local ownerUserId = ball:GetAttribute("OwnerUserId")
			local ownerPlayer = ownerUserId ~= 0 and Players:GetPlayerByUserId(ownerUserId) or nil

			self:ApplyShockwave(ball.Position, ownerPlayer, charge)

			ball:SetAttribute("BounceCharge", 0)
			ball.Size = Vector3.new(2, 2, 2)
			ball.Color = Color3.fromRGB(105, 145, 255)
		end
	end)

	self.ActiveBalls[ball] = true

	ball.Destroying:Connect(function()
		self.ActiveBalls[ball] = nil
	end)

	-- Removes old world balls automatically to prevent clutter and performance issues.
	Debris:AddItem(ball, BALL_LIFETIME)

	return ball
end

-- Throws the players equipped ball into the world.
function BallSystem:ThrowBall(player, direction)
	if self:IsCoolingDown(player) then
		return
	end

	if typeof(direction) ~= "Vector3" then
		return
	end

	if direction.Magnitude <= 0 then
		return
	end

	local character = player.Character

	if not character then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")

	if not root then
		return
	end

	local tool = character:FindFirstChild("Ball")

	if not tool then
		return
	end

	self:SetCooldown(player)
	tool:Destroy()

	local aimDirection = direction.Unit
	local spawnCFrame = root.CFrame * CFrame.new(0, 1.5, -3)
	local spawnPosition = spawnCFrame.Position

	-- Extra upward velocity makes the throw feel more arced and readable.
	local velocity = aimDirection * THROW_POWER + Vector3.new(0, 14, 0)

	local landingPosition, landingNormal = self:PredictLandingPoint(spawnPosition, velocity)

	self:ShowLandingMarker(landingPosition, landingNormal)

	local thrownBall = self:MakeWorldBall(spawnPosition, velocity, player)
	thrownBall:SetAttribute("Thrown", true)

	self:AddStat(player, "Throws", 1)
	self:PlaySound(root, "rbxassetid://12221967", 0.6, 1.2)
end

-- Configures the spawner prompt and handles spawning balls into the world.
function BallSystem:SetupSpawner()
	spawnerPrompt.ActionText = "Spawn Ball"
	spawnerPrompt.ObjectText = "Advanced Ball Spawner"
	spawnerPrompt.KeyboardKeyCode = Enum.KeyCode.E
	spawnerPrompt.HoldDuration = 0
	spawnerPrompt.MaxActivationDistance = 10

	spawnerPrompt.Triggered:Connect(function(player)
		-- Random offset and velocity make each spawned ball feel less static.
		local offset = Vector3.new(math.random(-3, 3), 5, math.random(-3, 3))
		local velocity = Vector3.new(math.random(-12, 12), 22, math.random(-12, 12))
		local ball = self:MakeWorldBall(spawnerPart.Position + offset, velocity, player)

		self:CreateFloatingText(ball.Position, "Spawned")
		self:PlaySound(spawnerPart, "rbxassetid://12221990", 0.55, 1.15)
	end)
end

-- Sets up player data and clears cooldowns when the player dies.
function BallSystem:SetupPlayer(player)
	self:GetPlayerStats(player)

	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 8)

		if humanoid then
			humanoid.Died:Connect(function()
				self.Cooldowns[player] = nil
			end)
		end
	end)
end

-- Updates small visual effects on active balls.
-- Heartbeat is used because this is a continuous server-side visual update.
function BallSystem:StartVisualLoop()
	RunService.Heartbeat:Connect(function()
		for ball in self.ActiveBalls do
			if ball.Parent then
				local charge = ball:GetAttribute("BounceCharge") or 0
				local highlight = ball:FindFirstChildOfClass("Highlight")

				if highlight then
					local pulse = math.sin(os.clock() * 6) * 0.08
					highlight.OutlineTransparency = math.clamp(0.15 - charge * 0.02 + pulse, 0, 0.7)
				end

				-- Charged balls spin slightly faster to communicate stored energy.
				if charge > 0 then
					ball.AssemblyAngularVelocity += Vector3.new(0, charge * 0.02, 0)
				end
			else
				self.ActiveBalls[ball] = nil
			end
		end
	end)
end

--// Player Setup
Players.PlayerAdded:Connect(function(player)
	system:SetupPlayer(player)
end)

Players.PlayerRemoving:Connect(function(player)
	system.Cooldowns[player] = nil
end)

for _, player in Players:GetPlayers() do
	system:SetupPlayer(player)
end

--// Remote Throw Handling
-- The server validates the request before actually throwing the ball.
throwEvent.OnServerEvent:Connect(function(player, direction)
	system:ThrowBall(player, direction)
end)

--// Start System
system:SetupSpawner()
system:StartVisualLoop()
