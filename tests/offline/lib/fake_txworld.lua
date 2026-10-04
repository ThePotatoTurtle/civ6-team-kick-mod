-- ===========================================================================
-- fake_txworld.lua  (offline harness) - fake engine extensions for the
-- Team Kick 0.1.0 tests (PLAN II.14). fake_engine.lua, fake_ui.lua and
-- harness.lua stay unchanged; load this file with
--   FAKE.dofile("tests/offline/lib/fake_txworld.lua"); FAKE_TX.Install(opts)
-- after H.world{...} (the fake_devworld pattern, test_dev_gameplay.lua:8-24),
-- or call FAKE_TX.World(opts), which builds the standard world and installs.
--
-- Install(opts):
--   split (true): the measured hotseat model (PLAN II.0 F1 to F3). Keeps
--     FAKE.teamModel = "config" and gives each player an instance GetTeam
--     that returns the config team in gameplay (F2: G reads the write at once)
--     and the live team in the UI (F3: stale until a load). A save and load is
--     H.reload(..., { applyConfigTeams = true }) or FAKE_TX.Reload().
--     split = false: gameplay does not see the config write either (the
--     NOT_SEEN path of the apply seam).
--   host (true), netMP (false), hotseat (true), hostID (0):
--     Network.IsGameHost, Network.GetGameHostPlayerID,
--     GameConfiguration.IsNetworkMultiplayer, GameConfiguration.IsHotseat.
--   PlayerConfigurations[i]:GetLeaderName() -> "LOC_LEADER_FAKE_<i>_NAME" on
--     every config object (also ones created later).
--
--   Diplomacy for the HARD kick (kick modes; test assumptions from Session 2
--     and 3 AL3 / AL3b, the reverse direction is PROVISIONAL, Session 3c):
--     WarTypes (FORMAL_WAR 1, SURPRISE_WAR 0) when missing; on every
--     player's diplomacy object:
--       DeclareWarOn(b, warType, third): logged in FAKE_TX.diploCalls; a pair
--         in the timeless alliance (FAKE_TX.Ally) gets no war unless third is
--         true (AL3b); else war (FAKE.SetWar; FAKE.teamWars = true makes it
--         team wide), state WAR, and b holds 100 grievances against the
--         declarer (AL3: the target held 100 against the declarer).
--       MakePeaceWith(b, v): logged; ends the war of the pair (FAKE.SetWar
--         false), state UNFRIENDLY both ways (AL3: MAKE_PEACE -> UNFRIENDLY).
--     Failure injection: FAKE_TX.diploFail["declare:<a>><b>"] or
--     ["peace:<a>><b>"] = "error" (the call throws) | "noop" (it returns and
--     changes nothing). FAKE_TX.DiploState(a, b) -> "WAR", "ALLIED",
--     "UNFRIENDLY" or "NEUTRAL"; FAKE_TX.Grievance(holder, against).
--   PopupDialogInGame (fake_ui) gets AddButton(label, fn) (PopupDialog,
--     BASE24 EndGameMenu.lua:1236-1237) recorded in dialog.buttons, and the
--     confirm and cancel labels (dialog.confirmLabel, dialog.cancelLabel).
--
-- Helpers: World(opts), LoadUI(), Reload(), Activate(pid, typeName),
-- Hotseat(pid), Ally(a, b), AllyTeam(team), DiploState, Grievance. LoadUI and Reload run the TX entry files that exist; files of
-- later build chunks (PLAN II.16) are skipped while they are missing.
-- Every model here is a test assumption except where it cites F1 to F7.
-- ===========================================================================

FAKE_TX = {}

FAKE_TX.GAMEPLAY = "TX/Scripts/TX_Gameplay.lua"
FAKE_TX.CONTEXTS = {
	{ name = "TeamWindow", rel = "TX/UI/TX_TeamWindow.lua" },
	{ name = "VotePopup", rel = "TX/UI/TX_VotePopup.lua" },
	{ name = "ApplyBanner", rel = "TX/UI/TX_ApplyBanner.lua" },
}
-- Globals of a Lua state that a load drops (the include()d modules run again).
FAKE_TX.GLOBALS = { "TX_Config", "TX_Util", "TX_Votes", "TX_Store", "TX_Notify", "TX_Apply", "TX_UI" }

local function Exists(rel)
	return __py_read(rel) ~= nil
end
FAKE_TX.Exists = Exists

-- Split GetTeam on one player (instance field, wins over the Player metatable).
local function Attach(id)
	local p = FAKE.players[id]
	if p == nil then
		return
	end
	if FAKE_TX.split then
		p.GetTeam = function(self)
			if FAKE.context == "G" then
				return self.configTeam
			end
			return self.team
		end
	else
		p.GetTeam = nil
	end
end
FAKE_TX.Attach = Attach

