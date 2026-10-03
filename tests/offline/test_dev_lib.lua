-- Tests of TX_Dev/Scripts/TX_Dev_Lib.lua (PLAN I.10): the dumper, the probe
-- wrapper, the team map helpers, phase labels, verdicts and the log shapes.
-- Only the lib is loaded; roots are plain test tables.

local LIB = "TX_Dev/Scripts/TX_Dev_Lib.lua"

local function Load(ctx)
	H.world{}
	FAKE.dofile(LIB)
	TXD.Init(ctx or "G")
	H.markBody()
end

local CHECK_VERDICTS = { PASS = true, FAIL = true, INFO = true }

-- Every line the lib prints has one of the two shapes of PLAN I.2.
local function AssertShapes()
	for _, l in ipairs(H.lines()) do
		if string.sub(l, 1, 11) == "[TX][CHECK]" then
			local v, ctx = string.match(l, "^%[TX%]%[CHECK%] %S+ (%u+) T%-?%d+ (%u+) ")
			H.ok(v ~= nil and CHECK_VERDICTS[v] and (ctx == "G" or ctx == "UI"), "CHECK line shape: " .. l)
		else
			local ctx = string.match(l, "^%[TX%]%[SPIKE%]%[[%w]+%] (%u+) ")
			H.ok(ctx == "G" or ctx == "UI", "SPIKE line shape: " .. l)
		end
	end
end

local function KeyVia(res, k)
	for _, e in ipairs(res.keys) do
		if e.k == k then return e.via end
	end
	return nil
end

local function HasNote(res, text)
	for _, n in ipairs(res.notes) do
		if string.find(n, text, 1, true) then return true end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Dumper
-- ---------------------------------------------------------------------------
test("dump: self, __index1, __index2 via labels", function()
	Load()
	local B = { BKey = function() end }
	local A = setmetatable({ AKey = 1 }, { __index = B })
	local obj = setmetatable({ OwnKey = "x" }, { __index = A })
	local res = TXD.Dump("obj", obj, 4)
	H.eq(KeyVia(res, "OwnKey"), "self")
	H.eq(KeyVia(res, "AKey"), "__index1")
	H.eq(KeyVia(res, "BKey"), "__index2")
	H.eq(KeyVia(res, "__index"), "mt", "metatable keys are recorded with via mt")
	H.len(res.notes, 0)
end)

test("dump: cycle in the __index chain ends the walk", function()
	Load()
	local A, B = { AKey = 1 }, { BKey = 2 }
	setmetatable(A, { __index = B })
	setmetatable(B, { __index = A })
	local obj = setmetatable({}, { __index = A })
	local res = TXD.Dump("obj", obj, 8)
	H.ok(HasNote(res, "cycle at obj.__index.__index.__index"), H.Ser(res.notes))
	H.eq(KeyVia(res, "BKey"), "__index2")
end)

test("dump: depth guard on a chain of 6", function()
	Load()
	local chain = { K6 = 6 }
	for i = 5, 1, -1 do
		chain = setmetatable({ ["K" .. i] = i }, { __index = chain })
	end
	local obj = setmetatable({ K0 = 0 }, { __index = chain })
	local res = TXD.Dump("obj", obj, 4)
	H.ok(HasNote(res, "depth limit at"), H.Ser(res.notes))
	H.eq(KeyVia(res, "K4"), "__index4")
	H.isnil(KeyVia(res, "K5"), "level 5 is past maxDepth 4")
end)

test("dump: __index function is opaque, protected metatable is noted", function()
	Load()
	local obj = setmetatable({ A = 1 }, { __index = function() error("never call me") end })
	local res = TXD.Dump("o", obj)
	H.ok(HasNote(res, "__index is a function (opaque)"), H.Ser(res.notes))
	local locked = setmetatable({ B = 1 }, { __metatable = "locked" })
	res = TXD.Dump("l", locked)
	H.ok(HasNote(res, "metatable protected: locked"), H.Ser(res.notes))
	H.eq(KeyVia(res, "B"), "self")
end)

