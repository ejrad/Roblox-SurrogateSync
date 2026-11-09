--!strict
--[[
	WorldScaler (ModuleScript, client-side)

	Relative / inverted world scaling: the local character stays at Scale 1.0 while a
	client-only clone of your world is scaled around a pivot by `worldScale`.
	Other players are shown as "visual surrogates" re-projected into your scaled world:

		P_mapped = pivot + (P_real - pivot) * (localWorldScale / remoteWorldScale)

	Features
	  - Hides the original static world on this client and replaces it with a scaled clone.
	  - Surrogate models for remote players (anchored, no physics fighting, appearance synced,
	    Motor6D animation mirrored every frame). Real remote characters are hidden locally.
	  - No game-specific logic: you decide what worldScale is and what remote players' scales are.

	Usage (LocalScript)
	  local WorldScaler = require(path.to.WorldScaler)

	  local scaler = WorldScaler.new({
	      pivot = workspace.Respawn.CFrame,
	      sources = { workspace.Obby, workspace.Respawn },
	      getRemoteWorldScale = function(plr) return plr:GetAttribute("WorldScale") or 1 end,
	  })

	  scaler:SetWorldScale(4)   -- world is now 4x bigger relative to you
	  scaler:Destroy()          -- clean up everything
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

-- ============================================================================
-- Types
-- ============================================================================

export type Config = {
	-- World point that scaling expands outward from (and surrogates are projected around).
	pivot: CFrame,

	-- Instances to hide and clone into the scaled world. If omitted, `isSource` is used
	-- to pick from Workspace's direct children.
	sources: { Instance }?,

	-- Used only when `sources` is nil. Return true for Workspace children that belong to the scalable world.
	isSource: ((Instance) -> boolean)?,

	-- Return the world scale a given remote player is currently experiencing. Default: 1.
	getRemoteWorldScale: ((Player) -> number)?,

	-- Initial world scale. Default: 1.
	initialWorldScale: number?,

	-- Enable surrogate models for other players. Default: true.
	syncRemotePlayers: boolean?,

	-- Called after a surrogate is (re)built. Add your own prompts, tags, effects here.
	onSurrogateCreated: ((player: Player, model: Model, root: BasePart) -> ())?,

	-- Called right before a surrogate is destroyed.
	onSurrogateRemoving: ((player: Player, model: Model) -> ())?,

	-- Called after the scaled world is rebuilt.
	onWorldRebuilt: ((world: Model, worldScale: number) -> ())?,
}

type SurrogateEntry = {
	remotePlayer: Player,
	realChar: Model,
	realRoot: BasePart,
	visualModel: Model,
	visualRoot: BasePart,
	realMotors: { [string]: Motor6D },
	visMotors: { [string]: Motor6D },
	lastAppliedScale: number,
	connections: { RBXScriptConnection },
}

export type WorldScaler = {
	SetWorldScale: (self: WorldScaler, worldScale: number) -> (),
	GetWorldScale: (self: WorldScaler) -> number,
	GetScaledWorld: (self: WorldScaler) -> Model?,
	GetPivot: (self: WorldScaler) -> CFrame,
	GetSurrogate: (self: WorldScaler, player: Player) -> Model?,
	GetRelativeScale: (self: WorldScaler, remoteWorldScale: number) -> number,
	MapPosition: (self: WorldScaler, realPosition: Vector3, remoteWorldScale: number) -> Vector3,
	TeleportToPivot: (self: WorldScaler, offset: Vector3?) -> (),
	RebuildSurrogate: (self: WorldScaler, player: Player) -> (),
	HideOriginals: (self: WorldScaler) -> (),
	Destroy: (self: WorldScaler) -> (),
	-- internals
	_config: Config,
	_pivot: CFrame,
	_worldScale: number,
	_originals: { Instance },
	_template: Model,
	_world: Model?,
	_surrogatesFolder: Folder,
	_surrogates: { [Player]: SurrogateEntry },
	_connections: { RBXScriptConnection },
	_destroyed: boolean,
}

-- ============================================================================
-- Helpers
-- ============================================================================

local WorldScaler = {}
WorldScaler.__index = WorldScaler

local SURROGATE_FOLDER_NAME = "LocalSurrogates"
local WORLD_NAME = "LocalScaledWorld"
local TEMPLATE_NAME = "WorldTemplate"

local function defaultIsSource(inst: Instance): boolean
	if not (inst:IsA("Model") or inst:IsA("BasePart") or inst:IsA("Folder")) then
		return false
	end
	if inst:IsA("Terrain") or inst:IsA("Camera") then
		return false
	end
	if Players:GetPlayerFromCharacter(inst) then
		return false
	end
	local n = inst.Name
	if n == SURROGATE_FOLDER_NAME or n == WORLD_NAME or n == TEMPLATE_NAME then
		return false
	end
	return true
end

local function hideInstanceTree(root: Instance)
	local function hide(inst: Instance)
		if inst:IsA("BasePart") then
			inst.Transparency = 1
			inst.CanCollide = false
			inst.CanTouch = false
			inst.CanQuery = false
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			inst.Transparency = 1
		elseif inst:IsA("ParticleEmitter") or inst:IsA("Light") or inst:IsA("BillboardGui") then
			(inst :: any).Enabled = false
		end
	end
	hide(root)
	for _, desc in ipairs(root:GetDescendants()) do
		hide(desc)
	end
end

local function hideRealCharacter(char: Model)
	for _, desc in ipairs(char:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Transparency = 1
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
		elseif desc:IsA("Decal") then
			desc.Transparency = 1
		end
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
end

-- Copies BodyColors / Shirt / Pants / ShirtGraphic / face decal from the real character to the surrogate.
local function syncAppearance(realChar: Model, visualModel: Model)
	local realBC = realChar:FindFirstChildOfClass("BodyColors")
	if realBC then
		local visBC = visualModel:FindFirstChildOfClass("BodyColors")
		if not visBC then
			visBC = Instance.new("BodyColors")
			visBC.Parent = visualModel
		end
		local bc = visBC :: BodyColors
		bc.HeadColor3 = realBC.HeadColor3
		bc.TorsoColor3 = realBC.TorsoColor3
		bc.LeftArmColor3 = realBC.LeftArmColor3
		bc.RightArmColor3 = realBC.RightArmColor3
		bc.LeftLegColor3 = realBC.LeftLegColor3
		bc.RightLegColor3 = realBC.RightLegColor3
	end

	local realShirt = realChar:FindFirstChildOfClass("Shirt")
	if realShirt then
		local visShirt = visualModel:FindFirstChildOfClass("Shirt")
		if not visShirt then
			visShirt = Instance.new("Shirt")
			visShirt.Parent = visualModel
		end
		(visShirt :: Shirt).ShirtTemplate = realShirt.ShirtTemplate
	end

	local realPants = realChar:FindFirstChildOfClass("Pants")
	if realPants then
		local visPants = visualModel:FindFirstChildOfClass("Pants")
		if not visPants then
			visPants = Instance.new("Pants")
			visPants.Parent = visualModel
		end
		(visPants :: Pants).PantsTemplate = realPants.PantsTemplate
	end

	local realGraphic = realChar:FindFirstChildOfClass("ShirtGraphic")
	if realGraphic then
		local visGraphic = visualModel:FindFirstChildOfClass("ShirtGraphic")
		if not visGraphic then
			visGraphic = Instance.new("ShirtGraphic")
			visGraphic.Parent = visualModel
		end
		(visGraphic :: ShirtGraphic).Graphic = realGraphic.Graphic
	end

	local realHead = realChar:FindFirstChild("Head")
	local visHead = visualModel:FindFirstChild("Head")
	if realHead and visHead then
		local realFace = realHead:FindFirstChildOfClass("Decal")
		if realFace then
			local visFace = visHead:FindFirstChildOfClass("Decal")
			if not visFace then
				visFace = Instance.new("Decal")
				visFace.Name = "face"
				visFace.Face = Enum.NormalId.Front
				visFace.Parent = visHead
			end
			local face = visFace :: Decal
			face.Texture = realFace.Texture
			face.Transparency = 0
		end
	end
end

-- ============================================================================
-- Constructor
-- ============================================================================

function WorldScaler.new(config: Config): WorldScaler
	local self = setmetatable({}, WorldScaler) :: any

	self._config = config
	self._pivot = config.pivot
	self._worldScale = config.initialWorldScale or 1
	self._originals = {}
	self._world = nil
	self._surrogates = {}
	self._connections = {}
	self._destroyed = false

	-- Build the template from the source instances
	local template = Instance.new("Model")
	template.Name = TEMPLATE_NAME

	local sources: { Instance }
	if config.sources then
		sources = config.sources
	else
		sources = {}
		local filter = config.isSource or defaultIsSource
		for _, child in ipairs(Workspace:GetChildren()) do
			if filter(child) then
				table.insert(sources, child)
			end
		end
	end

	for _, src in ipairs(sources) do
		local wasArchivable = src.Archivable
		src.Archivable = true
		local clone = src:Clone()
		src.Archivable = wasArchivable
		if clone then
			table.insert(self._originals, src)
			clone.Parent = template
		end
	end
	template.WorldPivot = config.pivot
	self._template = template

	local folder = Instance.new("Folder")
	folder.Name = SURROGATE_FOLDER_NAME
	folder.Parent = Workspace
	self._surrogatesFolder = folder

	self:HideOriginals()
	self:SetWorldScale(self._worldScale)

	if config.syncRemotePlayers ~= false then
		self:_startRemoteSync()
	end

	return self :: WorldScaler
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Hides and disables collisions on the original (unscaled) world on this client.
-- Call again if new parts get added to the original instances later.
function WorldScaler.HideOriginals(self: WorldScaler)
	for _, inst in ipairs(self._originals) do
		hideInstanceTree(inst)
	end
end

-- Rebuilds the scaled clone of the world at the given scale.
-- worldScale > 1 makes the world bigger relative to you (you feel smaller).
function WorldScaler.SetWorldScale(self: WorldScaler, worldScale: number)
	assert(worldScale > 0, "worldScale must be positive")
	self._worldScale = worldScale

	if self._world then
		self._world:Destroy()
		self._world = nil
	end

	local world = self._template:Clone()
	world.Name = WORLD_NAME
	world.WorldPivot = self._pivot
	world:ScaleTo(worldScale)
	world.Parent = Workspace
	self._world = world

	-- Everyone's relative scale depends on our scale, so refresh surrogates.
	for _, entry in pairs(self._surrogates) do
		entry.lastAppliedScale = -1 -- force re-apply next frame
	end

	local cb = self._config.onWorldRebuilt
	if cb then
		cb(world, worldScale)
	end
end

function WorldScaler.GetWorldScale(self: WorldScaler): number
	return self._worldScale
end

function WorldScaler.GetScaledWorld(self: WorldScaler): Model?
	return self._world
end

function WorldScaler.GetPivot(self: WorldScaler): CFrame
	return self._pivot
end

function WorldScaler.GetSurrogate(self: WorldScaler, player: Player): Model?
	local entry = self._surrogates[player]
	return if entry then entry.visualModel else nil
end

-- localWorldScale / remoteWorldScale
function WorldScaler.GetRelativeScale(self: WorldScaler, remoteWorldScale: number): number
	return self._worldScale / remoteWorldScale
end

-- Maps a remote player's real position into this client's scaled world.
function WorldScaler.MapPosition(self: WorldScaler, realPosition: Vector3, remoteWorldScale: number): Vector3
	local origin = self._pivot.Position
	return origin + (realPosition - origin) * self:GetRelativeScale(remoteWorldScale)
end

-- Convenience: moves the local character to the pivot (optionally offset), zeroing velocity.
function WorldScaler.TeleportToPivot(self: WorldScaler, offset: Vector3?)
	local char = localPlayer.Character
	if not char then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local pos = self._pivot.Position + (offset or Vector3.new(0, 3.2, 0))
	char:PivotTo(CFrame.lookAt(pos, pos + self._pivot.LookVector))
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

-- Forces a surrogate to be rebuilt from the player's current real character.
function WorldScaler.RebuildSurrogate(self: WorldScaler, player: Player)
	if player.Character then
		self:_createSurrogate(player, player.Character)
	end
end

function WorldScaler.Destroy(self: WorldScaler)
	if self._destroyed then
		return
	end
	self._destroyed = true

	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)

	for plr in pairs(self._surrogates) do
		self:_removeSurrogate(plr)
	end

	if self._world then
		self._world:Destroy()
		self._world = nil
	end
	self._template:Destroy()
	self._surrogatesFolder:Destroy()
end

-- ============================================================================
-- Surrogates (internal)
-- ============================================================================

function WorldScaler._removeSurrogate(self: any, remotePlayer: Player)
	local entry: SurrogateEntry? = self._surrogates[remotePlayer]
	if not entry then
		return
	end
	local cb = self._config.onSurrogateRemoving
	if cb then
		cb(remotePlayer, entry.visualModel)
	end
	for _, conn in ipairs(entry.connections) do
		conn:Disconnect()
	end
	entry.visualModel:Destroy()
	self._surrogates[remotePlayer] = nil
end

function WorldScaler._createSurrogate(self: any, remotePlayer: Player, realChar: Model)
	local previousScale = 1.0
	local existing: SurrogateEntry? = self._surrogates[remotePlayer]
	if existing then
		previousScale = existing.lastAppliedScale
		self:_removeSurrogate(remotePlayer)
	end

	local realRoot = realChar:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	if not realRoot or self._destroyed then
		return
	end

	realChar.Archivable = true
	local visualModel = realChar:Clone()
	if not visualModel then
		return
	end
	visualModel.Name = "Surrogate_" .. remotePlayer.Name

	local visualRoot = visualModel:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	if not visualRoot then
		visualModel:Destroy()
		return
	end

	-- PrimaryPart must be the root so PivotTo aligns at HumanoidRootPart, not the Head.
	visualModel.PrimaryPart = visualRoot
	visualRoot.Anchored = true

	for _, desc in ipairs(visualModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
			desc.Massless = true
			desc.Transparency = if desc == visualRoot then 1 else 0
		elseif desc:IsA("Decal") then
			desc.Transparency = 0
		end
	end

	-- The surrogate humanoid is only a visual puppet.
	local visHumanoid = visualModel:FindFirstChildOfClass("Humanoid")
	if visHumanoid then
		visHumanoid.RequiresNeck = false
		visHumanoid.BreakJointsOnDeath = false
		visHumanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		visHumanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		visHumanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		visHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	end

	syncAppearance(realChar, visualModel)
	visualModel.Parent = self._surrogatesFolder
	hideRealCharacter(realChar)

	local connections: { RBXScriptConnection } = {}

	-- Keep the real character hidden and mirror late-arriving accessories / clothing.
	table.insert(
		connections,
		realChar.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") then
				desc.Transparency = 1
				desc.CanCollide = false
			elseif desc:IsA("Decal") then
				desc.Transparency = 1
			end

			if desc:IsA("Accessory") then
				task.delay(0.05, function()
					if not visualModel.Parent then
						return
					end
					local old = visualModel:FindFirstChild(desc.Name)
					if old then
						old:Destroy()
					end
					local accClone = desc:Clone()
					accClone.Parent = visualModel
					for _, p in ipairs(accClone:GetDescendants()) do
						if p:IsA("BasePart") then
							p.CanCollide = false
							p.CanTouch = false
							p.CanQuery = false
							p.Massless = true
						end
					end
				end)
			elseif desc:IsA("BodyColors") or desc:IsA("Shirt") or desc:IsA("Pants") or desc:IsA("ShirtGraphic") then
				task.delay(0.05, function()
					if visualModel.Parent then
						syncAppearance(realChar, visualModel)
					end
				end)
			end
		end)
	)

	local realBC = realChar:FindFirstChildOfClass("BodyColors")
	if realBC then
		table.insert(
			connections,
			realBC.Changed:Connect(function()
				if visualModel.Parent then
					syncAppearance(realChar, visualModel)
				end
			end)
		)
	end

	-- Map Motor6D joints for animation mirroring.
	local realMotors: { [string]: Motor6D } = {}
	local visMotors: { [string]: Motor6D } = {}
	for _, desc in ipairs(realChar:GetDescendants()) do
		if desc:IsA("Motor6D") then
			realMotors[desc.Name] = desc
		end
	end
	for _, desc in ipairs(visualModel:GetDescendants()) do
		if desc:IsA("Motor6D") then
			visMotors[desc.Name] = desc
		end
	end

	self._surrogates[remotePlayer] = {
		remotePlayer = remotePlayer,
		realChar = realChar,
		realRoot = realRoot,
		visualModel = visualModel,
		visualRoot = visualRoot,
		realMotors = realMotors,
		visMotors = visMotors,
		lastAppliedScale = previousScale,
		connections = connections,
	}

	if math.abs(previousScale - 1.0) > 0.005 then
		visualModel:ScaleTo(previousScale)
	end

	local cb = self._config.onSurrogateCreated
	if cb then
		cb(remotePlayer, visualModel, visualRoot)
	end
end

function WorldScaler._setupRemotePlayer(self: any, otherPlayer: Player)
	if otherPlayer == localPlayer then
		return
	end

	table.insert(
		self._connections,
		otherPlayer.CharacterAdded:Connect(function(newChar)
			self:_createSurrogate(otherPlayer, newChar)
		end)
	)

	-- Rebuild once the full avatar (clothes, accessories) has finished loading.
	table.insert(
		self._connections,
		otherPlayer.CharacterAppearanceLoaded:Connect(function(loadedChar)
			if otherPlayer.Character == loadedChar then
				self:_createSurrogate(otherPlayer, loadedChar)
			end
		end)
	)

	table.insert(
		self._connections,
		otherPlayer.CharacterRemoving:Connect(function()
			self:_removeSurrogate(otherPlayer)
		end)
	)

	if otherPlayer.Character then
		task.spawn(function()
			self:_createSurrogate(otherPlayer, otherPlayer.Character :: Model)
		end)
	end
end

function WorldScaler._startRemoteSync(self: any)
	for _, p in ipairs(Players:GetPlayers()) do
		self:_setupRemotePlayer(p)
	end
	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(p)
			self:_setupRemotePlayer(p)
		end)
	)
	table.insert(
		self._connections,
		Players.PlayerRemoving:Connect(function(p)
			self:_removeSurrogate(p)
		end)
	)

	-- Right before each frame renders: reproject surrogates, apply relative scale, mirror animation.
	table.insert(
		self._connections,
		RunService.PreRender:Connect(function()
			local getRemoteScale = self._config.getRemoteWorldScale
			local origin = self._pivot.Position

			for remotePlayer, entry in pairs(self._surrogates :: { [Player]: SurrogateEntry }) do
				if entry.realChar.Parent and entry.visualModel.Parent and entry.realRoot.Parent then
					local remoteWorldScale = if getRemoteScale then getRemoteScale(remotePlayer) else 1
					if remoteWorldScale <= 0 then
						remoteWorldScale = 1
					end
					local relativeScale = self._worldScale / remoteWorldScale

					if math.abs(entry.lastAppliedScale - relativeScale) > 0.005 then
						entry.lastAppliedScale = relativeScale
						entry.visualModel.WorldPivot = entry.visualRoot.CFrame
						entry.visualModel:ScaleTo(relativeScale)
					end

					local rawPos = entry.realRoot.Position
					local mappedPos = origin + (rawPos - origin) * relativeScale
					entry.visualModel:PivotTo(CFrame.new(mappedPos) * entry.realRoot.CFrame.Rotation)

					for name, realMotor in pairs(entry.realMotors) do
						local visMotor = entry.visMotors[name]
						if visMotor and realMotor.Parent then
							visMotor.Transform = realMotor.Transform
						end
					end
				end
			end
		end)
	)
end

return WorldScaler