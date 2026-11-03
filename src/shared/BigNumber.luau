--!strict
--[[
	BigNumber: one numeric type for the whole economy.

	Values below 1e15 are stored as plain Luau doubles in `m`, with `e = 0` ("small form").
	Doubles are exact for integers up to 2^53 (about 9e15), so early-game math is exact.

	Values at or above 1e15 are stored as a normalized mantissa and exponent ("big form"):
	1 <= |m| < 10 and e >= 15. Callers never branch on the form. Every operation accepts
	both forms and returns the canonical one, so the 1e15 boundary is invisible to the UI
	and to the economy code.

	Instances are frozen. Every operation returns a new value.
]]

export type BigNumber = { m: number, e: number }
export type Serialized = { number }

local BigNumber = {}

local SMALL_EXP = 15
local SMALL_LIMIT = 10 ^ SMALL_EXP
-- Beyond this exponent gap, the smaller addend is below double precision.
local MAX_PRECISION_GAP = 17
-- Values this tiny are economically meaningless and would underflow 10^shift.
local MIN_EXP = -300

local function make(m: number, e: number): BigNumber
	return table.freeze({ m = m, e = e })
end

BigNumber.ZERO = make(0, 0)
BigNumber.ONE = make(1, 0)
BigNumber.SMALL_LIMIT = SMALL_LIMIT

local ZERO = BigNumber.ZERO
local ONE = BigNumber.ONE

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end
BigNumber.isFinite = isFinite

-- Splits |x| into a mantissa in [1, 10) and an integer exponent, correcting log10's
-- off-by-one at exact powers of ten, for example log10(1000) = 2.9999999999999996.
local function split(m: number): (number, number)
	local shift = math.floor(math.log10(math.abs(m)))
	local mant = m / 10 ^ shift
	local absMant = math.abs(mant)
	if absMant >= 10 then
		mant /= 10
		shift += 1
	elseif absMant < 1 then
		mant *= 10
		shift -= 1
	end
	return mant, shift
end

-- Canonicalizes value = m * 10^e.
local function normalize(m: number, e: number): BigNumber
	if m == 0 or m ~= m then
		return ZERO
	end
	if e == 0 and m > -SMALL_LIMIT and m < SMALL_LIMIT then
		return make(m, 0)
	end
	if m == math.huge or m == -math.huge then
		-- Clamp double overflow so inf or NaN never reaches saved data.
		m = if m > 0 then 9.999999999999 else -9.999999999999
		e += 308
	end
	local mant, shift = split(m)
	local exp = e + shift
	if exp < MIN_EXP then
		return ZERO
	end
	if exp < SMALL_EXP then
		return make(mant * 10 ^ exp, 0)
	end
	return make(mant, exp)
end

-- Returns (mantissa in [1,10), exponent) for either form.
local function parts(x: BigNumber): (number, number)
	if x.e ~= 0 or x.m == 0 then
		return x.m, x.e
	end
	return split(x.m)
end

function BigNumber.new(m: number, e: number?): BigNumber
	local exp = e or 0
	assert(isFinite(m), "BigNumber.new: mantissa must be finite")
	assert(isFinite(exp) and exp == math.floor(exp), "BigNumber.new: exponent must be an integer")
	return normalize(m, exp)
end

function BigNumber.fromNumber(n: number): BigNumber
	return normalize(n, 0)
end

-- Builds 10^exponent * mantissa, for configs that express huge costs by exponent.
function BigNumber.fromExponent(exponent: number, mantissa: number?): BigNumber
	return BigNumber.new(mantissa or 1, exponent)
end

function BigNumber.decompose(x: BigNumber): (number, number)
	return parts(x)
end

function BigNumber.isBig(x: BigNumber): boolean
	return x.e ~= 0
end

function BigNumber.isZero(x: BigNumber): boolean
	return x.m == 0
end

function BigNumber.isNegative(x: BigNumber): boolean
	return x.m < 0
end

function BigNumber.neg(x: BigNumber): BigNumber
	if x.m == 0 then
		return x
	end
	return make(-x.m, x.e)
end

function BigNumber.add(a: BigNumber, b: BigNumber): BigNumber
	if a.e == 0 and b.e == 0 then
		return normalize(a.m + b.m, 0)
	end
	if a.m == 0 then
		return b
	elseif b.m == 0 then
		return a
	end
	local am, ae = parts(a)
	local bm, be = parts(b)
	local gap = ae - be
	if gap > MAX_PRECISION_GAP then
		return a
	elseif gap < -MAX_PRECISION_GAP then
		return b
	elseif gap >= 0 then
		return normalize(am + bm / 10 ^ gap, ae)
	else
		return normalize(bm + am / 10 ^ -gap, be)
	end
end

function BigNumber.sub(a: BigNumber, b: BigNumber): BigNumber
	return BigNumber.add(a, BigNumber.neg(b))
end

