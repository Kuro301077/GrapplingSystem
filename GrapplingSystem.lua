--[[
	Grappling Hook System
	Author: TurboTechHD
	
	This system implements a grappling hook mechanic for R6 characters. The player holds E to 
	shoot a rope toward where they're looking, gets pulled toward that point with accelerating 
	speed, and launches off with momentum when they arrive or release early.
	
	The core loop works like this:
	1. Player presses E -> raycast from camera to find a valid surface
	2. If found, create visual rope + physics constraints to pull player
	3. Every frame: accelerate toward target, allow mid-air strafing
	4. On arrival or release: destroy constraints, apply momentum launch
	5. Player flies through the air with freefall animations until landing
	
	Key design decisions:
	- Raycast from camera (not character) so you grapple where you LOOK, feels way more intuitive
	- LinearVelocity instead of BodyVelocity because it gives precise speed control
	- Anti-gravity VectorForce so player travels in straight lines, not arcs
	- Humanoid state locking to prevent ragdolling at high speeds
	- FOV changes to sell the speed feeling
	- Body lean on strafe for visual feedback
]]

-- SERVICES
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

-- CORE REFERENCES
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

-- CONFIGURATION
local Config = {
	-- MaxDistance: how far the raycast reaches when looking for grapple points
	-- Min/MaxReelSpeed: the speed ramps from min to max as you grapple (feels like winding up)
	-- Acceleration: how fast the speed increases per frame (multiplied by dt * 60 for framerate independence)
	MaxDistance = 200,
	MinReelSpeed = 60,
	MaxReelSpeed = 120,
	Acceleration = 1,

	-- ArrivalDistance: how close to target before we consider you "arrived" and trigger launch
	-- LaunchUpwardForce: the vertical boost when you reach the target (slingshot effect)
	-- LaunchForwardMultiplier: how much of your grapple speed carries into forward momentum
	ArrivalDistance = 3,
	LaunchUpwardForce = 110,
	LaunchForwardMultiplier = 0.8,

	-- Cooldown: minimum time between grapples to prevent spam
	Cooldown = 0.10,

	-- The rope that connects player to grapple point
	RopeColor = Color3.fromRGB(139, 90, 43),
	RopeWidth = 0.5,

	GrappleKey = Enum.KeyCode.E,

	-- Wider FOV during grapple makes it feel faster (common game design trick)
	-- TweenTime controls how smoothly the FOV transitions
	DefaultFOV = 70,
	GrappleFOV = 100,
	FOVTweenTime = 0.6,

	-- StrafeSpeed: how fast you can move side-to-side while grappling
	-- This gives players control and makes the system feel responsive
	StrafeSpeed = 25,

	-- CrossfadeTime: how long animations blend between each other
	-- Prevents jarring snaps when switching animations
	CrossfadeTime = 0.15,

	-- MaxLeanAngle: maximum rotation (in radians) when strafing
	-- LeanSmoothing: higher = snappier lean response, lower = floatier
	MaxLeanAngle = math.rad(45),
	LeanSmoothing = 8,
}

-- TRAIL CONFIGURATION
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

-- STATE VARIABLES
-- We need to know if we're grappling, where we're going, how fast, etc.
local isGrappling = false
local targetPoint: Vector3? = nil
local currentSpeed = Config.MinReelSpeed
local lastGrappleTime = 0

-- VISUAL OBJECTS
local ropeBeam: Beam? = nil
local startAttachment: Attachment? = nil
local endAttachment: Attachment? = nil
local endPart: Part? = nil

-- PHYSICS OBJECTS
local linearVelocity: LinearVelocity? = nil
local vectorForce: VectorForce? = nil
local attachmentForVelocity: Attachment? = nil

-- ANIMATION STATE
local animTracks: {[string]: AnimationTrack} = {}
local animator: Animator? = nil
local currentAnimState = "None"

-- FREEFALL STATE
local isFreefalling = false
local freefallConnection: RBXScriptConnection? = nil

-- BODY LEAN STATE
local rootJoint: Motor6D? = nil
local originalC0: CFrame? = nil
local currentLean = 0

--TRAIL TRACKING
local activeTrails: {Trail} = {}
local activeAttachments: {Attachment} = {}

-- EVENT CONNECTIONS
local connections: {RBXScriptConnection} = {}

-- RAYCAST SETUP
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
local filterList: {Instance} = {}

-- HUMANOID STATE LOCKING
local humanoidLocked = false
local prevStates: {[Enum.HumanoidStateType]: boolean} = {}

-- FOV TWEEN TRACKING
local activeFOVTween: Tween? = nil

--[[
	Gets the local player's character model.
	Returns nil if the character doesn't exist yet (loading/respawning).
]]
local function getCharacter(): Model?
	return LocalPlayer.Character
end

