--!strict
--[[
	Guard: per-player, per-action token-bucket rate limiting with strike tracking.

	Each rule allows `rate` requests per second with bursts up to `burst`. Rejected requests
	add a strike, and strikes decay over time. Crossing `kickStrikes` triggers the onAbuse
	callback, which can log or kick. Ordinary auto-clicker apps only produce dropped requests.
]]

export type Rule = { rate: number, burst: number }
export type AbuseHandler = (player: Player, key: string, strikes: number) -> ()

type Bucket = { tokens: number, updatedAt: number }
type PlayerState = { buckets: { [string]: Bucket }, strikes: number, strikeUpdatedAt: number }

export type Guard = {
	allow: (self: Guard, player: Player, key: string) -> boolean,
	removePlayer: (self: Guard, player: Player) -> (),
	strikes: (self: Guard, player: Player) -> number,
}

local Guard = {}

local STRIKE_DECAY_PER_SECOND = 0.5

function Guard.new(rules: { [string]: Rule }, kickStrikes: number, onAbuse: AbuseHandler?, clock: (() -> number)?): Guard
	local now = clock or os.clock
	local players: { [Player]: PlayerState } = {}

	local function stateFor(player: Player): PlayerState
		local state = players[player]
		if not state then
			state = { buckets = {}, strikes = 0, strikeUpdatedAt = now() }
			players[player] = state
		end
		return state
	end

	local guard: Guard = {
		allow = function(_self: Guard, player: Player, key: string): boolean
			local rule = rules[key]
			if not rule then
				-- Unknown keys are denied by default: there is no ungated path.
				return false
			end
			local state = stateFor(player)
			local t = now()
			local bucket = state.buckets[key]
			if not bucket then
				bucket = { tokens = rule.burst, updatedAt = t }
				state.buckets[key] = bucket
			end
			bucket.tokens = math.min(rule.burst, bucket.tokens + (t - bucket.updatedAt) * rule.rate)
			bucket.updatedAt = t
			if bucket.tokens >= 1 then
				bucket.tokens -= 1
				return true
			end

			state.strikes = math.max(0, state.strikes - (t - state.strikeUpdatedAt) * STRIKE_DECAY_PER_SECOND) + 1
			state.strikeUpdatedAt = t
			if onAbuse and state.strikes >= kickStrikes then
				state.strikes = 0
				onAbuse(player, key, kickStrikes)
			end
			return false
		end,
		removePlayer = function(_self: Guard, player: Player)
			players[player] = nil
		end,
		strikes = function(_self: Guard, player: Player): number
			local state = players[player]
			return if state then state.strikes else 0
		end,
	}
	return guard
end

return Guard
