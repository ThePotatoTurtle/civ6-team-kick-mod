-- ===========================================================================
-- fake_devworld.lua  (offline harness) - extra fake engine for the TX_Dev
-- spike kit tests (test_dev_gameplay.lua, test_dev_panel.lua). Load it with
--   FAKE.dofile("tests/offline/lib/fake_devworld.lua"); FAKE_DEV.Install{...}
-- after H.world{...}. fake_engine.lua stays as it is: these stubs model
-- engine parts only the spike kit touches, and every model below is a test
-- assumption, not a measured fact.
--
-- Adds: Map and plots, units and cities per player, CityManager (GetCityAt,
-- GetDistrictAt), UnitManager.FinishMoves, PlayersVisibility, Teams,
-- DealManager (working deal, enacted deals, item scans), techs and boosts,
-- culture, GetDiplomaticAI, SetHasMet / SetHasDeclaredFriendship /
-- CanDeclareWarOn, GameConfiguration / Network / Game extras, the enums the
-- kit uses, and GameInfo Technologies / Boosts / Units / Civics /
-- DiplomaticStates rows.
--
-- Models (switches on FAKE_DEV):
--   sharedVision (true): a player sees a plot within 2 tiles of its own
--     units and cities, and of its live teammates' (team = Players:GetTeam()).
--   boostOnCreate (true): creating units can trigger an own-units boost.
--   sharedBoosts (true): a triggered boost reaches the live teammates.
--   Teams[t]: the players whose live team is t (nil when none).
--   AL (TX_Dev 0.0.1.2): FAKE_DEV.SetState(a, b, "DIPLO_STATE_ALLIED") sets a's
--     state toward b (the leftover state after a split). War wins over it;
--     MakePeaceWith ends the war and sets UNFRIENDLY both ways (MAKE_PEACE);
--     SetHasAllied(b, true) sets HasAllied, false is a no-op (EFV T27); an
--     enacted ALLIANCE deal sets HasAllied and ALLIED both ways;
--     Game.GetGameDiplomacy():SetAlliesShareVisFlag(v) switches sharedVision.
--   VIS (TX_Dev 0.0.1.3): FAKE_DEV.LinkVision(a, b) makes a and b see what the
--     other sees whatever the teams (the leftover vision after a split, Session 2).
--     PlayersVisibility[a]:RemoveOutgoingVisibility(b) cuts a -> b (Add restores);
--     Recheck*/SetVisibilityOn change no map vision (recorded only).
--     DeclareWarOn records its arguments, sets the war turn and gives the
--     defender 100 grievances against the attacker. SetHasMet(b, false) unmeets
--     (no state change: what the engine does is the AL8 / AL9 question).
-- ===========================================================================

FAKE_DEV = {}

local function Key(x, y)
	return x .. "," .. y
end

local function Dist(x1, y1, x2, y2)
	return math.max(math.abs(x1 - x2), math.abs(y1 - y2))
end

