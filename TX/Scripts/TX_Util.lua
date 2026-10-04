-- ===========================================================================
-- TX_Util.lua  (Team Expulsion 0.1.0)
-- TX:CONTEXT both
--
-- Shared helpers (PLAN II.4): log, the only pairs(), deep copy, small value
-- helpers. include("TX_Util") from gameplay and UI.
-- The only engine call is Game.GetCurrentGameTurn (G:C, UI:C), under pcall.
-- Pattern: EFV/Scripts/EFV_Util.lua:57-90 (EFV_Log), :155-165 (EFV_SortedKeys);
-- key order as TX_Dev/Scripts/TX_Dev_Lib.lua:91-110.
-- ===========================================================================

if TX_Util ~= nil and TX_Util.LOADED == 1 then
	return
end

include("TX_Config")

TX_Util = {}

local MAX_DEPTH = 20   -- nesting guard of DeepCopy

-- ---------------------------------------------------------------------------
-- TX_Util.Turn() -> number
-- Current game turn, -1 when it cannot be read.
-- ---------------------------------------------------------------------------
function TX_Util.Turn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then
		return t
	end
	return -1
end

-- ---------------------------------------------------------------------------
-- TX_Util.Log(level, tag, fmt, ...)
-- Prints "[TX][T<turn>][<tag>] <text>" when level <= TX_Config.LOG_LEVEL.
-- Level 1 lines start with "ERROR " (the offline runner fails a test on them).
-- With extra arguments fmt is a string.format pattern; a format error is
-- logged raw. Never throws. (EFV_Util.lua:57-90)
-- ---------------------------------------------------------------------------
function TX_Util.Log(level, tag, fmt, ...)
	local maxLevel = 2
	if TX_Config ~= nil and type(TX_Config.LOG_LEVEL) == "number" then
		maxLevel = TX_Config.LOG_LEVEL
	end
	if type(level) ~= "number" or level > maxLevel then
		return
	end
	local msg
	if select("#", ...) > 0 then
		local ok, s = pcall(string.format, tostring(fmt), ...)
		if ok then
			msg = s
		else
			msg = tostring(fmt) .. " [format error: " .. tostring(s) .. "]"
		end
	else
		msg = tostring(fmt)
	end
	if level == 1 then
		msg = "ERROR " .. msg
	end
	print("[TX][T" .. tostring(TX_Util.Turn()) .. "][" .. tostring(tag) .. "] " .. msg)
end

-- ---------------------------------------------------------------------------
-- TX_Util.SortedKeys(t) -> keys
-- The only pairs() in TX (MP rule: iteration order differs between machines).
-- Keys sorted by type name (numbers before strings), then by value.
-- ---------------------------------------------------------------------------
local function KeyLess(a, b)
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return ta < tb
	end
	if ta == "number" or ta == "string" then
		return a < b
	end
	return tostring(a) < tostring(b)
end

function TX_Util.SortedKeys(t)
	local keys = {}
	if type(t) ~= "table" then
		return keys
	end
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, KeyLess)
	return keys
end

-- ---------------------------------------------------------------------------
-- TX_Util.DeepCopy(v) -> copy
-- Copy of plain data. Game:GetProperty may return a live reference (EFV T03),
-- so every read is copied. Errors on nesting deeper than MAX_DEPTH.
-- ---------------------------------------------------------------------------
local function Copy(v, depth)
	if type(v) ~= "table" then
		return v
	end
	if depth > MAX_DEPTH then
		error("DeepCopy: nesting deeper than " .. MAX_DEPTH)
	end
	local out = {}
	for _, k in ipairs(TX_Util.SortedKeys(v)) do
		out[k] = Copy(v[k], depth + 1)
	end
	return out
end

function TX_Util.DeepCopy(v)
	return Copy(v, 0)
end

-- ---------------------------------------------------------------------------
-- TX_Util.B01(v) -> 1 | 0 | nil
-- Flags are stored as 0/1, never as booleans (PLAN II.2). nil stays nil;
-- false and 0 give 0; anything else gives 1 (0 is truthy in Lua, so a plain
-- "v and 1 or 0" would turn a stored 0 into 1).
-- ---------------------------------------------------------------------------
function TX_Util.B01(v)
	if v == nil then
		return nil
	end
	if v == false or v == 0 then
		return 0
	end
	return 1
end

-- ---------------------------------------------------------------------------
-- TX_Util.Str(v) -> string ("nil" for nil)
-- ---------------------------------------------------------------------------
function TX_Util.Str(v)
	if v == nil then
		return "nil"
	end
	return tostring(v)
end

TX_Util.LOADED = 1