-- ---------------------------------------------------------------------------
-- Diplomacy model for the HARD kick (test assumptions, see the header)
-- ---------------------------------------------------------------------------
local function PairKey(a, b)
	if a > b then
		a, b = b, a
	end
	return tostring(a) .. ":" .. tostring(b)
end

-- Timeless alliance of a pair (what ex-teammates keep after a split, F4 / Session 2 AL0).
function FAKE_TX.Ally(a, b)
	FAKE_TX.allied[PairKey(a, b)] = true
end

-- Every pair of living majors on team stays allied (call before the split).
function FAKE_TX.AllyTeam(team)
	local m = FAKE.TeamMembers(team)
	for i = 1, #m do
		for j = i + 1, #m do
			FAKE_TX.Ally(m[i], m[j])
		end
	end
end

function FAKE_TX.DiploState(a, b)
	if FAKE.IsAtWar(a, b) then
		return "WAR"
	end
	if FAKE_TX.allied[PairKey(a, b)] then
		return "ALLIED"
	end
	return FAKE_TX.state[PairKey(a, b)] or "NEUTRAL"
end

function FAKE_TX.Grievance(holder, against)
	return FAKE_TX.grievances[tostring(holder) .. ">" .. tostring(against)] or 0
end

local function DiploFail(kind, a, b)
	local f = FAKE_TX.diploFail[kind .. ":" .. tostring(a) .. ">" .. tostring(b)]
	if f == "error" then
		error("fake " .. kind .. " failure P" .. tostring(a) .. "->P" .. tostring(b))
	end
	return f == "noop"
end

