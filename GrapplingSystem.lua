--!strict
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
	
	Lowkey speed ran this cuz i am sleep deprived and i got other commissions kekw
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer :: Player
local Camera = workspace.CurrentCamera

type ConfigT = {
	MaxDistance: number,
	MinReelSpeed: number,
	MaxReelSpeed: number,
	Acceleration: number,
	ArrivalDistance: number,
	LaunchUpwardForce: number,
	LaunchForwardMultiplier: number,
	Cooldown: number,
	RopeColor: Color3,
	RopeWidth: number,
	GrappleKey: Enum.KeyCode,
	RaycastParams: RaycastParams?,
	DefaultFOV: number,
	GrappleFOV: number,
	FOVTweenTime: number,
	StrafeSpeed: number,
	CrossfadeTime: number,
	FreefallVelocityThreshold: number,
	MaxLeanAngle: number,
	LeanSmoothing: number,
	OrientationSmoothing: number,
}

local Config: ConfigT = {
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
	RaycastParams = nil,
	DefaultFOV = 70,
	GrappleFOV = 100,
	FOVTweenTime = 0.6,
	StrafeSpeed = 25,
	CrossfadeTime = 0.15,
	FreefallVelocityThreshold = -20,
	MaxLeanAngle = math.rad(45),
	LeanSmoothing = 8,
	OrientationSmoothing = 10,
}

local TrailConfig = {
	Lifetime = 0.25,
	ArmWidth = NumberSequence.new({
		NumberSequenceKeypoint.new(0.00, 0.08),
		NumberSequenceKeypoint.new(0.25, 0.05),
		NumberSequenceKeypoint.new(0.60, 0.03),
		NumberSequenceKeypoint.new(1.00, 0.00),
	}),
	LegWidth = NumberSequence.new({
		NumberSequenceKeypoint.new(0.00, 0.10),
		NumberSequenceKeypoint.new(0.25, 0.07),
		NumberSequenceKeypoint.new(0.60, 0.04),
		NumberSequenceKeypoint.new(1.00, 0.00),
	}),
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0.00, 0.75),
		NumberSequenceKeypoint.new(0.30, 0.88),
		NumberSequenceKeypoint.new(0.70, 0.96),
		NumberSequenceKeypoint.new(1.00, 1.00),
	}),
	Color = ColorSequence.new(Color3.fromRGB(220, 220, 220), Color3.fromRGB(255, 255, 255)),
	LightEmission = 1,
	LightInfluence = 1,
}

local R6Limbs = {
	Arms = { "Right Arm", "Left Arm" },
	Legs = { "Right Leg", "Left Leg" },
}

type PrevStates = {
	FallingDown: boolean?,
	Ragdoll: boolean?,
	GettingUp: boolean?,
}

type LockRecord = {
	count: number,
	prev: PrevStates,
}

type LockGuard = {
	release: () -> (),
}

local _locks: { [Humanoid]: LockRecord } = setmetatable({}, { __mode = "k" }) :: any

--[=[
	Ensures a lock record exists for a humanoid and returns it.

	@param hum Humanoid
	@return LockRecord
]=]
local function _ensureRec(hum: Humanoid): LockRecord
	local rec = _locks[hum]
	if not rec then
		local newRec: LockRecord = {
			count = 0,
			prev = {
				FallingDown = nil,
				Ragdoll = nil,
				GettingUp = nil,
			},
		}
		_locks[hum] = newRec
		return newRec
	end
	return rec
end

--[=[
	Acquires a reference-counted humanoid state lock and returns a guard that can release it.

	@param hum Humanoid?
	@return LockGuard
]=]
local function acquireHumanoidLock(hum: Humanoid?): LockGuard
	if not hum then
		return { release = function() end }
	end

	local rec = _ensureRec(hum)
	rec.count += 1

	if rec.count == 1 then
		local function getState(st: Enum.HumanoidStateType): boolean
			local ok, val = pcall(function()
				return hum:GetStateEnabled(st)
			end)
			return if ok then val else true
		end

		rec.prev.FallingDown = getState(Enum.HumanoidStateType.FallingDown)
		rec.prev.Ragdoll = getState(Enum.HumanoidStateType.Ragdoll)
		rec.prev.GettingUp = getState(Enum.HumanoidStateType.GettingUp)

		pcall(function()
			hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		end)
	end

	local released = false
	return {
		release = function()
			if released then return end
			released = true

			local r = _locks[hum]
			if not r then return end

			if r.count > 0 then
				r.count -= 1
			end

			if r.count == 0 then
				local fd = if r.prev.FallingDown == nil then true else r.prev.FallingDown
				local rd = if r.prev.Ragdoll == nil then true else r.prev.Ragdoll
				local gu = if r.prev.GettingUp == nil then true else r.prev.GettingUp

				pcall(function()
					hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, fd)
					hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, rd)
					hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, gu)
				end)

				r.prev = {
					FallingDown = nil,
					Ragdoll = nil,
					GettingUp = nil,
				}
			end
		end,
	}
end