--[[
	Gets the HumanoidRootPart from the character.
	This is the main physics part that represents the player's position/velocity.
	All our physics constraints attach to this part.
]]
local function getRootPart(): BasePart?
	local char = getCharacter()
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[[
	Gets the Humanoid from the character.
	We need this for state management, health checks, and animation control.
]]
local function getHumanoid(): Humanoid?
	local char = getCharacter()
	return char and char:FindFirstChildOfClass("Humanoid")
end

--[[
	Smoothly transitions the camera FOV to a target value.
	Uses TweenService for smooth interpolation with easing.
	
	Why we do this:
	- Wider FOV during grappling makes the player feel like they're moving faster
	- It's a common technique in games (used in racing games, sprinting, etc.)
	- The smooth transition prevents jarring visual changes
	
	@param targetFOV: The FOV value to transition to
	@param duration: How long the transition should take
]]
local function tweenFOV(targetFOV: number, duration: number)
	-- Cancel any existing FOV tween to prevent conflicts
	-- Without this, overlapping tweens could fight each other
	if activeFOVTween then
		activeFOVTween:Cancel()
	end

	-- Create and play the new tween
	-- Quad easing with Out direction gives a nice "settle into place" feel
	local tween = TweenService:Create(Camera, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {FieldOfView = targetFOV})
	activeFOVTween = tween
	tween:Play()
end

--[[
	Calculates the player's intended movement direction based on WASD input.
	
	Key design choice: We use the CAMERA's look/right vectors, not the character's.
	This means pressing W always moves you toward where you're LOOKING, not where
	your character is facing. This feels much more intuitive for aerial movement.
	
	We also zero out the Y component so looking up/down doesn't affect horizontal
	movement. Without this, looking straight down and pressing W would send you
	into the ground.
	
	@return Vector3: Normalized direction vector, or zero if no input
]]
local function getMoveDirection(): Vector3
	local moveDir = Vector3.zero

	-- Check each WASD key and add/subtract the corresponding camera vector
	-- This builds up a combined direction from all held keys
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		moveDir += Camera.CFrame.LookVector  -- Forward (where camera looks)
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		moveDir -= Camera.CFrame.LookVector  -- Backward
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		moveDir -= Camera.CFrame.RightVector -- Left (negative right)
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		moveDir += Camera.CFrame.RightVector -- Right
	end

	-- Flatten to horizontal plane by zeroing Y
	-- This prevents vertical movement from look direction
	moveDir = Vector3.new(moveDir.X, 0, moveDir.Z)

	-- Only return a direction if there's meaningful input
	-- The 0.1 threshold prevents tiny floating point noise from causing movement
	return if moveDir.Magnitude > 0.1 then moveDir.Unit else Vector3.zero
end

--[[
	Gets the strafe direction as a simple -1, 0, or +1 value.
	Used for the body lean effect - we lean in the direction we're strafing.
	
	@return number: -1 for left (A), +1 for right (D), 0 for neither or both
]]
local function getStrafeDirection(): number
	local left = UserInputService:IsKeyDown(Enum.KeyCode.A)
	local right = UserInputService:IsKeyDown(Enum.KeyCode.D)

	-- If pressing both or neither, no strafe direction
	if left and not right then return -1
	elseif right and not left then return 1
	end
	return 0
end

--[[
	Disables humanoid states that could cause issues during grappling.
	
	The problem: When a character moves very fast or experiences sudden velocity
	changes, Roblox often interprets this as "falling down" and triggers ragdoll
	or FallingDown states. This makes the player flop around uncontrollably.
	
	The solution: Temporarily disable these states while grappling, then restore
	them afterward. We save the original enabled state of each so we don't
	accidentally enable something that was disabled for other reasons.
	
	@param hum: The humanoid to lock states on
]]
local function lockHumanoidStates(hum: Humanoid)
	-- Prevent double-locking
	if humanoidLocked then return end
	humanoidLocked = true

	-- These states cause the most problems at high speeds
	local statesToLock = {
		Enum.HumanoidStateType.FallingDown, -- Trips and falls
		Enum.HumanoidStateType.Ragdoll,     -- Full ragdoll physics
		Enum.HumanoidStateType.GettingUp,   -- Recovery from ragdoll (can interrupt movement)
	}

	-- Save original state and disable
	-- Using pcall because some states might not be accessible in all contexts
	for _, state in statesToLock do
		local ok, val = pcall(function() return hum:GetStateEnabled(state) end)
		prevStates[state] = if ok then val else true
		pcall(function() hum:SetStateEnabled(state, false) end)
	end
end

--[[
	Restores humanoid states to their original values after grappling ends.
	This undoes what lockHumanoidStates did.
	
	@param hum: The humanoid to unlock states on
]]
local function unlockHumanoidStates(hum: Humanoid)
	-- Only unlock if we actually locked
	if not humanoidLocked then return end
	humanoidLocked = false

	-- Restore each state to its previous value
	for state, wasEnabled in prevStates do
		pcall(function() hum:SetStateEnabled(state, wasEnabled) end)
	end
	table.clear(prevStates)
