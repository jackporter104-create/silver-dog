--!strict
-- CLI unit tests for BigNumber + NumberFormat. Run: python3 tools/run_luau.py tests/BigNumber.spec.luau

local BigNumber = require("../shared/BigNumber")
local NumberFormat = require("../shared/NumberFormat")

type BigNumber = BigNumber.BigNumber

local passed, failed = 0, 0

local function check(name: string, condition: boolean, detail: string?)
	if condition then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. name .. (if detail then " (" .. detail .. ")" else ""))
	end
end

local function eqStr(name: string, actual: string, expected: string)
	check(name, actual == expected, "got '" .. actual .. "', expected '" .. expected .. "'")
end

local N = BigNumber.fromNumber
local E = BigNumber.fromExponent
local fmt = NumberFormat.format

-- Small form stays exact and plain
local a = N(999_999_999_999_999)
check("small form below 1e15", a.e == 0 and a.m == 999_999_999_999_999)
local promoted = BigNumber.add(a, N(1))
check("promotes at 1e15", promoted.e == 15 and promoted.m == 1, BigNumber.toString(promoted))
local demoted = BigNumber.sub(promoted, N(1))
check("demotes below 1e15", demoted.e == 0 and math.abs(demoted.m - 999_999_999_999_999) < 2, BigNumber.toString(demoted))
check("integer exactness early", BigNumber.add(N(0.1), N(0.2)).m > 0.29)

-- Arithmetic across the boundary
check("mul promotes", BigNumber.eq(BigNumber.mul(N(1e10), N(1e10)), E(20)))
check("div demotes", BigNumber.eq(BigNumber.div(E(20), N(1e10)), N(1e10)))
check("pow small exact", BigNumber.pow(N(1.15), 10).m == 1.15 ^ 10)
check("pow big", math.abs(BigNumber.log10(BigNumber.pow(N(1.15), 1000)) - 1000 * math.log10(1.15)) < 1e-9)
check("add precision gap", BigNumber.eq(BigNumber.add(E(100), N(5)), E(100)))
check("add same exponent", BigNumber.eq(BigNumber.add(E(20, 5), E(20, 5)), E(21)))
check("sub to zero", BigNumber.isZero(BigNumber.sub(E(40, 3), E(40, 3))))
check("subClamped", BigNumber.isZero(BigNumber.subClamped(N(5), N(10))))
check("floor small", BigNumber.floor(N(12.9)).m == 12)

-- Comparisons
check("cmp small/big", BigNumber.lt(N(999_999_999_999_999), E(15)))
check("cmp big/big", BigNumber.gt(E(16, 1.1), E(16)))
check("cmp exponents", BigNumber.gt(E(17), E(16, 9.99)))
check("cmp negative", BigNumber.lt(BigNumber.neg(E(20)), N(-5)))
check("cmp equal", BigNumber.eq(E(30, 2.5), E(30, 2.5)))
check("gte boundary", BigNumber.gte(N(1000), N(1000)))

-- Overflow & sanitisation never produce NaN/inf
local huge = BigNumber.mul(E(300), E(300))
check("no overflow", huge.e == 600 and BigNumber.isFinite(huge.m))
check("NaN -> 0", BigNumber.isZero(N(0 / 0)))
check("inf clamped", BigNumber.isFinite(N(math.huge).m))

-- Serialization validation
local rt = BigNumber.deserialize(BigNumber.serialize(E(156, 1.5)))
check("roundtrip", rt ~= nil and BigNumber.eq(rt, E(156, 1.5)))
check("reject string", BigNumber.deserialize("1e5") == nil)
check("reject NaN", BigNumber.deserialize({ 0 / 0, 0 }) == nil)
check("reject frac exp", BigNumber.deserialize({ 1, 1.5 }) == nil)
check("reject inf", BigNumber.deserialize({ math.huge, 0 }) == nil)
local fixed = BigNumber.deserialize({ 1234, 20 })
check("renormalize", fixed ~= nil and fixed.m == 1.234 and fixed.e == 23)

-- Formatting: normal numbers early, truncation not rounding
eqStr("zero", fmt(N(0)), "0")
eqStr("one", fmt(N(1)), "1")
eqStr("ten", fmt(N(10)), "10")
eqStr("999.9 floors", fmt(N(999.9)), "999")
eqStr("decimals", fmt(N(0.56), { decimals = 1 }), "0.5")
eqStr("1K", fmt(N(1000)), "1K")
eqStr("1.5K", fmt(N(1500)), "1.5K")
eqStr("truncate 1999", fmt(N(1999)), "1.99K")
eqStr("truncate 999999", fmt(N(999_999)), "999K")
eqStr("1M", fmt(N(1e6)), "1M")
eqStr("1.15 float", fmt(N(1150)), "1.15K")
eqStr("12.3B", fmt(N(12_399_999_999)), "12.3B")
eqStr("1T", fmt(N(1e12)), "1T")
eqStr("boundary 999.99T", fmt(N(999_999_999_999_999)), "999T")
eqStr("1Qa at transition", fmt(E(15)), "1Qa")
eqStr("Decillion", fmt(E(33)), "1Dc")
eqStr("Unquinquagintillion short", fmt(E(156, 1.5)), "1.5UQq")
eqStr("Unquinquagintillion long", fmt(E(156, 1.5), { notation = "long" }), "1.5 Unquinquagintillion")
eqStr("Centillion", fmt(E(303)), "1Ce")
eqStr("beyond names", fmt(E(400, 4.56789)), "4.56e400")
eqStr("scientific", fmt(E(20, 9.999), { notation = "scientific" }), "9.99e20")
eqStr("negative", fmt(N(-1500)), "-1.5K")
eqStr("rate", NumberFormat.formatRate(N(0.5)), "0.5/s")
check("suffix name", NumberFormat.suffixName(E(156)) == "Unquinquagintillion")

-- Long names match the standard short-scale spelling
local expectedNames = {
	[4] = "Trillion",
	[11] = "Decillion",
	[12] = "Undecillion",
	[21] = "Vigintillion",
	[22] = "Unvigintillion",
	[52] = "Unquinquagintillion",
	[101] = "Centillion",
}
for group, name in expectedNames do
	eqStr("long name " .. group, NumberFormat.longSuffix(group) or "nil", name)
end

-- Fuzz: format never shows a value above the real one; compare stays consistent with add
local seed = 12345
local function rand(): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end
local fuzzFailures = 0
for _ = 1, 5000 do
	local x = E(math.floor(rand() * 200), 1 + rand() * 9)
	local y = E(math.floor(rand() * 200), 1 + rand() * 9)
	local sum = BigNumber.add(x, y)
	if BigNumber.lt(sum, BigNumber.max(x, y)) then
		fuzzFailures += 1
	end
	local text = fmt(x, { notation = "scientific" })
	local mantText, expText = string.match(text, "^([%d%.]+)e(%d+)$")
	if mantText and expText then
		local shown = E(tonumber(expText) :: number, tonumber(mantText) :: number)
		if BigNumber.gt(shown, x) then
			fuzzFailures += 1
		end
	elseif BigNumber.log10(x) >= 3 then
		fuzzFailures += 1
	end
end
check("fuzz monotonic + truncation", fuzzFailures == 0, tostring(fuzzFailures) .. " failures")

print(string.format("BigNumber/NumberFormat: %d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