--[=[
	Force releases any lock record for the humanoid and restores previous states.

	@param hum Humanoid?
	@return boolean
]=]
local function forceReleaseHumanoidLock(hum: Humanoid?): boolean
	if not hum then return false end

	local rec = _locks[hum]
	if not rec then return false end

	local had = rec.count > 0 or (rec.prev.FallingDown ~= nil or rec.prev.Ragdoll ~= nil or rec.prev.GettingUp ~= nil)

	local fd = if rec.prev.FallingDown == nil then true else rec.prev.FallingDown
	local rd = if rec.prev.Ragdoll == nil then true else rec.prev.Ragdoll
	local gu = if rec.prev.GettingUp == nil then true else rec.prev.GettingUp

	rec.count = 0
	rec.prev = {
		FallingDown = nil,
		Ragdoll = nil,
		GettingUp = nil,
	}
	_locks[hum] = nil

	pcall(function()
		hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, fd)
		hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, rd)
		hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, gu)
	end)

	return had
end

local activeFOVTween: Tween? = nil

--[=[
	Tweens the current camera FOV to a target value.

	@param targetFOV number
	@param duration number
	@return nil
]=]
local function tweenFOV(targetFOV: number, duration: number): ()
	local cam = Camera
	if not cam then return end

	if activeFOVTween then
		activeFOVTween:Cancel()
	end

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(cam, tweenInfo, { FieldOfView = targetFOV })
	activeFOVTween = tween
	tween:Play()
end

--[=[
	Returns a planar move direction vector based on WASD relative to the camera.

	@return Vector3
]=]
local function getMoveDirection(): Vector3
	local cam = Camera
	if not cam then return Vector3.zero end

	local moveDir = Vector3.zero

	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		moveDir += cam.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		moveDir -= cam.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		moveDir -= cam.CFrame.RightVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		moveDir += cam.CFrame.RightVector
	end

	moveDir = Vector3.new(moveDir.X, 0, moveDir.Z)
	if moveDir.Magnitude > 0.1 then
		return moveDir.Unit
	end

	return Vector3.zero
end

--[=[
	Returns the strafe direction from A/D input.

	@return number
]=]
local function getStrafeDirection(): number
	local left = UserInputService:IsKeyDown(Enum.KeyCode.A)
	local right = UserInputService:IsKeyDown(Enum.KeyCode.D)

	if left and not right then
		return -1
	elseif right and not left then
		return 1
	end
	return 0
end

--[=[
	Sets the camera subject to the character's head if available.

	@param character Model
	@return nil
]=]
local function setCameraSubjectToHead(character: Model): ()
	local cam = workspace.CurrentCamera
	if not cam then return end

	local head = character:WaitForChild("Head", 5)
	if head and head:IsA("BasePart") then
		cam.CameraSubject = head
		print("[Camera] Subject set to Head")
	end
end

type BodyOrientationManager = {
	character: Model?,
	rootJoint: Motor6D?,
	originalC0: CFrame?,
	currentLean: number,
	currentPitch: number,
	currentYaw: number,
	active: boolean,

	Setup: (self: BodyOrientationManager, character: Model) -> (),
	Update: (self: BodyOrientationManager, dt: number, strafeDir: number, targetPoint: Vector3?) -> (),
	Reset: (self: BodyOrientationManager) -> (),
	Cleanup: (self: BodyOrientationManager) -> (),
}

--[=[
	Creates a body orientation manager that applies lean/pitch via an R6 root Motor6D.

	@return BodyOrientationManager
]=]
local function createBodyOrientationManager(): BodyOrientationManager
	local manager: BodyOrientationManager = {
		character = nil,
		rootJoint = nil,
		originalC0 = nil,
		currentLean = 0,
		currentPitch = 0,
		currentYaw = 0,
		active = false,
	} :: BodyOrientationManager

	--[=[
		Initializes the manager for a character by finding the torso root Motor6D and caching its C0.

		@param character Model
		@return nil
	]=]
	function manager:Setup(character: Model): ()
		self.character = character

		local torso = character:FindFirstChild("Torso")
		if not torso then return end

		local rootJoint = torso:FindFirstChild("Root Hip") :: Motor6D?
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

		if rootJoint then
			self.rootJoint = rootJoint
			self.originalC0 = rootJoint.C0
			self.active = true
			print("[BodyOrientation] Setup complete")
		else
			warn("[BodyOrientation] Root joint not found")
		end
	end

	--[=[
		Updates lean and pitch based on input and target point, applying it to the Motor6D.

		@param dt number
		@param strafeDir number
		@param targetPoint Vector3?
		@return nil
	]=]
	function manager:Update(dt: number, strafeDir: number, targetPoint: Vector3?): ()
		if not self.active or not self.rootJoint or not self.originalC0 then return end

		local character = self.character
		if not character then return end

		local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not rootPart then return end

		local targetLean = -strafeDir * Config.MaxLeanAngle
		self.currentLean += (targetLean - self.currentLean) * math.min(1, dt * Config.LeanSmoothing)

		local targetPitch = 0
		if targetPoint then
			local toTarget = targetPoint - rootPart.Position
			if toTarget.Magnitude > 0.1 then
				local dir = toTarget.Unit
				targetPitch = math.asin(math.clamp(dir.Y, -1, 1))
			end
		end
		self.currentPitch += (targetPitch - self.currentPitch) * math.min(1, dt * Config.OrientationSmoothing)

		self.currentYaw = 0

		local rot = CFrame.Angles(self.currentPitch, 0, self.currentLean)
		self.rootJoint.C0 = rot * self.originalC0
	end

	--[=[
		Resets the Motor6D back to its cached original C0 and clears internal state.

		@return nil
	]=]
	function manager:Reset(): ()
		if not self.active then return end

		self.currentLean = 0
		self.currentPitch = 0
		self.currentYaw = 0

		if self.rootJoint and self.originalC0 then
			self.rootJoint.C0 = self.originalC0
		end
	end

	--[=[
		Cleans up references and returns the joint to its original orientation.

		@return nil
	]=]
	function manager:Cleanup(): ()
		self:Reset()
		self.character = nil
		self.rootJoint = nil
		self.originalC0 = nil
		self.active = false
	end

	return manager