end

--[[
	Updates the raycast filter to include all current player characters.
	Called when players join/respawn to keep the filter current.
	
	Why we exclude all players:
	- Grappling onto yourself would be weird and broken
	- Grappling onto other players could be used for griefing
	- We only want to grapple onto world geometry
]]
local function updateRaycastFilter()
	table.clear(filterList)

	-- Add every player's character to the exclude list
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(filterList, player.Character)
		end
	end

	-- Apply the updated filter
	raycastParams.FilterDescendantsInstances = filterList
end

--[[
	Loads all grappling animations from the Anims folder.
	Called when the character spawns to prepare animation tracks.
	
	Animation structure:
	- GrappleStart: Plays once when grapple begins (arm reaches out)
	- GrappleLoop: Loops while being pulled (flying pose)
	- GrappleArrive: Plays once when reaching target (landing prep)
	- Freefall: Plays once when starting to fall
	- Freefall_Loop: Loops while falling
	
	@param character: The character model to load animations for
]]
local function loadAnimations(character: Model)
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	-- Get or create the animator
	-- Animator is the component that actually plays AnimationTracks
	animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end

	-- Find the animations folder
	local animsFolder = script:FindFirstChild("Anims")
	if not animsFolder then
		warn("[Grapple] Anims folder not found")
		return
	end

	-- Load each animation by name
	local animNames = {"GrappleStart", "GrappleLoop", "GrappleArrive", "Freefall", "Freefall_Loop"}
	for _, name in animNames do
		local animInstance = animsFolder:FindFirstChild(name)
		if animInstance and animInstance:IsA("Animation") and animator then
			local track = animator:LoadAnimation(animInstance)
			-- High priority so grapple anims override other animations
			track.Priority = Enum.AnimationPriority.Action4
			-- Loop animations need the Looped property set
			if name == "GrappleLoop" or name == "Freefall_Loop" then
				track.Looped = true
			end
			animTracks[name] = track
		end
	end
end

--[[
	Stops all grapple-related animations with a fade out.
	Used when grappling ends or when transitioning between states.
	
	@param fadeTime: How long to fade out (defaults to CrossfadeTime config)
]]
local function stopAllGrappleAnims(fadeTime: number?)
	local fade = fadeTime or Config.CrossfadeTime
	for _, track in animTracks do
		if track.IsPlaying then
			track:Stop(fade)
		end
	end
	currentAnimState = "None"
end

--[[
	Plays the grapple start animation, then transitions to the loop.
	
	The flow is: GrappleStart (once) -> GrappleLoop (continuous)
	We connect to the Stopped event to chain them together seamlessly.
]]
local function playGrappleStart()
	-- Quick fade out of any current animations
	stopAllGrappleAnims(0.05)

	local startTrack = animTracks.GrappleStart
	local loopTrack = animTracks.GrappleLoop

	if startTrack then
		startTrack:Play(Config.CrossfadeTime)
		currentAnimState = "GrappleStart"

		-- When start animation finishes, begin the loop
		if loopTrack then
			local conn: RBXScriptConnection
			conn = startTrack.Stopped:Connect(function()
				conn:Disconnect()  -- Clean up the connection
				-- Only transition to loop if we're still in the start state and still grappling
				-- This check prevents weird transitions if the player released during the start anim
				if currentAnimState == "GrappleStart" and isGrappling then
					loopTrack:Play(Config.CrossfadeTime)
					currentAnimState = "GrappleLoop"
				end
			end)
		end
	elseif loopTrack then
		-- If no start animation, just play the loop directly
		loopTrack:Play(Config.CrossfadeTime)
		currentAnimState = "GrappleLoop"
	end
end

--[[
	Plays the arrival animation when reaching the grapple target.
	This is a one-shot animation that plays when the grapple completes successfully.
]]
local function playGrappleArrive()
	local arriveTrack = animTracks.GrappleArrive
	if not arriveTrack then return end

	stopAllGrappleAnims(0.05)
	arriveTrack:Play(Config.CrossfadeTime)
	currentAnimState = "GrappleArrive"
end

--[[
	Plays the freefall animation when the player starts falling.
	Similar to grapple, it's a start animation that transitions to a loop.
	
	Guards against playing if already freefalling or currently grappling.
]]
local function playFreefallAnim()
	-- Don't double-play or interrupt grappling
	if isFreefalling or isGrappling then return end

	isFreefalling = true
	local freefallTrack = animTracks.Freefall
	local loopTrack = animTracks.Freefall_Loop

	if freefallTrack and not freefallTrack.IsPlaying then
		freefallTrack:Play(Config.CrossfadeTime)

		-- Chain to loop when start finishes
		if loopTrack then
			local conn: RBXScriptConnection
			conn = freefallTrack.Stopped:Connect(function()
				conn:Disconnect()
				-- Only loop if still freefalling and not grappling
				if isFreefalling and not isGrappling then
					loopTrack:Play(Config.CrossfadeTime)
				end
			end)
		end
	end
