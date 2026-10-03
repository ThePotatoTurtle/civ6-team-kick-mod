-- ===========================================================================
-- TX_Dev_Lib.lua  (TX_Dev 0.0.1.1, spike kit for Team Expulsion 0.0.1)
-- TX:CONTEXT both
-- TX:GLOBALS TXD TX_Probe
--
-- Shared helpers of the spike panel (PLAN I.4). Included by both entry files:
--   Scripts/TX_Dev_Gameplay.lua  include("TX_Dev_Lib"); TXD.Init("G")
--   UI/TX_Dev_Panel.lua          include("TX_Dev_Lib"); TXD.Init("UI")
-- ImportFiles in TX_Dev.modinfo (the EFV.modinfo ImportFiles pattern).
--
-- Rules for this file:
--   * No engine call at load. The only engine call is Game.GetCurrentGameTurn
--     (G:C and UI:C) inside TXD.Turn, under pcall.
--   * It never names a context-only global. Each entry file passes its own
--     root table (TXD.SetRoots), so the probe and the dumper reach the engine
--     only through the roots of the context they run in.
--   * The only pairs() call is in TXD.SortedKeys (MP rule, api_audit).
--   * Every function closes over the local M, not over the global TXD, and
--     TX_Probe is the local Probe. Entry files keep their own copy with
--     "local TXD = TXD" / "local TX_Probe = TX_Probe". In game every context
--     is its own Lua state anyway; the offline tests run G and UI in one
--     state, where a second include() replaces the globals.
--
-- Log shapes (tools/summarize_log.py parses both):
--   [TX][SPIKE][<section>] <ctx> <text>
--   [TX][CHECK] <ID> PASS|FAIL|INFO T<turn> <ctx> <text>
-- ===========================================================================

local M = {}
TXD = M

M.VERSION = "0.0.1.1"
M.FOR_TX = "0.0.1"
M.ctx = "?"
M.roots = {}

-- ---------------------------------------------------------------------------
-- Basics
-- ---------------------------------------------------------------------------
function M.Init(ctx)
	if ctx == "G" then
		M.ctx = "G"
	else
		M.ctx = "UI"
	end
end

-- t[name] = function() return <global> end, one per root name (PLAN I.2).
function M.SetRoots(t)
	M.roots = t or {}
end

function M.Str(v)
	if v == nil then
		return "nil"
	end
	return tostring(v)
end

function M.Turn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then
		return t
	end
	return -1
end

-- true / false / nil to 1 / 0 / nil (Game properties store no booleans).
function M.B01(v)
	if v == nil then
		return nil
	end
	if v then
		return 1
	end
	return 0
end

function M.YN(v)
	if v == nil then
		return "?"
	end
	if v then
		return "yes"
	end
	return "no"
end

-- Keys of t sorted by type, then by value (numbers and strings) or tostring.
-- The only pairs() call of the kit.
function M.SortedKeys(t)
	local keys = {}
	if type(t) ~= "table" then
		return keys
	end
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		if ta == "number" or ta == "string" then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

-- ---------------------------------------------------------------------------
-- Log lines
-- ---------------------------------------------------------------------------
local function SectionName(s)
	local name = string.gsub(M.Str(s), "[^%w]", "")
	if name == "" then
		name = "MISC"
	end
	return name
end

function M.Spike(section, text)
	print("[TX][SPIKE][" .. SectionName(section) .. "] " .. M.ctx .. " " .. M.Str(text))
end

local VERDICTS = { PASS = true, FAIL = true, INFO = true }

function M.Check(id, verdict, text)
	local v = verdict
	local t = M.Str(text)
	if type(v) ~= "string" or not VERDICTS[v] then
		t = "BADVERDICT:" .. M.Str(verdict) .. " " .. t
		v = "INFO"
	end
	local cid = string.gsub(M.Str(id), "%s", "_")
	print("[TX][CHECK] " .. cid .. " " .. v .. " T" .. M.Turn() .. " " .. M.ctx .. " " .. t)
end