end

type AnimationTracks = {
	GrappleStart: AnimationTrack?,
	GrappleLoop: AnimationTrack?,
	GrappleArrive: AnimationTrack?,
	Freefall: AnimationTrack?,
}

type AnimationManager = {
	tracks: AnimationTracks,
	animator: Animator?,
	currentState: string,
	isFreefalling: boolean,
	freefallConnection: RBXScriptConnection?,

	Load: (self: AnimationManager, character: Model) -> (),
	PlayGrappleStart: (self: AnimationManager) -> (),
	PlayGrappleLoop: (self: AnimationManager) -> (),
	PlayGrappleArrive: (self: AnimationManager) -> (),
	StopGrappleAnims: (self: AnimationManager) -> (),
	StartFreefallCheck: (self: AnimationManager, rootPart: BasePart) -> (),
	StopFreefallCheck: (self: AnimationManager) -> (),
	Cleanup: (self: AnimationManager) -> (),
}

--[=[
	Creates an animation manager that loads and plays grapple/freefall tracks.

	@return AnimationManager
]=]
local function createAnimationManager(): AnimationManager
	local manager: AnimationManager = {
		tracks = {
			GrappleStart = nil,
			GrappleLoop = nil,
			GrappleArrive = nil,
			Freefall = nil,
		},
		animator = nil,
		currentState = "None",
		isFreefalling = false,
		freefallConnection = nil,
	} :: AnimationManager

	--[=[
		Loads animations from the "Anims" folder under this script into the character's Animator.

		@param character Model
		@return nil
	]=]
	function manager:Load(character: Model): ()
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then return end

		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
		self.animator = animator

		local animsFolder = script:FindFirstChild("Anims")
		if not animsFolder then
			warn("[Anim] Anims folder not found")
			return
		end

		local function loadAnim(name: string): AnimationTrack?
			local animInstance = animsFolder:FindFirstChild(name)
			if animInstance and animInstance:IsA("Animation") and animator then
				local track = animator:LoadAnimation(animInstance)
				track.Priority = Enum.AnimationPriority.Action
				return track
			end
			warn("[Anim] Animation not found:", name)
			return nil
		end

		self.tracks.GrappleStart = loadAnim("GrappleStart")
		self.tracks.GrappleLoop = loadAnim("GrappleLoop")
		self.tracks.GrappleArrive = loadAnim("GrappleArrive")
		self.tracks.Freefall = loadAnim("Freefall")

		if self.tracks.GrappleLoop then
			self.tracks.GrappleLoop.Looped = true
		end
		if self.tracks.Freefall then
			self.tracks.Freefall.Looped = true
		end

		print("[Anim] Animations loaded")
	end

	--[=[
		Plays the grapple start animation and transitions into the loop if available.

		@return nil
	]=]
	function manager:PlayGrappleStart(): ()
		self:StopFreefallCheck()

		if self.tracks.Freefall and self.tracks.Freefall.IsPlaying then
			self.tracks.Freefall:Stop(Config.CrossfadeTime)
		end

		local startTrack = self.tracks.GrappleStart
		local loopTrack = self.tracks.GrappleLoop

		if startTrack then
			startTrack:Play(Config.CrossfadeTime)
			self.currentState = "GrappleStart"

			if loopTrack then
				local conn: RBXScriptConnection
				conn = startTrack.Stopped:Connect(function()
					conn:Disconnect()
					if self.currentState == "GrappleStart" then
						self:PlayGrappleLoop()
					end
				end)
			end
		elseif loopTrack then
			self:PlayGrappleLoop()
		end
	end

	--[=[
		Plays the grapple loop animation.

		@return nil
	]=]
	function manager:PlayGrappleLoop(): ()
		local loopTrack = self.tracks.GrappleLoop
		if not loopTrack then return end

		if self.tracks.GrappleStart and self.tracks.GrappleStart.IsPlaying then
			self.tracks.GrappleStart:Stop(Config.CrossfadeTime)
		end

		if not loopTrack.IsPlaying then
			loopTrack:Play(Config.CrossfadeTime)
		end
		self.currentState = "GrappleLoop"
	end

	--[=[
		Plays the grapple arrive animation.

		@return nil
	]=]
	function manager:PlayGrappleArrive(): ()
		local arriveTrack = self.tracks.GrappleArrive
		if not arriveTrack then return end

		if self.tracks.GrappleStart and self.tracks.GrappleStart.IsPlaying then
			self.tracks.GrappleStart:Stop(Config.CrossfadeTime)
		end
		if self.tracks.GrappleLoop and self.tracks.GrappleLoop.IsPlaying then
			self.tracks.GrappleLoop:Stop(Config.CrossfadeTime)
		end

		arriveTrack:Play(Config.CrossfadeTime)
		self.currentState = "GrappleArrive"
	end

	--[=[
		Stops all grapple-related animations.

		@return nil
	]=]
	function manager:StopGrappleAnims(): ()
		local fadeTime = Config.CrossfadeTime

		if self.tracks.GrappleStart and self.tracks.GrappleStart.IsPlaying then
			self.tracks.GrappleStart:Stop(fadeTime)
		end
		if self.tracks.GrappleLoop and self.tracks.GrappleLoop.IsPlaying then
			self.tracks.GrappleLoop:Stop(fadeTime)
		end
		if self.tracks.GrappleArrive and self.tracks.GrappleArrive.IsPlaying then
			self.tracks.GrappleArrive:Stop(fadeTime)
		end

		self.currentState = "None"
	end

	--[=[
		Starts monitoring vertical velocity to play/stop freefall animation.

		@param rootPart BasePart
		@return nil
	]=]
	function manager:StartFreefallCheck(rootPart: BasePart): ()
		self:StopFreefallCheck()

		self.freefallConnection = RunService.Heartbeat:Connect(function()
			local vel = rootPart.AssemblyLinearVelocity
			local isFalling = vel.Y < Config.FreefallVelocityThreshold

			if isFalling and not self.isFreefalling then
				self.isFreefalling = true
				if self.tracks.Freefall and not self.tracks.Freefall.IsPlaying then
					self.tracks.Freefall:Play(Config.CrossfadeTime)
				end
			elseif not isFalling and self.isFreefalling then
				self.isFreefalling = false
				if self.tracks.Freefall and self.tracks.Freefall.IsPlaying then
					self.tracks.Freefall:Stop(Config.CrossfadeTime)
				end
			end
		end)
	end

	--[=[
		Stops the freefall monitor and stops the freefall animation.

		@return nil
	]=]
	function manager:StopFreefallCheck(): ()
		if self.freefallConnection then
			self.freefallConnection:Disconnect()
			self.freefallConnection = nil
		end

		self.isFreefalling = false
		if self.tracks.Freefall and self.tracks.Freefall.IsPlaying then
			self.tracks.Freefall:Stop(Config.CrossfadeTime)
		end
	end

	--[=[
		Cleans up all loaded tracks and connections.

		@return nil
	]=]
	function manager:Cleanup(): ()
		self:StopFreefallCheck()
		self:StopGrappleAnims()

		for _, track in self.tracks :: any do
			if track then
				track:Stop(0)
				track:Destroy()
			end
		end

		self.tracks = {
			GrappleStart = nil,
			GrappleLoop = nil,
			GrappleArrive = nil,
			Freefall = nil,
		}
		self.animator = nil
		self.currentState = "None"
	end

	return manager