local function Mates(pid)
	local p = FAKE.players[pid]
	local out = {}
	if p == nil then return out end
	for _, id in ipairs(FAKE.SortedKeys(FAKE.players)) do
		if FAKE.players[id].team == p.team then out[#out + 1] = id end
	end
	return out
end
FAKE_DEV.Mates = Mates

-- ---------------------------------------------------------------------------
-- GameInfo rows (made up, shaped like the game's)
-- ---------------------------------------------------------------------------
local OWN = "BOOST_TRIGGER_OWN_X_UNITS_OF_TYPE"
FAKE_DEV.GAMEINFO = {
	Technologies = { pk = "TechnologyType", rows = {
		{ TechnologyType = "TECH_POTTERY" }, { TechnologyType = "TECH_SAILING" }, { TechnologyType = "TECH_ARCHERY" },
		{ TechnologyType = "TECH_SHIPBUILDING" }, { TechnologyType = "TECH_MACHINERY" }, { TechnologyType = "TECH_METAL_CASTING" },
	} },
	Boosts = { rows = {
		{ BoostID = 1, TechnologyType = "TECH_ARCHERY", BoostClass = "BOOST_TRIGGER_KILL_WITH", Unit1Type = "UNIT_SLINGER" },
		{ BoostID = 2, TechnologyType = "TECH_SHIPBUILDING", BoostClass = OWN, Unit1Type = "UNIT_GALLEY", NumItems = 2 },
		{ BoostID = 3, CivicType = "CIVIC_CODE_OF_LAWS", BoostClass = OWN, Unit1Type = "UNIT_WARRIOR", NumItems = 3 },
		{ BoostID = 4, TechnologyType = "TECH_METAL_CASTING", BoostClass = OWN, Unit1Type = "UNIT_CROSSBOWMAN", NumItems = 2 },
		{ BoostID = 5, TechnologyType = "TECH_MACHINERY", BoostClass = OWN, Unit1Type = "UNIT_ARCHER", NumItems = 3 },
	} },
	Units = { pk = "UnitType", rows = {
		{ UnitType = "UNIT_WARRIOR", Domain = "DOMAIN_LAND" }, { UnitType = "UNIT_SLINGER", Domain = "DOMAIN_LAND" },
		{ UnitType = "UNIT_ARCHER", Domain = "DOMAIN_LAND" }, { UnitType = "UNIT_CROSSBOWMAN", Domain = "DOMAIN_LAND" },
		{ UnitType = "UNIT_GALLEY", Domain = "DOMAIN_SEA" }, { UnitType = "UNIT_TANK", Domain = "DOMAIN_LAND" },
		{ UnitType = "UNIT_SCOUT", Domain = "DOMAIN_LAND" },
	} },
	Civics = { pk = "CivicType", rows = { { CivicType = "CIVIC_CODE_OF_LAWS" }, { CivicType = "CIVIC_EARLY_EMPIRE" },
		{ CivicType = "CIVIC_CIVIL_SERVICE" } } },
	DiplomaticStates = { pk = "StateType", rows = {
		{ StateType = "DIPLO_STATE_ALLIED" }, { StateType = "DIPLO_STATE_DECLARED_FRIEND" }, { StateType = "DIPLO_STATE_FRIENDLY" },
		{ StateType = "DIPLO_STATE_NEUTRAL" }, { StateType = "DIPLO_STATE_UNFRIENDLY" }, { StateType = "DIPLO_STATE_DENOUNCED" },
		{ StateType = "DIPLO_STATE_WAR" },
	} },
	DiplomaticVisibilitySources = { pk = "VisibilitySourceType", rows = {
		{ VisibilitySourceType = "SOURCE_TECH" }, { VisibilitySourceType = "SOURCE_ALLY" },
	} },
}

-- ---------------------------------------------------------------------------
-- Map
-- ---------------------------------------------------------------------------
local Plot = {}
Plot.__index = Plot
function Plot:GetX() return self.x end
function Plot:GetY() return self.y end
function Plot:GetIndex() return self.idx end
function Plot:IsWater() return FAKE_DEV.water[Key(self.x, self.y)] == true end
function Plot:IsImpassable() return FAKE_DEV.impassable[Key(self.x, self.y)] == true end
function Plot:IsNaturalWonder() return false end
function Plot:GetOwner()
	local o = FAKE_DEV.owner[Key(self.x, self.y)]
	if o == nil then return -1 end
	return o
end
function Plot:GetUnitCount()
	local n = 0
	for _, u in ipairs(FAKE_DEV.units) do
		if not u.dead and u.x == self.x and u.y == self.y then n = n + 1 end
	end
	return n
end

local function GetPlot(x, y)
	if type(x) ~= "number" or type(y) ~= "number" or x < 0 or y < 0 or x >= FAKE_DEV.w or y >= FAKE_DEV.h then
		return nil
	end
	local idx = y * FAKE_DEV.w + x
	FAKE_DEV.plots[idx] = FAKE_DEV.plots[idx] or setmetatable({ x = x, y = y, idx = idx }, Plot)
	return FAKE_DEV.plots[idx]
end

-- ---------------------------------------------------------------------------
-- Units and cities
-- ---------------------------------------------------------------------------
local Unit = {}
Unit.__index = Unit
function Unit:GetID() return self.id end
function Unit:GetOwner() return self.owner end
function Unit:GetX() return self.x end
function Unit:GetY() return self.y end
function Unit:GetType() return self.typeIdx end

local City = {}
City.__index = City
function City:GetID() return self.id end
function City:GetOwner() return self.owner end
function City:GetOriginalOwner() return self.orig end
function City:GetX() return self.x end
function City:GetY() return self.y end
function City:IsOriginalCapital() return self.capital == true end

local function Iter(list)
	local i = 0
	return function()
		i = i + 1
		if list[i] ~= nil then return i, list[i] end
		return nil
	end
end

local function UnitsOf(pid)
	local out = {}
	for _, u in ipairs(FAKE_DEV.units) do
		if not u.dead and u.owner == pid then out[#out + 1] = u end
	end
	return out
end

local function CitiesOf(pid)
	local out = {}
	for _, c in ipairs(FAKE_DEV.cities) do
		if c.owner == pid then out[#out + 1] = c end
	end
	return out
end

local function TriggerBoost(pid, idx)
	local who = { pid }
	if FAKE_DEV.sharedBoosts then who = Mates(pid) end
	for _, id in ipairs(who) do
		FAKE_DEV.boosts[id] = FAKE_DEV.boosts[id] or {}
		FAKE_DEV.boosts[id][idx] = true
	end
end

local function CheckOwnUnitBoosts(pid)
	if not FAKE_DEV.boostOnCreate then return end
	for row in GameInfo.Boosts() do
		if row.BoostClass == OWN and row.TechnologyType ~= nil then
			local n = 0
			for _, u in ipairs(UnitsOf(pid)) do
				if GameInfo.Units[u.typeIdx].UnitType == row.Unit1Type then n = n + 1 end
			end
			if n >= (row.NumItems or 1) then
				TriggerBoost(pid, GameInfo.Technologies[row.TechnologyType].Index)
			end
		end
	end
end

function FAKE_DEV.AddUnit(pid, unitType, x, y)
	local row = GameInfo.Units[unitType]
	local u = setmetatable({ id = FAKE_DEV.nextUnit, owner = pid, typeIdx = row.Index, x = x, y = y }, Unit)
	FAKE_DEV.nextUnit = FAKE_DEV.nextUnit + 1
	FAKE_DEV.units[#FAKE_DEV.units + 1] = u
	return u
end

-- A city of pid at (x, y); the first city of a player is its capital. Claims ring 1.
function FAKE_DEV.AddCity(pid, x, y)
	local c = setmetatable({ id = FAKE_DEV.nextCity, owner = pid, orig = pid, x = x, y = y, capital = #CitiesOf(pid) == 0 }, City)
	FAKE_DEV.nextCity = FAKE_DEV.nextCity + 1
	FAKE_DEV.cities[#FAKE_DEV.cities + 1] = c
	for dy = -1, 1 do
		for dx = -1, 1 do
			if GetPlot(x + dx, y + dy) ~= nil then FAKE_DEV.owner[Key(x + dx, y + dy)] = pid end
		end
	end
	FAKE_DEV.districts[c.id] = { dmg = { [0] = 0, [1] = 0 }, max = { [0] = 200, [1] = 100 } }
	return c
end

function FAKE_DEV.CityAt(x, y)
	for _, c in ipairs(FAKE_DEV.cities) do
		if c.x == x and c.y == y then return c end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------
-- a's vision reaches b whatever the teams (both ways).
function FAKE_DEV.LinkVision(a, b)
	FAKE_DEV.links[a] = FAKE_DEV.links[a] or {}
	FAKE_DEV.links[b] = FAKE_DEV.links[b] or {}
	FAKE_DEV.links[a][b] = true
	FAKE_DEV.links[b][a] = true
end

local function Sees(pid, x, y)
	if FAKE_DEV.visible[pid] ~= nil and FAKE_DEV.visible[pid][Key(x, y)] then return true end
	local who = { pid }
	if FAKE_DEV.sharedVision then who = Mates(pid) end
	for _, a in ipairs(FAKE.SortedKeys(FAKE_DEV.links)) do
		if a ~= pid and FAKE_DEV.links[a][pid] then who[#who + 1] = a end
	end
	for _, id in ipairs(who) do
		for _, u in ipairs(UnitsOf(id)) do
			if Dist(u.x, u.y, x, y) <= 2 then return true end
		end
		for _, c in ipairs(CitiesOf(id)) do
			if Dist(c.x, c.y, x, y) <= 2 then return true end
		end
	end
	return false
end
FAKE_DEV.Sees = Sees

-- ---------------------------------------------------------------------------
-- Deals
-- ---------------------------------------------------------------------------
local Item = {}
Item.__index = Item
function Item:SetSubType(s) self.sub = s end
function Item:SetDuration(d) self.duration = d end
function Item:SetLocked(v) self.locked = v end
function Item:SetAmount(a) self.amount = a end
function Item:SetValueType(v) self.value = v end
function Item:GetFromPlayerID() return self.from end
function Item:GetDuration() return self.duration end
function Item:GetEnactedTurn() return self.enacted end

local Deal = {}
Deal.__index = Deal
function Deal:AddItemOfType(t, from)
	local it = setmetatable({ type = t, from = from }, Item)
	self.items[#self.items + 1] = it
	return it
end
function Deal:Validate() return true end
local function Match(it, t, sub, from)
	if it.type ~= t or it.from ~= from then return false end
	if sub == nil then return true end
	if sub == DealItemSubTypes.NONE then return it.sub == nil end
	return it.sub == sub
end
function Deal:FindItemByType(t, sub, from)
	for _, it in ipairs(self.items) do
		if Match(it, t, sub, from) then return it end
	end
	return nil
end
function Deal:FindItemsByType(t, sub, from)
	local out = {}
	for _, it in ipairs(self.items) do
		if Match(it, t, sub, from) then out[#out + 1] = it end
	end
	if #out == 0 then return nil end
	return out
end

-- Removes every enacted deal between a and b (a deal that ended).
function FAKE_DEV.RemoveDeals(a, b)
	local keep = {}
	for _, d in ipairs(FAKE_DEV.deals) do
		if not ((d.a == a and d.b == b) or (d.a == b and d.b == a)) then keep[#keep + 1] = d end
	end
	FAKE_DEV.deals = keep
	FAKE.PairSet(FAKE.diplo.ob, a, b, false)
	FAKE.PairSet(FAKE.diplo.ob, b, a, false)
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------
local function StateIndex(name)
	return GameInfo.DiplomaticStates[name].Index
end

-- AL: explicit per-pair states (a's state toward b).
function FAKE_DEV.SetState(a, b, name)
	FAKE_DEV.states[a] = FAKE_DEV.states[a] or {}
	FAKE_DEV.states[a][b] = name
end

local function StateTypeOf(pid, other)
	if FAKE.IsAtWar(pid, other) then return "DIPLO_STATE_WAR" end
	if FAKE_DEV.states[pid] ~= nil and FAKE_DEV.states[pid][other] ~= nil then return FAKE_DEV.states[pid][other] end
	if FAKE.PairGet(FAKE.diplo.allied, pid, other) then return "DIPLO_STATE_ALLIED" end
	if FAKE.PairGet(FAKE.diplo.friend, pid, other) then return "DIPLO_STATE_DECLARED_FRIEND" end
	return "DIPLO_STATE_NEUTRAL"
end

local function Attach(pid, p)
	rawset(p, "GetUnits", function()
		return {
			Create = function(_, idx, x, y)
				if GetPlot(x, y) == nil then return nil end
				local u = setmetatable({ id = FAKE_DEV.nextUnit, owner = pid, typeIdx = idx, x = x, y = y }, Unit)
				FAKE_DEV.nextUnit = FAKE_DEV.nextUnit + 1
				FAKE_DEV.units[#FAKE_DEV.units + 1] = u
				FAKE_DEV.created[#FAKE_DEV.created + 1] = u
				CheckOwnUnitBoosts(pid)
				return u
			end,
			Members = function() return Iter(UnitsOf(pid)) end,
		}
	end)
	rawset(p, "GetCities", function()
		return {
			GetCapitalCity = function()
				for _, c in ipairs(CitiesOf(pid)) do
					if c.capital and c.orig == pid then return c end
				end
				return nil
			end,
			Members = function() return Iter(CitiesOf(pid)) end,
		}
	end)
	rawset(p, "GetTechs", function()
		return {
			HasBoostBeenTriggered = function(_, idx) return FAKE_DEV.boosts[pid] ~= nil and FAKE_DEV.boosts[pid][idx] == true end,
			HasTech = function(_, idx) return FAKE_DEV.techs[pid] ~= nil and FAKE_DEV.techs[pid][idx] == true end,
		}
	end)
	rawset(p, "GetCulture", function()
		return {
			SetCivic = function(_, idx, v)
				FAKE_DEV.civics[pid] = FAKE_DEV.civics[pid] or {}
				FAKE_DEV.civics[pid][idx] = v
			end,
		}
	end)
	rawset(p, "GetDiplomaticAI", function()
		return {
			-- p's view of other
			GetDiplomaticStateIndex = function(_, other)
				return StateIndex(StateTypeOf(pid, other))
			end,
		}
	end)
	-- G: the state as a StateType string (GCO_PlayerScript.lua:1033-1043)
	rawset(p, "GetAi_Diplomacy", function()
		return { GetDiplomaticState = function(_, other) return StateTypeOf(pid, other) end }
	end)
	local d = p.diplomacy
	rawset(d, "SetHasMet", function(_, b, v)
		FAKE.PairSet(FAKE.diplo.met, pid, b, v ~= false)
	end)
	rawset(d, "SetHasDeclaredFriendship", function(_, b, v)
		FAKE.PairSet(FAKE.diplo.friend, pid, b, v)
	end)
	rawset(d, "MakePeaceWith", function(_, b)
		FAKE.SetWar(pid, b, false)
		FAKE_DEV.SetState(pid, b, "DIPLO_STATE_UNFRIENDLY")
		FAKE_DEV.SetState(b, pid, "DIPLO_STATE_UNFRIENDLY")
		FAKE_DEV.peace[#FAKE_DEV.peace + 1] = { a = pid, b = b }
	end)
	rawset(d, "SetHasAllied", function(_, b, v)
		if v then FAKE.PairSet(FAKE.diplo.allied, pid, b, true) end
	end)
	rawset(d, "CanDeclareWarOn", function(_, b)
		local pb = FAKE.players[b]
		return pb ~= nil and pb.team ~= p.team and not FAKE.IsAtWar(pid, b) and not FAKE.PairGet(FAKE.diplo.friend, pid, b)
	end)
	-- VIS and the AL3 side effects (TX_Dev 0.0.1.3)
	local D = FAKE_DEV
	rawset(d, "DeclareWarOn", function(_, b, warType, flag)
		D.dows[#D.dows + 1] = { a = pid, b = b, warType = warType, flag = flag }
		FAKE.SetWar(pid, b, true)
		D.warTurn[Key(pid, b)], D.warTurn[Key(b, pid)] = FAKE.turn, FAKE.turn
		D.grievances[Key(b, pid)] = (D.grievances[Key(b, pid)] or 0) + 100
	end)
	rawset(d, "GetAtWarChangeTurn", function(_, b) return D.warTurn[Key(pid, b)] or -1 end)
	rawset(d, "GetGrievancesAgainst", function(_, b) return D.grievances[Key(pid, b)] or 0 end)
	rawset(d, "CanMakePeaceWith", function(_, b) return FAKE.IsAtWar(pid, b) end)
	rawset(d, "ComputeDOWWarmongerPoints", function(_, b, warType) return 50 end)
	rawset(d, "GetWarmongerLevel", function(_, pts) return "LOC_FAKE_WARMONGER_" .. tostring(pts) end)
	rawset(d, "GetVisibilityOn", function(_, b)
		local v = D.diploVis[Key(pid, b)]
		if v == nil then return 2 end
		return v
	end)
	rawset(d, "SetVisibilityOn", function(_, b, v)
		D.diploVis[Key(pid, b)] = v
		D.visCalls[#D.visCalls + 1] = "SetVisibilityOn " .. pid .. "," .. b .. "," .. tostring(v)
	end)
	rawset(d, "RecheckVisibilityOnAll", function()
		D.visCalls[#D.visCalls + 1] = "RecheckVisibilityOnAll " .. pid
	end)
	rawset(d, "RecheckVisibilityOn", function(_, b)
		D.visCalls[#D.visCalls + 1] = "RecheckVisibilityOn " .. pid .. "," .. b
	end)
	rawset(d, "IsVisibilitySourceActive", function(_, b, idx)
		return idx == GameInfo.DiplomaticVisibilitySources.SOURCE_ALLY.Index and StateTypeOf(pid, b) == "DIPLO_STATE_ALLIED"
	end)
end

-- opts: w, h (map size), sharedVision, sharedBoosts, boostOnCreate, hotseat,
-- netMP, host, teams (false: no Teams global).
function FAKE_DEV.Install(opts)
	opts = opts or {}
	local D = FAKE_DEV
	D.w, D.h = opts.w or 24, opts.h or 14
	D.plots, D.water, D.impassable, D.owner = {}, {}, {}, {}
	D.units, D.nextUnit, D.created = {}, 1, {}
	D.cities, D.nextCity, D.districts = {}, 1, {}
	D.visible, D.visCount = {}, {}
	D.boosts, D.techs, D.civics = {}, {}, {}
	D.deals, D.working = {}, {}
	D.states, D.peace, D.visFlag = {}, {}, {}
	D.links, D.visCalls, D.dows, D.warTurn, D.grievances, D.diploVis, D.era = {}, {}, {}, {}, {}, {}, {}
	D.sharedVision = opts.sharedVision ~= false
	D.sharedBoosts = opts.sharedBoosts ~= false
	D.boostOnCreate = opts.boostOnCreate ~= false
	D.hotseat = opts.hotseat ~= false
	D.netMP = opts.netMP == true
	D.host = opts.host ~= false
	D.winningTeam = -1

	local data = FAKE.gameInfoData or { Types = { pk = "Type", rows = {} } }
	for _, name in ipairs(FAKE.SortedKeys(D.GAMEINFO)) do
		data[name] = FAKE.DeepCopy(D.GAMEINFO[name])
	end
	FAKE.LoadGameInfo(data, nil)

	WarTypes = { FORMAL_WAR = 1, SURPRISE_WAR = 0 }
	DefenseTypes = { DISTRICT_GARRISON = 0, DISTRICT_OUTER = 1 }
	DealDirection = { OUTGOING = 0, INCOMING = 1 }
	DealItemTypes = { AGREEMENTS = 1, GOLD = 2 }
	DealAgreementTypes = { OPEN_BORDERS = 7, ALLIANCE = 9 }
	DiplomacyActionTypes = { SET_WAR_STATE = 3, ALLY = 5 }
	DB = { MakeHash = function(s) return string.len(s) * 1000 + 7 end }
	DealItemSubTypes = { NONE = -1 }

	Map = {
		GetGridSize = function() return D.w, D.h end,
		GetPlot = GetPlot,
		GetPlotDistance = function(x1, y1, x2, y2) return Dist(x1, y1, x2, y2) end,
		GetNeighborPlots = function(x, y, r)
			local out = {}
			for yy = y - r, y + r do
				for xx = x - r, x + r do
					local pl = GetPlot(xx, yy)
					if pl ~= nil then out[#out + 1] = pl end
				end
			end
			return out
		end,
	}
	CityManager = {
		GetCityAt = function(x, y) return D.CityAt(x, y) end,
		GetDistrictAt = function(x, y)
			local c = D.CityAt(x, y)
			if c == nil then return nil end
			local st = D.districts[c.id]
			return {
				GetMaxDamage = function(_, t) return st.max[t] end,
				GetDamage = function(_, t) return st.dmg[t] end,
				SetDamage = function(_, t, v) st.dmg[t] = v end,
			}
		end,
	}
	UnitManager = { FinishMoves = function(u) u.finished = true end }
	PlayersVisibility = setmetatable({}, {
		__index = function(_, pid)
			if FAKE.players[pid] == nil then return nil end
			return {
				IsVisible = function(_, x, y) return Sees(pid, x, y) end,
				RemoveOutgoingVisibility = function(_, other)
					D.visCalls[#D.visCalls + 1] = "RemoveOutgoingVisibility " .. pid .. "," .. tostring(other)
					if D.links[pid] ~= nil then D.links[pid][other] = nil end
				end,
				AddOutgoingVisibility = function(_, other)
					D.visCalls[#D.visCalls + 1] = "AddOutgoingVisibility " .. pid .. "," .. tostring(other)
					D.links[pid] = D.links[pid] or {}
					D.links[pid][other] = true
				end,
				ChangeVisibilityCount = function(_, idx, n)
					D.visCount[#D.visCount + 1] = { pid = pid, idx = idx, n = n }
					D.visible[pid] = D.visible[pid] or {}
					local w = D.w
					D.visible[pid][Key(idx % w, math.floor(idx / w))] = true
				end,
			}
		end,
	})
	if opts.teams ~= false then
		Teams = setmetatable({}, {
			__index = function(_, t)
				local out = {}
				for _, id in ipairs(FAKE.SortedKeys(FAKE.players)) do
					if FAKE.players[id].team == t then out[#out + 1] = id end
				end
				if #out == 0 then return nil end
				return out
			end,
		})
	else
		Teams = nil
	end
	DealManager = {
		ClearWorkingDeal = function(dir, a, b) D.working[Key(a, b)] = nil end,
		GetWorkingDeal = function(dir, a, b)
			local k = Key(a, b)
			D.working[k] = D.working[k] or setmetatable({ a = a, b = b, items = {} }, Deal)
			return D.working[k]
		end,
		EnactWorkingDeal = function(a, b)
			local w = D.working[Key(a, b)]
			if w == nil then return end
			D.working[Key(a, b)] = nil
			w.turn = FAKE.turn
			for _, it in ipairs(w.items) do
				it.enacted = FAKE.turn
				if it.type == DealItemTypes.AGREEMENTS and it.sub == DealAgreementTypes.OPEN_BORDERS then
					local receiver = (it.from == a) and b or a
					FAKE.PairSet(FAKE.diplo.ob, receiver, it.from, true)
				end
				if it.type == DealItemTypes.AGREEMENTS and it.sub == DealAgreementTypes.ALLIANCE then
					FAKE.PairSet(FAKE.diplo.allied, a, b, true)
					FAKE.PairSet(FAKE.diplo.allied, b, a, true)
					FAKE_DEV.SetState(a, b, "DIPLO_STATE_ALLIED")
					FAKE_DEV.SetState(b, a, "DIPLO_STATE_ALLIED")
				end
			end
			D.deals[#D.deals + 1] = w
		end,
		GetPlayerDeals = function(a, b)
			local out = {}
			for _, d in ipairs(D.deals) do
				if (d.a == a and d.b == b) or (d.a == b and d.b == a) then out[#out + 1] = d end
			end
			if #out == 0 then return nil end
			return out
		end,
	}
	GameConfiguration.IsHotseat = function() return D.hotseat end
	GameConfiguration.IsNetworkMultiplayer = function() return D.netMP end
	GameConfiguration.GetTeamPlayerCount = function(t)
		local n = 0
		for _, id in ipairs(FAKE.SortedKeys(FAKE.players)) do
			if FAKE.players[id].configTeam == t then n = n + 1 end
		end
		return n
	end
	GameConfiguration.GetTeamName = function(t) return "Team " .. tostring(t) end
	Network.IsGameHost = function() return D.host end
	Network.GetLocalPlayerID = function() return FAKE.localPlayer end
	Network.GetGameHostPlayerID = function() return 0 end
	Game.GetWinningTeam = function() return D.winningTeam, -1 end
	Game.GetGameDiplomacy = function()
		return {
			SetAlliesShareVisFlag = function(_, v)
				D.visFlag[#D.visFlag + 1] = v
				D.sharedVision = v == true
			end,
			GetMinPeaceDuration = function() return 10 end,
		}
	end
	Game.GetEras = function()
		return { GetPlayerCurrentScore = function(_, pid) return D.era[pid] or 0 end }
	end

	for _, id in ipairs(FAKE.SortedKeys(FAKE.players)) do
		Attach(id, FAKE.players[id])
	end
end
