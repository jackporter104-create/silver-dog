--!strict
--[[
	Monetization ids. 0 = disabled (the server ignores it).
	Replace these with your real asset ids from the Creator Dashboard.
	Purchases are prompted from the Roblox menu or your own shop; the HUD has no buy buttons.
]]

local Monetization = {}

-- Gamepass: x2 income from every stand, forever.
Monetization.DOUBLE_INCOME_PASS_ID = 0

-- Developer product: "Time Warp" grants Economy.TIME_WARP_SECONDS of income instantly.
Monetization.TIME_WARP_PRODUCT_ID = 0

return Monetization