end

type TrailHandle = {
	trails: { Trail },
	attachments: { Attachment },
}

--[=[
	Creates a Trail with two Attachments on a limb part.

	@param part BasePart
	@param widthSequence NumberSequence
	@return Trail
	@return Attachment
	@return Attachment
]=]
local function createLimbTrail(part: BasePart, widthSequence: NumberSequence): (Trail, Attachment, Attachment)
	local halfHeight = part.Size.Y * 0.4

	local a0 = Instance.new("Attachment")
	a0.Name = "GrappleTrailA0"
	a0.Position = Vector3.new(0, halfHeight, 0)
	a0.Parent = part

	local a1 = Instance.new("Attachment")
	a1.Name = "GrappleTrailA1"
	a1.Position = Vector3.new(0, -halfHeight, 0)
	a1.Parent = part

	local trail = Instance.new("Trail")
	trail.Name = "GrappleLimbTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = TrailConfig.Lifetime
	trail.MinLength = 0.02
	trail.WidthScale = widthSequence
	trail.Transparency = TrailConfig.Transparency
	trail.Color = TrailConfig.Color
	trail.LightEmission = TrailConfig.LightEmission
	trail.LightInfluence = TrailConfig.LightInfluence
	trail.FaceCamera = true
	trail.Enabled = true
	trail.Parent = part

	return trail, a0, a1
end

--[=[
	Starts limb trails on R6 limbs and returns a handle for cleanup.

	@param character Model
	@return TrailHandle?
]=]
local function startLimbTrails(character: Model): TrailHandle?
	local handle: TrailHandle = {
		trails = {},
		attachments = {},
	}

	for _, limbName in R6Limbs.Arms do
		local part = character:FindFirstChild(limbName)
		if part and part:IsA("BasePart") then
			local trail, a0, a1 = createLimbTrail(part, TrailConfig.ArmWidth)
			table.insert(handle.trails, trail)
			table.insert(handle.attachments, a0)
			table.insert(handle.attachments, a1)
		end
	end

	for _, limbName in R6Limbs.Legs do
		local part = character:FindFirstChild(limbName)
		if part and part:IsA("BasePart") then
			local trail, a0, a1 = createLimbTrail(part, TrailConfig.LegWidth)
			table.insert(handle.trails, trail)
			table.insert(handle.attachments, a0)
			table.insert(handle.attachments, a1)
		end
	end

	if #handle.trails == 0 then
		return nil
	end

	return handle
