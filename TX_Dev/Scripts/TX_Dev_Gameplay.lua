-- ===========================================================================
-- TX_Dev_Gameplay.lua  (TX_Dev 0.0.1.5, spike kit for Team Expulsion 0.0.1)
-- Context: gameplay (AddGameplayScripts). TESTING ONLY. PLAN I.5.
--
-- One handler, GameEvents.TX_Dev(playerID, params), dispatching on params.cmd
-- (the EFV_Dev pattern, EFV_Dev_Gameplay.lua:3997-4016). Requests come from
-- UI/TX_Dev_Panel.lua as flat params (numbers and strings only):
--   cmd, stamp (turn*1000 + n), target, team, ctx, plus per-command fields.
-- The turn-start snapshot runs on GameEvents.OnGameTurnStarted.
--
-- State lives in Game properties written only here (Game:SetProperty is G):
--   TX_DEV_ARM  the arm record (PLAN I.2 schema), plus the setup records
--               v4 / v5 / v9 / v10 made before arming
--   TX_DEV_S1   { stamp, n, keys = { {ctx, obj, key} } }  setter-like keys of the G dump
--   TX_DEV_S2   { stamp, n, hits = { {ctx, root, sel, name, style, args} } }  G setters that exist
-- No booleans (0/1), no empty tables or strings, lists are ordered arrays.
--
-- MP rules: no pairs() (TXD.SortedKeys only), no math.random, no
-- Game.GetLocalPlayer, players and plots in ascending order, no Events.*.
-- Every command runs in pcall; errors log "[TX][SPIKE][REQ] G ERROR <cmd> <err>".
-- Calls not VERIFIED in PLAN Appendix A go through TX_Probe.
-- ===========================================================================
include("TX_Dev_Lib")
local TXD = TXD
local TX_Probe = TX_Probe
TXD.Init("G")
TXD.SetRoots({
	Players = function() return Players end,
	PlayerConfigurations = function() return PlayerConfigurations end,
	Teams = function() return Teams end,
	Game = function() return Game end,
	GameConfiguration = function() return GameConfiguration end,
	PlayerManager = function() return PlayerManager end,
	DiplomacyManager = function() return DiplomacyManager end,
	Network = function() return Network end,
	PlayersVisibility = function() return PlayersVisibility end,
	DealManager = function() return DealManager end,
	DealItemTypes = function() return DealItemTypes end,
	DealItemSubTypes = function() return DealItemSubTypes end,
	DealAgreementTypes = function() return DealAgreementTypes end,
	DB = function() return DB end,
})

local Str = TXD.Str
local Spike = TXD.Spike
local Check = TXD.Check
local Turn = TXD.Turn

local KEY_ARM = "TX_DEV_ARM"
local KEY_S1 = "TX_DEV_S1"
local KEY_S2 = "TX_DEV_S2"
local CIVIC_OB = "CIVIC_EARLY_EMPIRE"   -- open borders prereq (EFV_Dev_Gameplay.lua:860)
local OB_TURNS = 30
local REVEAL_RADIUS = 3

-- Load detection (PLAN I.2): a fresh Lua state after every load.
local m_LoadCounted = false   -- this state already decided whether it is a load
local m_WroteArm = false      -- this state wrote TX_DEV_ARM
local m_LastCounted = false   -- the current request counted the load

local SnapshotG               -- forward
local AL3TReadG              -- forward

-- ---------------------------------------------------------------------------
-- Properties
-- ---------------------------------------------------------------------------
local function ArmLoad()
	local ok, a = pcall(function() return Game:GetProperty(KEY_ARM) end)
	if ok and type(a) == "table" then
		return a
	end
	return { v = 1 }
end

local function IsArmed(arm)
	return type(arm) == "table" and arm.armedTurn ~= nil
end

local function ArmSave(arm)
	arm.v = 1
	Game:SetProperty(KEY_ARM, arm)
	m_WroteArm = true
end

