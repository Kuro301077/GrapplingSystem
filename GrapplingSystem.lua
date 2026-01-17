--[[
	Grappling Hook System
	Author: TurboTechHD
	
	Features:
	- Hold E to grapple, release to detach
	- Accelerating reel speed with momentum launch
	- Chain grappling (can grapple mid-air)
	- Anti-fling humanoid state locking [not the most reliable but it'll do ig]
	- Smooth FOV transitions
	- Motor6D body lean on strafe (roll)
	- Character orients to face grapple target
	- Smooth animation transitions
	- R6 limb trails	
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local Config = {
	MaxDistance = 200,
	MinReelSpeed = 60,
	MaxReelSpeed = 120,
	Acceleration = 1,
	ArrivalDistance = 3,
	LaunchUpwardForce = 110,
	LaunchForwardMultiplier = 0.8,
	Cooldown = 0.10,
	RopeColor = Color3.fromRGB(139, 90, 43),
	RopeWidth = 0.5,
	GrappleKey = Enum.KeyCode.E,
	DefaultFOV = 70,
	GrappleFOV = 100,
	FOVTweenTime = 0.6,
	StrafeSpeed = 25,
	CrossfadeTime = 0.15,
	MaxLeanAngle = math.rad(45),
	LeanSmoothing = 8,
}

local TrailConfig = {
	Lifetime = 0.25,
	ArmWidth = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.08),
		NumberSequenceKeypoint.new(0.25, 0.05),
		NumberSequenceKeypoint.new(0.6, 0.03),
		NumberSequenceKeypoint.new(1, 0),
	}),
	LegWidth = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.10),
		NumberSequenceKeypoint.new(0.25, 0.07),
		NumberSequenceKeypoint.new(0.6, 0.04),
		NumberSequenceKeypoint.new(1, 0),
	}),
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.75),
		NumberSequenceKeypoint.new(0.3, 0.88),
		NumberSequenceKeypoint.new(0.7, 0.96),
		NumberSequenceKeypoint.new(1, 1),
	}),
	Color = ColorSequence.new(Color3.fromRGB(220, 220, 220), Color3.fromRGB(255, 255, 255)),
}

local isGrappling = false
local targetPoint: Vector3? = nil
local currentSpeed = Config.MinReelSpeed
local lastGrappleTime = 0

local ropeBeam: Beam? = nil
local startAttachment: Attachment? = nil
local endAttachment: Attachment? = nil
local endPart: Part? = nil
local linearVelocity: LinearVelocity? = nil
local vectorForce: VectorForce? = nil
local attachmentForVelocity: Attachment? = nil

local animTracks: {[string]: AnimationTrack} = {}
local animator: Animator? = nil
local currentAnimState = "None"
local isFreefalling = false
local freefallConnection: RBXScriptConnection? = nil

local rootJoint: Motor6D? = nil
local originalC0: CFrame? = nil
local currentLean = 0

local activeTrails: {Trail} = {}
local activeAttachments: {Attachment} = {}

local connections: {RBXScriptConnection} = {}

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
local filterList: {Instance} = {}

local humanoidLocked = false
local prevStates: {[Enum.HumanoidStateType]: boolean} = {}

local activeFOVTween: Tween? = nil


local function getCharacter(): Model?
	return LocalPlayer.Character
end

local function getRootPart(): BasePart?
	local char = getCharacter()
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getHumanoid(): Humanoid?
	local char = getCharacter()
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function tweenFOV(targetFOV: number, duration: number)
	if activeFOVTween then
		activeFOVTween:Cancel()
	end

	local tween = TweenService:Create(Camera, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {FieldOfView = targetFOV})
	activeFOVTween = tween
	tween:Play()
end

local function getMoveDirection(): Vector3
	local moveDir = Vector3.zero

	-- We grab the camera's look/right vectors because we want movement relative to where
	-- the player is looking, not where the character is facing. Feels way more intuitive.
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		moveDir += Camera.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		moveDir -= Camera.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		moveDir -= Camera.CFrame.RightVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		moveDir += Camera.CFrame.RightVector
	end

	-- Kill the Y component so looking up/down doesn't make you fly vertically.
	-- Without this, looking straight down and pressing W would send you into the ground.
	moveDir = Vector3.new(moveDir.X, 0, moveDir.Z)
	return if moveDir.Magnitude > 0.1 then moveDir.Unit else Vector3.zero