end

--[[
	Stops the freefall animation.
	Called when the player lands or starts a new grapple.
]]
local function stopFreefallAnim()
	isFreefalling = false
	if animTracks.Freefall and animTracks.Freefall.IsPlaying then
		animTracks.Freefall:Stop(Config.CrossfadeTime)
	end
	if animTracks.Freefall_Loop and animTracks.Freefall_Loop.IsPlaying then
		animTracks.Freefall_Loop:Stop(Config.CrossfadeTime)
	end
end

--[[
	Sets up a listener for humanoid state changes to play freefall animations.
	
	The humanoid's StateChanged event tells us when the player starts/stops falling.
	We use this to trigger freefall animations at the right times.
	
	@param humanoid: The humanoid to monitor
]]
local function startFreefallCheck(humanoid: Humanoid)
	-- Clean up any existing connection
	if freefallConnection then
		freefallConnection:Disconnect()
	end

	-- If already falling when this is called, start the animation immediately
	-- This handles the case where we start monitoring mid-fall
	if humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		playFreefallAnim()
	end

	-- Listen for state changes
	freefallConnection = humanoid.StateChanged:Connect(function(_, newState)
		-- Don't interfere with grappling
		if isGrappling then return end

		if newState == Enum.HumanoidStateType.Freefall then
			playFreefallAnim()
		elseif newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running then
			stopFreefallAnim()
		end
	end)
end

--[[
	Stops monitoring for freefall state changes.
	Called when character dies or is removed.
]]
local function stopFreefallCheck()
	if freefallConnection then
		freefallConnection:Disconnect()
		freefallConnection = nil
	end
	stopFreefallAnim()
end

--[[
	Finds and caches the root Motor6D for body lean manipulation.
	
	R6 characters have a Motor6D called "Root Hip" that connects the
	HumanoidRootPart to the Torso. By rotating this joint's C0, we can
	make the entire visible body lean without affecting physics.
	
	@param character: The character to set up
]]
local function setupBodyOrientation(character: Model)
	local torso = character:FindFirstChild("Torso")
	if not torso then return end

	-- Try to find the root joint - it's usually called "Root Hip" in the Torso
	rootJoint = torso:FindFirstChild("Root Hip") :: Motor6D?

	-- Fallback: search in HumanoidRootPart for any Motor6D pointing to Torso
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

	-- Cache the original C0 so we can restore it later
	-- C0 is the "rest pose" of the joint - where Part1 sits relative to Part0
	if rootJoint then
		originalC0 = rootJoint.C0
	end
end

--[[
	Updates the body lean based on strafe input.
	Called every frame during grappling.
	
	How it works:
	1. Get strafe direction (-1 left, +1 right, 0 none)
	2. Calculate target lean angle (negative strafeDir because left strafe = lean left)
	3. Smoothly interpolate current lean toward target
	4. Apply the lean rotation to the root joint
	
	The smooth interpolation prevents jarring snaps when changing direction.
	
	@param dt: Delta time for framerate-independent smoothing
	@param strafeDir: -1, 0, or +1 indicating strafe direction
]]
local function updateBodyOrientation(dt: number, strafeDir: number)
	if not rootJoint or not originalC0 then return end

	-- Calculate target lean (negate strafeDir: pressing A = lean left = negative rotation)
	local targetLean = -strafeDir * Config.MaxLeanAngle

	-- Smooth interpolation toward target
	-- math.min(1, ...) clamps the lerp factor to prevent overshooting on high framerates
	currentLean += (targetLean - currentLean) * math.min(1, dt * Config.LeanSmoothing)

	-- Apply lean as Z rotation (roll) on top of the original C0
	-- CFrame.Angles(x, y, z) = pitch, yaw, roll
	-- Multiplying our rotation by originalC0 preserves the default rig setup
	rootJoint.C0 = CFrame.Angles(0, 0, currentLean) * originalC0
end

--[[
	Resets the body lean to neutral.
	Called when grappling ends.
]]
local function resetBodyOrientation()
	currentLean = 0
	if rootJoint and originalC0 then
		rootJoint.C0 = originalC0
	end
end

