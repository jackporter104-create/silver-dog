--!strict
--[[
	Seasons and events registry. To add one, create a sibling module that returns a
	Types.SeasonDefinition and add it to LIST below. No server or client core code changes.
	The highest-priority season whose [startsAt, endsAt) window contains server time wins.
]]

local Types = require(script.Parent.Parent.Types)

local Default = require(script.Default)
local CoralCarnival = require(script.CoralCarnival)

type SeasonDefinition = Types.SeasonDefinition

local Seasons = {}

Seasons.DEFAULT_ID = Default.id
Seasons.LIST = { Default, CoralCarnival } :: { SeasonDefinition }
Seasons.BY_ID = {} :: { [string]: SeasonDefinition }
for _, season in Seasons.LIST do
	assert(Seasons.BY_ID[season.id] == nil, "Duplicate season id " .. season.id)
	Seasons.BY_ID[season.id] = season
end

function Seasons.isActive(season: SeasonDefinition, now: number): boolean
	if season.startsAt and now < season.startsAt then
		return false
	end
	if season.endsAt and now >= season.endsAt then
		return false
	end
	return true
end

function Seasons.resolve(now: number): SeasonDefinition
	local best = Seasons.BY_ID[Seasons.DEFAULT_ID]
	for _, season in Seasons.LIST do
		if Seasons.isActive(season, now) and season.priority > best.priority then
			best = season
		end
	end
	return best
end

function Seasons.get(id: string): SeasonDefinition
	return Seasons.BY_ID[id] or Seasons.BY_ID[Seasons.DEFAULT_ID]
end

return Seasons