end

local function getStrafeDirection(): number
	local left = UserInputService:IsKeyDown(Enum.KeyCode.A)
	local right = UserInputService:IsKeyDown(Enum.KeyCode.D)

	if left and not right then return -1
	elseif right and not left then return 1
	end
	return 0
end


local function lockHumanoidStates(hum: Humanoid)
	if humanoidLocked then return end
	humanoidLocked = true

	-- Roblox loves to ragdoll you when moving fast. We disable these states temporarily
	-- so the player doesn't flop around mid-grapple like a fish.
	local statesToLock = {
		Enum.HumanoidStateType.FallingDown,
		Enum.HumanoidStateType.Ragdoll,
		Enum.HumanoidStateType.GettingUp,
	}

	for _, state in statesToLock do
		local ok, val = pcall(function() return hum:GetStateEnabled(state) end)
		prevStates[state] = if ok then val else true
		pcall(function() hum:SetStateEnabled(state, false) end)
	end
end

local function unlockHumanoidStates(hum: Humanoid)
	if not humanoidLocked then return end
	humanoidLocked = false

	for state, wasEnabled in prevStates do
		pcall(function() hum:SetStateEnabled(state, wasEnabled) end)
	end
	table.clear(prevStates)
end


local function updateRaycastFilter()
	table.clear(filterList)
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(filterList, player.Character)
		end
	end
	raycastParams.FilterDescendantsInstances = filterList
end


local function loadAnimations(character: Model)
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end

	local animsFolder = script:FindFirstChild("Anims")
	if not animsFolder then
		warn("[Grapple] Anims folder not found")
		return
	end

	local animNames = {"GrappleStart", "GrappleLoop", "GrappleArrive", "Freefall", "Freefall_Loop"}
	for _, name in animNames do
		local animInstance = animsFolder:FindFirstChild(name)
		if animInstance and animInstance:IsA("Animation") and animator then
			local track = animator:LoadAnimation(animInstance)
			track.Priority = Enum.AnimationPriority.Action4
			if name == "GrappleLoop" or name == "Freefall_Loop" then
				track.Looped = true
			end
			animTracks[name] = track
		end
	end
end

local function stopAllGrappleAnims(fadeTime: number?)
	local fade = fadeTime or Config.CrossfadeTime
	for _, track in animTracks do
		if track.IsPlaying then
			track:Stop(fade)
		end
	end
	currentAnimState = "None"
end

local function playGrappleStart()
	stopAllGrappleAnims(0.05)

	local startTrack = animTracks.GrappleStart
	local loopTrack = animTracks.GrappleLoop

	if startTrack then
		startTrack:Play(Config.CrossfadeTime)
		currentAnimState = "GrappleStart"

		if loopTrack then
			local conn: RBXScriptConnection
			conn = startTrack.Stopped:Connect(function()
				conn:Disconnect()
				if currentAnimState == "GrappleStart" and isGrappling then
					loopTrack:Play(Config.CrossfadeTime)
					currentAnimState = "GrappleLoop"
				end
			end)
		end
	elseif loopTrack then
		loopTrack:Play(Config.CrossfadeTime)
		currentAnimState = "GrappleLoop"
	end
end

local function playGrappleArrive()
	local arriveTrack = animTracks.GrappleArrive
	if not arriveTrack then return end

	stopAllGrappleAnims(0.05)
	arriveTrack:Play(Config.CrossfadeTime)
	currentAnimState = "GrappleArrive"
end

local function playFreefallAnim()
	if isFreefalling or isGrappling then return end

	isFreefalling = true
	local freefallTrack = animTracks.Freefall
	local loopTrack = animTracks.Freefall_Loop

	if freefallTrack and not freefallTrack.IsPlaying then
		freefallTrack:Play(Config.CrossfadeTime)

		if loopTrack then
			local conn: RBXScriptConnection
			conn = freefallTrack.Stopped:Connect(function()
				conn:Disconnect()
				if isFreefalling and not isGrappling then
					loopTrack:Play(Config.CrossfadeTime)
				end
			end)
		end
	end