--[[
	Creates a trail on a single limb part.
	
	Trails work by connecting two Attachments and drawing a quad between
	their positions over time. We place attachments at the top and bottom
	of each limb to create a trail that covers the whole limb.
	
	@param part: The limb part to add a trail to
	@param widthSequence: The width profile for this trail (arms vs legs differ)
	@return Trail, Attachment, Attachment: The created objects for cleanup
]]
local function createLimbTrail(part: BasePart, widthSequence: NumberSequence): (Trail, Attachment, Attachment)
	-- Place attachments at 40% of limb height (not 50%) to keep trail inside the mesh
	-- Using full 50% would make the trail edges poke out of the limb
	local halfHeight = part.Size.Y * 0.4

	-- Top attachment
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, halfHeight, 0)
	a0.Parent = part

	-- Bottom attachment
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -halfHeight, 0)
	a1.Parent = part

	-- The trail itself
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = TrailConfig.Lifetime
	trail.MinLength = 0.02  -- Minimum segment length (prevents too many segments when moving slowly)
	trail.WidthScale = widthSequence
	trail.Transparency = TrailConfig.Transparency
	trail.Color = TrailConfig.Color
	trail.LightEmission = 1   -- Fully emissive (glows in dark)
	trail.LightInfluence = 1  -- Also affected by world lighting
	trail.FaceCamera = true   -- Always faces the player's camera
	trail.Parent = part

	return trail, a0, a1
end

--[[
	Creates trails on all limbs (both arms and legs).
	Called when grappling starts.
	
	@param character: The character to add trails to
]]
local function startLimbTrails(character: Model)
	-- Define which limbs get trails and their width profiles
	local limbConfigs = {
		{names = {"Right Arm", "Left Arm"}, width = TrailConfig.ArmWidth},
		{names = {"Right Leg", "Left Leg"}, width = TrailConfig.LegWidth},
	}

	-- Create trails for each limb
	for _, config in limbConfigs do
		for _, limbName in config.names do
			local part = character:FindFirstChild(limbName)
			if part and part:IsA("BasePart") then
				local trail, a0, a1 = createLimbTrail(part, config.width)
				-- Track all created objects for cleanup
				table.insert(activeTrails, trail)
				table.insert(activeAttachments, a0)
				table.insert(activeAttachments, a1)
			end
		end
	end
end

--[[
	Removes all limb trails.
	Called when grappling ends.
	
	We don't destroy immediately - instead we disable the trails and let
	Debris clean them up after their lifetime expires. This allows the
	existing trail segments to fade out naturally instead of popping.
]]
local function stopLimbTrails()
	for _, trail in activeTrails do
		trail.Enabled = false  -- Stop generating new segments
		-- Let Debris destroy it after the trail has fully faded
		Debris:AddItem(trail, TrailConfig.Lifetime + 0.1)
	end
	for _, att in activeAttachments do
		Debris:AddItem(att, TrailConfig.Lifetime + 0.1)
	end
	-- Clear our tracking tables
	table.clear(activeTrails)
	table.clear(activeAttachments)
end

--[[
	Finds a valid grapple point by raycasting from the camera.
	
	Key design decision: We raycast from the CAMERA, not the character.
	This means you grapple toward where you're LOOKING, not where your
	character happens to be facing. Much more intuitive for the player.
	
	We exclude all player characters from the raycast so you can't
	grapple onto yourself or other players.
	
	@return Vector3?: The grapple point, or nil if nothing valid found
]]
local function findGrapplePoint(): Vector3?
	local rootPart = getRootPart()
	local character = getCharacter()
	if not rootPart or not character then return nil end

	-- Make sure our own character is in the filter
	if not table.find(filterList, character) then
		table.insert(filterList, character)
		raycastParams.FilterDescendantsInstances = filterList
	end

	-- Raycast from camera position in camera look direction
	local origin = Camera.CFrame.Position
	local direction = Camera.CFrame.LookVector * Config.MaxDistance
	local result = workspace:Raycast(origin, direction, raycastParams)

	if result then
		-- Double-check we didn't hit a player (shouldn't happen with filter, but safety first)
		local ancestorModel = result.Instance:FindFirstAncestorOfClass("Model")
		if ancestorModel and Players:GetPlayerFromCharacter(ancestorModel) then
			return nil
		end
		return result.Position
	end

	return nil
end

--[[
	Creates the visual rope from the player's arm to the target point.
	
	Implementation:
	1. Create an attachment on the player's right arm (at the hand position)
	2. Create an invisible part at the grapple target
	3. Create an attachment on that part
	4. Create a Beam connecting the two attachments
	
	The Beam automatically updates as the player moves, keeping the rope
	visually connected between the hand and target.
	
	@param target: The world position to connect the rope to
]]
local function createRopeVisual(target: Vector3)
	local character = getCharacter()
	if not character then return end

	-- Use the right arm if available, otherwise fall back to root part
	local rightArm = character:FindFirstChild("Right Arm") :: BasePart? or getRootPart()
	if not rightArm then return end

	-- Attachment at the bottom of the arm (hand area)
	startAttachment = Instance.new("Attachment")
	startAttachment.Position = Vector3.new(0, -rightArm.Size.Y / 2, 0)
	startAttachment.Parent = rightArm

	-- Create an invisible anchor part at the grapple point
	-- Beams need two attachments, and attachments need parts to live in
	endPart = Instance.new("Part")
	endPart.Size = Vector3.new(0.5, 0.5, 0.5)
	endPart.Position = target
	endPart.Anchored = true    -- Doesn't move
	endPart.CanCollide = false -- Doesn't block anything
	endPart.Transparency = 1   -- Invisible
	endPart.Parent = workspace

	endAttachment = Instance.new("Attachment")
	endAttachment.Parent = endPart

	-- The actual rope visual
	ropeBeam = Instance.new("Beam")
	ropeBeam.Attachment0 = startAttachment
	ropeBeam.Attachment1 = endAttachment
	ropeBeam.Color = ColorSequence.new(Config.RopeColor)
	ropeBeam.Width0 = Config.RopeWidth
	ropeBeam.Width1 = Config.RopeWidth
	ropeBeam.FaceCamera = true  -- Always visible regardless of angle
	ropeBeam.Segments = 1       -- Straight line (more segments would add curve)
	ropeBeam.Parent = rightArm