end

--[=[
	Stops and schedules cleanup for all trails and attachments in the handle.

	@param handle TrailHandle?
	@return nil
]=]
local function stopLimbTrails(handle: TrailHandle?): ()
	if not handle then return end

	for _, trail in handle.trails do
		trail.Enabled = false
	end

	local cleanupDelay = TrailConfig.Lifetime + 0.1

	for _, trail in handle.trails do
		Debris:AddItem(trail, cleanupDelay)
	end

	for _, attachment in handle.attachments do
		Debris:AddItem(attachment, cleanupDelay)
	end

	handle.trails = {}
	handle.attachments = {}
end

type GrappleSystemImpl = {
	__index: GrappleSystemImpl,
	new: () -> GrappleSystem,
	SetupRaycastParams: (self: GrappleSystem) -> (),
	GetRootPart: (self: GrappleSystem) -> BasePart?,
	GetHumanoid: (self: GrappleSystem) -> Humanoid?,
	FindGrapplePoint: (self: GrappleSystem) -> Vector3?,
	CreateRopeVisual: (self: GrappleSystem, targetPos: Vector3) -> (),
	DestroyRopeVisual: (self: GrappleSystem) -> (),
	CreateBodyVelocity: (self: GrappleSystem) -> BodyVelocity?,
	DestroyBodyVelocity: (self: GrappleSystem) -> (),
	GetDirectionToTarget: (self: GrappleSystem) -> Vector3,
	GetDistanceToTarget: (self: GrappleSystem) -> number,
	ApplyMomentum: (self: GrappleSystem, arrivedAtTarget: boolean) -> (),
	UpdateGrapple: (self: GrappleSystem, deltaTime: number) -> (),
	StartGrapple: (self: GrappleSystem) -> boolean,
	StopGrapple: (self: GrappleSystem, arrivedAtTarget: boolean) -> (),
	OnInputBegan: (self: GrappleSystem, input: InputObject, gameProcessed: boolean) -> (),
	OnInputEnded: (self: GrappleSystem, input: InputObject, gameProcessed: boolean) -> (),
	OnCharacterAdded: (self: GrappleSystem, character: Model) -> (),
	OnCharacterRemoving: (self: GrappleSystem) -> (),
	Initialize: (self: GrappleSystem) -> (),
	Destroy: (self: GrappleSystem) -> (),
}

type GrappleSystemFields = {
	isGrappling: boolean,
	targetPoint: Vector3?,
	currentSpeed: number,
	lastGrappleTime: number,
	ropeBeam: Beam?,
	startAttachment: Attachment?,
	endAttachment: Attachment?,
	endPart: Part?,
	bodyVelocity: BodyVelocity?,
	connections: { RBXScriptConnection },
	filterList: { Instance },
	humanoidLockGuard: LockGuard?,
	animManager: AnimationManager,
	bodyOrientManager: BodyOrientationManager,
	trailHandle: TrailHandle?,
}

type GrappleSystem = typeof(setmetatable({} :: GrappleSystemFields, {} :: GrappleSystemImpl))

local GrappleSystem = {} :: GrappleSystemImpl
GrappleSystem.__index = GrappleSystem

--[=[
	Constructs a new GrappleSystem instance.

	@return GrappleSystem
]=]
function GrappleSystem.new(): GrappleSystem
	local self = setmetatable({} :: GrappleSystemFields, GrappleSystem)

	self.isGrappling = false
	self.targetPoint = nil
	self.currentSpeed = Config.MinReelSpeed
	self.lastGrappleTime = 0

	self.ropeBeam = nil
	self.startAttachment = nil
	self.endAttachment = nil
	self.endPart = nil

	self.bodyVelocity = nil
	self.humanoidLockGuard = nil

	self.connections = {}
	self.filterList = {}

	self.animManager = createAnimationManager()
	self.bodyOrientManager = createBodyOrientationManager()
	self.trailHandle = nil

	self:SetupRaycastParams()

	return self
end

--[=[
	Builds and maintains RaycastParams to exclude player characters from raycasts.

	@return nil
]=]
function GrappleSystem:SetupRaycastParams(): ()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	table.clear(self.filterList)

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(self.filterList, player.Character)
		end
	end

	params.FilterDescendantsInstances = self.filterList
	Config.RaycastParams = params

	local connection = Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			table.insert(self.filterList, character)
			params.FilterDescendantsInstances = self.filterList
		end)
	end)
	table.insert(self.connections, connection)

	for _, player in Players:GetPlayers() do
		local conn = player.CharacterAdded:Connect(function(character: Model)
			table.insert(self.filterList, character)
			params.FilterDescendantsInstances = self.filterList
		end)
		table.insert(self.connections, conn)
	end
end

--[=[
	Returns the local player's HumanoidRootPart.

	@return BasePart?
]=]
function GrappleSystem:GetRootPart(): BasePart?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[=[
	Returns the local player's Humanoid.

	@return Humanoid?
]=]
function GrappleSystem:GetHumanoid(): Humanoid?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