end

local function stopFreefallAnim()
	isFreefalling = false
	if animTracks.Freefall and animTracks.Freefall.IsPlaying then
		animTracks.Freefall:Stop(Config.CrossfadeTime)
	end
	if animTracks.Freefall_Loop and animTracks.Freefall_Loop.IsPlaying then
		animTracks.Freefall_Loop:Stop(Config.CrossfadeTime)
	end
end

local function startFreefallCheck(humanoid: Humanoid)
	if freefallConnection then
		freefallConnection:Disconnect()
	end

	-- Already falling? Start the anim now since StateChanged won't fire
	if humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		playFreefallAnim()
	end

	freefallConnection = humanoid.StateChanged:Connect(function(_, newState)
		if isGrappling then return end

		if newState == Enum.HumanoidStateType.Freefall then
			playFreefallAnim()
		elseif newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running then
			stopFreefallAnim()
		end
	end)
end

local function stopFreefallCheck()
	if freefallConnection then
		freefallConnection:Disconnect()
		freefallConnection = nil
	end
	stopFreefallAnim()
end


local function setupBodyOrientation(character: Model)
	local torso = character:FindFirstChild("Torso")
	if not torso then return end

	rootJoint = torso:FindFirstChild("Root Hip") :: Motor6D?
	if not rootJoint then
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp then
			for _, child in hrp:GetChildren() do
				if child:IsA("Motor6D") and child.Part1 == torso then
					rootJoint = child
					break
				end
			end
		end
	end

	-- Cache the original C0 so we can restore it later. C0 is the "rest pose" of the joint,
	-- basically where Part1 sits relative to Part0 when nothing's animating it.
	if rootJoint then
		originalC0 = rootJoint.C0
	end
end

local function updateBodyOrientation(dt: number, strafeDir: number)
	if not rootJoint or not originalC0 then return end

	-- strafeDir is -1 for A, +1 for D. We negate it because pressing A (left) should
	-- make the character lean left, which is a negative Z rotation (roll).
	local targetLean = -strafeDir * Config.MaxLeanAngle

	-- Smooth interpolation so the lean doesn't snap instantly. The math.min(1, ...) clamps
	-- the lerp factor so we don't overshoot on high framerates.
	currentLean += (targetLean - currentLean) * math.min(1, dt * Config.LeanSmoothing)

	-- CFrame.Angles(x, y, z) = pitch, yaw, roll. We only touch Z (roll) for the lean.
	-- Multiplying our rotation by originalC0 applies the lean ON TOP of the default pose,
	-- so we're not fighting the rig's natural setup.
	rootJoint.C0 = CFrame.Angles(0, 0, currentLean) * originalC0
end

local function resetBodyOrientation()
	currentLean = 0
	if rootJoint and originalC0 then
		rootJoint.C0 = originalC0
	end
end

local function createLimbTrail(part: BasePart, widthSequence: NumberSequence): (Trail, Attachment, Attachment)
	-- Attachments at 40% of the limb height (not 50%) so the trail stays inside the mesh
	-- instead of poking out the edges. Looks cleaner.
	local halfHeight = part.Size.Y * 0.4

	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, halfHeight, 0)
	a0.Parent = part

	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -halfHeight, 0)
	a1.Parent = part

	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = TrailConfig.Lifetime
	trail.MinLength = 0.02
	trail.WidthScale = widthSequence
	trail.Transparency = TrailConfig.Transparency
	trail.Color = TrailConfig.Color
	trail.LightEmission = 1
	trail.LightInfluence = 1
	trail.FaceCamera = true
	trail.Parent = part

	return trail, a0, a1
end