function BigNumber.mul(a: BigNumber, b: BigNumber): BigNumber
	if a.m == 0 or b.m == 0 then
		return ZERO
	end
	if a.e == 0 and b.e == 0 then
		return normalize(a.m * b.m, 0)
	end
	local am, ae = parts(a)
	local bm, be = parts(b)
	return normalize(am * bm, ae + be)
end

function BigNumber.div(a: BigNumber, b: BigNumber): BigNumber
	assert(b.m ~= 0, "BigNumber.div: division by zero")
	if a.m == 0 then
		return ZERO
	end
	if a.e == 0 and b.e == 0 then
		return normalize(a.m / b.m, 0)
	end
	local am, ae = parts(a)
	local bm, be = parts(b)
	return normalize(am / bm, ae - be)
end

function BigNumber.mulNumber(a: BigNumber, n: number): BigNumber
	return BigNumber.mul(a, normalize(n, 0))
end

function BigNumber.addNumber(a: BigNumber, n: number): BigNumber
	return BigNumber.add(a, normalize(n, 0))
end

function BigNumber.log10(x: BigNumber): number
	assert(x.m > 0, "BigNumber.log10: value must be positive")
	if x.e == 0 then
		return math.log10(x.m)
	end
	return math.log10(x.m) + x.e
end

-- x^n for x >= 0 and plain exponent n. Exact Luau pow while the result stays small.
function BigNumber.pow(x: BigNumber, n: number): BigNumber
	assert(isFinite(n), "BigNumber.pow: exponent must be finite")
	if n == 0 then
		return ONE
	end
	assert(x.m >= 0, "BigNumber.pow: negative base unsupported")
	if x.m == 0 then
		return ZERO
	end
	local logResult = BigNumber.log10(x) * n
	if x.e == 0 and logResult < SMALL_EXP - 1 then
		return normalize(x.m ^ n, 0)
	end
	local exp = math.floor(logResult)
	return normalize(10 ^ (logResult - exp), exp)
end

function BigNumber.compare(a: BigNumber, b: BigNumber): number
	if a.e == 0 and b.e == 0 then
		return if a.m < b.m then -1 elseif a.m > b.m then 1 else 0
	end
	local signA = if a.m > 0 then 1 elseif a.m < 0 then -1 else 0
	local signB = if b.m > 0 then 1 elseif b.m < 0 then -1 else 0
	if signA ~= signB then
		return if signA < signB then -1 else 1
	end
	local am, ae = parts(a)
	local bm, be = parts(b)
	local result: number
	if ae ~= be then
		result = if ae < be then -1 else 1
	elseif am ~= bm then
		result = if math.abs(am) < math.abs(bm) then -1 else 1
	else
		return 0
	end
	return result * signA
end

function BigNumber.lt(a: BigNumber, b: BigNumber): boolean
	return BigNumber.compare(a, b) < 0
end

function BigNumber.lte(a: BigNumber, b: BigNumber): boolean
	return BigNumber.compare(a, b) <= 0
end

function BigNumber.gt(a: BigNumber, b: BigNumber): boolean
	return BigNumber.compare(a, b) > 0
end

function BigNumber.gte(a: BigNumber, b: BigNumber): boolean
	return BigNumber.compare(a, b) >= 0
end

function BigNumber.eq(a: BigNumber, b: BigNumber): boolean
	return BigNumber.compare(a, b) == 0
end

function BigNumber.max(a: BigNumber, b: BigNumber): BigNumber
	return if BigNumber.compare(a, b) >= 0 then a else b
end

function BigNumber.min(a: BigNumber, b: BigNumber): BigNumber
	return if BigNumber.compare(a, b) <= 0 then a else b
end

-- a - b, clamped at zero. Guards purchases against float error just under zero.
function BigNumber.subClamped(a: BigNumber, b: BigNumber): BigNumber
	local result = BigNumber.sub(a, b)
	return if result.m < 0 then ZERO else result
end

-- Big-form values are already integral at double precision.
function BigNumber.floor(x: BigNumber): BigNumber
	if x.e ~= 0 then
		return x
	end
	return normalize(math.floor(x.m), 0)
end

-- Lossy for big values. May return math.huge. Use only for display heuristics.
function BigNumber.toNumber(x: BigNumber): number
	if x.e == 0 then
		return x.m
	end
	return x.m * 10 ^ x.e
end

function BigNumber.serialize(x: BigNumber): Serialized
	return { x.m, x.e }
end

-- Validates untrusted input from a DataStore or the network. Returns nil when invalid.
function BigNumber.deserialize(value: unknown): BigNumber?
	if typeof(value) ~= "table" then
		return nil
	end
	local t = value :: any
	local m, e = t[1], t[2]
	if typeof(m) ~= "number" or typeof(e) ~= "number" then
		return nil
	end
	if not isFinite(m) or not isFinite(e) or e ~= math.floor(e) then
		return nil
	end
	return normalize(m, e)
end

function BigNumber.toString(x: BigNumber): string
	if x.e == 0 then
		return tostring(x.m)
	end
	return string.format("%.6fe%d", x.m, x.e)
end

return BigNumber