test("dump: userdata with a metatable (newproxy)", function()
	Load()
	if newproxy == nil then H.skip("newproxy is not available") end
	local u = newproxy(true)
	getmetatable(u).__index = { GetTeam = function() return 0 end, SetTeam = function() end }
	local res = TXD.Dump("Players[0]", u)
	H.eq(KeyVia(res, "GetTeam"), "__index1")
	H.eq(KeyVia(res, "__index"), "mt")
	H.deq(res.setters, { "SetTeam" })
end)

test("dump: team, grep and setter filters", function()
	Load()
	local obj = { JoinTeam = 1, AssignX = 2, Merge = 3, GetTeam = 4, SetTeamName = 5, SetTeam = 6, Unrelated = 7,
		SetWinningTeam = 8 }
	local res = TXD.Dump("Game", obj)
	H.deq(res.team, { "GetTeam(n)", "JoinTeam(n)", "SetTeam(n)", "SetTeamName(n)", "SetWinningTeam(n)" })
	H.deq(res.grep, { "AssignX(n)", "GetTeam(n)", "JoinTeam(n)", "Merge(n)", "SetTeam(n)", "SetTeamName(n)", "SetWinningTeam(n)" })
	H.deq(res.setters, { "AssignX", "JoinTeam", "Merge", "SetTeam" })
	H.ok(HasNote(res, "never-call key SetWinningTeam"), H.Ser(res.notes))
	H.ok(not TXD.IsSetterKey("Players[0]", "SetTeamName"))
	H.ok(not TXD.IsSetterKey("Players[0]", "GetTeam"))
	H.ok(TXD.IsSetterKey("Teams[t]", "AddPlayer"), "Teams objects: AddPlayer counts")
	H.ok(not TXD.IsSetterKey("Players[0]", "AddPlayer"))
	local ok, why = TXD.IsSetterKey("Game", "SetWinningTeam")
	H.eq(ok, false)
	H.eq(why, "never")
end)

test("dump: LogDump chunks the key list, every key once", function()
	Load()
	local obj = {}
	for i = 1, 120 do obj["SomeLongKeyName_" .. i] = i end
	obj.SetTeam = function() end
	local res = TXD.Dump("Big", obj)
	TXD.LogDump("S1", "Big", res)
	local seen, count = {}, 0
	for _, l in ipairs(H.lines("[TX][SPIKE][S1] G Big all(")) do
		local body = string.match(l, "^%[TX%]%[SPIKE%]%[S1%] G Big all%(%d+%) %d+/%d+: (.*)$")
		H.notnil(body, l)
		H.ok(string.len(body) <= 180, "chunk longer than 180: " .. string.len(body))
		for w in string.gmatch(body, "%S+") do
			if string.sub(w, 1, 1) ~= "<" then
				H.isnil(seen[w], "key twice: " .. w)
				seen[w] = true
				count = count + 1
			end
		end
	end
	H.eq(count, 121)
	H.ok(seen["SetTeam(f)"])
	H.ok(H.hasLine("[TX][SPIKE][S1] G Big team: SetTeam(f)"))
	H.ok(H.hasLine("[TX][SPIKE][S1] G Big setters: SetTeam"))
	AssertShapes()
end)

