-- ===========================================================================
-- TX_Store.lua  (Team Expulsion 0.1.0)
-- TX:CONTEXT both
--
-- The vote record store and its persistence in Game properties (PLAN II.5).
-- Gameplay loads, changes and commits it in every handler; the UI only loads
-- it. Only the code between the TX:G-ONLY markers writes.
--
-- Properties:
--   TX_Store = { schema = 1, nextID = n, lastTurn = n,
--                victoryTurn = n, victoryTeam = n,      -- only after a victory
--                ids = { 3, 5, 7 }, recs = { r3 = rec, ... } }  -- left out while empty
--   TX_Rev   = n, plus 1 on every commit (the UI caches on it).
--
-- Storage rules (PLAN II.2; EFV SPIKES S3 via EFV_Records.lua:13-33;
-- tests/offline/lib/fake_engine.lua ValidateStored): string keys or dense
-- 1..n arrays, never mixed; no key 0, no holes; only numbers, strings and
-- tables; flags as 0/1; no empty table or empty string anywhere (Shape leaves
-- them out, Normalize restores the defaults); deep copy on read; SetProperty
-- again after each change.
--
-- Load / Commit pattern: EFV/Scripts/EFV_Records.lua:122-160 (copy, sanitize),
-- :457-552 (load, repair ids and nextID, drop malformed records),
-- :554-617 (commit refuses a broken store).
-- Engine calls: Game:GetProperty (G, UI), Game:SetProperty (G only).
-- ===========================================================================

if TX_Store ~= nil and TX_Store.LOADED == 1 then
	return
end

include("TX_Config")
include("TX_Util")

TX_Store = {}

local MAX_DEPTH = 20

local function Log(level, fmt, ...)
	TX_Util.Log(level, "Store", fmt, ...)
end

local function RecKey(id)
	return "r" .. tostring(id)
end

-- States a stored record may have, and the closed ones Trim may drop.
local function KnownState(s)
	return s ~= nil and TX_Config.ST[s] == s
end

local function IsClosed(s)
	local ST = TX_Config.ST
	return s == ST.FAILED or s == ST.EXPIRED or s == ST.CANCELLED or s == ST.DONE
end

-- ---------------------------------------------------------------------------
-- TX_Store.Fresh(turn) -> store
-- ---------------------------------------------------------------------------
function TX_Store.Fresh(turn)
	local t = tonumber(turn) or 0
	return { schema = TX_Config.SCHEMA, nextID = 1, lastTurn = t - 1, ids = {}, recs = {} }
end

-- ---------------------------------------------------------------------------
-- Record validation (Normalize). Returns nil when the record is usable, else
-- a short reason. A missing applied on a PENDING_APPLY record is filled in.
-- ---------------------------------------------------------------------------
local function IsNum(v)
	return type(v) == "number" and v == v
end

local OPTIONAL_NUMBERS = { "closedTurn", "newTeamID", "applied", "appliedTurn", "appliedBy", "appliedAttempt",
	"undoneAttempt", "doneTurn", "hardDone" }