-- Splits a word list into lines of at most maxChars (default 180) characters.
function M.Chunk(words, maxChars)
	maxChars = maxChars or 180
	local lines, cur = {}, ""
	for _, w in ipairs(words or {}) do
		w = M.Str(w)
		if cur == "" then
			cur = w
		elseif string.len(cur) + 1 + string.len(w) <= maxChars then
			cur = cur .. " " .. w
		else
			lines[#lines + 1] = cur
			cur = w
		end
	end
	if cur ~= "" then
		lines[#lines + 1] = cur
	end
	return lines
end

-- ---------------------------------------------------------------------------
-- Never-call list (R "Never call"). Matched on "root.member" when the root
-- is a name, and always on the member-only list.
-- ---------------------------------------------------------------------------
M.NEVER = {
	"Game.SetWinningTeam",
	"GameConfiguration.RemovePlayer",
	"GameConfiguration.SetToDefaults",
	"PlayerConfigurations.SetSlotStatus",
	"PlayerConfigurations.SetMajorCiv",
	-- Session controls (MC2 "Objects": Network, UI). Their names match the
	-- Join/Leave grep, so S1 would offer them to S2 CALL as "setters".
	"Network.JoinGame",
	"Network.JoinGameByJoinCode",
	"Network.LeaveGame",
}
M.NEVER_MEMBER = { "SetWinningTeam", "SetToDefaults", "SetSlotStatus", "SetMajorCiv" }

local function StripMode(member)
	local s = M.Str(member)
	local c = string.sub(s, 1, 1)
	if c == ":" or c == "." or c == "?" or c == "=" or c == "#" then
		return string.sub(s, 2)
	end
	return s
end

function M.IsNever(rootName, member)
	if member == nil then
		return false
	end
	local name = StripMode(member)
	for _, n in ipairs(M.NEVER_MEMBER) do
		if name == n then
			return true
		end
	end
	if type(rootName) == "string" then
		local key = rootName .. "." .. name
		for _, n in ipairs(M.NEVER) do
			if key == n then
				return true
			end
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Resolver and probe
-- ---------------------------------------------------------------------------
-- Returns obj, path, err. root: a root name (TXD.SetRoots) or an object.
-- sel: nil or the index into the root. Every step runs in pcall.
-- path always names the whole expression, also when the root is missing.
function M.Resolve(root, sel)
	local obj, path
	if type(root) == "string" then
		path = root
	else
		path = "<" .. type(root) .. ">"
	end
	if sel ~= nil then
		path = path .. "[" .. M.Str(sel) .. "]"
	end
	if type(root) == "string" then
		local getter = M.roots[root]
		if getter == nil then
			return nil, path, "unknown root"
		end
		local ok, v = pcall(getter)
		if not ok then
			return nil, path, "ERR " .. M.Str(v)
		end
		obj = v
	else
		obj = root
	end
	if obj == nil then
		return nil, path, "nil"
	end
	if sel ~= nil then
		local ok, v = pcall(function() return obj[sel] end)
		if not ok then
			return nil, path, "ERR " .. M.Str(v)
		end
		if v == nil then
			return nil, path, "nil"
		end
		obj = v
	end
	return obj, path, nil
end

local function ArgText(args, n)
	local parts = {}
	for i = 1, n do
		local v = args[i]
		if type(v) == "string" then
			parts[i] = "\"" .. v .. "\""
		else
			parts[i] = M.Str(v)
		end
	end
	return table.concat(parts, ",")
end

local function Pack(...)
	return { n = select("#", ...), ... }
end

local function RetText(r)
	local parts = {}
	for i = 1, r.n do
		parts[i] = M.Str(r.rets[i])
	end
	return table.concat(parts, ",")
end

-- The spike probe (PLAN I.2). member modes, by first character:
--   ":Name" obj:Name(...)   ".Name" obj.Name(...)   "?Name" existence and type only
--   "=Name" field value      "#" length of obj        "" resolve obj only
-- A member without a mode character is called like ":Name".
-- label: a string logs "[TX][SPIKE][<first word>] <ctx> PROBE <label> <text>";
-- false logs nothing (the caller logs r.text or TXD.Tok(r) itself).
-- Returns { ok, refused, exists, n, rets, err, text, mode, obj }.
local function Probe(label, root, sel, member, ...)
	local args = { ... }
	local nargs = select("#", ...)
	local r = { ok = false, refused = false, exists = nil, n = 0, rets = {}, err = nil, text = "" }
	member = member or ""
	local mode = string.sub(member, 1, 1)
	local name = string.sub(member, 2)
	if member == "" then
		mode, name = "", ""
	elseif mode ~= ":" and mode ~= "." and mode ~= "?" and mode ~= "=" and mode ~= "#" then
		mode, name = ":", member
	end
	r.mode = mode
	local rootName = nil
	if type(root) == "string" then
		rootName = root
	end
	local obj, path, rerr = M.Resolve(root, sel)
	local desc
	if mode == "" then
		desc = path
	elseif mode == "#" then
		desc = "#" .. path
	elseif mode == "?" or mode == "=" then
		desc = path .. mode .. name
	else
		desc = path .. mode .. name .. "(" .. ArgText(args, nargs) .. ")"
	end
	local function Finish()
		r.text = desc .. " exists=" .. M.Str(r.exists) .. " ok=" .. tostring(r.ok) .. " ret=(" .. RetText(r) ..
			") err=" .. (r.err and M.Str(r.err) or "-")
		if r.refused then
			r.text = r.text .. " REFUSED never-call"
		end
		if type(label) == "string" then
			local first = string.match(label, "^%s*(%S+)") or "PROBE"
			M.Spike(first, "PROBE " .. label .. " " .. r.text)
		end
		return r
	end
	if obj == nil then
		if rerr == "nil" or rerr == "unknown root" then
			r.err = "MISSING root " .. M.Str(rerr)
		else
			r.err = "root " .. M.Str(rerr)
		end
		return Finish()
	end
	r.obj = obj
	if mode == "" then
		r.ok, r.exists, r.n = true, type(obj), 1
		r.rets[1] = obj
		return Finish()
	end
	if mode == "#" then
		r.exists = type(obj)
		local ok, len = pcall(function() return #obj end)
		if ok then
			r.ok, r.n = true, 1
			r.rets[1] = len
		else
			r.err = M.Str(len)
		end
		return Finish()
	end
	if (mode == ":" or mode == ".") and M.IsNever(rootName, name) then
		r.refused = true
		r.err = "never-call"
		return Finish()
	end
	local okI, v = pcall(function() return obj[name] end)
	if not okI then
		r.err = "index " .. M.Str(v)
		return Finish()
	end
	if v ~= nil then
		r.exists = type(v)
	end
	if mode == "?" then
		r.ok = true
		return Finish()
	end
	if mode == "=" then
		r.ok, r.n = true, 1
		r.rets[1] = v
		return Finish()
	end
	if v == nil then
		r.err = "MISSING"
		return Finish()
	end
	if type(v) ~= "function" then
		r.err = "not callable"
		return Finish()
	end
	local res
	if mode == ":" then
		res = Pack(pcall(v, obj, unpack(args, 1, nargs)))
	else
		res = Pack(pcall(v, unpack(args, 1, nargs)))
	end
	if res[1] then
		r.ok = true
		r.n = res.n - 1
		for i = 2, res.n do
			r.rets[i - 1] = res[i]
		end
	else
		r.err = M.Str(res[2])
	end
	return Finish()
end
TX_Probe = Probe

-- Short token of a probe result: value | MISSING | ERR:<msg> | REFUSED | nil.
-- An existence probe ("?") gives the member's type or nil.
function M.Tok(r)
	if type(r) ~= "table" then
		return "nil"
	end
	if r.refused then
		return "REFUSED"
	end
	if not r.ok then
		local e = M.Str(r.err)
		if string.sub(e, 1, 7) == "MISSING" then
			return "MISSING"
		end
		e = string.gsub(e, "%s+", "_")
		if string.len(e) > 80 then
			e = string.sub(e, 1, 80)
		end
		return "ERR:" .. e
	end
	if r.mode == "?" then
		return M.Str(r.exists)
	end
	if r.n == 0 then
		return "nil"
	end
	return RetText(r)
end

-- ---------------------------------------------------------------------------
-- Dumper (S1)
-- ---------------------------------------------------------------------------
-- No shipped Civ VI Lua uses rawget. For a key that pairs() returned, t[k]
-- gives the same value without metamethods (__index runs only for absent keys).
local rawget = rawget or function(t, k) return t[k] end

local TYPECHAR = { ["function"] = "f", table = "t", userdata = "u", number = "n", string = "s", boolean = "b" }
local GREP_WORDS = { "team", "join", "leave", "assign", "merge" }
local SETTER_PREFIX = { "Set", "Change", "Join", "Leave", "Assign", "Merge", "Add", "Remove", "Move", "Switch" }

function M.IsTeamKey(k)
	return string.find(string.lower(M.Str(k)), "team", 1, true) ~= nil
end

function M.IsGrepKey(k)
	local s = string.lower(M.Str(k))
	for _, w in ipairs(GREP_WORDS) do
		if string.find(s, w, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- "PlayerConfigurations[0]" -> "PlayerConfigurations", "Players[0]:GetDiplomacy()" -> "Players".
local function RootOf(objName)
	return string.match(M.Str(objName), "^([%a_][%w_]*)")
end

-- Returns true for a setter-like key, or false, "never" for a never-list name.
function M.IsSetterKey(objName, k)
	local key = M.Str(k)
	local cand = false
	if RootOf(objName) == "Teams" and (key == "AddPlayer" or key == "RemovePlayer") then
		cand = true
	elseif M.IsGrepKey(key) and key ~= "SetTeamName" then
		for _, pre in ipairs(SETTER_PREFIX) do
			if string.sub(key, 1, string.len(pre)) == pre then
				cand = true
				break
			end
		end
	end
	if not cand then
		return false
	end
	if M.IsNever(RootOf(objName), key) then
		return false, "never"
	end
	return true
end

-- Walks obj, its metatable and the __index chain (PLAN I.4 dumper rules).
-- Never calls a value; table values are read with rawget, for keys pairs gave.
-- Returns { keys = { {k, t, via} }, notes, team, grep, setters }.
function M.Dump(name, obj, maxDepth)
	maxDepth = maxDepth or 4
	local res = { keys = {}, notes = {}, team = {}, grep = {}, setters = {} }
	local seen, visited = {}, {}
	local function Note(s)
		res.notes[#res.notes + 1] = s
	end
	local function Add(k, v, via)
		local ks = M.Str(k)
		if seen[ks] then
			return
		end
		seen[ks] = true
		local tc = TYPECHAR[type(v)] or "?"
		local ann = ks .. "(" .. tc .. ")"
		res.keys[#res.keys + 1] = { k = ks, t = tc, via = via }
		if M.IsTeamKey(ks) then
			res.team[#res.team + 1] = ann
		end
		if M.IsGrepKey(ks) then
			res.grep[#res.grep + 1] = ann
		end
		local isSetter, why = M.IsSetterKey(name, ks)
		if isSetter then
			res.setters[#res.setters + 1] = ks
		elseif why == "never" then
			Note("never-call key " .. ks .. " left out of the setters")
		end
	end
	local function Walk(o, level, path)
		local to = type(o)
		if to ~= "table" and to ~= "userdata" then
			Note(path .. " is a " .. to)
			return
		end
		if visited[o] then
			Note("cycle at " .. path)
			return
		end
		visited[o] = true
		local via, mvia = "self", "mt"
		if level > 0 then
			via, mvia = "__index" .. level, "mt" .. level
		end
		if to == "table" then
			for _, k in ipairs(M.SortedKeys(o)) do
				Add(k, rawget(o, k), via)
			end
		end
		local okMt, mt = pcall(getmetatable, o)
		if not okMt then
			Note("getmetatable failed at " .. path .. ": " .. M.Str(mt))
			return
		end
		if mt == nil then
			return
		end
		if type(mt) ~= "table" then
			Note("metatable protected: " .. M.Str(mt) .. " at " .. path)
			return
		end
		for _, k in ipairs(M.SortedKeys(mt)) do
			Add(k, rawget(mt, k), mvia)
		end
		local idx = rawget(mt, "__index")
		local ti = type(idx)
		if ti == "table" or ti == "userdata" then
			if level + 1 > maxDepth then
				Note("depth limit at " .. path .. ".__index")
			else
				Walk(idx, level + 1, path .. ".__index")
			end
		elseif ti == "function" then
			Note("__index is a function (opaque) at " .. path)
		end
	end
	Walk(obj, 0, M.Str(name))
	return res
end

local function LogList(section, head, list)
	if #list == 0 then
		M.Spike(section, head .. ": none")
		return
	end
	local lines = M.Chunk(list, 180)
	for i, l in ipairs(lines) do
		if #lines == 1 then
			M.Spike(section, head .. ": " .. l)
		else
			M.Spike(section, head .. " " .. i .. "/" .. #lines .. ": " .. l)
		end
	end
end

-- Team line, grep line, every key in chunks, then notes and setters.
-- The key list carries a "<via>" word whenever the source level changes.
function M.LogDump(section, name, res)
	LogList(section, name .. " team", res.team)
	LogList(section, name .. " grep", res.grep)
	local words, via = {}, nil
	for _, e in ipairs(res.keys) do
		if e.via ~= via then
			via = e.via
			words[#words + 1] = "<" .. M.Str(via) .. ">"
		end
		words[#words + 1] = e.k .. "(" .. e.t .. ")"
	end
	local lines = M.Chunk(words, 180)
	if #lines == 0 then
		M.Spike(section, name .. " all(0): none")
	end
	for i, l in ipairs(lines) do
		M.Spike(section, name .. " all(" .. #res.keys .. ") " .. i .. "/" .. #lines .. ": " .. l)
	end
	if #res.notes > 0 then
		LogList(section, name .. " notes", res.notes)
	end
	if #res.setters > 0 then
		LogList(section, name .. " setters", res.setters)
	end
end

-- The 13 S1 targets of TP 1.1 plus Players[0]:GetTechs() (V4: TriggerBoost?).
-- sel "team0" = Players[0]:GetTeam().
M.DUMP_TARGETS = {
	{ name = "Players[0]", root = "Players", sel = 0 },
	{ name = "PlayerConfigurations[0]", root = "PlayerConfigurations", sel = 0 },
	{ name = "Game", root = "Game" },
	{ name = "GameConfiguration", root = "GameConfiguration" },
	{ name = "PlayerManager", root = "PlayerManager" },
	{ name = "DiplomacyManager", root = "DiplomacyManager" },
	{ name = "Players[0]:GetDiplomacy()", root = "Players", sel = 0, call = ":GetDiplomacy" },
	{ name = "Teams", root = "Teams" },
	{ name = "Teams[t]", root = "Teams", sel = "team0" },
	{ name = "Network", root = "Network" },
	{ name = "PlayersVisibility", root = "PlayersVisibility" },
	{ name = "PlayersVisibility[0]", root = "PlayersVisibility", sel = 0 },
	{ name = "DealManager", root = "DealManager" },
	{ name = "Players[0]:GetTechs()", root = "Players", sel = 0, call = ":GetTechs" },
}

-- Returns obj or nil, token.
function M.ResolveTarget(tg)
	local sel = tg.sel
	if sel == "team0" then
		local rt = Probe(false, "Players", 0, ":GetTeam")
		if not rt.ok or rt.rets[1] == nil then
			return nil, "Players[0]:GetTeam()=" .. M.Tok(rt)
		end
		sel = rt.rets[1]
	end
	local r
	if tg.call ~= nil then
		r = Probe(false, tg.root, sel, tg.call)
	else
		r = Probe(false, tg.root, sel, "")
	end
	if r.ok and r.rets[1] ~= nil then
		return r.rets[1], nil
	end
	return nil, M.Tok(r)
end

-- Dumps every target in this context. Returns the setter-like keys as
-- { {obj = targetName, key = k}, ... } in target order.
function M.DumpAll(section)
	local found = {}
	for _, tg in ipairs(M.DUMP_TARGETS) do
		local obj, tok = M.ResolveTarget(tg)
		if obj == nil then
			M.Spike(section, tg.name .. " = " .. M.Str(tok))
		else
			local res = M.Dump(tg.name, obj, 4)
			M.LogDump(section, tg.name, res)
			for _, k in ipairs(res.setters) do
				found[#found + 1] = { obj = tg.name, key = k }
			end
		end
	end
	return found
end

-- ---------------------------------------------------------------------------
-- Team map
-- ---------------------------------------------------------------------------
-- rows { {pid, team}, ... } -> { {team, members = {...}} } sorted by team, then pid.
function M.TeamGroups(rows)
	local byTeam, teams = {}, {}
	for _, r in ipairs(rows or {}) do
		local t = r.team
		if type(t) == "number" then
			if byTeam[t] == nil then
				byTeam[t] = {}
				teams[#teams + 1] = t
			end
			local list = byTeam[t]
			list[#list + 1] = r.pid
		end
	end
	table.sort(teams)
	local out = {}
	for _, t in ipairs(teams) do
		local members = byTeam[t]
		table.sort(members)
		out[#out + 1] = { team = t, members = members }
	end
	return out
end

-- "0={0,1} 1={2,3}"
function M.GroupsText(groups)
	local parts = {}
	for _, g in ipairs(groups or {}) do
		local m = {}
		for i, pid in ipairs(g.members) do
			m[i] = M.Str(pid)
		end
		parts[#parts + 1] = M.Str(g.team) .. "={" .. table.concat(m, ",") .. "}"
	end
	if #parts == 0 then
		return "none"
	end
	return table.concat(parts, " ")
end

-- Live and config teams of every row (dead players count), ascending, unique.
function M.UsedTeams(rows)
	local set, out = {}, {}
	for _, r in ipairs(rows or {}) do
		for _, t in ipairs({ r.team, r.cfg }) do
			if type(t) == "number" and not set[t] then
				set[t] = true
				out[#out + 1] = t
			end
		end
	end
	table.sort(out)
	return out
end

-- Lowest integer >= 0 not in used (NO_TEAM = -1 and other negatives ignored).
function M.UnusedTeam(used)
	local set = {}
	for _, t in ipairs(used or {}) do
		if type(t) == "number" then
			set[t] = true
		end
	end
	local t = 0
	while set[t] do
		t = t + 1
	end
	return t
end

-- R A1 "solo team numbering": among players alone on their live team
-- (rows with other = 1, Free Cities and Barbarians, are left out),
-- how many have team == pid. Returns k, n.
function M.SoloIdStats(rows)
	local count = {}
	for _, r in ipairs(rows or {}) do
		if type(r.team) == "number" then
			count[r.team] = (count[r.team] or 0) + 1
		end
	end
	local k, n = 0, 0
	for _, r in ipairs(rows or {}) do
		if type(r.team) == "number" and count[r.team] == 1 and tonumber(r.other) ~= 1 then
			n = n + 1
			if r.team == r.pid then
				k = k + 1
			end
		end
	end
	return k, n
end

-- Roles (PLAN I.8). rows { {pid, team, alive = 0|1, major = 0|1} }.
-- keeper: lowest alive major with the target's team; other: lowest alive
-- major on another team. -1 when there is none.
function M.PickRoles(rows, target)
	local tTeam = nil
	for _, r in ipairs(rows or {}) do
		if r.pid == target then
			tTeam = r.team
		end
	end
	local keeper, other = -1, -1
	local sorted = {}
	for _, r in ipairs(rows or {}) do
		sorted[#sorted + 1] = r
	end
	table.sort(sorted, function(a, b) return a.pid < b.pid end)
	for _, r in ipairs(sorted) do
		if tonumber(r.alive) == 1 and tonumber(r.major) == 1 and r.pid ~= target and r.pid < 62 then
			if r.team == tTeam and tTeam ~= nil then
				if keeper < 0 then
					keeper = r.pid
				end
			elseif other < 0 then
				other = r.pid
			end
		end
	end
	return keeper, other
end

-- ---------------------------------------------------------------------------
-- Phases and check IDs (PLAN I.2)
-- ---------------------------------------------------------------------------
function M.PhaseLabel(arm)
	local s
	if type(arm) ~= "table" or arm.phase == nil or arm.phase == "BASE" then
		s = "BASE"
	elseif arm.phase == "LIVE" then
		s = M.Str(arm.path) .. "LIVE"
	elseif arm.phase == "RELOAD" then
		s = M.Str(arm.path) .. "RELOAD" .. M.Str(tonumber(arm.loads) or 0)
	else
		s = M.Str(arm.phase)
	end
	if type(arm) == "table" and tonumber(arm.mp) == 1 then
		s = "MP-" .. s
	end
	return s
end

function M.IsBase(label)
	return label == "BASE" or label == "MP-BASE"
end

function M.CheckId(item, arm)
	return M.Str(item) .. "-" .. M.ctx .. "." .. M.PhaseLabel(arm)
end

-- ---------------------------------------------------------------------------
-- Verdicts (PLAN I.8). Each returns verdict, text. Phase BASE gives INFO.
-- ---------------------------------------------------------------------------
M.Verdict = {}
local INC = "INCONCLUSIVE: "

-- target and keeper live teams
function M.Verdict.V1(phase, tTeam, kTeam)
	local facts = "target team " .. M.Str(tTeam) .. ", keeper team " .. M.Str(kTeam)
	if M.IsBase(phase) then
		return "INFO", facts .. " (before the change)"
	end
	if tTeam == nil or kTeam == nil then
		return "INFO", INC .. "team unreadable; " .. facts
	end
	if tTeam ~= kTeam then
		return "PASS", facts .. ": they differ"
	end
	return "FAIL", facts .. ": still the same team"
end

-- One arm.v4 entry. entryPath: the path when the units were made.
function M.Verdict.V4(phase, entryPath, kB, tB, what)
	local facts = M.Str(what) .. " keeper boosted=" .. M.YN(kB) .. " target boosted=" .. M.YN(tB)
	if M.IsBase(phase) or entryPath == nil or entryPath == "BASE" then
		local shared = ""
		if kB and tB then
			shared = " (boost shared before the change: the control works)"
		elseif kB and tB == false then
			shared = " (boost NOT shared even before the change)"
		end
		return "INFO", "control, made before the change: " .. facts .. shared
	end
	if kB == nil or tB == nil then
		return "INFO", INC .. "boost state unreadable; " .. facts
	end
	if not kB then
		return "INFO", INC .. "units made by script don't trigger the boost; do V4 by hand; " .. facts
	end
	if tB then
		return "FAIL", facts .. ": boost still shared"
	end
	return "PASS", facts
end

-- Marker plot seen by keeper / target; nearest target asset distance.
function M.Verdict.V5(phase, kSees, tSees, nearest)
	local facts = "keeper sees=" .. M.YN(kSees) .. " target sees=" .. M.YN(tSees) .. " nearest target asset=" .. M.Str(nearest)
	if M.IsBase(phase) then
		if tSees == false then
			return "INFO", INC .. "target does not see the marker before the change, so vision is not shared and V5 is invalid; " .. facts
		end
		return "INFO", facts .. " (before the change: the target should see it)"
	end
	if kSees == nil or tSees == nil then
		return "INFO", INC .. "visibility unreadable; " .. facts
	end
	if nearest ~= nil and nearest <= 3 then
		return "INFO", INC .. "a target unit or city is within 3 tiles; " .. facts
	end
	if not kSees then
		return "INFO", INC .. "control failed, the keeper does not see its own marker; " .. facts
	end
	if tSees then
		return "FAIL", facts .. ": vision still shared"
	end
	return "PASS", facts
end

-- other at war with keeper (control) / with target.
function M.Verdict.V6(phase, owk, owt)
	local facts = "other at war with keeper=" .. M.YN(owk) .. ", with target=" .. M.YN(owt)
	if M.IsBase(phase) then
		return "INFO", facts
	end
	if owk == nil or owt == nil then
		return "INFO", INC .. "war state unreadable; " .. facts
	end
	if not owk then
		return "INFO", INC .. "control failed, the other is not at war with the keeper; " .. facts
	end
	if owt then
		return "FAIL", facts .. ": the target was dragged into the war"
	end
	return "PASS", facts
end

local V9_KEYS = { "ob12", "ob21", "gpt" }

-- base / now: { ob12, ob21, gpt } as 0/1 (ob12: target grants other open borders).
function M.Verdict.V9(phase, base, now)
	local function Facts(t)
		if type(t) ~= "table" then
			return "-"
		end
		return "ob12=" .. M.Str(t.ob12) .. " ob21=" .. M.Str(t.ob21) .. " gpt=" .. M.Str(t.gpt)
	end
	local facts = "base " .. Facts(base) .. " now " .. Facts(now)
	if M.IsBase(phase) then
		return "INFO", facts
	end
	if type(base) ~= "table" then
		return "INFO", INC .. "no BASE record; " .. facts
	end
	local present, lost = 0, {}
	for _, k in ipairs(V9_KEYS) do
		if tonumber(base[k]) == 1 then
			present = present + 1
			if type(now) ~= "table" or tonumber(now[k]) ~= 1 then
				lost[#lost + 1] = k
			end
		end
	end
	if present == 0 then
		return "INFO", INC .. "no deal at BASE; " .. facts
	end
	if #lost == 0 then
		return "PASS", facts .. ": every BASE deal is still there"
	end
	return "FAIL", facts .. ": gone " .. table.concat(lost, ",")
end

-- base: 1 when target and other were friends at BASE; ab / ba: now, both ways.
function M.Verdict.V10(phase, base, ab, ba)
	local facts = "base friends=" .. M.Str(base) .. " now target->other=" .. M.YN(ab) .. " other->target=" .. M.YN(ba)
	if M.IsBase(phase) then
		return "INFO", facts
	end
	if tonumber(base) ~= 1 then
		return "INFO", INC .. "no friendship at BASE; " .. facts
	end
	if ab == nil or ba == nil then
		return "INFO", INC .. "friendship unreadable; " .. facts
	end
	if ab and ba then
		return "PASS", facts .. ": still friends"
	end
	return "FAIL", facts .. ": friendship gone"
end

-- members: the winning team's members (nil when no victory);
-- ownsAll: the V3 attacker holds every enemy original capital.
function M.Verdict.V3(phase, members, keeper, target, ownsAll)
	if type(members) == "table" then
		local hasK, hasT, list = false, false, {}
		for _, pid in ipairs(members) do
			list[#list + 1] = M.Str(pid)
			if pid == keeper then
				hasK = true
			end
			if pid == target then
				hasT = true
			end
		end
		local facts = "victory members={" .. table.concat(list, ",") .. "} keeper=P" .. M.Str(keeper) .. " target=P" .. M.Str(target)
		if M.IsBase(phase) then
			return "INFO", facts
		end
		if hasK and hasT then
			return "FAIL", facts .. ": victory still shared"
		end
		if hasK or hasT then
			return "PASS", facts .. ": only one of them won"
		end
		return "INFO", facts .. ": neither keeper nor target won"
	end
	local facts = "no victory; attacker holds every enemy original capital=" .. M.YN(ownsAll)
	if M.IsBase(phase) then
		return "INFO", facts
	end
	if ownsAll then
		return "PASS", facts .. " and no victory fired (the target is now a rival)"
	end
	return "INFO", facts
end

-- ---------------------------------------------------------------------------
-- Misc pure helpers
-- ---------------------------------------------------------------------------
-- V12: h = (h*31 + byte) % 2147483647 over s.
function M.Fingerprint(s)
	local h = 0
	s = M.Str(s)
	for i = 1, string.len(s) do
		h = (h * 31 + string.byte(s, i)) % 2147483647
	end
	return h
end

-- Flat values to prefixed request params (numbers, non-empty strings; booleans as 1/0).
function M.Flatten(prefix, t)
	local out = {}
	for _, k in ipairs(M.SortedKeys(t)) do
		local v = t[k]
		if type(v) == "boolean" then
			v = M.B01(v)
		end
		if type(v) == "number" or (type(v) == "string" and v ~= "") then
			out[prefix .. M.Str(k)] = v
		end
	end
	return out
end

-- Request params back to flat values (keys with the prefix only). Returns t, n.
function M.Unflatten(params, prefix)
	local out, n = {}, 0
	local len = string.len(prefix)
	for _, k in ipairs(M.SortedKeys(params)) do
		if type(k) == "string" and string.len(k) > len and string.sub(k, 1, len) == prefix then
			local v = params[k]
			if type(v) == "number" or (type(v) == "string" and v ~= "") then
				out[string.sub(k, len + 1)] = v
				n = n + 1
			end
		end
	end
	return out, n
end

-- cands { {x, y, idx} }, assets { {x, y} }, dist(x1, y1, x2, y2).
-- Returns the candidate with the largest minimum distance (ties: lowest idx), and that distance.
function M.FarthestPlot(cands, assets, dist)
	local best, bestD = nil, nil
	for _, c in ipairs(cands or {}) do
		local d = 9999
		for _, a in ipairs(assets or {}) do
			local x = dist(c.x, c.y, a.x, a.y)
			if type(x) == "number" and x < d then
				d = x
			end
		end
		if best == nil or d > bestD or (d == bestD and c.idx < best.idx) then
			best, bestD = c, d
		end
	end
	return best, bestD
end

M.BOOST_OWN_UNITS = "BOOST_TRIGGER_OWN_X_UNITS_OF_TYPE"

-- rows: GameInfo.Boosts rows. usable(row) -> bool, techIndex(techType) -> index or nil,
-- isLand(unitType) -> bool. Returns the row with the lowest tech index that
-- has the own-units class, a tech, a land unit and is usable; and the index.
function M.PickBoost(rows, usable, techIndex, isLand)
	local best, bestIdx = nil, nil
	for _, row in ipairs(rows or {}) do
		if row.BoostClass == M.BOOST_OWN_UNITS and row.TechnologyType ~= nil and row.Unit1Type ~= nil then
			local idx = techIndex(row.TechnologyType)
			if type(idx) == "number" and isLand(row.Unit1Type) and usable(row) then
				if bestIdx == nil or idx < bestIdx then
					best, bestIdx = row, idx
				end
			end
		end
	end
	return best, bestIdx
end

-- ---------------------------------------------------------------------------
-- S2 candidate setters (R A2 and "Candidate team setters"). Argument shapes are
-- guesses and are logged as used. sel: "target" | "origTeam" | nil.
-- args: "team" | "player" | "player,team" | "none".
-- ---------------------------------------------------------------------------
M.SETTERS = {}
local function AddSetters(root, sel, names, style, args)
	for _, n in ipairs(names) do
		M.SETTERS[#M.SETTERS + 1] = { root = root, sel = sel, name = n, style = style, args = args }
	end
end
AddSetters("PlayerConfigurations", "target", { "SetTeam", "SetTeamName" }, ":", "team")
AddSetters("Players", "target", { "SetTeam", "ChangeTeam", "JoinTeam" }, ":", "team")
AddSetters("Players", "target", { "LeaveTeam" }, ":", "none")
AddSetters("Players", "target", { "SetTeamID" }, ":", "team")
AddSetters("Teams", "origTeam", { "AddTeam", "Merge", "SetTeam" }, ":", "team")
AddSetters("Teams", "origTeam", { "AddPlayer", "RemovePlayer" }, ":", "player")
AddSetters("Game", nil, { "SetTeam", "SetPlayerTeam", "ChangePlayerTeam", "AssignTeam" }, ".", "player,team")
AddSetters("PlayerManager", nil, { "SetTeam", "SetPlayerTeam", "ChangePlayerTeam", "AssignTeam" }, ".", "player,team")
AddSetters("GameConfiguration", nil, { "SetTeam", "SetPlayerTeam", "ChangePlayerTeam", "AssignTeam" }, ".", "player,team")

local MANAGER_ROOTS = { Game = true, GameConfiguration = true, PlayerManager = true, DiplomacyManager = true,
	Network = true, DealManager = true, PlayersVisibility = true, Teams = true }

-- The default call shape for a setter-like key S1 found (PLAN I.4).
-- objName: an S1 dump target name. Returns a SETTERS-like row or nil.
function M.SetterFromKey(objName, key)
	local name = M.Str(objName)
	if name == "Players[0]" then
		return { root = "Players", sel = "target", name = key, style = ":", args = "team" }
	elseif name == "PlayerConfigurations[0]" then
		return { root = "PlayerConfigurations", sel = "target", name = key, style = ":", args = "team" }
	elseif name == "Teams[t]" then
		local args = "team"
		if string.find(M.Str(key), "Player", 1, true) then
			args = "player"
		end
		return { root = "Teams", sel = "origTeam", name = key, style = ":", args = args }
	elseif MANAGER_ROOTS[name] then
		return { root = name, sel = nil, name = key, style = ".", args = "player,team" }
	end
	return nil
end

-- SETTERS plus the S1 keys (found: { {obj, key} }), without duplicates.
function M.SetterCandidates(found)
	local out, seen = {}, {}
	local function Push(c)
		if c == nil or M.IsNever(c.root, c.name) then
			return
		end
		local id = M.Str(c.root) .. "|" .. M.Str(c.sel) .. "|" .. M.Str(c.name)
		if not seen[id] then
			seen[id] = true
			out[#out + 1] = c
		end
	end
	for _, c in ipairs(M.SETTERS) do
		Push(c)
	end
	for _, f in ipairs(found or {}) do
		Push(M.SetterFromKey(f.obj, f.key))
	end
	return out
end

function M.SelValue(sel, target, origTeam)
	if sel == "target" then
		return target
	elseif sel == "origTeam" then
		return origTeam
	end
	return nil
end

-- Argument list for a setter row. Returns args, n.
function M.SetterArgs(args, target, team)
	if args == "none" then
		return {}, 0
	elseif args == "player" then
		return { target }, 1
	elseif args == "player,team" then
		return { target, team }, 2
	end
	return { team }, 1
end

function M.SetterText(c)
	local sel = ""
	if c.sel ~= nil and c.sel ~= "-" then
		sel = "[" .. M.Str(c.sel) .. "]"
	end
	return M.Str(c.root) .. sel .. M.Str(c.style) .. M.Str(c.name) .. "(" .. M.Str(c.args) .. ")"
end