local function startLimbTrails(character: Model)
	local limbConfigs = {
		{names = {"Right Arm", "Left Arm"}, width = TrailConfig.ArmWidth},
		{names = {"Right Leg", "Left Leg"}, width = TrailConfig.LegWidth},
	}

	for _, config in limbConfigs do
		for _, limbName in config.names do
			local part = character:FindFirstChild(limbName)
			if part and part:IsA("BasePart") then
				local trail, a0, a1 = createLimbTrail(part, config.width)
				table.insert(activeTrails, trail)
				table.insert(activeAttachments, a0)
				table.insert(activeAttachments, a1)
			end
		end
	end
end

local function stopLimbTrails()
	-- Don't destroy immediately - let the trails fade out naturally based on their lifetime
	for _, trail in activeTrails do
		trail.Enabled = false
		Debris:AddItem(trail, TrailConfig.Lifetime + 0.1)
	end
	for _, att in activeAttachments do
		Debris:AddItem(att, TrailConfig.Lifetime + 0.1)
	end
	table.clear(activeTrails)
	table.clear(activeAttachments)
end

local function findGrapplePoint(): Vector3?
	local rootPart = getRootPart()
	local character = getCharacter()
	if not rootPart or not character then return nil end

	if not table.find(filterList, character) then
		table.insert(filterList, character)
		raycastParams.FilterDescendantsInstances = filterList
	end

	-- Raycast from camera, not character. This way you grapple where you're LOOKING,
	-- not where your character happens to be facing. Much more intuitive.
	local origin = Camera.CFrame.Position
	local direction = Camera.CFrame.LookVector * Config.MaxDistance
	local result = workspace:Raycast(origin, direction, raycastParams)

	if result then
		local ancestorModel = result.Instance:FindFirstAncestorOfClass("Model")
		if ancestorModel and Players:GetPlayerFromCharacter(ancestorModel) then
			return nil
		end
		return result.Position
	end

	return nil
end


local function createRopeVisual(target: Vector3)
	local character = getCharacter()
	if not character then return end

	local rightArm = character:FindFirstChild("Right Arm") :: BasePart? or getRootPart()
	if not rightArm then return end

	-- Attach at the bottom of the arm (the hand area)
	startAttachment = Instance.new("Attachment")
	startAttachment.Position = Vector3.new(0, -rightArm.Size.Y / 2, 0)
	startAttachment.Parent = rightArm

	-- Invisible part at the grapple point to anchor the other end of the beam
	endPart = Instance.new("Part")
	endPart.Size = Vector3.new(0.5, 0.5, 0.5)
	endPart.Position = target
	endPart.Anchored = true
	endPart.CanCollide = false
	endPart.Transparency = 1
	endPart.Parent = workspace

	endAttachment = Instance.new("Attachment")
	endAttachment.Parent = endPart

	ropeBeam = Instance.new("Beam")
	ropeBeam.Attachment0 = startAttachment
	ropeBeam.Attachment1 = endAttachment
	ropeBeam.Color = ColorSequence.new(Config.RopeColor)
	ropeBeam.Width0 = Config.RopeWidth
	ropeBeam.Width1 = Config.RopeWidth
	ropeBeam.FaceCamera = true
	ropeBeam.Segments = 1
	ropeBeam.Parent = rightArm
end

local function destroyRopeVisual()
	if ropeBeam then ropeBeam:Destroy(); ropeBeam = nil end
	if startAttachment then startAttachment:Destroy(); startAttachment = nil end
	if endAttachment then endAttachment:Destroy(); endAttachment = nil end
	if endPart then endPart:Destroy(); endPart = nil end
end

local function createMovementConstraints(): boolean
	local rootPart = getRootPart()
	if not rootPart then return false end

	local existing = rootPart:FindFirstChild("GrappleAttachment")
	if existing then existing:Destroy() end

	attachmentForVelocity = Instance.new("Attachment")
	attachmentForVelocity.Name = "GrappleAttachment"
	attachmentForVelocity.Parent = rootPart

	-- LinearVelocity directly sets velocity instead of applying force like the old BodyVelocity.
	-- This gives us precise control - we say "move at X speed" and it does exactly that.
	linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "GrappleVelocity"
	linearVelocity.Attachment0 = attachmentForVelocity
	linearVelocity.MaxForce = 50000
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.Parent = rootPart

	local character = getCharacter()
	local mass = 0
	if character then
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				mass += part:GetMass()
			end
		end
	end

	-- Without this, gravity pulls you down while grappling and you end up in an arc.
	-- We apply an upward force exactly equal to gravity so you travel in a straight line.
	vectorForce = Instance.new("VectorForce")
	vectorForce.Name = "GrappleAntiGravity"
	vectorForce.Attachment0 = attachmentForVelocity
	vectorForce.Force = Vector3.new(0, mass * workspace.Gravity, 0)
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.Parent = rootPart

	return true