local function RecordProblem(rec)
	if type(rec) ~= "table" then
		return "not a table"
	end
	for _, f in ipairs({ "teamID", "proposerID", "targetID", "openedTurn", "expiresTurn" }) do
		if not IsNum(rec[f]) then
			return f .. " is not a number"
		end
	end
	if not KnownState(rec.state) then
		return "unknown state " .. TX_Util.Str(rec.state)
	end
	for _, f in ipairs(OPTIONAL_NUMBERS) do
		if rec[f] ~= nil and not IsNum(rec[f]) then
			return f .. " is not a number"
		end
	end
	if rec.reason ~= nil and type(rec.reason) ~= "string" then
		return "reason is not a string"
	end
	if rec.mode ~= nil and type(rec.mode) ~= "string" then
		return "mode is not a string"
	end
	if type(rec.voters) ~= "table" or #rec.voters == 0 then
		return "no voters"
	end
	local keys = TX_Util.SortedKeys(rec.voters)
	if #keys ~= #rec.voters then
		return "voters is not a list"
	end
	for _, e in ipairs(rec.voters) do
		if type(e) ~= "table" or not IsNum(e.pid) or type(e.v) ~= "string" or TX_Config.V[e.v] ~= e.v then
			return "bad voter entry"
		end
	end
	local ST = TX_Config.ST
	if (rec.state == ST.PENDING_APPLY or rec.state == ST.DONE) and not IsNum(rec.newTeamID) then
		return "no newTeamID"
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- TX_Store.Normalize(raw, turn) -> store, repaired
-- raw (or nil) to a full store. Missing tables become {}; ids are rebuilt
-- ascending from the "r<id>" keys and nextID raised above the highest id when
-- they disagree; malformed records are dropped with an ERROR line
-- (EFV_Records.lua:457-552). repaired is true when the store differs from
-- what was saved in a way the next Commit should fix. Pure.
-- ---------------------------------------------------------------------------
function TX_Store.Normalize(raw, turn)
	local store = TX_Store.Fresh(turn)
	if raw == nil then
		return store, false
	end
	if type(raw) ~= "table" then
		Log(1, "normalize: the saved store is a %s, not a table; starting empty", type(raw))
		return store, true
	end
	local repaired = false

	if IsNum(raw.schema) then
		store.schema = raw.schema
		if raw.schema > TX_Config.SCHEMA then
			Log(1, "normalize: save schema=%d is newer than this mod (schema=%d); loading as is", raw.schema, TX_Config.SCHEMA)
		end
	else
		Log(1, "normalize: schema missing; set to %d", TX_Config.SCHEMA)
		repaired = true
	end
	if IsNum(raw.lastTurn) then
		store.lastTurn = raw.lastTurn
	else
		Log(1, "normalize: lastTurn missing; set to %d", store.lastTurn)
		repaired = true
	end
	if IsNum(raw.victoryTurn) then
		store.victoryTurn = raw.victoryTurn
		if IsNum(raw.victoryTeam) then
			store.victoryTeam = raw.victoryTeam
		end
	end

	-- Records: the "r<id>" keys are the source of truth.
	local ids = {}
	if raw.recs ~= nil and type(raw.recs) ~= "table" then
		Log(1, "normalize: recs is a %s; dropped", type(raw.recs))
		repaired = true
	elseif type(raw.recs) == "table" then
		for _, k in ipairs(TX_Util.SortedKeys(raw.recs)) do
			local id = nil
			if type(k) == "string" then
				id = tonumber(string.match(k, "^r(%d+)$"))
			end
			local rec = raw.recs[k]
			local why = nil
			if id == nil then
				why = "bad key"
			else
				why = RecordProblem(rec)
			end
			if why ~= nil then
				Log(1, "normalize: dropped malformed record key=%s (%s)", TX_Util.Str(k), why)
				repaired = true
			else
				if rec.id ~= id then
					Log(1, "normalize: record key=%s had id=%s; fixed", k, TX_Util.Str(rec.id))
					rec.id = id
					repaired = true
				end
				-- Kick modes: a record saved before them has no mode and is a
				-- soft kick (silently); an unknown mode string is repaired.
				if rec.mode == nil then
					rec.mode = TX_Config.MODE_DEFAULT
				elseif TX_Config.MODE[rec.mode] ~= rec.mode then
					Log(1, "normalize: record %d had mode=%s; set to %s", id, rec.mode, TX_Config.MODE_DEFAULT)
					rec.mode = TX_Config.MODE_DEFAULT
					repaired = true
				end
				if rec.state == TX_Config.ST.PENDING_APPLY and not IsNum(rec.applied) then
					Log(1, "normalize: record %d had no applied flag; set to 0", id)
					rec.applied = 0
					repaired = true
				end
				store.recs[RecKey(id)] = rec
				ids[#ids + 1] = id
			end
		end
	end
	table.sort(ids)
	store.ids = ids

	local stored = raw.ids
	local same = (stored == nil and #ids == 0)
	if type(stored) == "table" and #TX_Util.SortedKeys(stored) == #ids then
		same = true
		for i = 1, #ids do
			if stored[i] ~= ids[i] then
				same = false
				break
			end
		end
	end
	if not same then
		Log(1, "normalize: ids disagree with the records (%d records); rebuilt from the records", #ids)
		repaired = true
	end

	local maxID = 0
	if #ids > 0 then
		maxID = ids[#ids]
	end
	if not IsNum(raw.nextID) then
		store.nextID = maxID + 1
		Log(1, "normalize: nextID missing; set to %d", store.nextID)
		repaired = true
	elseif raw.nextID <= maxID or raw.nextID < 1 then
		store.nextID = math.max(1, maxID + 1)
		Log(1, "normalize: nextID=%s not above the highest id %d; raised to %d", TX_Util.Str(raw.nextID), maxID, store.nextID)
		repaired = true
	else
		store.nextID = raw.nextID
	end
	return store, repaired
end

-- ---------------------------------------------------------------------------
-- TX_Store.Load() -> store, repaired
-- Reads TX_Store (pcall), deep copies and normalizes it. A read or normalize
-- error gives a fresh store with broken = 1, which Commit refuses to write
-- (a partial store must never overwrite the saved one; EFV_Records.Load).
-- Call once per handler; never cache the store across handlers.
-- ---------------------------------------------------------------------------
function TX_Store.Load()
	local turn = TX_Util.Turn()
	local okR, raw = pcall(function() return Game:GetProperty(TX_Config.PROP_STORE) end)
	if not okR then
		Log(1, "load: cannot read %s (%s); commit disabled", TX_Config.PROP_STORE, TX_Util.Str(raw))
		local broken = TX_Store.Fresh(turn)
		broken.broken = 1
		return broken, false
	end
	local okN, store, repaired = pcall(function()
		return TX_Store.Normalize(TX_Util.DeepCopy(raw), turn)
	end)
	if not okN then
		Log(1, "load: cannot normalize %s (%s); commit disabled", TX_Config.PROP_STORE, TX_Util.Str(store))
		local broken = TX_Store.Fresh(turn)
		broken.broken = 1
		return broken, false
	end
	Log(3, "load records=%d nextID=%d lastTurn=%d", #store.ids, store.nextID, store.lastTurn)
	return store, repaired
end

-- ---------------------------------------------------------------------------
-- TX_Store.Rev() -> number (TX_Rev, 0 when missing or unreadable)
-- ---------------------------------------------------------------------------
function TX_Store.Rev()
	local ok, v = pcall(function() return Game:GetProperty(TX_Config.PROP_REV) end)
	if ok and IsNum(v) then
		return v
	end
	return 0
end

-- ---------------------------------------------------------------------------
-- TX_Store.Shape(v) -> copy for writing
-- Empty tables and "" are left out, booleans become 0/1, functions, userdata
-- and threads are dropped with an ERROR line (EFV_Records.lua:140-160).
-- Arrays (keys 1..n) stay dense when an element is left out. Pure.
-- ---------------------------------------------------------------------------
local function IsArray(keys)
	if #keys == 0 then
		return false
	end
	for i, k in ipairs(keys) do
		if k ~= i then
			return false
		end
	end
	return true
end

local function ShapeValue(v, path, depth)
	local tv = type(v)
	if tv == "boolean" then
		if v then
			return 1
		end
		return 0
	elseif tv == "string" then
		if v == "" then
			return nil
		end
		return v
	elseif tv == "number" then
		return v
	elseif tv == "table" then
		if depth > MAX_DEPTH then
			error("Shape: nesting deeper than " .. MAX_DEPTH .. " at " .. path)
		end
		local keys = TX_Util.SortedKeys(v)
		local out = {}
		local n = 0
		if IsArray(keys) then
			for _, k in ipairs(keys) do
				local x = ShapeValue(v[k], path .. "[" .. k .. "]", depth + 1)
				if x ~= nil then
					n = n + 1
					out[n] = x
				end
			end
		else
			for _, k in ipairs(keys) do
				local x = ShapeValue(v[k], path .. "." .. tostring(k), depth + 1)
				if x ~= nil then
					n = n + 1
					out[k] = x
				end
			end
		end
		if n == 0 then
			return nil
		end
		return out
	elseif tv ~= "nil" then
		Log(1, "shape: dropped %s (type %s, not storable)", path, tv)
	end
	return nil
end

function TX_Store.Shape(store)
	local copy = {}
	if type(store) == "table" then
		for _, k in ipairs(TX_Util.SortedKeys(store)) do
			if k ~= "broken" then
				copy[k] = store[k]
			end
		end
	end
	return ShapeValue(copy, "store", 0) or {}
end

-- ---------------------------------------------------------------------------
-- TX_Store.Check(v) -> problems
-- The storage rules of PLAN II.2 as a list of problem texts (empty when the
-- value may be written). Mirror of fake_engine.lua ValidateStored, plus no
-- empty table, no empty string, no NaN or infinity. Pure.
-- ---------------------------------------------------------------------------
local function CheckValue(v, path, out, depth)
	local tv = type(v)
	if tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			out[#out + 1] = path .. ": not a finite number"
		end
		return
	end
	if tv == "string" then
		if v == "" then
			out[#out + 1] = path .. ": empty string"
		end
		return
	end
	if tv == "boolean" then
		out[#out + 1] = path .. ": boolean value (store 0/1)"
		return
	end
	if tv ~= "table" then
		out[#out + 1] = path .. ": unsupported type " .. tv
		return
	end
	if depth > MAX_DEPTH then
		out[#out + 1] = path .. ": nested too deep"
		return
	end
	local keys = TX_Util.SortedKeys(v)
	if #keys == 0 then
		out[#out + 1] = path .. ": empty table"
		return
	end
	local nStr, nNum, maxN = 0, 0, 0
	for _, k in ipairs(keys) do
		if type(k) == "string" then
			nStr = nStr + 1
		elseif type(k) == "number" then
			if k == 0 then
				out[#out + 1] = path .. ": key 0"
			elseif k ~= math.floor(k) or k < 0 then
				out[#out + 1] = path .. ": non-integer or negative key " .. tostring(k)
			else
				nNum = nNum + 1
				if k > maxN then
					maxN = k
				end
			end
		else
			out[#out + 1] = path .. ": key of type " .. type(k)
		end
		CheckValue(v[k], path .. "." .. tostring(k), out, depth + 1)
	end
	if nStr > 0 and nNum > 0 then
		out[#out + 1] = path .. ": mixed string and number keys"
	end
	if nNum > 0 and maxN ~= nNum then
		out[#out + 1] = path .. ": array with holes (max " .. maxN .. ", count " .. nNum .. ")"
	end
end

function TX_Store.Check(v)
	local out = {}
	CheckValue(v, "store", out, 0)
	return out
end

-- ---------------------------------------------------------------------------
-- TX_Store.Commit(store) -> true when written
-- Gameplay only. Refuses a broken store; Shape; Check (any problem: ERROR,
-- nothing written); Game:SetProperty("TX_Store", shaped), then TX_Rev + 1.
-- Handlers commit, then flush notifications (EFV order).
-- ---------------------------------------------------------------------------
-- TX:G-ONLY begin
function TX_Store.Commit(store)
	if UI ~= nil then
		Log(1, "commit refused: the UI never writes the store")
		return false
	end
	if type(store) ~= "table" then
		Log(1, "commit refused: no store")
		return false
	end
	if store.broken == 1 then
		Log(1, "commit refused: the store could not be read in this handler (broken)")
		return false
	end
	local okS, shaped = pcall(TX_Store.Shape, store)
	if not okS then
		Log(1, "commit refused: shape failed (%s)", TX_Util.Str(shaped))
		return false
	end
	local problems = TX_Store.Check(shaped)
	if #problems > 0 then
		Log(1, "commit refused, %d storage problem(s): %s", #problems, table.concat(problems, "; ", 1, math.min(#problems, 4)))
		return false
	end
	local okW, errW = pcall(function() Game:SetProperty(TX_Config.PROP_STORE, shaped) end)
	if not okW then
		Log(1, "commit: SetProperty %s failed (%s)", TX_Config.PROP_STORE, TX_Util.Str(errW))
		return false
	end
	local rev = TX_Store.Rev() + 1
	local okV, errV = pcall(function() Game:SetProperty(TX_Config.PROP_REV, rev) end)
	if not okV then
		Log(1, "commit: SetProperty %s failed (%s)", TX_Config.PROP_REV, TX_Util.Str(errV))
	end
	Log(3, "commit rev=%d records=%d nextID=%d", rev, #(store.ids or {}), tonumber(store.nextID) or 0)
	return true
end
-- TX:G-ONLY end

-- ---------------------------------------------------------------------------
-- Record access (pure)
-- ---------------------------------------------------------------------------
-- TX_Store.Add(store, rec) -> rec: id = nextID, appended to ids, recs["r"..id].
function TX_Store.Add(store, rec)
	local id = store.nextID
	rec.id = id
	store.nextID = id + 1
	store.ids[#store.ids + 1] = id
	store.recs[RecKey(id)] = rec
	return rec
end

-- TX_Store.Get(store, id) -> rec or nil (id may be a number or a numeric string).
function TX_Store.Get(store, id)
	local n = tonumber(id)
	if n == nil or type(store) ~= "table" or type(store.recs) ~= "table" then
		return nil
	end
	return store.recs[RecKey(n)]
end

-- TX_Store.Records(store) -> records in id order (the only iteration order).
function TX_Store.Records(store)
	local out = {}
	for _, id in ipairs(store.ids) do
		local rec = store.recs[RecKey(id)]
		if rec ~= nil then
			out[#out + 1] = rec
		end
	end
	return out
end

-- TX_Store.Trim(store, max) -> number dropped
-- Keeps at most max closed records (FAILED, EXPIRED, CANCELLED, DONE) and
-- drops the oldest beyond that. OPEN, PASSED and PENDING_APPLY are never dropped.
function TX_Store.Trim(store, max)
	local limit = tonumber(max) or TX_Config.HISTORY_MAX
	local closed = {}
	for _, rec in ipairs(TX_Store.Records(store)) do
		if IsClosed(rec.state) then
			closed[#closed + 1] = rec.id
		end
	end
	local drop = #closed - limit
	if drop <= 0 then
		return 0
	end
	local gone = {}
	for i = 1, drop do
		gone[closed[i]] = true
		store.recs[RecKey(closed[i])] = nil
	end
	local ids = {}
	for _, id in ipairs(store.ids) do
		if not gone[id] then
			ids[#ids + 1] = id
		end
	end
	store.ids = ids
	Log(3, "trim dropped %d closed record(s)", drop)
	return drop
end

TX_Store.LOADED = 1
