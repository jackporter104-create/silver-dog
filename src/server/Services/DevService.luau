--!strict
--[[
	DevService: developer chat commands for testing the economy.

	  /give 10B     adds 10 Billion (any amount NumberFormat.parse understands: 1500, 2.5T, 1e30, 1UQq)

	Only these players can use it: anyone in Roblox Studio, the experience owner (user-owned
	experiences), and the user ids in ADMIN_USER_IDS. Everyone else is silently ignored.
	Granted currency counts as earned this run, so it also unlocks Evolution and the stairway.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormat = require(Shared.NumberFormat)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

local EconomyService = require(script.Parent.EconomyService)

local DevService = {}

-- Add tester user ids here to allow /give in live servers.
local ADMIN_USER_IDS: { [number]: boolean } = {}

local function isAuthorized(player: Player): boolean
	if RunService:IsStudio() or ADMIN_USER_IDS[player.UserId] then
		return true
	end
	return game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
end

local function reply(player: Player, kind: Types.NotifyKind, text: string)
	local payload: Types.Notification = { kind = kind, text = text }
	Net.get().Notify:FireClient(player, payload)
end

local function onGive(textSource: TextSource, message: string)
	local player = Players:GetPlayerByUserId(textSource.UserId)
	if not player or not isAuthorized(player) then
		return
	end
	local words = string.split(message, " ")
	local amount = if words[2] then NumberFormat.parse(table.concat(words, "", 2)) else nil
	if not amount or amount.m <= 0 then
		reply(player, "Error", "Usage: /give 10B  (also 1500, 2.5T, 1e30)")
		return
	end
	if EconomyService.grantCurrency(player, amount) then
		reply(player, "Success", "Dev: added " .. NumberFormat.format(amount))
	end
end

function DevService.init()
	local command = Instance.new("TextChatCommand")
	command.Name = "DevGiveCommand"
	command.PrimaryAlias = "/give"
	command.Triggered:Connect(onGive)
	command.Parent = TextChatService
end

return DevService