end

local function destroyMovementConstraints()
	local rootPart = getRootPart()

	if linearVelocity then
		-- Zero the velocity before destroying. If we don't, the last velocity "sticks" and
		-- you get launched in a random direction when the constraint disappears.
		linearVelocity.VectorVelocity = Vector3.zero
		linearVelocity.MaxForce = 0
		task.defer(function()
			if linearVelocity then linearVelocity:Destroy(); linearVelocity = nil end
		end)
	end

	if vectorForce then vectorForce:Destroy(); vectorForce = nil end
	if attachmentForVelocity then attachmentForVelocity:Destroy(); attachmentForVelocity = nil end

	-- Safety cap so edge cases don't fling you into orbit
	if rootPart then
		local vel = rootPart.AssemblyLinearVelocity
		if vel.Magnitude > 200 then
			rootPart.AssemblyLinearVelocity = vel.Unit * 200
		end
	end
end

local function getDirectionToTarget(): Vector3
	local rootPart = getRootPart()
	if not rootPart or not targetPoint then return Vector3.zero end

	local direction = targetPoint - rootPart.Position
	return if direction.Magnitude > 0.1 then direction.Unit else Vector3.zero
end

local function getDistanceToTarget(): number
	local rootPart = getRootPart()
	if not rootPart or not targetPoint then return 0 end
	return (targetPoint - rootPart.Position).Magnitude
end


local function applyMomentum(arrivedAtTarget: boolean)
	local rootPart = getRootPart()
	if not rootPart then return end

	local direction = getDirectionToTarget()
	if direction.Magnitude < 0.1 then
		direction = rootPart.CFrame.LookVector
	end

	-- Flatten to horizontal so we don't launch downward if the target was below us
	local horizontalDir = Vector3.new(direction.X, 0, direction.Z)
	horizontalDir = if horizontalDir.Magnitude > 0.1 then horizontalDir.Unit else rootPart.CFrame.LookVector

	local momentum: Vector3
	if arrivedAtTarget then
		-- Slingshot feel: big upward pop + forward momentum based on how fast you were going
		local upward = Vector3.new(0, Config.LaunchUpwardForce, 0)
		local forward = horizontalDir * (currentSpeed * Config.LaunchForwardMultiplier)
		momentum = upward + forward
	else
		-- Let go early? You keep most of your momentum but not all of it.
		-- Rewards committing to the full grapple.
		momentum = direction * (currentSpeed * 0.8)
	end

	if momentum.Magnitude > 150 then
		momentum = momentum.Unit * 150
	end

	rootPart.AssemblyLinearVelocity = momentum
end


local function stopGrapple(arrivedAtTarget: boolean)
	if not isGrappling then return end
	isGrappling = false

	resetBodyOrientation()
	stopLimbTrails()
	destroyMovementConstraints()

	task.defer(function()
		applyMomentum(arrivedAtTarget)
	end)

	destroyRopeVisual()

	local humanoid = getHumanoid()
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		unlockHumanoidStates(humanoid)
	end

	tweenFOV(Config.DefaultFOV, Config.FOVTweenTime)

	if arrivedAtTarget then
		playGrappleArrive()

		local arriveTrack = animTracks.GrappleArrive
		if arriveTrack and humanoid then
			local conn: RBXScriptConnection
			conn = arriveTrack.Stopped:Connect(function()
				conn:Disconnect()
				startFreefallCheck(humanoid)
			end)
		elseif humanoid then
			startFreefallCheck(humanoid)
		end
	else
		stopAllGrappleAnims()
		if humanoid then
			startFreefallCheck(humanoid)
		end
	end

	targetPoint = nil
	currentSpeed = Config.MinReelSpeed
	lastGrappleTime = os.clock()