test("dump: values are never called", function()
	Load()
	local called = false
	local obj = setmetatable({ Boom = function() called = true; error("called") end },
		{ __index = { Boom2 = function() called = true end } })
	local res = TXD.Dump("o", obj)
	TXD.LogDump("S1", "o", res)
	H.ok(not called)
	H.eq(#res.keys, 3, "Boom, __index, Boom2")
end)

-- ---------------------------------------------------------------------------
-- Probe wrapper
-- ---------------------------------------------------------------------------
local function ProbeRoots()
	local calls = {}
	local cfg = {
		SetTeam = function(self, t) calls[#calls + 1] = { self = self, t = t }; return nil end,
		Pair = function(self) return 1, "two", nil end,
		Raise = function() error("boom inside") end,
		Field = 42,
	}
	local game = {
		Static = function(a, b) calls[#calls + 1] = { a = a, b = b }; return a + b end,
		SetWinningTeam = function() calls[#calls + 1] = "WIN" end,
		GOLD = 7,
	}
	TXD.SetRoots({
		PlayerConfigurations = function() return { [1] = cfg } end,
		Game = function() return game end,
		List = function() return { 1, 2, 3 } end,
		Broken = function() error("root getter failed") end,
	})
	return calls, cfg, game
end

test("probe: missing root, missing member, not callable, raising call", function()
	Load("UI")
	ProbeRoots()
	local r = TX_Probe(false, "Teams", 1, ":AddTeam", 5)
	H.isnil(r.exists)
	H.eq(r.ok, false)
	H.ok(string.find(r.text, "Teams[1]:AddTeam(5)", 1, true), r.text)
	H.eq(TXD.Tok(r), "MISSING")
	r = TX_Probe(false, "PlayerConfigurations", 1, ":Nope")
	H.eq(TXD.Tok(r), "MISSING")
	H.eq(r.ok, false)
	r = TX_Probe(false, "PlayerConfigurations", 1, ":Field")
	H.eq(TXD.Tok(r), "ERR:not_callable")
	H.eq(r.exists, "number")
	r = TX_Probe(false, "PlayerConfigurations", 1, ":Raise")
	H.eq(r.ok, false)
	H.ok(string.find(r.err, "boom inside", 1, true), r.err)
	H.ok(string.find(TXD.Tok(r), "^ERR:"), TXD.Tok(r))
	r = TX_Probe(false, "Broken", nil, "?X")
	H.ok(string.find(r.err, "root getter failed", 1, true), r.err)
	H.len(H.lines(), 0, "quiet mode prints nothing")
end)

test("probe: returns, modes and self", function()
	Load()
	local calls, cfg = ProbeRoots()
	local r = TX_Probe(false, "PlayerConfigurations", 1, ":Pair")
	H.eq(r.ok, true)
	H.eq(r.n, 3)
	H.eq(r.rets[1], 1)
	H.eq(r.rets[2], "two")
	H.eq(TXD.Tok(r), "1,two,nil")
	r = TX_Probe(false, "PlayerConfigurations", 1, ":SetTeam", 5)
	H.eq(r.ok, true)
	H.eq(TXD.Tok(r), "nil")
	H.eq(calls[1].self, cfg, ": passes self")
	H.eq(calls[1].t, 5)
	r = TX_Probe(false, "Game", nil, ".Static", 2, 3)
	H.eq(r.rets[1], 5)
	H.eq(calls[2].a, 2, ". passes no self")
	local before = #calls
	r = TX_Probe(false, "PlayerConfigurations", 1, "?SetTeam")
	H.eq(r.exists, "function")
	H.eq(TXD.Tok(r), "function")
	H.eq(#calls, before, "? does not call")
	r = TX_Probe(false, "Game", nil, "=GOLD")
	H.eq(r.rets[1], 7)
	r = TX_Probe(false, "List", nil, "#")
	H.eq(r.rets[1], 3)
	r = TX_Probe(false, "Game", nil, "")
	H.eq(r.exists, "table")
	r = TX_Probe(false, cfg, nil, ":SetTeam", 9)
	H.eq(r.ok, true, "an object as the root")
	H.eq(calls[#calls].t, 9)
end)

test("probe: never-call list refuses, existence is allowed", function()
	Load()
	local calls = ProbeRoots()
	local r = TX_Probe("S2 CALL", "Game", nil, ".SetWinningTeam", 1)
	H.eq(r.refused, true)
	H.eq(r.ok, false)
	H.len(calls, 0, "the member is never called")
	H.eq(TXD.Tok(r), "REFUSED")
	H.ok(H.hasLine("REFUSED never-call"))
	r = TX_Probe(false, "Game", nil, "?SetWinningTeam")
	H.eq(r.exists, "function")
	H.eq(r.refused, false)
	H.ok(TXD.IsNever("PlayerConfigurations", "SetSlotStatus"))
	H.ok(TXD.IsNever(nil, ":SetMajorCiv"))
	H.ok(not TXD.IsNever("Teams", "RemovePlayer"))
	H.ok(TXD.IsNever("GameConfiguration", "RemovePlayer"))
end)

test("probe: exact log line shape", function()
	Load("UI")
	ProbeRoots()
	TX_Probe("S3 set", "PlayerConfigurations", 1, ":SetTeam", 5)
	H.eq(H.lines()[1], "[TX][SPIKE][S3] UI PROBE S3 set PlayerConfigurations[1]:SetTeam(5) exists=function ok=true ret=(nil) err=-")
	TX_Probe("V9 gpt", "Game", nil, ".Static", 1, 2)
	H.eq(H.lines()[2], "[TX][SPIKE][V9] UI PROBE V9 gpt Game.Static(1,2) exists=function ok=true ret=(3) err=-")
	AssertShapes()
end)

-- ---------------------------------------------------------------------------
-- Team map
-- ---------------------------------------------------------------------------
test("team map: groups, unused ID, used teams, solo stats", function()
	Load()
	local rows = { { pid = 0, team = 0 }, { pid = 1, team = 0 }, { pid = 2, team = 1 }, { pid = 3, team = 1 },
		{ pid = 4, team = 4 }, { pid = 62, team = 62, other = 1 }, { pid = 63, team = 63, other = 1 } }
	local g = TXD.TeamGroups(rows)
	H.eq(TXD.GroupsText(g), "0={0,1} 1={2,3} 4={4} 62={62} 63={63}")
	H.eq(TXD.UnusedTeam({ 0, 1, 4, 62, 63 }), 2)
	H.eq(TXD.UnusedTeam({ 0, 1, 2 }), 3)
	H.eq(TXD.UnusedTeam({ -1, 0, 1 }), 2, "NO_TEAM ignored")
	-- dead players' teams count: UsedTeams takes every row
	local withDead = { { pid = 0, team = 0, alive = 1 }, { pid = 1, team = 2, alive = 0 }, { pid = 2, team = 1, alive = 1 } }
	H.eq(TXD.UnusedTeam(TXD.UsedTeams(withDead)), 3)
	-- the config-team union: a team used only as a config team is not offered
	local cfgOnly = { { pid = 0, team = 0, cfg = 0 }, { pid = 1, team = 0, cfg = 2 }, { pid = 2, team = 1, cfg = 1 } }
	H.deq(TXD.UsedTeams(cfgOnly), { 0, 1, 2 })
	H.eq(TXD.UnusedTeam(TXD.UsedTeams(cfgOnly)), 3)
	local k, n = TXD.SoloIdStats(rows)
	H.eq(k, 1, "only the city-state (4) is solo with team == pid; 62/63 left out")
	H.eq(n, 1)
	local k2, n2 = TXD.SoloIdStats({ { pid = 0, team = 0 }, { pid = 1, team = 5 }, { pid = 2, team = 2 } })
	H.eq(k2, 2)
	H.eq(n2, 3)
end)

test("roles: keeper and other", function()
	Load()
	local rows = { { pid = 3, team = 1, alive = 1, major = 1 }, { pid = 0, team = 0, alive = 1, major = 1 },
		{ pid = 1, team = 0, alive = 1, major = 1 }, { pid = 2, team = 1, alive = 1, major = 1 },
		{ pid = 4, team = 4, alive = 1, major = 0 }, { pid = 62, team = 62, alive = 1, major = 0 } }
	local keeper, other = TXD.PickRoles(rows, 1)
	H.eq(keeper, 0)
	H.eq(other, 2)
	keeper, other = TXD.PickRoles(rows, 3)
	H.eq(keeper, 2)
	H.eq(other, 0)
end)

-- ---------------------------------------------------------------------------
-- Phase labels, check IDs
-- ---------------------------------------------------------------------------
test("phase labels and check IDs", function()
	Load()
	H.eq(TXD.PhaseLabel(nil), "BASE")
	H.eq(TXD.PhaseLabel({ phase = "BASE", path = "BASE" }), "BASE")
	H.eq(TXD.PhaseLabel({ phase = "LIVE", path = "S3" }), "S3LIVE")
	H.eq(TXD.PhaseLabel({ phase = "RELOAD", path = "S3", loads = 2 }), "S3RELOAD2")
	H.eq(TXD.PhaseLabel({ phase = "LIVE", path = "S2", mp = 1 }), "MP-S2LIVE")
	H.eq(TXD.PhaseLabel({ phase = "RELOAD", path = "S3b", loads = 1 }), "S3bRELOAD1")
	H.eq(TXD.PhaseLabel({ phase = "BASE", mp = 1 }), "MP-BASE")
	H.eq(TXD.CheckId("V1", { phase = "BASE" }), "V1-G.BASE")
	TXD.Init("UI")
	H.eq(TXD.CheckId("V5", { phase = "RELOAD", path = "S3", loads = 1 }), "V5-UI.S3RELOAD1")
	TXD.Init("G")
	H.eq(TXD.CheckId("V6", { phase = "LIVE", path = "S3", mp = 1 }), "V6-G.MP-S3LIVE")
end)

-- ---------------------------------------------------------------------------
-- Verdicts
-- ---------------------------------------------------------------------------
local function V(fn, ...)
	local v, t = fn(...)
	return v, t
end

test("verdicts: V1", function()
	Load()
	H.eq(V(TXD.Verdict.V1, "BASE", 0, 0), "INFO")
	H.eq(V(TXD.Verdict.V1, "MP-BASE", 2, 0), "INFO")
	H.eq(V(TXD.Verdict.V1, "S3LIVE", 2, 0), "PASS")
	H.eq(V(TXD.Verdict.V1, "S3LIVE", 0, 0), "FAIL")
	local v, t = TXD.Verdict.V1("S3LIVE", nil, 0)
	H.eq(v, "INFO")
	H.ok(string.find(t, "^INCONCLUSIVE:"), t)
end)

test("verdicts: V4", function()
	Load()
	H.eq(V(TXD.Verdict.V4, "BASE", "BASE", true, true, "x"), "INFO")
	H.eq(V(TXD.Verdict.V4, "S3LIVE", "BASE", true, true, "x"), "INFO", "an entry made before the change is the control")
	H.eq(V(TXD.Verdict.V4, "S3LIVE", "S3", true, false, "x"), "PASS")
	H.eq(V(TXD.Verdict.V4, "S3RELOAD1", "S3", true, true, "x"), "FAIL")
	local v, t = TXD.Verdict.V4("S3LIVE", "S3", false, false, "x")
	H.eq(v, "INFO")
	H.ok(string.find(t, "^INCONCLUSIVE: units made by script don't trigger the boost; do V4 by hand"), t)
	v, t = TXD.Verdict.V4("S3LIVE", "S3", nil, false, "x")
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE:"), t)
end)

test("verdicts: V5", function()
	Load()
	H.eq(V(TXD.Verdict.V5, "BASE", true, true, 8), "INFO")
	local v, t = TXD.Verdict.V5("BASE", true, false, 8)
	H.eq(v, "INFO")
	H.ok(string.find(t, "^INCONCLUSIVE: target does not see"), t)
	H.eq(V(TXD.Verdict.V5, "S3LIVE", true, false, 8), "PASS")
	H.eq(V(TXD.Verdict.V5, "S3LIVE", true, true, 8), "FAIL")
	v, t = TXD.Verdict.V5("S3LIVE", true, true, 3)
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE: a target unit or city is within 3 tiles"), t)
	v, t = TXD.Verdict.V5("S3LIVE", false, false, 8)
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE: control failed"), t)
	v, t = TXD.Verdict.V5("S3LIVE", nil, false, 8)
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE:"), t)
end)

test("verdicts: V6", function()
	Load()
	H.eq(V(TXD.Verdict.V6, "BASE", true, true), "INFO")
	H.eq(V(TXD.Verdict.V6, "S3RELOAD1", true, false), "PASS")
	H.eq(V(TXD.Verdict.V6, "S3RELOAD1", true, true), "FAIL")
	local v, t = TXD.Verdict.V6("S3LIVE", false, false)
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE: control failed"), t)
	v, t = TXD.Verdict.V6("S3LIVE", nil, false)
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE:"), t)
end)

test("verdicts: V9", function()
	Load()
	local base = { ob12 = 1, ob21 = 1, gpt = 0 }
	H.eq(V(TXD.Verdict.V9, "BASE", base, base), "INFO")
	H.eq(V(TXD.Verdict.V9, "S3LIVE", base, { ob12 = 1, ob21 = 1, gpt = 0 }), "PASS")
	local v, t = TXD.Verdict.V9("S3LIVE", base, { ob12 = 1, ob21 = 0, gpt = 0 })
	H.eq(v, "FAIL")
	H.ok(string.find(t, "gone ob21", 1, true), t)
	v, t = TXD.Verdict.V9("S3LIVE", { ob12 = 0, ob21 = 0, gpt = 0 }, base)
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE: no deal at BASE"), t)
	v, t = TXD.Verdict.V9("S3LIVE", nil, base)
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE: no BASE record"), t)
end)

test("verdicts: V10", function()
	Load()
	H.eq(V(TXD.Verdict.V10, "BASE", 1, true, true), "INFO")
	H.eq(V(TXD.Verdict.V10, "S3LIVE", 1, true, true), "PASS")
	H.eq(V(TXD.Verdict.V10, "S3LIVE", 1, true, false), "FAIL")
	local v, t = TXD.Verdict.V10("S3LIVE", 0, true, true)
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE: no friendship at BASE"), t)
	v, t = TXD.Verdict.V10("S3LIVE", 1, nil, true)
	H.ok(v == "INFO" and string.find(t, "^INCONCLUSIVE:"), t)
end)

test("verdicts: V3", function()
	Load()
	H.eq(V(TXD.Verdict.V3, "BASE", { 0, 1 }, 0, 1), "INFO")
	H.eq(V(TXD.Verdict.V3, "S3RELOAD1", { 0, 1 }, 0, 1), "FAIL")
	H.eq(V(TXD.Verdict.V3, "S3RELOAD1", { 0 }, 0, 1), "PASS")
	H.eq(V(TXD.Verdict.V3, "S3RELOAD1", { 2, 3 }, 0, 1), "INFO")
	H.eq(V(TXD.Verdict.V3, "S3RELOAD1", nil, 0, 1, true), "PASS")
	H.eq(V(TXD.Verdict.V3, "S3RELOAD1", nil, 0, 1, false), "INFO")
	H.eq(V(TXD.Verdict.V3, "BASE", nil, 0, 1, true), "INFO")
end)

-- ---------------------------------------------------------------------------
-- Others
-- ---------------------------------------------------------------------------
test("fingerprint is stable and order-sensitive", function()
	Load()
	H.eq(TXD.Fingerprint("0={0,1} 1={2,3}"), TXD.Fingerprint("0={0,1} 1={2,3}"))
	H.ne(TXD.Fingerprint("ab"), TXD.Fingerprint("ba"))
	H.eq(TXD.Fingerprint(""), 0)
	H.eq(TXD.Fingerprint("a"), 97)
	H.eq(TXD.Fingerprint("ab"), 97 * 31 + 98)
end)

test("Flatten / Unflatten round trip", function()
	Load()
	local t = { v1cfgT = 5, name = "x", flag = 1, off = 0, yes = true, empty = "" }
	local p = TXD.Flatten("u_", t)
	H.deq(p, { u_v1cfgT = 5, u_name = "x", u_flag = 1, u_off = 0, u_yes = 1 })
	p.cmd = "store_ui"
	p.OnStart = "TX_Dev"
	local back, n = TXD.Unflatten(p, "u_")
	H.deq(back, { v1cfgT = 5, name = "x", flag = 1, off = 0, yes = 1 })
	H.eq(n, 5)
end)

test("FarthestPlot tie-breaks to the lowest idx", function()
	Load()
	local function dist(x1, y1, x2, y2) return math.max(math.abs(x1 - x2), math.abs(y1 - y2)) end
	local cands = { { x = 9, y = 0, idx = 9 }, { x = 0, y = 9, idx = 90 }, { x = 5, y = 5, idx = 55 }, { x = 0, y = 0, idx = 0 } }
	local best, d = TXD.FarthestPlot(cands, { { x = 0, y = 0 } }, dist)
	H.eq(best.idx, 9)
	H.eq(d, 9)
	best, d = TXD.FarthestPlot(cands, {}, dist)
	H.eq(best.idx, 0, "no assets: every distance ties")
end)

test("PickBoost: naval, civic and unusable rows are skipped, ordered by tech Index", function()
	Load()
	local rows = {
		{ BoostID = 1, TechnologyType = "TECH_C", BoostClass = TXD.BOOST_OWN_UNITS, Unit1Type = "UNIT_CROSSBOWMAN", NumItems = 2 },
		{ BoostID = 2, TechnologyType = "TECH_A", BoostClass = TXD.BOOST_OWN_UNITS, Unit1Type = "UNIT_GALLEY", NumItems = 2 },
		{ BoostID = 3, CivicType = "CIVIC_X", BoostClass = TXD.BOOST_OWN_UNITS, Unit1Type = "UNIT_WARRIOR", NumItems = 3 },
		{ BoostID = 4, TechnologyType = "TECH_B", BoostClass = TXD.BOOST_OWN_UNITS, Unit1Type = "UNIT_ARCHER", NumItems = 3 },
		{ BoostID = 5, TechnologyType = "TECH_Z", BoostClass = "BOOST_TRIGGER_MEET_CIV" },
	}
	local idx = { TECH_A = 1, TECH_B = 5, TECH_C = 9, TECH_Z = 0 }
	local land = { UNIT_CROSSBOWMAN = true, UNIT_ARCHER = true, UNIT_WARRIOR = true, UNIT_GALLEY = false }
	local function techIndex(t) return idx[t] end
	local function isLand(u) return land[u] == true end
	local row, i = TXD.PickBoost(rows, function() return true end, techIndex, isLand)
	H.eq(row.BoostID, 4)
	H.eq(i, 5)
	row = TXD.PickBoost(rows, function(r) return r.TechnologyType ~= "TECH_B" end, techIndex, isLand)
	H.eq(row.BoostID, 1)
	row = TXD.PickBoost(rows, function() return false end, techIndex, isLand)
	H.isnil(row)
end)

test("setter candidates: table, defaults for S1 keys, no duplicates", function()
	Load()
	local c = TXD.SetterCandidates({ { obj = "Players[0]", key = "SetTeam" }, { obj = "Players[0]", key = "AssignToTeam" },
		{ obj = "Teams[t]", key = "MovePlayer" }, { obj = "Game", key = "MergeTeams" }, { obj = "Players[0]:GetTechs()", key = "X" } })
	H.eq(#c, #TXD.SETTERS + 3)
	local last = c[#c]
	H.deq(last, { root = "Game", name = "MergeTeams", style = ".", args = "player,team" })
	H.eq(c[#c - 1].args, "player", "Teams[t] key with Player in its name")
	local a, n = TXD.SetterArgs("player,team", 1, 5)
	H.deq(a, { 1, 5 })
	H.eq(n, 2)
	a, n = TXD.SetterArgs("none", 1, 5)
	H.eq(n, 0)
	H.eq(TXD.SelValue("origTeam", 1, 0), 0)
	H.eq(TXD.SetterText({ root = "Players", sel = "target", style = ":", name = "SetTeam", args = "team" }), "Players[target]:SetTeam(team)")
end)

test("CHECK and SPIKE line format, BADVERDICT", function()
	Load("UI")
	TXD.Check("V1-UI.BASE", "PASS", "text")
	TXD.Check("V1-UI.BASE", "MAYBE", "text")
	TXD.Spike("S3b", "lobby")
	TXD.Spike("weird section!", "x")
	H.eq(H.lines()[1], "[TX][CHECK] V1-UI.BASE PASS T1 UI text")
	H.eq(H.lines()[2], "[TX][CHECK] V1-UI.BASE INFO T1 UI BADVERDICT:MAYBE text")
	H.eq(H.lines()[3], "[TX][SPIKE][S3b] UI lobby")
	H.eq(H.lines()[4], "[TX][SPIKE][weirdsection] UI x")
	AssertShapes()
end)

test("chunking: no line longer than maxChars, long words alone", function()
	Load()
	local lines = TXD.Chunk({ "aaaa", "bbbb", "cccc", string.rep("x", 12), "d" }, 10)
	H.deq(lines, { "aaaa bbbb", "cccc", string.rep("x", 12), "d" })
	H.deq(TXD.Chunk({}, 10), {})
end)
