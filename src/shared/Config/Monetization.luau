--!strict
--[[
	Monetization ids. 0 = disabled (the UI hides the button and the server ignores it).
	Replace these with your real asset ids from the Creator Dashboard.
]]

local Monetization = {}

-- Gamepass: the auto-clicker never drains (at least Economy.GAMEPASS_AUTO_CPS clicks/s).
Monetization.INFINITE_AUTO_CLICKER_PASS_ID = 0

-- Developer product: "Battery Overcharge" fills the battery to 3x capacity
-- (grants tier 1 when the player has no auto-clicker yet).
Monetization.BATTERY_OVERCHARGE_PRODUCT_ID = 0
Monetization.OVERCHARGE_MULTIPLIER = 3

return Monetization