local function S1Keys()
	local ok, s = pcall(function() return Game:GetProperty(KEY_S1) end)
	local out = {}
	if ok and type(s) == "table" and type(s.keys) == "table" then
		for _, k in ipairs(s.keys) do
			if k.obj ~= "-" then
				out[#out + 1] = { obj = k.obj, key = k.key }
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------
local function P(pid)
	if type(pid) ~= "number" then
		return nil
	end
	local ok, p = pcall(function() return Players[pid] end)
	if ok then
		return p
	end
	return nil
end

local function Flag(fn)
	local ok, v = pcall(fn)
	return ok and v == true
end

local function Alive(pid)
	local p = P(pid)
	return p ~= nil and Flag(function() return p:IsAlive() end)
end

local function IsMajor(pid)
	local p = P(pid)
	return p ~= nil and Flag(function() return p:IsMajor() end)
end

local function IsHuman(pid)
	local p = P(pid)
	return p ~= nil and Flag(function() return p:IsHuman() end)
end

local function FreeCitiesID()
	local ok, id = pcall(function() return PlayerManager.GetFreeCitiesPlayerID() end)
	if ok and type(id) == "number" then
		return id
	end
	return 62
end

-- Free Cities and Barbarians: never counted for wars or solo team IDs (PB).
local function IsOther(pid)
	local p = P(pid)
	if p == nil then
		return false
	end
	return pid == FreeCitiesID() or Flag(function() return p:IsBarbarian() end)
end

local function TeamOf(pid)
	local p = P(pid)
	if p == nil then
		return nil
	end
	local ok, t = pcall(function() return p:GetTeam() end)
	if ok and type(t) == "number" then
		return t
	end
	return nil
end

local function B(v)
	if v then
		return "1"
	end
	return "0"
end

-- Every existing slot 0..63, ascending.
local function TeamRows()
	local rows = {}
	for i = 0, 63 do
		if P(i) ~= nil then
			rows[#rows + 1] = { pid = i, team = TeamOf(i), alive = TXD.B01(Alive(i)), major = TXD.B01(IsMajor(i)),
				human = TXD.B01(IsHuman(i)), other = TXD.B01(IsOther(i)) }
		end
	end
	return rows
end

local function Majors()
	local out = {}
	for i = 0, 63 do
		if Alive(i) and IsMajor(i) then
			out[#out + 1] = i
		end
	end
	return out
end

-- target, keeper, other: the arm's roles, or computed from p.target (PLAN I.8).
local function Roles(arm, p)
	if IsArmed(arm) then
		return arm.target, arm.keeper, arm.other
	end
	local target = tonumber(p and p.target) or 1
	local keeper, other = TXD.PickRoles(TeamRows(), target)
	return target, keeper, other
end

local function BaseTeam(arm, pid)
	for _, r in ipairs(arm.teamsBase or {}) do
		if r.pid == pid then
			return r.team
		end
	end
	return nil
end

-- Members of pid's team at arm time, ascending.
local function BaseMates(arm, pid)
	local t = BaseTeam(arm, pid)
	local out = {}
	for _, r in ipairs(arm.teamsBase or {}) do
		if t ~= nil and r.team == t then
			out[#out + 1] = r.pid
		end
	end
	return out
end

local function PName(pid)
	return "P" .. Str(pid)
end

-- ---------------------------------------------------------------------------
-- Diplomacy (direct, audited calls; EFV_Dev Diplo/Call pattern :85-94, 623-628)
-- ---------------------------------------------------------------------------
local function AtWar(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():IsAtWarWith(b) end)
	if ok then
		return v == true
	end
	return nil
end

local function Allied(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():HasAllied(b) end)
	if ok then
		return v == true
	end
	return nil
end

local function Friends(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():HasDeclaredFriendship(b) end)
	if ok then
		return v == true
	end
	return nil
end

local function Met(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():HasMet(b) end)
	if ok then
		return v == true
	end
	return nil
end

-- EFV_Dev_Gameplay.lua:643-646
local function MeetPair(a, b)
	pcall(function() Players[a]:GetDiplomacy():SetHasMet(b) end)
	pcall(function() Players[b]:GetDiplomacy():SetHasMet(a) end)
end

-- EFV_Dev_Gameplay.lua:247-252 (SetDiploPair), friendship only.
local function SetFriendPair(a, b, value)
	local ok1, e1 = pcall(function() Players[a]:GetDiplomacy():SetHasDeclaredFriendship(b, value) end)
	local ok2, e2 = pcall(function() Players[b]:GetDiplomacy():SetHasDeclaredFriendship(a, value) end)
	if not (ok1 and ok2) then
		Spike("V10", "SetHasDeclaredFriendship " .. PName(a) .. "<->" .. PName(b) .. " err=" .. Str(e1) .. " / " .. Str(e2))
	end
	return ok1 and ok2
end

-- a declares formal war on b; b on a as the fallback (EFV_Dev_Gameplay.lua:632-641).
local function DeclareWar(a, b)
	if a == nil or b == nil or a < 0 or b < 0 or AtWar(a, b) then
		return AtWar(a, b) == true
	end
	local ok, err = pcall(function() Players[a]:GetDiplomacy():DeclareWarOn(b, WarTypes.FORMAL_WAR, true) end)
	if not AtWar(a, b) then
		local ok2, err2 = pcall(function() Players[b]:GetDiplomacy():DeclareWarOn(a, WarTypes.FORMAL_WAR, true) end)
		Spike("DIPLO", PName(a) .. " declares war on " .. PName(b) .. " ok=" .. tostring(ok) .. " err=" .. Str(err) ..
			"; fallback " .. PName(b) .. " on " .. PName(a) .. " ok=" .. tostring(ok2) .. " err=" .. Str(err2))
	end
	return AtWar(a, b) == true
end

-- EFV_Dev_Gameplay.lua:920-924
local function GrantCivic(pid, civicType, section)
	local ok, err = pcall(function() Players[pid]:GetCulture():SetCivic(GameInfo.Civics[civicType].Index, true) end)
	Spike(section or "V9", "civic " .. PName(pid) .. " " .. civicType .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
	return ok
end

-- Deal scan (EFV_Rules.lua:304-333): OB from both sides, GPT through a probe.
-- obAB = a grants b open borders. Returns { n, obAB, obBA, gpt, gptTok, err }.
local function DealScan(a, b)
	local res = { n = 0, obAB = 0, obBA = 0, gpt = 0, gptTok = "-" }
	local ok, err = pcall(function()
		local deals = DealManager.GetPlayerDeals(a, b)
		if deals == nil then
			return
		end
		local rg = TX_Probe(false, "DealItemTypes", nil, "=GOLD")
		local rn = TX_Probe(false, "DealItemSubTypes", nil, "=NONE")
		local gold, none = rg.rets[1], rn.rets[1]
		for _, pDeal in ipairs(deals) do
			res.n = res.n + 1
			local itA = pDeal:FindItemByType(DealItemTypes.AGREEMENTS, DealAgreementTypes.OPEN_BORDERS, a)
			if itA ~= nil and itA:GetFromPlayerID() == a then
				res.obAB = 1
			end
			local itB = pDeal:FindItemByType(DealItemTypes.AGREEMENTS, DealAgreementTypes.OPEN_BORDERS, b)
			if itB ~= nil and itB:GetFromPlayerID() == b then
				res.obBA = 1
			end
			if gold ~= nil and none ~= nil then
				local r = TX_Probe(false, pDeal, nil, ":FindItemByType", gold, none, a)
				if r.ok and r.rets[1] ~= nil then
					res.gpt = 1
					res.gptTok = "item"
				elseif r.ok then
					res.gptTok = "none"
				else
					res.gptTok = TXD.Tok(r)
				end
			else
				res.gptTok = "GOLD:" .. TXD.Tok(rg) .. ",NONE:" .. TXD.Tok(rn)
			end
		end
	end)
	if not ok then
		res.err = Str(err)
	end
	return res
end

-- grantor gives receiver open borders (EFV_Dev_Gameplay.lua:928-946, TX deal scan).
local function GrantOpenBorders(grantor, receiver)
	if DealScan(grantor, receiver).obAB == 1 then
		return true
	end
	local ok, err = pcall(function()
		DealManager.ClearWorkingDeal(DealDirection.OUTGOING, grantor, receiver)
		local pDeal = DealManager.GetWorkingDeal(DealDirection.OUTGOING, grantor, receiver)
		if pDeal == nil then
			error("GetWorkingDeal returned nil")
		end
		local item = pDeal:AddItemOfType(DealItemTypes.AGREEMENTS, grantor)
		if item == nil then
			error("AddItemOfType returned nil")
		end
		item:SetSubType(DealAgreementTypes.OPEN_BORDERS)
		item:SetDuration(OB_TURNS)
		item:SetLocked(true)
		pDeal:Validate()
		DealManager.EnactWorkingDeal(grantor, receiver)
	end)
	local has = DealScan(grantor, receiver).obAB == 1
	Spike("V9", PName(grantor) .. " grants " .. PName(receiver) .. " open borders (" .. OB_TURNS .. " turns): enact ok=" ..
		tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. ", seen by the deal scan=" .. tostring(has))
	return has
end

-- giver pays taker 1 gold per turn for 30 turns. Every step is a probe:
-- GOLD items have UI evidence only (DiplomacyDealView.lua:874-883).
local function GptDeal(giver, taker)
	local rg = TX_Probe("V9 gpt", "DealItemTypes", nil, "=GOLD")
	local gold = rg.rets[1]
	if gold == nil then
		return false
	end
	TX_Probe("V9 gpt", "DealManager", nil, ".ClearWorkingDeal", DealDirection.OUTGOING, giver, taker)
	local rd = TX_Probe("V9 gpt", "DealManager", nil, ".GetWorkingDeal", DealDirection.OUTGOING, giver, taker)
	local pDeal = rd.rets[1]
	if pDeal == nil then
		return false
	end
	local ri = TX_Probe("V9 gpt", pDeal, nil, ":AddItemOfType", gold, giver)
	local item = ri.rets[1]
	if item == nil then
		return false
	end
	TX_Probe("V9 gpt", item, nil, ":SetAmount", 1)
	TX_Probe("V9 gpt", item, nil, ":SetDuration", OB_TURNS)
	TX_Probe("V9 gpt", pDeal, nil, ":Validate")
	local re = TX_Probe("V9 gpt", "DealManager", nil, ".EnactWorkingDeal", giver, taker)
	return re.ok
end

-- ---------------------------------------------------------------------------
-- Map, cities, units (EFV_Dev patterns)
-- ---------------------------------------------------------------------------
-- EFV_Dev_Gameplay.lua:677-688
local function Capital(pid)
	local c = nil
	pcall(function() c = Players[pid]:GetCities():GetCapitalCity() end)
	if c ~= nil then
		return c
	end
	pcall(function()
		for _, city in Players[pid]:GetCities():Members() do
			if c == nil or city:GetID() < c:GetID() then
				c = city
			end
		end
	end)
	return c
end

local function Dist(x1, y1, x2, y2)
	local ok, d = pcall(function() return Map.GetPlotDistance(x1, y1, x2, y2) end)
	if ok and type(d) == "number" then
		return d
	end
	return 999
end

-- Plots at exactly distance ring, sorted by index (EFV_Dev_Gameplay.lua:705-720).
local function Ring(x, y, ring)
	local out = {}
	if ring == 0 then
		local ok, p = pcall(function() return Map.GetPlot(x, y) end)
		if ok and p ~= nil then
			out[1] = p
		end
		return out
	end
	local ok, plots = pcall(function() return Map.GetNeighborPlots(x, y, ring) end)
	if ok and plots ~= nil then
		for _, p in ipairs(plots) do
			if Dist(x, y, p:GetX(), p:GetY()) == ring then
				out[#out + 1] = p
			end
		end
	end
	table.sort(out, function(a, b) return a:GetIndex() < b:GetIndex() end)
	return out
end

-- EFV_Dev_Gameplay.lua:167-174
local function FreeLand(plot)
	if plot == nil then
		return false
	end
	local ok, res = pcall(function()
		return plot:GetUnitCount() == 0 and not plot:IsWater() and not plot:IsImpassable()
			and CityManager.GetCityAt(plot:GetX(), plot:GetY()) == nil
	end)
	return ok and res == true
end

local function NotWonder(plot)
	local ok, w = pcall(function() return plot:IsNaturalWonder() end)
	return not (ok and w == true)
end

-- First free land plot from minRing to maxRing around (x, y) (EFV FindPlot :734-744).
local function FindFreePlot(x, y, maxRing, minRing)
	for ring = minRing or 0, maxRing do
		for _, p in ipairs(Ring(x, y, ring)) do
			if FreeLand(p) and NotWonder(p) then
				return p
			end
		end
	end
	return nil
end

-- EFV_Dev_Gameplay.lua:215-225
local function CreateUnit(section, ownerID, unitType, x, y)
	local row = GameInfo.Units[unitType]
	if row == nil then
		Spike(section, "unknown unit type " .. Str(unitType))
		return nil
	end
	local ok, u = pcall(function() return Players[ownerID]:GetUnits():Create(row.Index, x, y) end)
	if not ok or u == nil then
		Spike(section, "Create failed for " .. Str(unitType) .. " at " .. Str(x) .. "," .. Str(y) .. ": " .. Str(u))
		return nil
	end
	return u
end

-- Walls down and the city centre at 1 HP (EFV_Dev_Gameplay.lua:974-988; refs :854-873).
local function WeakenCity(city)
	local ok, msg = pcall(function()
		local d = CityManager.GetDistrictAt(city:GetX(), city:GetY())
		if d == nil then
			error("no district at the city centre")
		end
		local G, O = DefenseTypes.DISTRICT_GARRISON, DefenseTypes.DISTRICT_OUTER
		local oMax = tonumber(d:GetMaxDamage(O)) or 0
		if oMax > 0 then
			d:SetDamage(O, oMax)
		end
		local gMax = tonumber(d:GetMaxDamage(G)) or 0
		if gMax > 1 then
			d:SetDamage(G, gMax - 1)
		end
		return "city HP " .. (gMax - (tonumber(d:GetDamage(G)) or 0)) .. "/" .. gMax .. ", walls " ..
			(oMax - (tonumber(d:GetDamage(O)) or 0)) .. "/" .. oMax
	end)
	return ok, Str(msg)
end

-- Reveals the plots within radius of (x, y) to pid (EFV_Dev RevealCity :900-918).
local function Reveal(pid, x, y, radius)
	local n, err = 0, nil
	for ring = 0, radius do
		for _, plot in ipairs(Ring(x, y, ring)) do
			local ok, e = pcall(function() PlayersVisibility[pid]:ChangeVisibilityCount(plot:GetIndex(), 1) end)
			if ok then
				n = n + 1
			else
				err = e
			end
		end
	end
	return n, err
end

-- The capital a major had at arm time (arm.caps), else its current capital.
local function CapCity(arm, pid)
	for _, c in ipairs(arm.caps or {}) do
		if c.pid == pid then
			local ok, city = pcall(function() return CityManager.GetCityAt(c.x, c.y) end)
			if ok and city ~= nil then
				return city
			end
		end
	end
	return Capital(pid)
end

-- Cities and units of pid as { {x, y} }.
local function Assets(pid)
	local out = {}
	pcall(function()
		for _, c in Players[pid]:GetCities():Members() do
			out[#out + 1] = { x = c:GetX(), y = c:GetY() }
		end
	end)
	pcall(function()
		for _, u in Players[pid]:GetUnits():Members() do
			out[#out + 1] = { x = u:GetX(), y = u:GetY() }
		end
	end)
	return out
end

-- ---------------------------------------------------------------------------
-- Text helpers
-- ---------------------------------------------------------------------------
local function WarMatrix()
	local majors = Majors()
	local parts = {}
	for i = 1, #majors do
		for j = i + 1, #majors do
			if AtWar(majors[i], majors[j]) then
				parts[#parts + 1] = majors[i] .. "-" .. majors[j]
			end
		end
	end
	if #parts == 0 then
		return "war: none"
	end
	return "war: " .. table.concat(parts, " ")
end

-- S4: what gameplay sees of a change (PLAN I.7).
local function S4Text(t, want)
	local r = TX_Probe(false, "PlayerConfigurations", t, ":GetTeam")
	return "gameplay reads Players[" .. Str(t) .. "]:GetTeam()=" .. Str(TeamOf(t)) .. " (want " .. Str(want) ..
		"), cfg via probe=" .. TXD.Tok(r)
end

-- ---------------------------------------------------------------------------
-- AL: the leftover ALLIED state between ex-teammates (research/ALLIANCE.md 5)
-- ---------------------------------------------------------------------------
local function DiploG(pid)
	local ok, d = pcall(function() return Players[pid]:GetDiplomacy() end)
	if ok then
		return d
	end
	return nil
end

-- a's state toward b as a StateType string, probe (GCO_PlayerScript.lua:1033-1043).
-- Returns the string or nil, and a token for the log.
local function StateG(a, b)
	local ra = TX_Probe(false, "Players", a, ":GetAi_Diplomacy")
	if not ra.ok or ra.rets[1] == nil then
		return nil, "GetAi_Diplomacy:" .. TXD.Tok(ra)
	end
	local rs = TX_Probe(false, ra.rets[1], nil, ":GetDiplomaticState", b)
	if rs.ok and type(rs.rets[1]) == "string" then
		return rs.rets[1], rs.rets[1]
	end
	return nil, TXD.Tok(rs)
end

-- The G read-out. item: the step ("AL0", "AL3", "AL3b", "AL7off", "K", ...);
-- stage: before | after | turn | a mid stage | nil. AL0 (the button) is always INFO.
local function ALReadG(arm, item, stage, note)
	local k, t = arm.keeper, arm.target
	local sTK, tokTK = StateG(t, k)
	local sKT, tokKT = StateG(k, t)
	local cw = TX_Probe(false, DiploG(k), nil, ":CanDeclareWarOn", t)
	local vis = "-"
	if type(arm.v5) == "table" then
		vis = TXD.Tok(TX_Probe(false, "PlayersVisibility", t, ":IsVisible", arm.v5.x, arm.v5.y))
	end
	local metKT, metTK = Met(k, t), Met(t, k)
	local facts = "war=" .. TXD.YN(AtWar(k, t)) .. " HasAllied k->t=" .. TXD.YN(Allied(k, t)) .. " t->k=" .. TXD.YN(Allied(t, k)) ..
		" friends k->t=" .. TXD.YN(Friends(k, t)) .. " t->k=" .. TXD.YN(Friends(t, k)) .. " met k->t=" .. TXD.YN(metKT) .. " t->k=" .. TXD.YN(metTK) ..
		" G state(target view)=" .. tokTK .. " (keeper view)=" .. tokKT .. " CanDeclareWarOn k->t=" .. TXD.Tok(cw) ..
		" target sees marker=" .. vis
	local v, txt = TXD.Verdict.AL(TXD.PhaseLabel(arm), sTK, sKT, metKT, metTK)
	if item == "AL0" then
		v = "INFO"
	end
	local head = ""
	if stage ~= nil then
		head = stage .. ": "
	end
	Check(TXD.StepId(item, arm, stage), v, head .. txt .. "; keeper P" .. Str(k) .. " target P" .. Str(t) .. "; " .. facts ..
		(note and ("; " .. note) or ""))
	return facts
end

-- ---------------------------------------------------------------------------
-- VIS: the leftover shared vision (Session 2: it survives the split, AL3, AL7).
-- G half of the read-out. Visibility reads in G are probes (listing only).
-- ---------------------------------------------------------------------------
-- pid sees plot (x, y): true / false / nil (unreadable), and the probe token.
local function VisG(pid, x, y)
	local r = TX_Probe(false, "PlayersVisibility", pid, ":IsVisible", x, y)
	if r.ok and type(r.rets[1]) == "boolean" then
		return r.rets[1], TXD.Tok(r)
	end
	return nil, TXD.Tok(r)
end

-- Distance from (x, y) to pid's nearest city or unit (9999 when it has none).
local function NearestAsset(pid, x, y)
	local _, d = TXD.FarthestPlot({ { x = x, y = y, idx = 0 } }, Assets(pid), Dist)
	return d
end

-- The keeper city farthest from every target asset: { x, y, near } or nil.
local function FarCity(k, t)
	local cands = {}
	pcall(function()
		for _, c in Players[k]:GetCities():Members() do
			cands[#cands + 1] = { x = c:GetX(), y = c:GetY(), idx = c:GetID() }
		end
	end)
	local best, d = TXD.FarthestPlot(cands, Assets(t), Dist)
	if best == nil then
		return nil
	end
	return { x = best.x, y = best.y, near = d }
end

-- a's active diplomatic visibility sources on b (GameInfo.DiplomaticVisibilitySources,
-- IsVisibilitySourceActive(b, row.Index) as in DiplomacyActionView.lua:996-997, a probe).
local function VisSources(a, b)
	local d = DiploG(a)
	local active, bad = {}, nil
	local ok, err = pcall(function()
		for row in GameInfo.DiplomaticVisibilitySources() do
			local r = TX_Probe(false, d, nil, ":IsVisibilitySourceActive", b, row.Index)
			if not r.ok then
				bad = bad or TXD.Tok(r)
			elseif r.rets[1] == true then
				active[#active + 1] = Str(row.VisibilitySourceType)
			end
		end
	end)
	if not ok then
		return "ERR:" .. string.gsub(Str(err), "%s+", "_")
	end
	if bad ~= nil then
		return bad
	end
	if #active == 0 then
		return "none"
	end
	return table.concat(active, ",")
end

local function VisOnTok(a, b)
	return TXD.Tok(TX_Probe(false, DiploG(a), nil, ":GetVisibilityOn", b))
end

-- The G VIS read-out. item: VIS0 (always INFO), VIS1..VIS3, Kvis.
local function VisReadG(arm, item, stage, note)
	local k, t = arm.keeper, arm.target
	local m, c = { has = false }, { has = false }
	local where, toks = {}, {}
	if type(arm.v5) == "table" then
		local x, y = arm.v5.x, arm.v5.y
		local kS, kTok = VisG(k, x, y)
		local tS, tTok = VisG(t, x, y)
		m = { has = true, k = kS, t = tS, near = NearestAsset(t, x, y) }
		where[#where + 1] = "marker at " .. Str(x) .. "," .. Str(y)
		toks[#toks + 1] = "marker k=" .. kTok .. " t=" .. tTok
	end
	local city = FarCity(k, t)
	if city ~= nil then
		local kS, kTok = VisG(k, city.x, city.y)
		local tS, tTok = VisG(t, city.x, city.y)
		c = { has = true, k = kS, t = tS, near = city.near }
		where[#where + 1] = "city at " .. city.x .. "," .. city.y
		toks[#toks + 1] = "city k=" .. kTok .. " t=" .. tTok
	end
	local v, txt = TXD.Verdict.VIS(TXD.PhaseLabel(arm), m, c)
	if item == "VIS0" then
		v = "INFO"
	end
	local head = ""
	if stage ~= nil then
		head = stage .. ": "
	end
	Check(TXD.StepId(item, arm, stage), v, head .. txt .. "; keeper P" .. Str(k) .. " target P" .. Str(t) .. "; " ..
		(#where > 0 and table.concat(where, ", ") or "no marker, no keeper city") .. "; G IsVisible " ..
		(#toks > 0 and table.concat(toks, " ") or "-") .. "; GetVisibilityOn k->t=" .. VisOnTok(k, t) .. " t->k=" ..
		VisOnTok(t, k) .. "; sources k->t=" .. VisSources(k, t) .. " t->k=" .. VisSources(t, k) ..
		(note and ("; " .. note) or ""))
end

-- VIS1 (and K): keeper and target stop sending their vision to each other
-- (PlayersVisibility[p]:RemoveOutgoingVisibility(other), S1 dump G; gated to VIS / K).
local function VisRemove(label, k, t)
	local r1 = TX_Probe(label, "PlayersVisibility", k, ":RemoveOutgoingVisibility", t)
	local r2 = TX_Probe(label, "PlayersVisibility", t, ":RemoveOutgoingVisibility", k)
	return r1.ok and r2.ok
end

-- ---------------------------------------------------------------------------
-- Load detection (PLAN I.2)
-- ---------------------------------------------------------------------------
-- Counts a load once per Lua state: TX_DEV_ARM is armed and this state did
-- not write it. Returns true when this call counted it.
local function CountLoad(arm)
	if m_LoadCounted then
		return false
	end
	m_LoadCounted = true
	if not IsArmed(arm) or m_WroteArm then
		return false
	end
	arm.loads = (tonumber(arm.loads) or 0) + 1
	local note = ""
	if arm.phase == nil or arm.phase == "BASE" then
		local base, now = BaseTeam(arm, arm.target), TeamOf(arm.target)
		if base ~= nil and now ~= nil and base ~= now then
			arm.path, arm.phase, arm.loads, arm.changeTurn = "S3b", "RELOAD", 1, Turn()
			Spike("S3b", "team changed outside the panel (lobby?): P" .. Str(arm.target) .. " team " .. base .. " -> " .. now)
		else
			note = " (armed at BASE, reloaded " .. arm.loads .. ")"
		end
	else
		arm.phase = "RELOAD"
	end
	ArmSave(arm)
	Spike("SNAP", "load counted loads=" .. arm.loads .. " phase=" .. TXD.PhaseLabel(arm) .. note)
	return true
end

-- ---------------------------------------------------------------------------
-- Snapshot (PLAN I.5 SnapshotG)
-- ---------------------------------------------------------------------------
local function Safe(section, fn)
	local ok, err = pcall(fn)
	if not ok then
		Spike("SNAP", "ERROR " .. section .. " " .. Str(err))
	end
end

SnapshotG = function(reason)
	local arm = ArmLoad()
	CountLoad(arm)
	if not IsArmed(arm) then
		if reason == "button" then
			Spike("SNAP", "not armed: press Arm BASE + snapshot first")
		end
		return
	end
	local label = TXD.PhaseLabel(arm)
	local isBase = TXD.IsBase(label)
	local target, keeper, other = arm.target, arm.keeper, arm.other
	local g = {}
	local groups = TXD.GroupsText(TXD.TeamGroups(TeamRows()))
	local war = WarMatrix()
	local fp = TXD.Fingerprint(groups .. "|" .. war)
	Spike("SNAP", label .. " reason=" .. Str(reason) .. " teams: " .. groups .. " fp=" .. fp .. " " .. war)

	Safe("V1", function()
		Check(TXD.CheckId("V1", arm), TXD.Verdict.V1(label, TeamOf(target), TeamOf(keeper)))
	end)

	Safe("V3", function()
		local parts = {}
		for _, c in ipairs(arm.caps or {}) do
			local ok, city = pcall(function() return CityManager.GetCityAt(c.x, c.y) end)
			if ok and city ~= nil then
				local owner, orig = nil, nil
				pcall(function() owner = city:GetOwner() end)
				pcall(function() orig = city:GetOriginalOwner() end)
				local rc = TX_Probe(false, city, nil, ":IsOriginalCapital")
				parts[#parts + 1] = "P" .. c.pid .. "@" .. c.x .. "," .. c.y .. " owner=" .. Str(owner) .. " orig=" .. Str(orig) ..
					" isOrigCap=" .. TXD.Tok(rc)
			else
				parts[#parts + 1] = "P" .. c.pid .. "@" .. c.x .. "," .. c.y .. " no city"
			end
		end
		local v3 = ""
		if type(arm.v3) == "table" then
			v3 = "; V3 attacker P" .. Str(arm.v3.who) .. " since turn " .. Str(arm.v3.turn)
		end
		Check(TXD.CheckId("V3", arm), "INFO", "original capitals: " .. (#parts > 0 and table.concat(parts, "; ") or "none") .. v3)
	end)

	Safe("V5", function()
		if type(arm.v5) ~= "table" then
			return
		end
		local rt = TX_Probe(false, "PlayersVisibility", target, ":IsVisible", arm.v5.x, arm.v5.y)
		local rk = TX_Probe(false, "PlayersVisibility", keeper, ":IsVisible", arm.v5.x, arm.v5.y)
		Check(TXD.CheckId("V5", arm), "INFO", "visibility read in gameplay (probe): target sees marker=" .. TXD.Tok(rt) ..
			" keeper=" .. TXD.Tok(rk) .. " at " .. arm.v5.x .. "," .. arm.v5.y)
	end)

	Safe("V6", function()
		if type(arm.v6) ~= "table" then
			return
		end
		local id = TXD.CheckId("V6", arm)
		if Turn() <= (tonumber(arm.v6.turn) or 0) then
			Check(id, "INFO", "war declared on turn " .. Str(arm.v6.turn) .. "; the verdict comes at the next turn start")
			return
		end
		local mates = {}
		for _, m in ipairs(BaseMates(arm, other)) do
			if m ~= other then
				mates[#mates + 1] = "P" .. m .. " vs target=" .. TXD.YN(AtWar(m, target))
			end
		end
		local v, t = TXD.Verdict.V6(label, AtWar(other, keeper), AtWar(other, target))
		Check(id, v, t .. "; other's teammates: " .. (#mates > 0 and table.concat(mates, ", ") or "none"))
	end)

	Safe("V7", function()
		local s = DealScan(keeper, target)
		local rv = TX_Probe(false, "Players", keeper, ":GetDiplomacy")
		local vis = "-"
		if rv.ok and rv.rets[1] ~= nil then
			vis = TXD.Tok(TX_Probe(false, rv.rets[1], nil, ":GetVisibilityOn", target))
		end
		g.v7war, g.v7allied, g.v7friend = TXD.B01(AtWar(keeper, target)), TXD.B01(Allied(keeper, target)), TXD.B01(Friends(keeper, target))
		g.v7met, g.v7ob12, g.v7ob21 = TXD.B01(Met(keeper, target)), s.obAB, s.obBA
		Check(TXD.CheckId("V7", arm), "INFO", "keeper-target war=" .. Str(g.v7war) .. " allied=" .. Str(g.v7allied) ..
			" friends=" .. Str(g.v7friend) .. " met=" .. Str(g.v7met) .. " ob keeper->target=" .. s.obAB ..
			" ob target->keeper=" .. s.obBA .. " GetVisibilityOn=" .. vis)
	end)

	Safe("V9", function()
		local s = DealScan(target, other)
		local now = { ob12 = s.obAB, ob21 = s.obBA, gpt = s.gpt }
		g.v9ob12, g.v9ob21, g.v9gpt = s.obAB, s.obBA, s.gpt
		local base = nil
		if type(arm.g) == "table" and arm.g.v9ob12 ~= nil then
			base = { ob12 = arm.g.v9ob12, ob21 = arm.g.v9ob21, gpt = arm.g.v9gpt }
		elseif type(arm.v9) == "table" then
			base = { ob12 = arm.v9.ob12, ob21 = arm.v9.ob21, gpt = arm.v9.gpt }
		end
		local v, t = TXD.Verdict.V9(label, base, now)
		Check(TXD.CheckId("V9", arm), v, t .. "; deals=" .. s.n .. " gpt probe=" .. Str(s.gptTok) .. (s.err and (" err=" .. s.err) or ""))
	end)

	Safe("V10", function()
		local ab, ba = Friends(target, other), Friends(other, target)
		g.v10 = TXD.B01(ab == true and ba == true)
		local base = nil
		if type(arm.g) == "table" then
			base = arm.g.v10
		end
		Check(TXD.CheckId("V10", arm), TXD.Verdict.V10(label, base, ab, ba))
	end)

	Safe("AL", function()
		if reason == "turn" and type(arm.al) == "table" and Turn() > (tonumber(arm.al.turn) or 0) then
			local note = "turn " .. Turn() .. ", AL" .. Str(arm.al.n) .. " pressed on turn " .. Str(arm.al.turn)
			if arm.al.n == "3T" then
				AL3TReadG(arm, "turn", note)
			else
				ALReadG(arm, "AL" .. Str(arm.al.n), "turn", note)
			end
		end
	end)

	Safe("VIS", function()
		if reason == "turn" and type(arm.vis) == "table" and Turn() > (tonumber(arm.vis.turn) or 0) then
			VisReadG(arm, "VIS" .. Str(arm.vis.n), "turn", "turn " .. Turn() .. ", VIS" .. Str(arm.vis.n) .. " pressed on turn " ..
				Str(arm.vis.turn))
		end
	end)

	Safe("K", function()
		if reason == "turn" and type(arm.k) == "table" and Turn() > (tonumber(arm.k.turn) or 0) then
			local note = "turn " .. Turn() .. ", K pressed on turn " .. Str(arm.k.turn)
			ALReadG(arm, "K", "turn", note)
			VisReadG(arm, "Kvis", "turn", note)
		end
	end)

	Check(TXD.CheckId("V12", arm), "INFO", "fp=" .. fp .. " turn=" .. Turn())
	Safe("S4", function()
		local by = ""
		if arm.path ~= nil and arm.path ~= "BASE" then
			by = ", path " .. arm.path .. " since turn " .. Str(arm.changeTurn)
		end
		Check("S4-G." .. label, "INFO", S4Text(target, arm.newTeam) .. by .. " (snapshot " .. Str(reason) .. ")")
	end)

	if isBase then
		local fresh = ArmLoad()
		fresh.g = g
		ArmSave(fresh)
	end
end

-- ---------------------------------------------------------------------------
-- Commands: CMD[cmd](playerID, params)
-- ---------------------------------------------------------------------------
local CMD = {}

-- The change happened (S3 from the UI, S2 here or in the UI). PLAN I.5 "changed".
local function Changed(playerID, p, path)
	local arm = ArmLoad()
	local t = tonumber(p.target)
	local team = tonumber(p.team)
	if not IsArmed(arm) then
		Spike("S4", "changed path=" .. Str(path) .. " but not armed (press Arm BASE first); " .. S4Text(t, team) ..
			", change made by P" .. Str(playerID) .. " in " .. Str(p.ctx))
		return
	end
	arm.path, arm.phase, arm.changeTurn, arm.loads = path, "LIVE", Turn(), 0
	if team ~= nil then
		arm.newTeam = team
	end
	if p.stamp ~= nil then
		arm.stamp = p.stamp
	end
	ArmSave(arm)
	m_LoadCounted = true
	if t == nil then
		t = arm.target
	end
	Check("S4-G." .. TXD.PhaseLabel(arm), "INFO", S4Text(t, team or arm.newTeam) .. ", change made by P" ..
		Str(playerID) .. " in " .. Str(p.ctx))
	SnapshotG("changed")
end

CMD.s1_dump = function(playerID, p)
	local found = TXD.DumpAll("S1")
	local keys, names = {}, {}
	for _, f in ipairs(found) do
		keys[#keys + 1] = { ctx = "G", obj = f.obj, key = f.key }
		names[#names + 1] = f.obj .. ":" .. f.key
	end
	Check("S1-G", "INFO", "setters: " .. (#names > 0 and table.concat(names, " ") or "none"))
	local rec = { stamp = tonumber(p.stamp) or 0, n = #keys }
	if #keys > 0 then
		rec.keys = keys
	end
	Game:SetProperty(KEY_S1, rec)
end

CMD.s1_map = function(playerID, p)
	local rows, cfgOk = {}, false
	for i = 0, 63 do
		if P(i) ~= nil then
			local t = TeamOf(i)
			local r = TX_Probe(false, "PlayerConfigurations", i, ":GetTeam")
			local cfg = nil
			if r.ok and type(r.rets[1]) == "number" then
				cfg = r.rets[1]
				cfgOk = true
			end
			rows[#rows + 1] = { pid = i, team = t, cfg = cfg, other = TXD.B01(IsOther(i)) }
			Spike("S1", "slot " .. i .. " team=" .. Str(t) .. " alive=" .. B(Alive(i)) .. " major=" .. B(IsMajor(i)) ..
				" human=" .. B(IsHuman(i)) .. " cfgTeam=" .. TXD.Tok(r))
		end
	end
	Spike("S1", "teams: " .. TXD.GroupsText(TXD.TeamGroups(rows)))
	local unused = TXD.UnusedTeam(TXD.UsedTeams(rows))
	Spike("S1", "unused team: " .. unused .. " (lowest non-negative ID no slot uses; solo players own team IDs, R A1)")
	local k, n = TXD.SoloIdStats(rows)
	Check("S1TEAM-G", "INFO", "solo team==pid " .. k .. "/" .. n .. "; unused=" .. unused .. "; cfg readable in G=" ..
		(cfgOk and "yes" or "no"))
end

CMD.s2_probe = function(playerID, p)
	local arm = ArmLoad()
	local target = tonumber(p.target) or arm.target or 1
	local orig = TeamOf(target)
	if IsArmed(arm) then
		orig = arm.origTeam
	end
	local hits, names = {}, {}
	for _, c in ipairs(TXD.SetterCandidates(S1Keys())) do
		local r = TX_Probe("S2 exist", c.root, TXD.SelValue(c.sel, target, orig), "?" .. c.name)
		if r.exists == "function" then
			local h = { ctx = "G", root = c.root, name = c.name, style = c.style, args = c.args }
			if c.sel ~= nil then
				h.sel = c.sel
			end
			hits[#hits + 1] = h
			names[#names + 1] = TXD.SetterText(c)
		end
	end
	Check("S2-G", "INFO", "exist: " .. (#names > 0 and table.concat(names, " ") or "none"))
	local rec = { stamp = tonumber(p.stamp) or 0, n = #hits }
	if #hits > 0 then
		rec.hits = hits
	end
	Game:SetProperty(KEY_S2, rec)
end

CMD.s2_call = function(playerID, p)
	local root, name = Str(p.root), Str(p.name)
	local style = ":"
	if p.style == "." then
		style = "."
	end
	if TXD.IsNever(root, name) then
		Spike("S2", "REFUSED never-call " .. root .. "." .. name)
		Check("S2-G", "INFO", "call refused: " .. root .. "." .. name .. " is on the never-call list")
		return
	end
	local target, team = tonumber(p.target), tonumber(p.team)
	if target == nil or team == nil then
		Spike("S2", "CALL needs a target and a New team")
		return
	end
	local arm = ArmLoad()
	local orig = TeamOf(target)
	if IsArmed(arm) then
		orig = arm.origTeam
	end
	local sel = TXD.SelValue(p.sel, target, orig)
	local args, n = TXD.SetterArgs(p.args, target, team)
	Spike("S2", "about to call " .. TXD.SetterText({ root = root, sel = p.sel, style = style, name = name, args = p.args }) ..
		" target=P" .. target .. " team=" .. team .. " (a native crash loses the buffered log: write it in Result)")
	local r = TX_Probe("S2 CALL", root, sel, style .. name, unpack(args, 1, n))
	local tNow = TeamOf(target)
	local keeper = arm.keeper
	if not IsArmed(arm) then
		local _, k = Roles(arm, p)
		keeper = k
	end
	Spike("S2", "CALL " .. r.text .. "; now target team " .. Str(tNow) .. ", keeper team " .. Str(TeamOf(keeper)))
	Check("S2-G", "INFO", "call ok=" .. tostring(r.ok) .. " ret=" .. TXD.Tok(r) .. " target team now " .. Str(tNow))
	Changed(playerID, p, "S2")
end

CMD.arm = function(playerID, p)
	local old = ArmLoad()
	local target = tonumber(p.target) or 1
	local rows = TeamRows()
	local keeper, other = TXD.PickRoles(rows, target)
	local arm = {
		v = 1, armedTurn = Turn(), mp = tonumber(p.mp) or 0, hotseat = tonumber(p.hotseat) or 0,
		target = target, keeper = keeper, other = other,
		newTeam = tonumber(p.team) or TXD.UnusedTeam(TXD.UsedTeams(rows)),
		path = "BASE", phase = "BASE", loads = 0,
	}
	if p.stamp ~= nil then
		arm.stamp, arm.armStamp = p.stamp, p.stamp
	end
	arm.origTeam = TeamOf(target)
	local base = {}
	for _, r in ipairs(rows) do
		if r.team ~= nil then
			local e = { pid = r.pid, team = r.team }
			local cfg = tonumber(p["cfg_" .. r.pid])
			if cfg ~= nil then
				e.cfg = cfg
			end
			base[#base + 1] = e
		end
	end
	if #base > 0 then
		arm.teamsBase = base
	end
	local caps = {}
	for _, m in ipairs(Majors()) do
		local c = Capital(m)
		if c ~= nil then
			local okX, x, y = pcall(function() return c:GetX(), c:GetY() end)
			if okX then
				caps[#caps + 1] = { pid = m, x = x, y = y }
			end
		end
	end
	if #caps > 0 then
		arm.caps = caps
	end
	-- setup records made before arming stay (PLAN I.12 Session 1 steps 4 and 5)
	arm.v4, arm.v5, arm.v9, arm.v10 = old.v4, old.v5, old.v9, old.v10
	ArmSave(arm)
	Spike("SNAP", "armed roles keeper=P" .. Str(keeper) .. " target=P" .. target .. " other=P" .. Str(other) ..
		" origTeam=" .. Str(arm.origTeam) .. " newTeam=" .. Str(arm.newTeam) .. " mp=" .. arm.mp .. " hotseat=" .. arm.hotseat)
	SnapshotG("arm")
end

CMD.changed = function(playerID, p)
	local path = p.path
	-- S3n: the config write without a broadcast (0.0.1.4, research/RELOAD.md 3 probe)
	if path ~= "S3" and path ~= "S2" and path ~= "S3b" and path ~= "S3n" then
		path = "S3"
	end
	Changed(playerID, p, path)
end

CMD.loaded = function(playerID, p)
	if not m_LastCounted then
		Spike("SNAP", "loaded: no load to count in this Lua state (already counted, or not armed)")
		return
	end
	SnapshotG("loaded")
end

CMD.snap = function(playerID, p)
	SnapshotG("button")
end

CMD.store_ui = function(playerID, p)
	local arm = ArmLoad()
	if not IsArmed(arm) or arm.phase ~= "BASE" or p.armStamp == nil or p.armStamp ~= arm.armStamp then
		Spike("SNAP", "store_ui ignored (not armed at BASE, or the arm stamp " .. Str(p.armStamp) ..
			" is not " .. Str(arm.armStamp) .. ")")
		return
	end
	local values, n = TXD.Unflatten(p, "u_")
	if n > 0 then
		arm.ui = values
	end
	ArmSave(arm)
	Spike("SNAP", "stored " .. n .. " UI base values")
end

CMD.v4_boost = function(playerID, p)
	local arm = ArmLoad()
	local _, keeper = Roles(arm, p)
	local tech = Str(p.type)
	local row = nil
	for b in GameInfo.Boosts() do
		if row == nil and b.TechnologyType == tech and b.BoostClass == TXD.BOOST_OWN_UNITS then
			row = b
		end
	end
	if row == nil then
		Spike("V4", "no own-units boost row for " .. tech)
		return
	end
	local unit, want = row.Unit1Type, tonumber(row.NumItems) or 1
	local cap = Capital(keeper)
	if cap == nil then
		Spike("V4", "keeper P" .. Str(keeper) .. " has no capital")
		return
	end
	local made = 0
	for _ = 1, want do
		local plot = FindFreePlot(cap:GetX(), cap:GetY(), 3, 1)
		if plot ~= nil and CreateUnit("V4", keeper, unit, plot:GetX(), plot:GetY()) ~= nil then
			made = made + 1
		end
	end
	arm.v4 = arm.v4 or {}
	arm.v4[#arm.v4 + 1] = { tech = tech, unit = unit, n = made, turn = Turn(), path = arm.path or "BASE" }
	ArmSave(arm)
	Spike("V4", "spawned " .. made .. " " .. unit .. " for P" .. keeper .. " (" .. tech .. " boost: own " .. want .. ")")
end

CMD.v5_marker = function(playerID, p)
	local arm = ArmLoad()
	local target, keeper = Roles(arm, p)
	local w, h = Map.GetGridSize()
	local cands = {}
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local plot = Map.GetPlot(x, y)
			if FreeLand(plot) and NotWonder(plot) then
				local okO, owner = pcall(function() return plot:GetOwner() end)
				if okO and (owner == keeper or (type(owner) == "number" and owner < 0)) then
					cands[#cands + 1] = { x = x, y = y, idx = plot:GetIndex() }
				end
			end
		end
	end
	local best, d = TXD.FarthestPlot(cands, Assets(target), Dist)
	if best == nil then
		Spike("V5", "no free land plot owned by the keeper or nobody")
		return
	end
	local u = CreateUnit("V5", keeper, "UNIT_WARRIOR", best.x, best.y)
	if u == nil then
		return
	end
	pcall(function() UnitManager.FinishMoves(u) end)
	local uid = -1
	pcall(function() uid = u:GetID() end)
	arm.v5 = { x = best.x, y = best.y, u = uid }
	ArmSave(arm)
	Spike("V5", "marker P" .. keeper .. " Warrior at " .. best.x .. "," .. best.y .. ", nearest target asset " .. d .. " tiles")
end

CMD.v6_war = function(playerID, p)
	local arm = ArmLoad()
	if not IsArmed(arm) or arm.phase == "BASE" then
		Spike("V6", "refused before the change (a war can't be undone; peace has a 10-turn cooldown). Arm BASE, then make the change.")
		return
	end
	SnapshotG("pre-war")
	arm = ArmLoad()
	local keeper, target, other = arm.keeper, arm.target, arm.other
	MeetPair(other, keeper)
	local ok = DeclareWar(other, keeper)
	local who = { keeper, target, other }
	for _, m in ipairs(BaseMates(arm, other)) do
		if m ~= other then
			who[#who + 1] = m
		end
	end
	local cells = {}
	for i = 1, #who do
		for j = i + 1, #who do
			cells[#cells + 1] = who[i] .. "-" .. who[j] .. "=" .. TXD.YN(AtWar(who[i], who[j]))
		end
	end
	arm.v6 = { turn = Turn() }
	ArmSave(arm)
	Spike("V6", "P" .. other .. " declares war on P" .. keeper .. " ok=" .. tostring(ok) .. " ; war matrix " .. table.concat(cells, " "))
end

CMD.v9_deals = function(playerID, p)
	local arm = ArmLoad()
	local target, _, other = Roles(arm, p)
	MeetPair(target, other)
	GrantCivic(target, CIVIC_OB)
	GrantCivic(other, CIVIC_OB)
	GrantOpenBorders(target, other)
	GrantOpenBorders(other, target)
	GptDeal(target, other)
	local s = DealScan(target, other)
	arm.v9 = { ob12 = s.obAB, ob21 = s.obBA, gpt = s.gpt, turn = Turn() }
	ArmSave(arm)
	Spike("V9", "ob12=" .. s.obAB .. " ob21=" .. s.obBA .. " gpt=" .. s.gpt .. " deals=" .. s.n ..
		" (P" .. target .. " and P" .. other .. ")" .. (s.err and (" err=" .. s.err) or ""))
end

CMD.v10_friend = function(playerID, p)
	local arm = ArmLoad()
	local target, _, other = Roles(arm, p)
	MeetPair(target, other)
	SetFriendPair(target, other, true)
	local ab, ba = Friends(target, other), Friends(other, target)
	arm.v10 = { turn = Turn() }
	ArmSave(arm)
	Spike("V10", "friends=" .. TXD.YN(ab) .. "/" .. TXD.YN(ba) .. " (P" .. target .. " and P" .. other .. ")")
end

CMD.v3_setup = function(playerID, p)
	local arm = ArmLoad()
	if not IsArmed(arm) or arm.phase == "BASE" or type(arm.v6) ~= "table" then
		Spike("V3", "refused: arm BASE, make the change and press V6 first")
		return
	end
	local who = arm.keeper
	if p.who == "target" then
		who = arm.target
	end
	local whoBase = BaseTeam(arm, who)
	for _, m in ipairs(Majors()) do
		local mBase = BaseTeam(arm, m)
		if m ~= who and mBase ~= nil and mBase ~= whoBase then
			if not AtWar(who, m) then
				MeetPair(who, m)
				DeclareWar(who, m)
			end
			local city = CapCity(arm, m)
			if city == nil then
				Spike("V3", "P" .. who .. ": P" .. m .. " has no capital")
			else
				local x, y = city:GetX(), city:GetY()
				local n = Reveal(who, x, y, REVEAL_RADIUS)
				local tanks = {}
				for _ = 1, 3 do
					local plot = FindFreePlot(x, y, 2, 1)
					if plot ~= nil and CreateUnit("V3", who, "UNIT_TANK", plot:GetX(), plot:GetY()) ~= nil then
						tanks[#tanks + 1] = plot:GetX() .. "," .. plot:GetY()
					end
				end
				local okW, wmsg = WeakenCity(city)
				Spike("V3", "P" .. who .. ": capital of P" .. m .. " at " .. x .. "," .. y .. " weakened=" .. tostring(okW) ..
					" (" .. wmsg .. "), " .. #tanks .. " Tanks at " .. table.concat(tanks, " ") .. ", " .. n ..
					" plots revealed, at war=" .. TXD.YN(AtWar(who, m)))
			end
		end
	end
	arm.v3 = { who = who, turn = Turn() }
	ArmSave(arm)
end

-- Session 2 quick setup: V10 friends, V9 deals, V5 marker, in that order (V4 skipped:
-- its control failed in Session 1).
CMD.q_setup2 = function(playerID, p)
	Spike("SNAP", "Q Setup Session 2: V10 friends, V9 deals, V5 marker")
	for _, c in ipairs({ "v10_friend", "v9_deals", "v5_marker" }) do
		local ok, err = pcall(CMD[c], playerID, p)
		if not ok then
			Spike("REQ", "ERROR " .. c .. " " .. Str(err))
		end
	end
end

-- AL buttons (research/ALLIANCE.md 5). Roles from the arm: k keeper, t target.
local ALLIANCE_CIVIC = "CIVIC_CIVIL_SERVICE"   -- alliance prereq (ALLIANCE.md 3, rank 2)
local ALLIANCE_TYPE = "ALLIANCE_RESEARCH"      -- DiplomacyActionView_Expansion1.lua:165

-- The arm for a destructive AL or VIS step, or nil (refused at BASE: still teammates).
local function StepArm(section)
	local arm = ArmLoad()
	if not IsArmed(arm) or arm.phase == "BASE" then
		Spike(section, "refused: arm BASE and split the team first (or load TX3_split)")
		return nil
	end
	return arm
end

local function ALArm(n)
	return StepArm("AL" .. n)
end

-- Remember the step so the next turn starts read it again.
-- key: "al" (n = "3", "3b", "7off", ...), "vis" (n = 1..3) or "k".
local function StepDone(key, n)
	local arm = ArmLoad()
	arm[key] = { n = n, turn = Turn() }
	ArmSave(arm)
end

local function ALDone(n)
	StepDone("al", n)
end

-- AL0: the read-out only. Works unarmed too (roles from the panel Target).
CMD.al_read = function(playerID, p)
	local arm = ArmLoad()
	local a = arm
	if not IsArmed(arm) then
		local t, k = Roles(arm, p)
		a = { target = t, keeper = k, v5 = arm.v5 }
	end
	ALReadG(a, "AL0")
	VisReadG(a, "VIS0")
end

-- AL1: end the leftover friendship (SetHasDeclaredFriendship false both ways, AL G:C).
CMD.al1_friend_off = function(playerID, p)
	local arm = ALArm("1")
	if arm == nil then
		return
	end
	local k, t = arm.keeper, arm.target
	ALReadG(arm, "AL1", "before")
	local ok = SetFriendPair(k, t, false)
	Spike("AL1", "friendship off P" .. k .. "<->P" .. t .. " ok=" .. tostring(ok) .. " now k->t=" .. TXD.YN(Friends(k, t)) ..
		" t->k=" .. TXD.YN(Friends(t, k)))
	ALReadG(arm, "AL1", "after")
	ALDone("1")
end

-- AL2: existence only. The one call is the GetGameDiplomacy() getter, to reach
-- SetAlliesShareVisFlag (MC2 GameDiplomacy, G).
CMD.al2_exist = function(playerID, p)
	local arm = ArmLoad()
	local _, k = Roles(arm, p)
	local names = {}
	local function Ex(label, root, sel, member)
		local r = TX_Probe("AL2 exist", root, sel, member)
		names[#names + 1] = label .. "=" .. TXD.Tok(r)
		return r
	end
	local d = DiploG(k)
	for _, m in ipairs({ "SetHasAllied", "MakePeaceWith", "CanMakePeaceWith", "CanDeclareWarOn", "SetPermanentAlliance",
		"NeverMakePeaceWith", "SetHasDeclaredFriendship" }) do
		Ex("Diplomacy:" .. m, d, nil, "?" .. m)
	end
	Ex("Players:GetAi_Diplomacy", "Players", k, "?GetAi_Diplomacy")
	local rg = Ex("Game.GetGameDiplomacy", "Game", nil, "?GetGameDiplomacy")
	if rg.exists == "function" then
		local gd = TX_Probe("AL2 getter", "Game", nil, ".GetGameDiplomacy")
		Ex("GameDiplomacy:SetAlliesShareVisFlag", gd.rets[1], nil, "?SetAlliesShareVisFlag")
	end
	Ex("DealAgreementTypes.ALLIANCE", "DealAgreementTypes", nil, "=ALLIANCE")
	Ex("DB.MakeHash", "DB", nil, "?MakeHash")
	Check(TXD.ALId("2", arm), "INFO", "exist: " .. table.concat(names, " "))
end

-- War, then peace (GO_TO_WAR, then MAKE_PEACE -> UNFRIENDLY; DiplomaticActions.xml:261-262).
-- item: AL3, AL3b or K (check IDs and the spike section). third: the third
-- DeclareWarOn argument. true is the verified V6 shape (DeclareWar, with the
-- target-on-keeper fallback); false (AL3b) is a probe, keeper on target only.
-- MakePeaceWith is a probe (Pirates :767, GCO_DiplomacyScript.lua:163).
local function WarThenPeace(arm, item, third, reloadSave)
	local k, t = arm.keeper, arm.target
	local okW
	if third then
		okW = DeclareWar(k, t)
		Spike(item, "P" .. k .. " declares war on P" .. t .. " at war=" .. tostring(okW))
	else
		TX_Probe(item .. " war", DiploG(k), nil, ":DeclareWarOn", t, WarTypes.FORMAL_WAR, false)
		okW = AtWar(k, t) == true
		Spike(item, "P" .. k .. " declares war on P" .. t .. " (DeclareWarOn third arg false) at war=" .. tostring(okW))
	end
	ALReadG(arm, item, "war")
	TX_Probe(item .. " peace", DiploG(k), nil, ":MakePeaceWith", t, true)
	if AtWar(k, t) then
		TX_Probe(item .. " peace", DiploG(k), nil, ":MakePeaceWith", t)
	end
	if AtWar(k, t) then
		TX_Probe(item .. " peace", DiploG(t), nil, ":MakePeaceWith", k, true)
	end
	Spike(item, "peace: at war now=" .. TXD.YN(AtWar(k, t)))
	if AtWar(k, t) ~= false then
		Spike(item, "WARNING peace failed or unreadable: P" .. k .. " and P" .. t .. " may still be at war. Load " .. reloadSave .. ".")
	end
	return okW
end

-- AL3: war, then peace (DeclareWarOn third arg true, as V6).
CMD.al3_war_peace = function(playerID, p)
	local arm = ALArm("3")
	if arm == nil then
		return
	end
	ALReadG(arm, "AL3", "before")
	WarThenPeace(arm, "AL3", true, "TX3_split")
	ALReadG(arm, "AL3", "after")
	ALDone("3")
end

-- AL3b: AL3 with DeclareWarOn(t, WarTypes.FORMAL_WAR, false), to compare the penalties.
CMD.al3b_war_peace = function(playerID, p)
	local arm = ALArm("3b")
	if arm == nil then
		return
	end
	ALReadG(arm, "AL3b", "before")
	WarThenPeace(arm, "AL3b", false, "TX3_split")
	ALReadG(arm, "AL3b", "after")
	ALDone("3b")
end

-- ---------------------------------------------------------------------------
-- AL3T (0.0.1.5): the HARD kick's war step. The KICKED player (target) declares
-- war on each remaining living teammate of its ORIGINAL team (arm teamsBase,
-- ascending), then makes peace, so the grievances fall on the target
-- (DECISIONS 2026-10-04). AL3 proved keeper->target DeclareWarOn(t, FORMAL_WAR,
-- true) then MakePeaceWith(t, true) ends the ALLIED state. Open: the reverse
-- direction, and 2+ keepers (still one team: a war on one may be a war on all,
-- peace with one may or may not be peace with all). Hence: no declaration on a
-- keeper the target is already at war with, peace only with keepers still at war.
-- ---------------------------------------------------------------------------
local function AL3TKeepers(arm)
	return TXD.BaseKeepers(arm, Alive)
end

-- "P0-P1=no P0-P2=yes P1-P2=yes": war among the target and all keepers.
local function AL3TWarMatrix(arm, keepers)
	local ids = { arm.target }
	for _, k in ipairs(keepers) do
		ids[#ids + 1] = k
	end
	table.sort(ids)
	local parts = {}
	for i = 1, #ids do
		for j = i + 1, #ids do
			parts[#parts + 1] = "P" .. ids[i] .. "-P" .. ids[j] .. "=" .. TXD.YN(AtWar(ids[i], ids[j]))
		end
	end
	return table.concat(parts, " ")
end

-- The G read-out over every pair target<->keeper (G state both ways, as AL0).
AL3TReadG = function(arm, stage, note)
	local t = arm.target
	local keepers = AL3TKeepers(arm)
	local list, facts = {}, {}
	for _, k in ipairs(keepers) do
		local sTK, tokTK = StateG(t, k)
		local sKT, tokKT = StateG(k, t)
		local war = AtWar(t, k)
		if war ~= true and AtWar(k, t) == true then
			war = true
		end
		local metKT, metTK = Met(k, t), Met(t, k)
		list[#list + 1] = { k = k, sTK = sTK, sKT = sKT, metKT = metKT, metTK = metTK, war = war }
		facts[#facts + 1] = "P" .. t .. "<->P" .. k .. " G state(target view)=" .. tokTK .. " (keeper view)=" .. tokKT ..
			" war=" .. TXD.YN(war) .. " HasAllied k->t=" .. TXD.YN(Allied(k, t)) .. " t->k=" .. TXD.YN(Allied(t, k)) ..
			" friends k->t=" .. TXD.YN(Friends(k, t)) .. " t->k=" .. TXD.YN(Friends(t, k)) ..
			" met k->t=" .. TXD.YN(metKT) .. " t->k=" .. TXD.YN(metTK)
	end
	local v, txt = TXD.Verdict.AL3T(TXD.PhaseLabel(arm), list)
	local head = ""
	if stage ~= nil then
		head = stage .. ": "
	end
	local ks = {}
	for _, k in ipairs(keepers) do
		ks[#ks + 1] = "P" .. k
	end
	Check(TXD.StepId("AL3T", arm, stage), v, head .. txt .. "; target P" .. Str(t) .. " keepers " ..
		(#ks > 0 and table.concat(ks, ",") or "none") .. "; " .. (#facts > 0 and table.concat(facts, "; ") or "no pair") ..
		"; war matrix " .. AL3TWarMatrix(arm, keepers) .. (note and ("; " .. note) or ""))
end

-- AL3T: target declares war on each keeper (third arg true), then peace with
-- each keeper still at war (target MakePeaceWith(k, true), the AL3 fallbacks
-- after it). Refused unarmed, at BASE, or with no keeper.
CMD.al3t_war_peace = function(playerID, p)
	local arm = StepArm("AL3T")
	if arm == nil then
		return
	end
	local t = arm.target
	local keepers = AL3TKeepers(arm)
	if #keepers == 0 then
		Spike("AL3T", "refused: the target P" .. Str(t) .. " has no living teammate left from its original team (arm record)")
		return
	end
	local ks = {}
	for _, k in ipairs(keepers) do
		ks[#ks + 1] = "P" .. k
	end
	Spike("AL3T", "target P" .. t .. " declares war on " .. table.concat(ks, ",") .. ", then makes peace")
	AL3TReadG(arm, "before")
	for _, k in ipairs(keepers) do
		if AtWar(t, k) then
			Spike("AL3T", "P" .. t .. " already at war with P" .. k .. " (a war on a teammate?): no declaration")
		else
			local ok, err = pcall(function() Players[t]:GetDiplomacy():DeclareWarOn(k, WarTypes.FORMAL_WAR, true) end)
			Spike("AL3T", "P" .. t .. " declares war on P" .. k .. " (DeclareWarOn(" .. k .. ",FORMAL_WAR,true)) ok=" .. tostring(ok) ..
				(ok and "" or (" err=" .. Str(err))) .. " at war=" .. TXD.YN(AtWar(t, k)))
		end
		Spike("AL3T", "war matrix after P" .. k .. ": " .. AL3TWarMatrix(arm, keepers))
	end
	AL3TReadG(arm, "war")
	for _, k in ipairs(keepers) do
		if AtWar(t, k) then
			TX_Probe("AL3T peace", DiploG(t), nil, ":MakePeaceWith", k, true)
			if AtWar(t, k) then
				TX_Probe("AL3T peace", DiploG(t), nil, ":MakePeaceWith", k)
			end
			if AtWar(t, k) then
				TX_Probe("AL3T peace", DiploG(k), nil, ":MakePeaceWith", t, true)
			end
			Spike("AL3T", "peace P" .. t .. " with P" .. k .. ": at war now=" .. TXD.YN(AtWar(t, k)) .. "; war matrix " ..
				AL3TWarMatrix(arm, keepers))
		else
			Spike("AL3T", "P" .. t .. " not at war with P" .. k .. ": no peace call")
		end
	end
	local still = {}
	for _, k in ipairs(keepers) do
		if AtWar(t, k) ~= false then
			still[#still + 1] = "P" .. k
		end
	end
	if #still > 0 then
		Spike("AL3T", "WARNING peace failed or unreadable: P" .. t .. " may still be at war with " .. table.concat(still, ",") ..
			". Load the split save (TX3c_split / TX3c3_split / TX3cAI_split).")
	end
	AL3TReadG(arm, "after")
	ALDone("3T")
end

-- AL4: a real alliance with a 1-turn duration, so it can expire into
-- LEAVE_ALLIANCE -> FRIENDLY (DiplomaticActions.xml:271). The EFV GrantOpenBorders
-- deal shape (EFV_Dev_Gameplay.lua:928-946) with the XP1 alliance item
-- (DiplomacyActionView_Expansion1.lua:161-171). Every step is a probe.
-- p.hash: DB.MakeHash(ALLIANCE_TYPE) computed in the UI (DB is UI-evidenced).
-- item: AL4 or AL4L (probe labels and the spike section).
local function AllianceDeal(arm, item, p)
	local k, t = arm.keeper, arm.target
	GrantCivic(k, ALLIANCE_CIVIC, item)
	GrantCivic(t, ALLIANCE_CIVIC, item)
	local ra = TX_Probe(item .. " deal", "DealAgreementTypes", nil, "=ALLIANCE")
	local hash = tonumber(p.hash)
	if hash == nil then
		hash = TX_Probe(item .. " deal", "DB", nil, ".MakeHash", ALLIANCE_TYPE).rets[1]
	end
	local enacted = "not tried"
	if ra.rets[1] == nil or hash == nil then
		enacted = "no ALLIANCE enum or hash"
	else
		TX_Probe(item .. " deal", "DealManager", nil, ".ClearWorkingDeal", DealDirection.OUTGOING, k, t)
		local deal = TX_Probe(item .. " deal", "DealManager", nil, ".GetWorkingDeal", DealDirection.OUTGOING, k, t).rets[1]
		local it = nil
		if deal ~= nil then
			it = TX_Probe(item .. " deal", deal, nil, ":AddItemOfType", DealItemTypes.AGREEMENTS, k).rets[1]
		end
		if it == nil then
			enacted = "no deal item"
		else
			TX_Probe(item .. " deal", it, nil, ":SetSubType", ra.rets[1])
			TX_Probe(item .. " deal", it, nil, ":SetValueType", hash)
			TX_Probe(item .. " deal", it, nil, ":SetDuration", 1)
			TX_Probe(item .. " deal", it, nil, ":SetLocked", true)
			TX_Probe(item .. " deal", deal, nil, ":Validate")
			enacted = tostring(TX_Probe(item .. " deal", "DealManager", nil, ".EnactWorkingDeal", k, t).ok)
		end
	end
	Spike(item, "alliance deal P" .. k .. "->P" .. t .. " (" .. ALLIANCE_TYPE .. ", 1 turn) enact ok=" .. enacted ..
		" hash=" .. Str(hash) .. " HasAllied k->t=" .. TXD.YN(Allied(k, t)) .. " t->k=" .. TXD.YN(Allied(t, k)) ..
		" deals=" .. DealScan(k, t).n)
end

CMD.al4_alliance = function(playerID, p)
	local arm = ALArm("4")
	if arm == nil then
		return
	end
	ALReadG(arm, "AL4", "before")
	AllianceDeal(arm, "AL4", p)
	ALReadG(arm, "AL4", "after")
	ALDone("4")
end

-- AL4L: the alliance-expiry long run (Leon's option 2: a real alliance that
-- truly ends). AL4's deal, then AL1 (friendship off both ways) at once, so
-- nothing but the alliance holds the pair. The turn reads (every turn start,
-- UI: GetAllianceType, TurnsUntilExpiration) show what happens on the expiry turn.
CMD.al4l_alliance_long = function(playerID, p)
	local arm = ALArm("4L")
	if arm == nil then
		return
	end
	local k, t = arm.keeper, arm.target
	ALReadG(arm, "AL4L", "before")
	AllianceDeal(arm, "AL4L", p)
	ALReadG(arm, "AL4L", "deal")
	local ok = SetFriendPair(k, t, false)
	Spike("AL4L", "friendship off P" .. k .. "<->P" .. t .. " ok=" .. tostring(ok) .. " now k->t=" .. TXD.YN(Friends(k, t)) ..
		" t->k=" .. TXD.YN(Friends(t, k)))
	ALReadG(arm, "AL4L", "after")
	ALDone("4L")
end

-- AL5: SetHasAllied true both ways, then false both ways (EFV SetDiploPair,
-- EFV_Dev_Gameplay.lua:247-252; false was a no-op in EFV Session F T27). Gated to AL5.
CMD.al5_allied_toggle = function(playerID, p)
	local arm = ALArm("5")
	if arm == nil then
		return
	end
	local k, t = arm.keeper, arm.target
	ALReadG(arm, "AL5", "before")
	TX_Probe("AL5 allied", DiploG(k), nil, ":SetHasAllied", t, true)
	TX_Probe("AL5 allied", DiploG(t), nil, ":SetHasAllied", k, true)
	ALReadG(arm, "AL5", "set")
	TX_Probe("AL5 allied", DiploG(k), nil, ":SetHasAllied", t, false)
	TX_Probe("AL5 allied", DiploG(t), nil, ":SetHasAllied", k, false)
	ALReadG(arm, "AL5", "after")
	ALDone("5")
end

-- Clean-break probes (Leon's option 1: no war, no alliance). SetHasMet with a
-- second argument false has no shipped use (SetHasMet(b) is verified: Pirates
-- :382, MeetPair); gated to AL8 / AL9 labels.
local function Unmeet(item, k, t)
	TX_Probe(item .. " unmeet", DiploG(k), nil, ":SetHasMet", t, false)
	TX_Probe(item .. " unmeet", DiploG(t), nil, ":SetHasMet", k, false)
	Spike(item, "SetHasMet(false) P" .. k .. "<->P" .. t .. ": met k->t=" .. TXD.YN(Met(k, t)) .. " t->k=" .. TXD.YN(Met(t, k)))
end

-- AL8: unmeet both ways (GetDiplomacy():SetHasMet(other, false)).
CMD.al8_unmeet = function(playerID, p)
	local arm = ALArm("8")
	if arm == nil then
		return
	end
	ALReadG(arm, "AL8", "before")
	Unmeet("AL8", arm.keeper, arm.target)
	ALReadG(arm, "AL8", "after")
	ALDone("8")
end

-- AL9: unmeet both ways, then meet again (SetHasMet(other), the verified
-- MeetPair shape). Idea [UNV]: a first meeting may start the pair fresh
-- (NEUTRAL) instead of the leftover ALLIED.
CMD.al9_remeet = function(playerID, p)
	local arm = ALArm("9")
	if arm == nil then
		return
	end
	local k, t = arm.keeper, arm.target
	ALReadG(arm, "AL9", "before")
	Unmeet("AL9", k, t)
	ALReadG(arm, "AL9", "unmet")
	MeetPair(k, t)
	Spike("AL9", "SetHasMet P" .. k .. "<->P" .. t .. " again: met k->t=" .. TXD.YN(Met(k, t)) .. " t->k=" .. TXD.YN(Met(t, k)))
	ALReadG(arm, "AL9", "after")
	ALDone("9")
end

-- AL7: Game.GetGameDiplomacy():SetAlliesShareVisFlag(p.on == 1) (MC2, G only).
-- GLOBAL: it affects every team, the intact one too. Diagnostic only, gated to AL7.
CMD.al7_vis = function(playerID, p)
	local on = tonumber(p.on) == 1
	local n = "7off"
	if on then
		n = "7on"
	end
	local arm = ALArm(n)
	if arm == nil then
		return
	end
	ALReadG(arm, "AL" .. n, "before")
	local gd = TX_Probe("AL7 vis", "Game", nil, ".GetGameDiplomacy").rets[1]
	local r = TX_Probe("AL7 vis", gd, nil, ":SetAlliesShareVisFlag", on)
	Spike("AL7", "SetAlliesShareVisFlag(" .. tostring(on) .. ") ok=" .. tostring(r.ok) .. " (global: every team)")
	ALReadG(arm, "AL" .. n, "after")
	ALDone(n)
end

-- VIS steps (Session 3): can a script end the leftover shared vision?
-- n = 1: PlayersVisibility[k]:RemoveOutgoingVisibility(t) and [t] on k.
-- n = 2: GetDiplomacy():RecheckVisibilityOnAll() and RecheckVisibilityOn(other), both players.
-- n = 3: GetDiplomacy():SetVisibilityOn(other, 0) both ways (diplomatic access level;
--        GetVisibilityOn logged before and after).
-- All five calls come from the Session 2 S1 dump (G) with no shipped use: probes,
-- gated to labels starting with VIS. Refused at BASE.
CMD.vis_step = function(playerID, p)
	local n = tonumber(p.n)
	if n ~= 1 and n ~= 2 and n ~= 3 then
		Spike("VIS", "unknown VIS step " .. Str(p.n))
		return
	end
	local item = "VIS" .. n
	local arm = StepArm(item)
	if arm == nil then
		return
	end
	local k, t = arm.keeper, arm.target
	VisReadG(arm, item, "before")
	if n == 1 then
		local ok = VisRemove("VIS1 remove", k, t)
		Spike(item, "RemoveOutgoingVisibility P" .. k .. "->P" .. t .. " and P" .. t .. "->P" .. k .. " ok=" .. tostring(ok))
	elseif n == 2 then
		for _, pair in ipairs({ { k, t }, { t, k } }) do
			TX_Probe("VIS2 recheck", DiploG(pair[1]), nil, ":RecheckVisibilityOnAll")
			TX_Probe("VIS2 recheck", DiploG(pair[1]), nil, ":RecheckVisibilityOn", pair[2])
		end
		Spike(item, "RecheckVisibilityOnAll and RecheckVisibilityOn for P" .. k .. " and P" .. t .. " done")
	else
		local before = "k->t=" .. VisOnTok(k, t) .. " t->k=" .. VisOnTok(t, k)
		TX_Probe("VIS3 set", DiploG(k), nil, ":SetVisibilityOn", t, 0)
		TX_Probe("VIS3 set", DiploG(t), nil, ":SetVisibilityOn", k, 0)
		Spike(item, "GetVisibilityOn before " .. before .. ", after k->t=" .. VisOnTok(k, t) .. " t->k=" .. VisOnTok(t, k))
	end
	VisReadG(arm, item, "after")
	StepDone("vis", n)
end

-- K: the full kick, a rehearsal of the real mod action (Mode B, Session 2).
-- The UI has just written the Target's config team and broadcast it (S3).
-- This request records the change (as "changed"), then runs VIS1
-- (RemoveOutgoingVisibility both ways). No war (Leon: war is the last resort),
-- so the leftover ALLIED state stays. Refused unless armed at BASE. Leon then
-- saves TX3_kick and loads it: the base UI is stale until a load.
CMD.k_kick = function(playerID, p)
	local arm = ArmLoad()
	if not IsArmed(arm) or arm.phase ~= "BASE" then
		Spike("K", "refused: K starts at BASE (load TX3_base, or press Arm BASE first)")
		return
	end
	local t, team = tonumber(p.target), tonumber(p.team)
	if t == nil or t ~= arm.target or team == nil then
		Spike("K", "refused: target P" .. Str(p.target) .. " is not the armed target P" .. Str(arm.target) ..
			", or no team (" .. Str(p.team) .. ")")
		return
	end
	Changed(playerID, p, "S3")
	arm = ArmLoad()
	local k = arm.keeper
	Spike("K", "full kick of P" .. t .. " (config team " .. Str(arm.origTeam) .. " -> " .. team .. "): gameplay reads target team " ..
		Str(TeamOf(t)) .. ", keeper team " .. Str(TeamOf(k)))
	ALReadG(arm, "K", "before")
	VisReadG(arm, "Kvis", "before")
	if TeamOf(t) == nil or TeamOf(t) == TeamOf(k) then
		Spike("K", "WARNING gameplay still reads one team: vision step skipped. Save, load, then VIS1 by hand.")
	else
		local ok = VisRemove("K vis", k, t)
		Spike("K", "RemoveOutgoingVisibility P" .. k .. "->P" .. t .. " and P" .. t .. "->P" .. k .. " ok=" .. tostring(ok))
	end
	ALReadG(arm, "K", "after")
	VisReadG(arm, "Kvis", "after")
	StepDone("k", 1)
	Spike("K", "done. NOW save the game as TX3_kick and load TX3_kick (the base UI is stale until a load).")
end

-- War, allied, friend, open borders and met matrix (EFV_Dev CMD.diplo shape, :464-489).
CMD.diplo = function(playerID, p)
	local ids = Majors()
	Spike("DIPLO", "per pair a->b: W=war A=allied F=friend O=a has open borders from b M=met T=team")
	for _, a in ipairs(ids) do
		local cells = {}
		for _, b in ipairs(ids) do
			if a ~= b then
				local f = ""
				if AtWar(a, b) then f = f .. "W" end
				if Allied(a, b) then f = f .. "A" end
				if Friends(a, b) then f = f .. "F" end
				if DealScan(a, b).obBA == 1 then f = f .. "O" end
				if Met(a, b) then f = f .. "M" end
				if TeamOf(a) ~= nil and TeamOf(a) == TeamOf(b) then f = f .. "T" end
				if f ~= "" then
					cells[#cells + 1] = b .. ":" .. f
				end
			end
		end
		Spike("DIPLO", "P" .. a .. " team " .. Str(TeamOf(a)) .. " -> " .. table.concat(cells, " "))
	end
end

CMD.clear = function(playerID, p)
	Game:SetProperty(KEY_ARM, { v = 1, cleared = Turn() })
	Game:SetProperty(KEY_S1, { stamp = 0, n = 0 })
	Game:SetProperty(KEY_S2, { stamp = 0, n = 0 })
	m_WroteArm = true
	Spike("SNAP", "cleared")
end

-- ---------------------------------------------------------------------------
-- Dispatcher (EFV_Dev_Gameplay.lua:3997-4016)
-- ---------------------------------------------------------------------------
-- Echo the request stamp into the arm, so the UI's WaitFor sees its answer.
local function Echo(p)
	if p.stamp == nil or p.cmd == "store_ui" then
		return
	end
	local arm = ArmLoad()
	if IsArmed(arm) and arm.stamp ~= p.stamp then
		arm.stamp = p.stamp
		ArmSave(arm)
	end
end

local function OnRequest(playerID, params)
	if type(params) ~= "table" then
		Spike("REQ", "non-table params")
		return
	end
	local cmd = Str(params.cmd)
	Spike("REQ", "got " .. cmd .. " from P" .. Str(playerID) .. " stamp=" .. Str(params.stamp))
	m_LastCounted = false
	local okL, errL = pcall(function() m_LastCounted = CountLoad(ArmLoad()) end)
	if not okL then
		Spike("REQ", "ERROR load-check " .. Str(errL))
	end
	local fn = CMD[cmd]
	if fn == nil then
		Spike("REQ", "unknown cmd " .. cmd)
		return
	end
	local ok, err = pcall(fn, playerID, params)
	if not ok then
		Spike("REQ", "ERROR " .. cmd .. " " .. Str(err))
	end
	local okE, errE = pcall(Echo, params)
	if not okE then
		Spike("REQ", "ERROR echo " .. Str(errE))
	end
end

local function OnTurnStarted(turn)
	local ok, err = pcall(SnapshotG, "turn")
	if not ok then
		Spike("SNAP", "ERROR turn snapshot " .. Str(err))
	end
end

GameEvents.TX_Dev.Add(OnRequest)
GameEvents.OnGameTurnStarted.Add(OnTurnStarted)

Spike("INIT", "TX_Dev " .. TXD.VERSION .. " loaded (for TX " .. TXD.FOR_TX .. " spike) turn=" .. Turn() ..
	" armed=" .. B(IsArmed(ArmLoad())))