-- b plus, with FAKE.teamWars, every living member of b's team (ascending).
local function Victims(a, b)
	local out = { b }
	local pb = FAKE.players[b]
	if FAKE.teamWars and pb ~= nil then
		for _, x in ipairs(FAKE.TeamMembers(pb.team)) do
			if x ~= b and x ~= a then
				out[#out + 1] = x
			end
		end
	end
	return out
end

local function WrapDiplomacy(id)
	local p = FAKE.players[id]
	if p == nil or p.diplomacy == nil or rawget(p.diplomacy, "TX_wrapped") then
		return
	end
	local d = p.diplomacy
	rawset(d, "TX_wrapped", true)
	rawset(d, "DeclareWarOn", function(_, b, warType, third)
		local calls = FAKE_TX.diploCalls
		calls[#calls + 1] = { fn = "DeclareWarOn", a = id, b = b, warType = warType, third = third, context = FAKE.context }
		if DiploFail("declare", id, b) then
			return
		end
		if FAKE_TX.allied[PairKey(id, b)] and third ~= true then
			return   -- AL3b: no war on an ally without the third argument
		end
		FAKE.SetWar(id, b, true)
		-- Everybody the declarer is now at war with (b's team when
		-- FAKE.teamWars): no alliance any more, grievances against the declarer.
		for _, x in ipairs(Victims(id, b)) do
			FAKE_TX.allied[PairKey(id, x)] = nil
			local g = tostring(x) .. ">" .. tostring(id)
			FAKE_TX.grievances[g] = (FAKE_TX.grievances[g] or 0) + 100
		end
	end)
	rawset(d, "MakePeaceWith", function(_, b, v)
		local calls = FAKE_TX.diploCalls
		calls[#calls + 1] = { fn = "MakePeaceWith", a = id, b = b, v = v, context = FAKE.context }
		if DiploFail("peace", id, b) then
			return
		end
		local was = Victims(id, b)
		FAKE.SetWar(id, b, false)
		for _, x in ipairs(was) do
			if not FAKE.IsAtWar(id, x) then
				FAKE_TX.state[PairKey(id, x)] = "UNFRIENDLY"
			end
		end
	end)
end

-- Diplomacy calls of one kind (or all), in call order.
function FAKE_TX.Calls(fn)
	local out = {}
	for _, c in ipairs(FAKE_TX.diploCalls) do
		if fn == nil or c.fn == fn then
			out[#out + 1] = c
		end
	end
	return out
end

-- PopupDialogInGame extras (fake_ui stays unchanged): AddButton and labels.
local function PatchPopup()
	if PopupDialogInGame == nil or rawget(PopupDialogInGame, "TX_patched") then
		return
	end
	rawset(PopupDialogInGame, "TX_patched", true)
	function PopupDialogInGame:AddButton(label, fn)
		self.buttons[#self.buttons + 1] = { label = label, fn = fn }
	end
	function PopupDialogInGame:AddConfirmButton(label, fn)
		self.confirm = fn
		self.confirmLabel = label
	end
	function PopupDialogInGame:AddCancelButton(label, fn)
		self.cancel = fn
		self.cancelLabel = label
	end
end
FAKE_TX.PatchPopup = PatchPopup

function FAKE_TX.Install(opts)
	opts = opts or {}
	local T = FAKE_TX
	T.diploCalls = {}
	T.diploFail = {}
	T.allied = {}
	T.state = {}
	T.grievances = {}
	if WarTypes == nil then
		WarTypes = { FORMAL_WAR = 1, SURPRISE_WAR = 0 }
	end
	T.split = opts.split ~= false
	T.host = opts.host ~= false
	T.netMP = opts.netMP == true
	T.hotseat = opts.hotseat ~= false
	T.hostID = opts.hostID or 0
	FAKE.teamModel = "config"
	for _, id in ipairs(FAKE.SortedKeys(FAKE.players)) do
		Attach(id)
		WrapDiplomacy(id)
	end
	Network.IsGameHost = function() return T.host end
	Network.GetGameHostPlayerID = function() return T.hostID end
	GameConfiguration.IsNetworkMultiplayer = function() return T.netMP end
	GameConfiguration.IsHotseat = function() return T.hotseat end
	-- GetLeaderName on the cached config objects (fake_engine NewConfig has none).
	if not T.cfgWrapped then
		local mt = getmetatable(PlayerConfigurations)
		local orig = mt.__index
		mt.__index = function(t, id)
			local c = orig(t, id)
			if c ~= nil and c.GetLeaderName == nil then
				local pid = id
				c.GetLeaderName = function() return "LOC_LEADER_FAKE_" .. tostring(pid) .. "_NAME" end
			end
			return c
		end
		T.cfgWrapped = true
	end
end

-- The standard TX world (PLAN II.14): P0, P1, P2 human on team 0; P3 human and
-- P4 AI on team 1; P5 human solo; city-state 6; Free Cities 62; Barbarians 63.
-- Solo players own team IDs in slot order (F5): P5 = 2, 6 = 3, 62 = 4,
-- 63 = 5; slots 7..61 are empty (team -1, not alive, not major), so the first
-- free team ID is 6. Every pair of majors has met unless opts.met == false.
-- opts also goes to Install.
function FAKE_TX.World(opts)
	opts = opts or {}
	local players = {
		{ id = 0, human = true, team = 0 },
		{ id = 1, human = true, team = 0 },
		{ id = 2, human = true, team = 0 },
		{ id = 3, human = true, team = 1 },
		{ id = 4, team = 1 },
		{ id = 5, human = true, team = 2 },
		{ id = 6, kind = "CITY_STATE", team = 3 },
	}
	if opts.empty ~= false then
		for i = 7, 61 do
			players[#players + 1] = { id = i, kind = "EMPTY", alive = false, team = -1 }
		end
	end
	players[#players + 1] = { id = 62, kind = "FREE_CITIES", team = 4 }
	players[#players + 1] = { id = 63, kind = "BARBARIAN", team = 5 }
	H.world{ turn = opts.turn or 1, players = players }
	if opts.met ~= false then
		for a = 0, 5 do
			for b = a + 1, 5 do
				H.meet(a, b)
			end
		end
	end
	FAKE_TX.Install(opts)
	return FAKE.players
end

-- Loads the TX UI contexts that exist (FAKE_UI.Enable first if needed), then
-- fires Events.LoadGameViewStateDone. Returns { TeamWindow = env, ... }.
function FAKE_TX.LoadUI()
	if UI == nil then
		FAKE_UI.Enable()
	end
	PatchPopup()
	local envs = {}
	for _, c in ipairs(FAKE_TX.CONTEXTS) do
		if Exists(c.rel) then
			envs[c.name] = FAKE_UI.LoadContext(c.rel)
		end
	end
	FAKE_TX.ui = envs
	FAKE_TX.uiLoaded = true
	Events.LoadGameViewStateDone()
	return envs
end

-- Save and load: every handler and TX global is dropped, config teams become
-- live teams (F4), the gameplay script runs again as gameplay, and the UI
-- contexts are loaded again when they were loaded before.
function FAKE_TX.Reload()
	local function Run()
		H.reload({}, FAKE_TX.GLOBALS, { applyConfigTeams = true })
		if Exists(FAKE_TX.GAMEPLAY) then
			FAKE.dofile(FAKE_TX.GAMEPLAY)
		end
	end
	if UI ~= nil then
		FAKE_UI.AsGameplay(Run)
	else
		Run()
	end
	if FAKE_TX.uiLoaded then
		return FAKE_TX.LoadUI()
	end
	return nil
end

-- Fires Events.NotificationActivated(pid, id, true) for the newest notification
-- of typeName that pid still has. Returns the notification id or nil.
function FAKE_TX.Activate(pid, typeName)
	local hit = nil
	for _, n in ipairs(FAKE.notifications) do
		if n.pid == pid and n.typeName == typeName and not n.dismissed then
			hit = n
		end
	end
	if hit == nil then
		return nil
	end
	Events.NotificationActivated(pid, hit.id, true)
	return hit.id
end

-- Hotseat hand-off: the local player becomes pid, then Events.LocalPlayerChanged.
function FAKE_TX.Hotseat(pid)
	local prev = FAKE.localPlayer
	FAKE.localPlayer = pid
	Events.LocalPlayerChanged(pid, prev)
end