end

local function startGrapple(): boolean
	local now = os.clock()
	if now - lastGrappleTime < Config.Cooldown then
		return false
	end

	local rootPart = getRootPart()
	local humanoid = getHumanoid()
	local character = getCharacter()
	if not rootPart or not humanoid or not character then
		return false
	end

	if humanoid.Health <= 0 then
		return false
	end

	local target = findGrapplePoint()
	if not target then return false end

	targetPoint = target
	isGrappling = true
	currentSpeed = Config.MinReelSpeed

	createRopeVisual(target)

	if not createMovementConstraints() then
		isGrappling = false
		destroyRopeVisual()
		return false
	end

	lockHumanoidStates(humanoid)
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	stopFreefallCheck()
	playGrappleStart()
	startLimbTrails(character)

	tweenFOV(Config.GrappleFOV, Config.FOVTweenTime)

	return true
end

local function updateGrapple(dt: number)
	if not isGrappling then return end

	local rootPart = getRootPart()
	if not rootPart then
		stopGrapple(false)
		return
	end

	local distance = getDistanceToTarget()
	if distance <= Config.ArrivalDistance then
		stopGrapple(true)
		return
	end

	-- Speed ramps up over time for that "winding up" feel.
	-- Multiply by dt * 60 so it behaves the same at any framerate.
	currentSpeed = math.min(currentSpeed + Config.Acceleration * dt * 60, Config.MaxReelSpeed)

	local direction = getDirectionToTarget()
	local strafeVelocity = getMoveDirection() * Config.StrafeSpeed
	local finalVelocity = (direction * currentSpeed) + strafeVelocity

	if linearVelocity then
		linearVelocity.VectorVelocity = finalVelocity
	end

	updateBodyOrientation(dt, getStrafeDirection())
end

local function onCharacterAdded(character: Model)
	loadAnimations(character)
	setupBodyOrientation(character)
	updateRaycastFilter()

	local head = character:WaitForChild("Head", 5)
	if head and head:IsA("BasePart") then
		Camera.CameraSubject = head
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local diedConn = humanoid.Died:Connect(function()
		if isGrappling then
			stopGrapple(false)
		end
		stopFreefallCheck()
	end)
	table.insert(connections, diedConn)

	startFreefallCheck(humanoid)
end

local function onCharacterRemoving()
	stopFreefallCheck()
	resetBodyOrientation()
	rootJoint = nil
	originalC0 = nil

	if isGrappling then
		isGrappling = false
		destroyMovementConstraints()
		destroyRopeVisual()
		stopLimbTrails()

		local humanoid = getHumanoid()
		if humanoid then unlockHumanoidStates(humanoid) end

		tweenFOV(Config.DefaultFOV, Config.FOVTweenTime)
		targetPoint = nil
		currentSpeed = Config.MinReelSpeed
	end

	for _, track in animTracks do
		track:Stop(0)
	end
	table.clear(animTracks)
	animator = nil
	currentAnimState = "None"
end

local function initialize()
	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Config.GrappleKey then
			startGrapple()
		end
	end))

	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Config.GrappleKey and isGrappling then
			stopGrapple(false)
		end
	end))

	table.insert(connections, RunService.RenderStepped:Connect(updateGrapple))

	table.insert(connections, Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(char)
			table.insert(filterList, char)
			raycastParams.FilterDescendantsInstances = filterList
		end)
	end))

	for _, player in Players:GetPlayers() do
		table.insert(connections, player.CharacterAdded:Connect(function(char)
			table.insert(filterList, char)
			raycastParams.FilterDescendantsInstances = filterList
		end))
	end

	if LocalPlayer.Character then
		onCharacterAdded(LocalPlayer.Character)
	end

	table.insert(connections, LocalPlayer.CharacterAdded:Connect(onCharacterAdded))
	table.insert(connections, LocalPlayer.CharacterRemoving:Connect(onCharacterRemoving))
end

initialize()