end

--[[
	Destroys all rope visual elements.
	Called when grappling ends.
]]
local function destroyRopeVisual()
	if ropeBeam then ropeBeam:Destroy(); ropeBeam = nil end
	if startAttachment then startAttachment:Destroy(); startAttachment = nil end
	if endAttachment then endAttachment:Destroy(); endAttachment = nil end
	if endPart then endPart:Destroy(); endPart = nil end
end

--[[
	Creates the physics constraints that pull the player toward the target.
	
	We use two constraints:
	
	1. LinearVelocity: Directly sets the player's velocity each frame.
	   Unlike the old BodyVelocity, LinearVelocity gives precise control -
	   we say "move at X speed" and it does exactly that.
	
	2. VectorForce: Applies a constant upward force equal to gravity.
	   This cancels out gravity so the player travels in a straight line
	   toward the target instead of an arc. Without this, you'd dip down
	   while grappling and might miss your target.
	
	@return boolean: True if constraints were created successfully
]]
local function createMovementConstraints(): boolean
	local rootPart = getRootPart()
	if not rootPart then return false end

	-- Clean up any existing grapple attachment (shouldn't happen, but safety)
	local existing = rootPart:FindFirstChild("GrappleAttachment")
	if existing then existing:Destroy() end

	-- Constraints need an attachment to specify where forces apply
	attachmentForVelocity = Instance.new("Attachment")
	attachmentForVelocity.Name = "GrappleAttachment"
	attachmentForVelocity.Parent = rootPart

	-- LinearVelocity: Controls movement direction and speed
	linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "GrappleVelocity"
	linearVelocity.Attachment0 = attachmentForVelocity
	linearVelocity.MaxForce = 50000  -- High enough to overcome any resistance
	linearVelocity.VectorVelocity = Vector3.zero  -- Will be set each frame
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World  -- World space, not local
	linearVelocity.Parent = rootPart

	-- Calculate total character mass for anti-gravity force
	local character = getCharacter()
	local mass = 0
	if character then
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				mass += part:GetMass()
			end
		end
	end

	-- VectorForce: Cancels gravity for straight-line movement
	-- Force = mass * gravity (Newton's second law)
	vectorForce = Instance.new("VectorForce")
	vectorForce.Name = "GrappleAntiGravity"
	vectorForce.Attachment0 = attachmentForVelocity
	vectorForce.Force = Vector3.new(0, mass * workspace.Gravity, 0)
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.Parent = rootPart

	return true
end

--[[
	Destroys the physics constraints.
	Called when grappling ends.
	
	Important: We zero the velocity BEFORE destroying the constraint.
	If we don't, the last velocity "sticks" and the player gets
	launched in whatever direction they were going.
]]
local function destroyMovementConstraints()
	local rootPart = getRootPart()

	if linearVelocity then
		-- Zero velocity to prevent launch on destroy
		linearVelocity.VectorVelocity = Vector3.zero
		linearVelocity.MaxForce = 0
		-- Use task.defer to destroy on the next frame
		-- This gives the physics engine time to apply the zero velocity
		task.defer(function()
			if linearVelocity then linearVelocity:Destroy(); linearVelocity = nil end
		end)
	end

	if vectorForce then vectorForce:Destroy(); vectorForce = nil end
	if attachmentForVelocity then attachmentForVelocity:Destroy(); attachmentForVelocity = nil end

	-- Safety cap on velocity to prevent edge cases from flinging the player
	if rootPart then
		local vel = rootPart.AssemblyLinearVelocity
		if vel.Magnitude > 200 then
			rootPart.AssemblyLinearVelocity = vel.Unit * 200
		end
	end
end

--[[
	Calculates the direction from the player to the grapple target.
	
	@return Vector3: Normalized direction, or zero if invalid
]]
local function getDirectionToTarget(): Vector3
	local rootPart = getRootPart()
	if not rootPart or not targetPoint then return Vector3.zero end

	local direction = targetPoint - rootPart.Position
	-- Only return a direction if we're far enough away for it to be meaningful
	return if direction.Magnitude > 0.1 then direction.Unit else Vector3.zero
end

--[[
	Calculates the distance from the player to the grapple target.
	
	@return number: Distance in studs
]]
local function getDistanceToTarget(): number
	local rootPart = getRootPart()
	if not rootPart or not targetPoint then return 0 end
	return (targetPoint - rootPart.Position).Magnitude
end

--[[
	Applies momentum to the player when grappling ends.
	
	The momentum depends on whether the player reached the target or released early:
	
	Arrived at target:
	- Big upward boost (slingshot effect)
	- Forward momentum based on grapple speed
	- Rewards completing the full grapple
	
	Released early:
	- Keep most of current momentum (80%)
	- Direction follows grapple path
	- Rewards committing to the grapple
	
	@param arrivedAtTarget: Whether the player reached the grapple point
]]
local function applyMomentum(arrivedAtTarget: boolean)
	local rootPart = getRootPart()
	if not rootPart then return end

	-- Get the direction we were traveling
	local direction = getDirectionToTarget()
	if direction.Magnitude < 0.1 then
		direction = rootPart.CFrame.LookVector
	end

	-- Flatten to horizontal so we don't launch downward if target was below
	local horizontalDir = Vector3.new(direction.X, 0, direction.Z)
	horizontalDir = if horizontalDir.Magnitude > 0.1 then horizontalDir.Unit else rootPart.CFrame.LookVector

	local momentum: Vector3
	if arrivedAtTarget then
		-- Full arrival: big upward pop + forward momentum
		-- This creates that satisfying slingshot feeling
		local upward = Vector3.new(0, Config.LaunchUpwardForce, 0)
		local forward = horizontalDir * (currentSpeed * Config.LaunchForwardMultiplier)
		momentum = upward + forward
	else
		-- Early release: keep most momentum but not all
		-- This rewards committing to the full grapple
		momentum = direction * (currentSpeed * 0.8)
	end

	-- Cap momentum to prevent ridiculous speeds
	if momentum.Magnitude > 150 then
		momentum = momentum.Unit * 150
	end

	rootPart.AssemblyLinearVelocity = momentum
end

--[[
	Stops the grapple and cleans up all associated objects.
	
	This function handles everything needed to end a grapple cleanly:
	1. Reset body lean
	2. Stop limb trails
	3. Destroy physics constraints
	4. Apply momentum (deferred to avoid physics conflicts)
	5. Destroy rope visual
	6. Restore humanoid states
	7. Reset FOV
	8. Play appropriate animations
	9. Resume freefall monitoring
	
	@param arrivedAtTarget: Whether the player reached the grapple point
]]
local function stopGrapple(arrivedAtTarget: boolean)
	-- Guard against double-stopping
	if not isGrappling then return end
	isGrappling = false

	-- Clean up visual effects
	resetBodyOrientation()
	stopLimbTrails()

	-- Clean up physics (this zeros velocity before destroying)
	destroyMovementConstraints()

	-- Apply momentum on the next frame to avoid physics conflicts
	-- task.defer ensures this runs after the current physics step
	task.defer(function()
		applyMomentum(arrivedAtTarget)
	end)

	-- Clean up rope visual
	destroyRopeVisual()

	-- Restore humanoid to normal state
	local humanoid = getHumanoid()
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		unlockHumanoidStates(humanoid)
	end

	-- Return FOV to normal
	tweenFOV(Config.DefaultFOV, Config.FOVTweenTime)

	-- Handle animations based on how grapple ended
	if arrivedAtTarget then
		-- Play arrival animation, then resume freefall monitoring
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
		-- Early release: just stop anims and resume freefall monitoring
		stopAllGrappleAnims()
		if humanoid then
			startFreefallCheck(humanoid)
		end
	end

	-- Clear state for next grapple
	targetPoint = nil
	currentSpeed = Config.MinReelSpeed
	lastGrappleTime = os.clock()
end

--[[
	Attempts to start a new grapple.
	
	This function handles all the setup needed to begin grappling:
	1. Check cooldown
	2. Validate character state
	3. Find grapple point via raycast
	4. Create rope visual
	5. Create physics constraints
	6. Lock humanoid states
	7. Start animations and trails
	8. Begin FOV transition
	
	@return boolean: True if grapple started successfully
]]
local function startGrapple(): boolean
	-- Check cooldown to prevent spam
	local now = os.clock()
	if now - lastGrappleTime < Config.Cooldown then
		print("[Grapple] On cooldown")
		return false
	end

	-- Validate we have a valid character
	local rootPart = getRootPart()
	local humanoid = getHumanoid()
	local character = getCharacter()
	if not rootPart or not humanoid or not character then
		print("[Grapple] Missing character components")
		return false
	end

	-- Can't grapple if dead
	if humanoid.Health <= 0 then
		print("[Grapple] Player is dead")
		return false
	end

	-- Find where to grapple
	local target = findGrapplePoint()
	if not target then
		print("[Grapple] No valid target found")
		return false
	end

	-- All checks passed - begin grappling!
	targetPoint = target
	isGrappling = true
	currentSpeed = Config.MinReelSpeed

	-- Create the visual rope
	createRopeVisual(target)

	-- Create physics constraints
	if not createMovementConstraints() then
		-- Failed to create constraints, abort
		isGrappling = false
		destroyRopeVisual()
		print("[Grapple] Failed to create movement constraints")
		return false
	end

	-- Lock humanoid states to prevent ragdolling
	lockHumanoidStates(humanoid)
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	-- Start animations and visual effects
	stopFreefallCheck()  -- Stop freefall anim if playing
	playGrappleStart()
	startLimbTrails(character)

	-- Begin FOV transition for speed feeling
	tweenFOV(Config.GrappleFOV, Config.FOVTweenTime)

	return true
end

--[[
	Updates the grapple each frame while active.
	Called every RenderStepped (tied to framerate).
	
	This is the core grapple loop that:
	1. Checks if we've arrived at the target
	2. Accelerates the reel speed over time
	3. Calculates movement direction + strafe input
	4. Applies the final velocity to the LinearVelocity constraint
	5. Updates body lean based on strafe direction
	
	@param dt: Delta time since last frame
]]
local function updateGrapple(dt: number)
	-- Nothing to update if not grappling
	if not isGrappling then return end

	local rootPart = getRootPart()
	if not rootPart then
		stopGrapple(false)
		return
	end

	-- Check if we've arrived
	local distance = getDistanceToTarget()
	if distance <= Config.ArrivalDistance then
		stopGrapple(true)
		return
	end

	-- Accelerate speed over time (multiply by dt * 60 for framerate independence)
	-- At 60 FPS, this adds exactly Config.Acceleration per frame
	-- At 30 FPS, it adds 2 * Config.Acceleration per frame, etc.
	currentSpeed = math.min(currentSpeed + Config.Acceleration * dt * 60, Config.MaxReelSpeed)

	-- Calculate final velocity: toward target + strafe input
	local direction = getDirectionToTarget()
	local strafeVelocity = getMoveDirection() * Config.StrafeSpeed
	local finalVelocity = (direction * currentSpeed) + strafeVelocity

	-- Apply to the LinearVelocity constraint
	if linearVelocity then
		linearVelocity.VectorVelocity = finalVelocity
	end

	-- Update visual body lean
	updateBodyOrientation(dt, getStrafeDirection())
end


--[[
	Called when the player's character spawns.
	Sets up everything needed for grappling on this character.
	
	@param character: The newly spawned character
]]
local function onCharacterAdded(character: Model)
	-- Load animations for this character
	loadAnimations(character)

	-- Set up body lean system
	setupBodyOrientation(character)

	-- Update raycast filter with this character
	updateRaycastFilter()

	-- Set camera to follow the head (feels better for grappling)
	local head = character:WaitForChild("Head", 5)
	if head and head:IsA("BasePart") then
		Camera.CameraSubject = head
	end

	-- Set up death handling
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local diedConn = humanoid.Died:Connect(function()
		if isGrappling then
			stopGrapple(false)
		end
		stopFreefallCheck()
	end)
	table.insert(connections, diedConn)

	-- Start monitoring for freefall
	startFreefallCheck(humanoid)
end

--[[
	Called when the player's character is being removed (death/respawn).
	Cleans up all grapple-related objects and state.
]]
local function onCharacterRemoving()
	-- Stop freefall monitoring
	stopFreefallCheck()

	-- Reset body lean
	resetBodyOrientation()
	rootJoint = nil
	originalC0 = nil

	-- Clean up if currently grappling
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

	-- Stop all animations immediately (no fade since character is being removed)
	for _, track in animTracks do
		track:Stop(0)
	end
	table.clear(animTracks)
	animator = nil
	currentAnimState = "None"
end


--[[
	Initializes the grappling hook system.
	
	Sets up:
	1. Input listeners for grapple key
	2. RenderStepped connection for update loop
	3. Player added/removed listeners for raycast filter
	4. Character added/removing listeners for this player
]]
local function initialize()
	-- Listen for grapple key press
	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		-- Ignore if typing in chat or other UI elements
		if gameProcessed then return end
		if input.KeyCode == Config.GrappleKey then
			startGrapple()
		end
	end))

	-- Listen for grapple key release
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Config.GrappleKey and isGrappling then
			stopGrapple(false)  -- Early release, didn't arrive
		end
	end))

	-- Update grapple every frame
	table.insert(connections, RunService.RenderStepped:Connect(updateGrapple))

	-- Keep raycast filter updated as players join
	table.insert(connections, Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(char)
			table.insert(filterList, char)
			raycastParams.FilterDescendantsInstances = filterList
		end)
	end))

	-- Also update filter for existing players (in case script loads late)
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
