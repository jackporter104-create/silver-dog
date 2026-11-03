--!strict
--[[
	Remote definitions. The server creates them and clients wait for them.

	Client -> Server
	  Action (RemoteEvent):            (stationId: string)  -- intent only, no values
	Server -> Client
	  Tick (UnreliableRemoteEvent):    { currencyM, currencyE, rateM, rateE, serverTime, buffMultiplier }  ~1 Hz
	  Snapshot (RemoteEvent):          Types.Snapshot on any state change
	  Cycle (RemoteEvent):             Types.CycleEvent when a hand-run stand cycle starts
	  Notify (RemoteEvent):            Types.Notification
	  UiConfig (RemoteEvent):          Types.UiConfig (A/B variant + live overrides)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type Remotes = {
	Action: RemoteEvent,
	Tick: UnreliableRemoteEvent,
	Snapshot: RemoteEvent,
	Cycle: RemoteEvent,
	Notify: RemoteEvent,
	UiConfig: RemoteEvent,
}

local Net = {}

Net.FOLDER_NAME = "OceanRemotes"
Net.TICK_INTERVAL = 1
Net.TICK_FIELDS = 6

local cached: Remotes? = nil

local function create<T>(className: string, name: string, parent: Instance): T
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing.ClassName == className, "Remote " .. name .. " has wrong class")
		return (existing :: any) :: T
	end
	local remote = Instance.new(className :: any)
	remote.Name = name
	remote.Parent = parent
	return (remote :: any) :: T
end

local function wait<T>(name: string, parent: Instance, className: string): T
	local child = parent:WaitForChild(name, 30)
	assert(child and child.ClassName == className, "Timed out waiting for remote " .. name)
	return (child :: any) :: T
end

function Net.get(): Remotes
	if cached then
		return cached
	end
	local remotes: Remotes
	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(Net.FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = Net.FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
		assert(folder, "remote folder")
		remotes = {
			Action = create("RemoteEvent", "Action", folder),
			Tick = create("UnreliableRemoteEvent", "Tick", folder),
			Snapshot = create("RemoteEvent", "Snapshot", folder),
			Cycle = create("RemoteEvent", "Cycle", folder),
			Notify = create("RemoteEvent", "Notify", folder),
			UiConfig = create("RemoteEvent", "UiConfig", folder),
		}
	else
		local folder = ReplicatedStorage:WaitForChild(Net.FOLDER_NAME, 30)
		assert(folder, "Timed out waiting for remotes folder")
		remotes = {
			Action = wait("Action", folder, "RemoteEvent"),
			Tick = wait("Tick", folder, "UnreliableRemoteEvent"),
			Snapshot = wait("Snapshot", folder, "RemoteEvent"),
			Cycle = wait("Cycle", folder, "RemoteEvent"),
			Notify = wait("Notify", folder, "RemoteEvent"),
			UiConfig = wait("UiConfig", folder, "RemoteEvent"),
		}
	end
	cached = remotes
	return remotes
end

return Net