--[=[
	Finds a valid grapple point by raycasting from the camera.

	@return Vector3?
]=]
function GrappleSystem:FindGrapplePoint(): Vector3?
	local rootPart = self:GetRootPart()
	if not rootPart then
		return nil
	end

	local character = LocalPlayer.Character
	if character then
		local params = Config.RaycastParams
		if not params then
			return nil
		end

		if not table.find(self.filterList, character) then
			table.insert(self.filterList, character)
			params.FilterDescendantsInstances = self.filterList
		end
	end

	local currentCamera = Camera
	if not currentCamera then
		return nil
	end

	local origin = currentCamera.CFrame.Position
	local direction = currentCamera.CFrame.LookVector * Config.MaxDistance

	local result = workspace:Raycast(origin, direction, Config.RaycastParams)

	if result then
		local hitPart = result.Instance
		local ancestorModel = hitPart:FindFirstAncestorOfClass("Model")

		if ancestorModel then
			local hitPlayer = Players:GetPlayerFromCharacter(ancestorModel)
			if hitPlayer then
				print("[Grapple] Target is a player, ignoring")
				return nil
			end
		end

		print("[Grapple] Valid target found at distance:", (result.Position - rootPart.Position).Magnitude)
		return result.Position
	end

	print("[Grapple] No target in range")
	return nil
end

--[=[
	Creates the rope beam visual from the right arm to the target position.

	@param targetPos Vector3
	@return nil
]=]
function GrappleSystem:CreateRopeVisual(targetPos: Vector3): ()
	local character = LocalPlayer.Character
	if not character then return end

	local rightArm = character:FindFirstChild("Right Arm") :: BasePart?
	if not rightArm then
		rightArm = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	if not rightArm then return end

	local startAtt = Instance.new("Attachment")
	startAtt.Name = "GrappleStart"
	startAtt.Position = Vector3.new(0, -rightArm.Size.Y / 2, 0)
	startAtt.Parent = rightArm
	self.startAttachment = startAtt

	local endP = Instance.new("Part")
	endP.Name = "GrappleEndPoint"
	endP.Size = Vector3.new(0.5, 0.5, 0.5)
	endP.Position = targetPos
	endP.Anchored = true
	endP.CanCollide = false
	endP.Transparency = 1
	endP.Parent = workspace
	self.endPart = endP

	local endAtt = Instance.new("Attachment")
	endAtt.Name = "GrappleEnd"
	endAtt.Parent = endP
	self.endAttachment = endAtt

	local beam = Instance.new("Beam")
	beam.Name = "GrappleRope"
	beam.Attachment0 = startAtt
	beam.Attachment1 = endAtt
	beam.Color = ColorSequence.new(Config.RopeColor, Config.RopeColor)
	beam.Width0 = Config.RopeWidth
	beam.Width1 = Config.RopeWidth
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Parent = rightArm
	self.ropeBeam = beam
end

--[=[
	Destroys the rope beam visual and its attachments/endpoint.

	@return nil
]=]
function GrappleSystem:DestroyRopeVisual(): ()
	if self.ropeBeam then
		self.ropeBeam:Destroy()
		self.ropeBeam = nil
	end

	if self.startAttachment then
		self.startAttachment:Destroy()
		self.startAttachment = nil
	end

	if self.endAttachment then
		self.endAttachment:Destroy()
		self.endAttachment = nil
	end

	if self.endPart then
		self.endPart:Destroy()
		self.endPart = nil
	end
end

--[=[
	Creates a BodyVelocity on the HumanoidRootPart for grappling motion.

	@return BodyVelocity?
]=]
function GrappleSystem:CreateBodyVelocity(): BodyVelocity?
	local rootPart = self:GetRootPart()
	if not rootPart then
		return nil
	end

	local existing = rootPart:FindFirstChild("GrappleVelocity")
	if existing then
		existing:Destroy()
	end

	local bv = Instance.new("BodyVelocity")
	bv.Name = "GrappleVelocity"
	bv.MaxForce = Vector3.new(50000, 50000, 50000)
	bv.Velocity = Vector3.zero
	bv.Parent = rootPart

	return bv
end

--[=[
	Destroys the BodyVelocity and clamps extreme velocities to reduce fling.

	@return nil
]=]
function GrappleSystem:DestroyBodyVelocity(): ()
	local rootPart = self:GetRootPart()

	if self.bodyVelocity then
		self.bodyVelocity.Velocity = Vector3.zero
		self.bodyVelocity.MaxForce = Vector3.zero
		task.defer(function()
			if self.bodyVelocity then
				self.bodyVelocity:Destroy()
				self.bodyVelocity = nil
			end
		end)
	end

	if rootPart then
		local currentVel = rootPart.AssemblyLinearVelocity
		if currentVel.Magnitude > 200 then
			rootPart.AssemblyLinearVelocity = currentVel.Unit * 200
		end
	end
end

