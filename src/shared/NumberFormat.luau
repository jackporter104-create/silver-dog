--!strict
--[[
	Display formatting for BigNumber values.

	All formatting TRUNCATES (never rounds up), so a displayed amount never exceeds the real one.
	  < 1,000            -> "999" (or "0.5" when decimals are requested)
	  1e3 .. 1e303       -> "1.23K", "45.6M", "789T", "1.2Qa", ... "1.5UQq" (Unquinquagintillion)
	  >= 1e306           -> scientific "1.23e308"
	Notation "long" spells the suffix ("1.5 Unquinquagintillion"); "scientific" forces e-notation
	for anything at or above 1,000.
]]

local BigNumber = require(script.Parent.BigNumber)
type BigNumber = BigNumber.BigNumber

export type Notation = "suffix" | "long" | "scientific"
export type FormatOptions = {
	notation: Notation?,
	-- Decimal places for values below 1,000 (for example income rates such as 0.5/s).
	decimals: number?,
}

local NumberFormat = {}

local LOW_SHORT = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No" }
local LOW_LONG = {
	"Thousand",
	"Million",
	"Billion",
	"Trillion",
	"Quadrillion",
	"Quintillion",
	"Sextillion",
	"Septillion",
	"Octillion",
	"Nonillion",
}
local UNIT_SHORT = { "", "U", "D", "T", "Qa", "Qi", "Sx", "Sp", "O", "N" }
local TENS_SHORT = { "", "Dc", "Vg", "Tg", "Qd", "Qq", "Sg", "St", "Og", "Ng" }
local UNIT_LONG = { "", "Un", "Duo", "Tre", "Quattuor", "Quin", "Sex", "Septen", "Octo", "Novem" }
local TENS_LONG = {
	"",
	"decillion",
	"vigintillion",
	"trigintillion",
	"quadragintillion",
	"quinquagintillion",
	"sexagintillion",
	"septuagintillion",
	"octogintillion",
	"nonagintillion",
}

-- Group k covers 10^(3k). k = 1..10 uses the classic names. k >= 11 is the (k-1)-th "-illion".
local MAX_GROUP = 101 -- Centillion, 10^303
local SHORT: { string } = {}
local LONG: { string } = {}

for k = 1, MAX_GROUP do
	if k <= #LOW_SHORT then
		SHORT[k] = LOW_SHORT[k]
		LONG[k] = LOW_LONG[k]
	elseif k == MAX_GROUP then
		SHORT[k] = "Ce"
		LONG[k] = "Centillion"
	else
		local n = k - 1
		local units, tens = n % 10, n // 10
		SHORT[k] = UNIT_SHORT[units + 1] .. TENS_SHORT[tens + 1]
		local name = UNIT_LONG[units + 1] .. TENS_LONG[tens + 1]
		LONG[k] = string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
	end
end

-- Big-form mantissas carry binary error (1.15 is stored as 1.1499999999999999). This tolerance
-- lets that read as 115. It sits far below the mantissa's real precision. Small-form values
-- are truncated exactly with no tolerance.
local MANTISSA_EPSILON = 1e-10

local function stripZeros(text: string): string
	if string.find(text, ".", 1, true) then
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")
	end
	return text
end

local function truncateFixed(value: number, decimals: number): string
	local scale = 10 ^ decimals
	local truncated = math.floor(value * scale) / scale
	if decimals <= 0 then
		return string.format("%d", truncated)
	end
	return stripZeros(string.format("%." .. decimals .. "f", truncated))
end

-- First three significant digits as an integer in [100, 999], truncated.
local function leadingDigits(x: BigNumber, mantissa: number, exponent: number): number
	local digits: number
	if BigNumber.isBig(x) then
		digits = math.floor(mantissa * 100 + MANTISSA_EPSILON)
	else
		-- One correctly rounded division of the exact double, so it is safe to floor.
		digits = math.floor(x.m / 10 ^ (exponent - 2))
	end
	return math.clamp(digits, 100, 999)
end

-- Places the decimal point in three digits: (123, 1) -> "1.23", (120, 2) -> "12", (999, 3) -> "999".
local function placeDigits(digits: number, integerDigits: number): string
	if integerDigits >= 3 then
		return tostring(digits)
	end
	local fractionDigits = 3 - integerDigits
	local divisor = 10 ^ fractionDigits
	local text = string.format("%d.%0" .. fractionDigits .. "d", digits // divisor, digits % divisor)
	return stripZeros(text)
end

function NumberFormat.format(x: BigNumber, options: FormatOptions?): string
	if x.m < 0 then
		return "-" .. NumberFormat.format(BigNumber.neg(x), options)
	end
	if x.m == 0 then
		return "0"
	end
	local notation: Notation = if options and options.notation then options.notation else "suffix"
	local mantissa, exponent = BigNumber.decompose(x)

	if exponent < 3 then
		local decimals = if options and options.decimals then options.decimals else 0
		return truncateFixed(BigNumber.toNumber(x), decimals)
	end

	local digits = leadingDigits(x, mantissa, exponent)
	local group = exponent // 3
	if notation == "scientific" or group > MAX_GROUP then
		return placeDigits(digits, 1) .. "e" .. exponent
	end

	local lead = placeDigits(digits, exponent - group * 3 + 1)
	if notation == "long" then
		return lead .. " " .. LONG[group]
	end
	return lead .. SHORT[group]
end

function NumberFormat.formatRate(x: BigNumber, options: FormatOptions?): string
	local merged: FormatOptions = {
		notation = if options then options.notation else nil,
		decimals = if options and options.decimals then options.decimals else 1,
	}
	return NumberFormat.format(x, merged) .. "/s"
end

-- Full suffix name for a value, or nil below 1,000 or above the named range.
function NumberFormat.suffixName(x: BigNumber): string?
	if x.m <= 0 then
		return nil
	end
	local _, exponent = BigNumber.decompose(x)
	local group = exponent // 3
	if group < 1 or group > MAX_GROUP then
		return nil
	end
	return LONG[group]
end

function NumberFormat.shortSuffix(group: number): string?
	return SHORT[group]
end

function NumberFormat.longSuffix(group: number): string?
	return LONG[group]
end

return NumberFormat
