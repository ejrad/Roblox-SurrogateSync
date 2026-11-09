--!strict
-- Example LocalScript showing how to use WorldScaler.
-- Assumes WorldScaler (ModuleScript) is in ReplicatedStorage and the server sets a "WorldScale"
-- attribute on each Player (replicated attributes are how clients learn each other's scale).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WorldScaler = require(ReplicatedStorage:WaitForChild("WorldScaler"))

local player = Players.LocalPlayer
local anchorPart = Workspace:WaitForChild("Respawn") :: BasePart

local function readScale(plr: Player): number
	local v = plr:GetAttribute("WorldScale")
	return if typeof(v) == "number" and v > 0 then v else 1
end

local scaler = WorldScaler.new({
	pivot = anchorPart.CFrame,

	-- Option A: list the instances explicitly
	sources = { Workspace:WaitForChild("Obby"), anchorPart },
	-- Option B: omit `sources` and pass `isSource = function(inst) ... end` to filter Workspace children

	initialWorldScale = readScale(player),
	getRemoteWorldScale = readScale,

	-- Optional hooks: add anything game-specific here, outside the module
	onSurrogateCreated = function(plr, model, root)
		local prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = plr.DisplayName
		prompt.ActionText = "Interact"
		prompt.MaxActivationDistance = 14 * scaler:GetWorldScale()
		prompt.Parent = root
		prompt.Triggered:Connect(function()
			print("Interacted with", plr.Name)
		end)
	end,
})

-- Rescale whenever your scale changes
player:GetAttributeChangedSignal("WorldScale"):Connect(function()
	scaler:SetWorldScale(readScale(player))
	scaler:TeleportToPivot()
end)

-- Re-hide originals and respawn at the pivot when the character loads
player.CharacterAdded:Connect(function()
	task.defer(function()
		scaler:HideOriginals()
		scaler:TeleportToPivot()
	end)
end)