--[=[
	Returns a unit vector direction from the player to the grapple target.

	@return Vector3
]=]
function GrappleSystem:GetDirectionToTarget(): Vector3
	local rootPart = self:GetRootPart()
	if not rootPart or not self.targetPoint then
		return Vector3.zero
	end

	local direction = self.targetPoint - rootPart.Position
	local magnitude = direction.Magnitude

	if magnitude < 0.1 then
		return Vector3.zero
	end

	return direction.Unit
end

--[=[
	Returns the distance from the player to the grapple target.

	@return number
]=]
function GrappleSystem:GetDistanceToTarget(): number
	local rootPart = self:GetRootPart()
	if not rootPart or not self.targetPoint then
		return 0
	end

	return (self.targetPoint - rootPart.Position).Magnitude
end

--[=[
	Applies momentum to the player on detach/arrival.

	@param arrivedAtTarget boolean
	@return nil
]=]
function GrappleSystem:ApplyMomentum(arrivedAtTarget: boolean): ()
	local rootPart = self:GetRootPart()
	if not rootPart then
		return
	end

	local direction = self:GetDirectionToTarget()
	if direction.Magnitude < 0.1 then
		direction = rootPart.CFrame.LookVector
	end

	local horizontalDir = Vector3.new(direction.X, 0, direction.Z)
	if horizontalDir.Magnitude > 0.1 then
		horizontalDir = horizontalDir.Unit
	else
		horizontalDir = rootPart.CFrame.LookVector
	end

	local momentum: Vector3

	if arrivedAtTarget then
		local upwardForce = Vector3.new(0, Config.LaunchUpwardForce, 0)
		local forwardForce = horizontalDir * (self.currentSpeed * Config.LaunchForwardMultiplier)
		momentum = upwardForce + forwardForce
		print("[Grapple] Arrival launch applied - Speed:", self.currentSpeed)
	else
		momentum = direction * (self.currentSpeed * 0.8)
		print("[Grapple] Early release momentum preserved")
	end

	local maxMomentum = 150
	if momentum.Magnitude > maxMomentum then
		momentum = momentum.Unit * maxMomentum
	end

	rootPart.AssemblyLinearVelocity = momentum
end

--[=[
	Per-frame grapple update: reels in, applies strafe, and updates body orientation.

	@param deltaTime number
	@return nil
]=]
function GrappleSystem:UpdateGrapple(deltaTime: number): ()
	if not self.isGrappling then
		return
	end

	local rootPart = self:GetRootPart()
	if not rootPart then
		self:StopGrapple(false)
		return
	end

	local distance = self:GetDistanceToTarget()

	if distance <= Config.ArrivalDistance then
		print("[Grapple] Arrived at target")
		self:StopGrapple(true)
		return
	end

	self.currentSpeed = math.min(self.currentSpeed + (Config.Acceleration * deltaTime * 60), Config.MaxReelSpeed)

	local direction = self:GetDirectionToTarget()
	local strafeDir = getMoveDirection()
	local strafeVelocity = strafeDir * Config.StrafeSpeed
	local finalVelocity = (direction * self.currentSpeed) + strafeVelocity

	if self.bodyVelocity then
		self.bodyVelocity.Velocity = finalVelocity
	end

	local strafeLR = getStrafeDirection()
	self.bodyOrientManager:Update(deltaTime, strafeLR, self.targetPoint)
end

--[=[
	Starts grappling if off cooldown and a valid grapple point is found.

	@return boolean
]=]
function GrappleSystem:StartGrapple(): boolean
	local currentTime = tick()
	if currentTime - self.lastGrappleTime < Config.Cooldown then
		print("[Grapple] On cooldown:", Config.Cooldown - (currentTime - self.lastGrappleTime))
		return false
	end

	local rootPart = self:GetRootPart()
	local humanoid = self:GetHumanoid()
	local character = LocalPlayer.Character
	if not rootPart or not humanoid or not character then
		print("[Grapple] Character not ready")
		return false
	end

	if humanoid.Health <= 0 then
		print("[Grapple] Player is dead")
		return false
	end

	local targetPoint = self:FindGrapplePoint()
	if not targetPoint then
		return false
	end

	self.targetPoint = targetPoint
	self.isGrappling = true
	self.currentSpeed = Config.MinReelSpeed

	self:CreateRopeVisual(targetPoint)
	self.bodyVelocity = self:CreateBodyVelocity()

	self.humanoidLockGuard = acquireHumanoidLock(humanoid)
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	self.animManager:PlayGrappleStart()
	self.trailHandle = startLimbTrails(character)

	tweenFOV(Config.GrappleFOV, Config.FOVTweenTime)

	print("[Grapple] Started - Distance:", self:GetDistanceToTarget())
	return true
end

--[=[
	Stops grappling, cleans up visuals/physics, and applies momentum.

	@param arrivedAtTarget boolean
	@return nil
]=]
function GrappleSystem:StopGrapple(arrivedAtTarget: boolean): ()
	if not self.isGrappling then
		return
	end

	self.isGrappling = false

	self.bodyOrientManager:Reset()

	if arrivedAtTarget then
		self.animManager:PlayGrappleArrive()
		task.delay(0.5, function()
			self.animManager:StopGrappleAnims()
			local rootPart = self:GetRootPart()
			if rootPart then
				self.animManager:StartFreefallCheck(rootPart)
			end
		end)
	else
		self.animManager:StopGrappleAnims()
		local rootPart = self:GetRootPart()
		if rootPart then
			self.animManager:StartFreefallCheck(rootPart)
		end
	end

	stopLimbTrails(self.trailHandle)
	self.trailHandle = nil

	self:DestroyBodyVelocity()

	task.defer(function()
		self:ApplyMomentum(arrivedAtTarget)
	end)

	self:DestroyRopeVisual()

	local humanoid = self:GetHumanoid()
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end

	if self.humanoidLockGuard then
		self.humanoidLockGuard.release()
		self.humanoidLockGuard = nil
	end

	tweenFOV(Config.DefaultFOV, Config.FOVTweenTime)

	self.targetPoint = nil
	self.currentSpeed = Config.MinReelSpeed
	self.lastGrappleTime = tick()

	print("[Grapple] Stopped - Arrived:", arrivedAtTarget)
end

--[=[
	Handles input began and starts grappling on the configured key.

	@param input InputObject
	@param gameProcessed boolean
	@return nil
]=]
function GrappleSystem:OnInputBegan(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end

	if input.KeyCode == Config.GrappleKey then
		self:StartGrapple()
	end
end

--[=[
	Handles input ended and stops grappling when the configured key is released.

	@param input InputObject
	@param gameProcessed boolean
	@return nil
]=]
function GrappleSystem:OnInputEnded(input: InputObject, _gameProcessed: boolean): ()
	if input.KeyCode == Config.GrappleKey then
		if self.isGrappling then
			self:StopGrapple(false)
		end
	end
end

--[=[
	Initializes systems for a newly added character.

	@param character Model
	@return nil
]=]
function GrappleSystem:OnCharacterAdded(character: Model): ()
	self.animManager:Load(character)
	self.bodyOrientManager:Setup(character)

	setCameraSubjectToHead(character)

	self:SetupRaycastParams()

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local diedConn = humanoid.Died:Connect(function()
		self:OnCharacterRemoving()
	end)
	table.insert(self.connections, diedConn)

	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	self.animManager:StartFreefallCheck(rootPart)

	print("[Grapple] Character setup complete")
end

--[=[
	Cleans up systems when the character is being removed.

	@return nil
]=]
function GrappleSystem:OnCharacterRemoving(): ()
	self.animManager:StopFreefallCheck()
	self.bodyOrientManager:Cleanup()

	if self.isGrappling then
		self.isGrappling = false

		if self.bodyVelocity then
			self.bodyVelocity:Destroy()
			self.bodyVelocity = nil
		end

		self:DestroyRopeVisual()

		stopLimbTrails(self.trailHandle)
		self.trailHandle = nil

		local humanoid = self:GetHumanoid()
		if humanoid then
			forceReleaseHumanoidLock(humanoid)
		end
		self.humanoidLockGuard = nil

		tweenFOV(Config.DefaultFOV, Config.FOVTweenTime)

		self.targetPoint = nil
		self.currentSpeed = Config.MinReelSpeed
		print("[Grapple] Force stopped - Character removed")
	end

	self.animManager:Cleanup()
end

--[=[
	Binds input/update connections and sets up character listeners.

	@return nil
]=]
function GrappleSystem:Initialize(): ()
	local inputBeganConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		self:OnInputBegan(input, gameProcessed)
	end)
	table.insert(self.connections, inputBeganConn)

	local inputEndedConn = UserInputService.InputEnded:Connect(function(input: InputObject, gameProcessed: boolean)
		self:OnInputEnded(input, gameProcessed)
	end)
	table.insert(self.connections, inputEndedConn)

	local updateConn = RunService.RenderStepped:Connect(function(deltaTime: number)
		self:UpdateGrapple(deltaTime)
	end)
	table.insert(self.connections, updateConn)

	local character = LocalPlayer.Character
	if character then
		self:OnCharacterAdded(character)
	end

	local charAddedConn = LocalPlayer.CharacterAdded:Connect(function(char: Model)
		self:OnCharacterAdded(char)
	end)
	table.insert(self.connections, charAddedConn)

	local charRemovingConn = LocalPlayer.CharacterRemoving:Connect(function(_character: Model)
		self:OnCharacterRemoving()
	end)
	table.insert(self.connections, charRemovingConn)

	print("[Grapple] System initialized - Press", Config.GrappleKey.Name, "to grapple")
end

--[=[
	Destroys the grapple system instance, cleaning up connections and state.

	@return nil
]=]
function GrappleSystem:Destroy(): ()
	if self.isGrappling then
		self.isGrappling = false

		if self.bodyVelocity then
			self.bodyVelocity:Destroy()
			self.bodyVelocity = nil
		end

		self:DestroyRopeVisual()

		stopLimbTrails(self.trailHandle)
		self.trailHandle = nil

		if self.humanoidLockGuard then
			self.humanoidLockGuard.release()
			self.humanoidLockGuard = nil
		end

		tweenFOV(Config.DefaultFOV, 0.1)
	end

	self.animManager:Cleanup()
	self.bodyOrientManager:Cleanup()

	for _, connection in self.connections do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(self.connections)

	print("[Grapple] System destroyed")
end

local grappleSystem = GrappleSystem.new()
grappleSystem:Initialize()
