-- ===========================================================================
-- TX_Dev_Panel.lua  (TX_Dev 0.0.1.1, spike kit for Team Expulsion 0.0.1)
-- Context: UI (AddUserInterfaces, Context InGame). TESTING ONLY. PLAN I.6.
--
-- Panel toggled by Ctrl+Shift+D or the "DEV" launch bar button (copied from
-- EFV_Dev_Panel.lua). Buttons either run UI-side spike code here (S1 dump,
-- team map, S2 probes, the S3 config write, the UI snapshot) or send a flat
-- EXECUTE_SCRIPT request to Scripts/TX_Dev_Gameplay.lua:
--   UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT,
--     { OnStart = "TX_Dev", cmd = "...", stamp, target, team, ctx = "UI", ... })
-- Gameplay echoes the stamp into TX_DEV_ARM (or TX_DEV_S2); WaitFor polls
-- for it in OnUpdate and then runs the UI follow-up (EFV_Dev_Panel.lua:1305-1327).
--
-- Calls not VERIFIED in PLAN Appendix A go through TX_Probe.
-- AddUserInterfaces contexts load HIDDEN: Initialize calls
-- ContextPtr:SetHide(false); only Controls.Main is toggled.
-- ===========================================================================
include("InstanceManager")
include("TX_Dev_Lib")
local TXD = TXD
local TX_Probe = TX_Probe
TXD.Init("UI")
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
})

local Str = TXD.Str
local Spike = TXD.Spike
local Check = TXD.Check

local KEY_ARM = "TX_DEV_ARM"
local KEY_S2 = "TX_DEV_S2"
local POLL = 0.3          -- WaitFor poll interval (s)
local WAIT_MAX = 5        -- WaitFor timeout (s)
local FRIEND_STATE = "DIPLO_STATE_DECLARED_FRIEND"

local m_ButtonIM = InstanceManager:new("DevButtonInstance", "Button", Controls.ButtonStack)
local m_HeaderIM = InstanceManager:new("DevHeaderInstance", "Header", Controls.ButtonStack)
local m_Open = false
local m_LaunchInst = {}
local m_LaunchDone = false
local m_Targets = {}
local m_TargetIdx = 1
local m_Clock = 0
local m_Waits = {}
local m_StampN = 0
local m_SnapTurn = -1
local m_S1Found = {}        -- setter-like keys of the UI dump { {obj, key} }
local m_UISetters = {}      -- S2 hits in UI
local m_SetterList = {}     -- UI + G hits, never-list names left out
local m_SetterIdx = 1
local m_Suggested = nil     -- S1 Team map's unused team
local m_Victory = nil       -- { team, members } of the last Events.TeamVictory

local SnapshotUI           -- forward
local RefreshInfo          -- forward

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function Trim(s)
	if s == nil then
		return ""
	end
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function EditText(ctrl)
	local ok, t = pcall(function() return ctrl:GetText() end)
	if ok and t ~= nil then
		return Trim(t)
	end
	return ""
end

-- Request stamp turn * 1000 + counter (EFV_Dev_Panel.lua:61-69).
local function NextStamp()
	m_StampN = m_StampN + 1
	return TXD.Turn() * 1000 + m_StampN
end

local function LocalID()
	return Game.GetLocalPlayer()
end

local function ReadProp(key)
	local ok, v = pcall(function() return Game:GetProperty(key) end)
	if ok then
		return v
	end
	return nil
end

local function ArmRead()
	local a = ReadProp(KEY_ARM)
	if type(a) == "table" then
		return a
	end
	return nil
end

local function IsArmed(arm)
	return type(arm) == "table" and arm.armedTurn ~= nil
end

local function Flag(fn)
	local ok, v = pcall(fn)
	if not ok then
		return nil
	end
	return v == true
end

local function TeamOf(pid)
	local ok, t = pcall(function() return Players[pid]:GetTeam() end)
	if ok and type(t) == "number" then
		return t
	end
	return nil
end

local function CfgTeamOf(pid)
	local ok, t = pcall(function() return PlayerConfigurations[pid]:GetTeam() end)
	if ok and type(t) == "number" then
		return t
	end
	return nil
end

local function TeamList(team)
	local ok, list = pcall(function() return Teams[team] end)
	if ok and type(list) == "table" then
		return list
	end
	return nil
end

local function TeamsLen(team)
	local list = TeamList(team)
	if list == nil then
		return "nil"
	end
	return tostring(#list)
end

local function InTeam(team, pid)
	local list = TeamList(team)
	if list == nil then
		return nil
	end
	for _, m in ipairs(list) do
		if m == pid then
			return true
		end
	end
	return false
end

local function TeamCount(team)
	local ok, n = pcall(function() return GameConfiguration.GetTeamPlayerCount(team) end)
	if ok then
		return Str(n)
	end
	return "ERR"
end

local function PlayerName(pid)
	local name = "P" .. Str(pid)
	pcall(function()
		name = name .. " " .. Locale.Lookup(PlayerConfigurations[pid]:GetCivilizationShortDescription())
	end)
	return name
end

local function Hotseat()
	local ok, v = pcall(function() return GameConfiguration.IsHotseat() end)
	if ok and v then
		return 1
	end
	return 0
end

local function NetMP()
	local r = TX_Probe(false, "GameConfiguration", nil, ".IsNetworkMultiplayer")
	if r.ok and r.rets[1] == true then
		return 1
	end
	return 0
end

-- Every existing slot 0..63: live and config team, flags.
local function Rows()
	local rows = {}
	for i = 0, 63 do
		local okP, p = pcall(function() return Players[i] end)
		if okP and p ~= nil then
			local alive = Flag(function() return p:IsAlive() end)
			local major = Flag(function() return p:IsMajor() end)
			rows[#rows + 1] = { pid = i, team = TeamOf(i), cfg = CfgTeamOf(i), alive = TXD.B01(alive),
				major = TXD.B01(major), other = TXD.B01(i >= 62) }
		end
	end
	return rows
end

-- Target cycle: alive majors only (EFV_Dev_Panel.lua:130-149, majors only).
local function RebuildTargets()
	local prev = m_Targets[m_TargetIdx]
	m_Targets = {}
	for _, r in ipairs(Rows()) do
		if r.alive == 1 and r.major == 1 then
			m_Targets[#m_Targets + 1] = r.pid
		end
	end
	m_TargetIdx = 1
	for i, id in ipairs(m_Targets) do
		if id == prev then
			m_TargetIdx = i
			return
		end
	end
	for i, id in ipairs(m_Targets) do
		if id == 1 then
			m_TargetIdx = i
			return
		end
	end
end

local function CurrentTarget()
	return m_Targets[m_TargetIdx] or 1
end

-- target, keeper, other, origTeam, newTeam: the arm's, or computed now.
local function Roles()
	local arm = ArmRead()
	if IsArmed(arm) then
		return arm.target, arm.keeper, arm.other, arm.origTeam, arm.newTeam
	end
	local target = CurrentTarget()
	local keeper, other = TXD.PickRoles(Rows(), target)
	return target, keeper, other, TeamOf(target), tonumber(EditText(Controls.TeamEdit)) or m_Suggested
end

-- local player, host and hotseat flags (PLAN I.6). Host and network calls are probes.
local function Machine()
	return "local=P" .. Str(LocalID()) ..
		" netLocal=" .. TXD.Tok(TX_Probe(false, "Network", nil, ".GetLocalPlayerID")) ..
		" host=" .. TXD.Tok(TX_Probe(false, "Network", nil, ".IsGameHost")) ..
		" hostID=" .. TXD.Tok(TX_Probe(false, "Network", nil, ".GetGameHostPlayerID")) ..
		" netMP=" .. TXD.Tok(TX_Probe(false, "GameConfiguration", nil, ".IsNetworkMultiplayer")) ..
		" hotseat=" .. Hotseat()
end

-- "ok" or the error token of a probe that returns nothing useful.
local function Res(r)
	if r.ok then
		return "ok"
	end
	return TXD.Tok(r)
end

local function DiploOf(pid)
	local ok, d = pcall(function() return Players[pid]:GetDiplomacy() end)
	if ok then
		return d
	end
	return nil
end

local function AtWar(a, b)
	return Flag(function() return Players[a]:GetDiplomacy():IsAtWarWith(b) end)
end

local function HasOB(a, b)
	return Flag(function() return Players[a]:GetDiplomacy():HasOpenBordersFrom(b) end)
end

-- a's view of b as a StateType (DiplomacyActionView.lua:869-871).
local function StateName(a, b)
	local ok, name = pcall(function()
		local idx = Players[a]:GetDiplomaticAI():GetDiplomaticStateIndex(b)
		return GameInfo.DiplomaticStates[idx].StateType
	end)
	if ok then
		return name
	end
	return nil
end

local function TechIndex(techType)
	local ok, idx = pcall(function() return GameInfo.Technologies[techType].Index end)
	if ok then
		return idx
	end
	return nil
end

local function Boosted(pid, idx)
	if idx == nil then
		return nil
	end
	return Flag(function() return Players[pid]:GetTechs():HasBoostBeenTriggered(idx) end)
end

local function HasTech(pid, idx)
	if idx == nil then
		return nil
	end
	return Flag(function() return Players[pid]:GetTechs():HasTech(idx) end)
end

local function Visible(pid, x, y)
	return Flag(function() return PlayersVisibility[pid]:IsVisible(x, y) end)
end

-- Distance to pid's nearest city or unit.
local function NearestAsset(pid, x, y)
	local best = nil
	local function Try(ax, ay)
		local ok, d = pcall(function() return Map.GetPlotDistance(x, y, ax, ay) end)
		if ok and type(d) == "number" and (best == nil or d < best) then
			best = d
		end
	end
	pcall(function()
		for _, c in Players[pid]:GetCities():Members() do
			Try(c:GetX(), c:GetY())
		end
	end)
	pcall(function()
		for _, u in Players[pid]:GetUnits():Members() do
			Try(u:GetX(), u:GetY())
		end
	end)
	return best
end

-- GPT deal a -> b (ReportScreen.lua:363-368): 1 when a gold item from a exists.
local function GptFrom(a, b)
	local ok, n = pcall(function()
		local count = 0
		local deals = DealManager.GetPlayerDeals(a, b)
		if deals ~= nil then
			for _, pDeal in ipairs(deals) do
				local items = pDeal:FindItemsByType(DealItemTypes.GOLD, DealItemSubTypes.NONE, a)
				if items ~= nil then
					count = count + #items
				end
			end
		end
		return count
	end)
	if not ok then
		return nil
	end
	return TXD.B01(n > 0)
end

-- ---------------------------------------------------------------------------
-- Requests (flat params: numbers and strings only)
-- ---------------------------------------------------------------------------
local function Send(p)
	local shown = {}
	for _, k in ipairs(TXD.SortedKeys(p)) do
		shown[#shown + 1] = k .. "=" .. Str(p[k])
	end
	local ok, err = pcall(function()
		UI.RequestPlayerOperation(LocalID(), PlayerOperations.EXECUTE_SCRIPT, p)
	end)
	Spike("REQ", "sent " .. Str(p.cmd) .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) ..
		" {" .. table.concat(shown, ", ") .. "}")
	return ok
end

local function BaseParams(cmd)
	local p = { OnStart = "TX_Dev", cmd = cmd, stamp = NextStamp(), target = CurrentTarget(), ctx = "UI" }
	local team = tonumber(EditText(Controls.TeamEdit))
	if team ~= nil then
		p.team = team
	end
	return p
end

-- Polls TX_DEV_ARM.stamp (kind "arm") or TX_DEV_S2.stamp (kind "s2") in
-- OnUpdate every POLL s for up to WAIT_MAX s, then runs fn either way.
local function WaitFor(stamp, fn, kind, what)
	m_Waits[#m_Waits + 1] = { stamp = stamp, fn = fn, kind = kind or "arm", what = what or "?",
		nextAt = m_Clock, untilAt = m_Clock + WAIT_MAX }
end

local function Answered(w)
	if w.kind == "s2" then
		local s = ReadProp(KEY_S2)
		return type(s) == "table" and s.stamp == w.stamp
	end
	local a = ArmRead()
	return type(a) == "table" and a.stamp == w.stamp
end

local function SendAndWait(p, fn, kind)
	if Send(p) then
		WaitFor(p.stamp, fn, kind, p.cmd)
	end
end

-- ---------------------------------------------------------------------------
-- S1
-- ---------------------------------------------------------------------------
local function S1DumpUI()
	m_S1Found = TXD.DumpAll("S1")
	local names = {}
	for _, f in ipairs(m_S1Found) do
		names[#names + 1] = f.obj .. ":" .. f.key
	end
	Check("S1-UI", "INFO", "setters: " .. (#names > 0 and table.concat(names, " ") or "none"))
end

local function S1MapUI()
	local rows = {}
	for i = 0, 63 do
		local okP, p = pcall(function() return Players[i] end)
		local exists = okP and p ~= nil
		local cfg = CfgTeamOf(i)
		if exists or (cfg ~= nil and cfg >= 0) then
			local live = TeamOf(i)
			rows[#rows + 1] = { pid = i, team = live, cfg = cfg, other = TXD.B01(i >= 62) }
			local cfgHuman = Flag(function() return PlayerConfigurations[i]:IsHuman() end)
			local slot = TX_Probe(false, "PlayerConfigurations", i, ":GetSlotStatus")
			local alive, major, human = "-", "-", "-"
			if exists then
				alive = Str(TXD.B01(Flag(function() return p:IsAlive() end)))
				major = Str(TXD.B01(Flag(function() return p:IsMajor() end)))
				human = Str(TXD.B01(Flag(function() return p:IsHuman() end)))
			end
			local t = live
			if t == nil then
				t = cfg
			end
			Spike("S1", "slot " .. i .. " team=" .. Str(live) .. " alive=" .. alive .. " major=" .. major .. " human=" .. human ..
				" cfgTeam=" .. Str(cfg) .. " cfgHuman=" .. TXD.YN(cfgHuman) .. " slotStatus=" .. TXD.Tok(slot) ..
				" #Teams[" .. Str(t) .. "]=" .. TeamsLen(t) .. " GetTeamPlayerCount=" .. TeamCount(t))
		end
	end
	local live, cfg = {}, {}
	for _, r in ipairs(rows) do
		live[#live + 1] = { pid = r.pid, team = r.team }
		cfg[#cfg + 1] = { pid = r.pid, team = r.cfg }
	end
	Spike("S1", "live teams: " .. TXD.GroupsText(TXD.TeamGroups(live)))
	Spike("S1", "cfg teams: " .. TXD.GroupsText(TXD.TeamGroups(cfg)))
	local unused = TXD.UnusedTeam(TXD.UsedTeams(rows))
	m_Suggested = unused
	if EditText(Controls.TeamEdit) == "" then
		Controls.TeamEdit:SetText(tostring(unused))
	end
	local target = CurrentTarget()
	local targetFree = true
	for _, t in ipairs(TXD.UsedTeams(rows)) do
		if t == target then
			targetFree = false
		end
	end
	Spike("S1", "unused team: " .. unused .. " (lowest non-negative ID no slot uses, live or config; solo players own team IDs, R A1)")
	Spike("S1", "alternative: target pid " .. target .. " is unused=" .. TXD.YN(targetFree) .. " (hint only, R A1)")
	local k, n = TXD.SoloIdStats(rows)
	Check("S1TEAM-UI", "INFO", "solo team==pid " .. k .. "/" .. n .. "; unused=" .. unused .. "; target pid " .. target ..
		" unused=" .. TXD.YN(targetFree))
	Send(BaseParams("s1_map"))
end

-- ---------------------------------------------------------------------------
-- S2
-- ---------------------------------------------------------------------------
local function SetterLabelText()
	local c = m_SetterList[m_SetterIdx]
	if c == nil then
		return "(none: press S2 Probe setters)"
	end
	return c.tag .. " " .. TXD.SetterText(c) .. "  [" .. m_SetterIdx .. "/" .. #m_SetterList .. "]"
end

local function RebuildSetterList()
	local list = {}
	for _, c in ipairs(m_UISetters) do
		if not TXD.IsNever(c.root, c.name) then
			list[#list + 1] = c
		end
	end
	local s2 = ReadProp(KEY_S2)
	if type(s2) == "table" and type(s2.hits) == "table" then
		for _, h in ipairs(s2.hits) do
			if not TXD.IsNever(h.root, h.name) then
				list[#list + 1] = { tag = "G", root = h.root, sel = h.sel, name = h.name, style = h.style, args = h.args }
			end
		end
	end
	m_SetterList = list
	m_SetterIdx = 1
	local names = {}
	for _, c in ipairs(list) do
		names[#names + 1] = c.tag .. ":" .. TXD.SetterText(c)
	end
	Spike("S2", "setter list (UI+G): " .. (#names > 0 and table.concat(names, " ") or "none"))
	RefreshInfo()
end

local function S2ProbeUI()
	local arm = ArmRead()
	local target = CurrentTarget()
	local orig = TeamOf(target)
	if IsArmed(arm) then
		orig = arm.origTeam
	end
	m_UISetters = {}
	local names = {}
	for _, c in ipairs(TXD.SetterCandidates(m_S1Found)) do
		local r = TX_Probe("S2 exist", c.root, TXD.SelValue(c.sel, target, orig), "?" .. c.name)
		if r.exists == "function" then
			if c.root == "PlayerConfigurations" and c.name == "SetTeam" then
				Spike("S2", "PlayerConfigurations:SetTeam exists in UI: that is the S3 path, listed apart")
			else
				m_UISetters[#m_UISetters + 1] = { tag = "UI", root = c.root, sel = c.sel, name = c.name, style = c.style, args = c.args }
				names[#names + 1] = TXD.SetterText(c)
			end
		end
	end
	Check("S2-UI", "INFO", "exist: " .. (#names > 0 and table.concat(names, " ") or "none"))
	local p = BaseParams("s2_probe")
	if Send(p) then
		WaitFor(p.stamp, RebuildSetterList, "s2", "s2_probe")
	else
		RebuildSetterList()
	end
end

local function S2CallSelected()
	local c = m_SetterList[m_SetterIdx]
	if c == nil then
		Spike("S2", "CALL: no setter selected (press S2 Probe setters first)")
		return
	end
	if TXD.IsNever(c.root, c.name) then
		Spike("S2", "REFUSED never-call " .. Str(c.root) .. "." .. Str(c.name))
		return
	end
	local target = CurrentTarget()
	local team = tonumber(EditText(Controls.TeamEdit))
	if team == nil then
		Spike("S2", "CALL: type a New team first (S1 Team map suggests one)")
		return
	end
	if c.tag == "G" then
		local p = BaseParams("s2_call")
		p.root, p.name, p.style, p.args = c.root, c.name, c.style, c.args
		if c.sel ~= nil then
			p.sel = c.sel
		end
		SendAndWait(p, function() SnapshotUI("changed") end, "arm")
		return
	end
	local arm = ArmRead()
	local orig = TeamOf(target)
	if IsArmed(arm) then
		orig = arm.origTeam
	end
	local args, n = TXD.SetterArgs(c.args, target, team)
	Spike("S2", "about to call " .. TXD.SetterText(c) .. " in UI target=P" .. target .. " team=" .. team ..
		" (a native crash loses the buffered log: write it in Result)")
	local r = TX_Probe("S2 CALL", c.root, TXD.SelValue(c.sel, target, orig), c.style .. c.name, unpack(args, 1, n))
	local _, keeper = Roles()
	Check("S2-UI", "INFO", "call ok=" .. tostring(r.ok) .. " ret=" .. TXD.Tok(r) .. " target team now " .. Str(TeamOf(target)) ..
		", keeper team " .. Str(TeamOf(keeper)) .. ", target cfg team " .. Str(CfgTeamOf(target)))
	local p = BaseParams("changed")
	p.path, p.target, p.team = "S2", target, team
	SendAndWait(p, function() SnapshotUI("changed") end, "arm")
end

-- ---------------------------------------------------------------------------
-- S3: config team change in UI (TP 1.3)
-- ---------------------------------------------------------------------------
local function MpFlag(arm)
	if IsArmed(arm) then
		return tonumber(arm.mp) or 0
	end
	return NetMP()
end

local function S3Set(mode)
	local t = CurrentTarget()
	if mode == "self" then
		t = LocalID()
	end
	local team = tonumber(EditText(Controls.TeamEdit))
	if team == nil then
		Spike("S3", "set: type a New team first (S1 Team map suggests one)")
		return
	end
	local arm = ArmRead()
	local mach = Machine()
	local cfgBefore, liveBefore = CfgTeamOf(t), TeamOf(t)
	Spike("S3", "about to set the config team of P" .. t .. " " .. Str(cfgBefore) .. " -> " .. team ..
		" and broadcast (a native crash loses the buffered log: write it in Result); machine " .. mach)
	local rSet = TX_Probe("S3 set", "PlayerConfigurations", t, ":SetTeam", team)
	local rCast = TX_Probe("S3 broadcast", "Network", nil, ".BroadcastPlayerInfo", t)
	local cfg, live = CfgTeamOf(t), TeamOf(t)
	local label = TXD.PhaseLabel({ path = "S3", phase = "LIVE", mp = MpFlag(arm) })
	local verdict = "FAIL"
	if cfg == team then
		verdict = "PASS"
	end
	Check("S3-UI." .. label, verdict, "config team of P" .. t .. " " .. Str(cfgBefore) .. " -> " .. Str(cfg) ..
		" (want " .. team .. "); live team " .. Str(liveBefore) .. " -> " .. Str(live) ..
		"; #Teams[" .. team .. "]=" .. TeamsLen(team) .. " #Teams[" .. Str(liveBefore) .. "]=" .. TeamsLen(liveBefore) ..
		" GetTeamPlayerCount(" .. team .. ")=" .. TeamCount(team) .. "; set " .. Res(rSet) ..
		" broadcast " .. Res(rCast) .. "; machine " .. mach)
	local changedLive = "no"
	if live ~= liveBefore then
		changedLive = "yes"
	end
	Check("S3LIVE-UI." .. label, "INFO", "Players[" .. t .. "]:GetTeam() changed live=" .. changedLive)
	local p = BaseParams("changed")
	p.path, p.target, p.team = "S3", t, team
	if liveBefore ~= nil then
		p.orig = liveBefore
	end
	SendAndWait(p, function() SnapshotUI("changed") end, "arm")
end

local function S3Undo()
	local arm = ArmRead()
	if not IsArmed(arm) then
		Spike("S3", "undo: not armed, so the BASE config team is unknown")
		return
	end
	local t = CurrentTarget()
	local base = nil
	for _, r in ipairs(arm.teamsBase or {}) do
		if r.pid == t then
			base = r.cfg
			if base == nil then
				base = r.team
			end
		end
	end
	if base == nil then
		Spike("S3", "undo: P" .. t .. " has no BASE team record")
		return
	end
	local before = CfgTeamOf(t)
	local r1 = TX_Probe("S3 undo set", "PlayerConfigurations", t, ":SetTeam", base)
	local r2 = TX_Probe("S3 undo broadcast", "Network", nil, ".BroadcastPlayerInfo", t)
	Spike("S3", "S3 undo P" .. t .. " config team " .. Str(before) .. " -> " .. Str(CfgTeamOf(t)) .. " (BASE cfg " .. base ..
		"); live team " .. Str(TeamOf(t)) .. "; set " .. Res(r1) .. " broadcast " .. Res(r2) .. "; machine " .. Machine())
end

-- ---------------------------------------------------------------------------
-- Checklist (PLAN I.8, UI snapshot)
-- ---------------------------------------------------------------------------
local function Safe(section, fn)
	local ok, err = pcall(fn)
	if not ok then
		Spike("SNAP", "ERROR " .. section .. " " .. Str(err))
	end
end

local function BaseUI(arm, key)
	if type(arm.ui) == "table" then
		return arm.ui[key]
	end
	return nil
end

local function V3UI(arm, label)
	local who = nil
	if type(arm.v3) == "table" then
		who = arm.v3.who
	end
	local whoBase = nil
	for _, r in ipairs(arm.teamsBase or {}) do
		if r.pid == who then
			whoBase = r.team
		end
	end
	local parts, ownsAll, enemies = {}, true, 0
	for _, c in ipairs(arm.caps or {}) do
		local ok, city = pcall(function() return CityManager.GetCityAt(c.x, c.y) end)
		local owner, orig = nil, nil
		local isCap = "-"
		if ok and city ~= nil then
			pcall(function() owner = city:GetOwner() end)
			pcall(function() orig = city:GetOriginalOwner() end)
			isCap = TXD.Tok(TX_Probe(false, city, nil, ":IsOriginalCapital"))
		end
		parts[#parts + 1] = "P" .. c.pid .. "@" .. c.x .. "," .. c.y .. " owner=" .. Str(owner) .. " orig=" .. Str(orig) ..
			" isOrigCap=" .. isCap
		local cBase = nil
		for _, r in ipairs(arm.teamsBase or {}) do
			if r.pid == c.pid then
				cBase = r.team
			end
		end
		if who ~= nil and c.pid ~= who and cBase ~= nil and cBase ~= whoBase then
			enemies = enemies + 1
			if owner ~= who then
				ownsAll = false
			end
		end
	end
	local id = TXD.CheckId("V3", arm)
	if who == nil or TXD.Turn() <= (tonumber(arm.v3.turn) or 0) then
		Check(id, "INFO", "original capitals: " .. (#parts > 0 and table.concat(parts, "; ") or "none"))
		return
	end
	local members = nil
	local okW, team = pcall(function() return Game.GetWinningTeam() end)
	if okW and type(team) == "number" and team >= 0 then
		members = TeamList(team) or {}
	elseif m_Victory ~= nil then
		members = m_Victory.members
	end
	local v, t = TXD.Verdict.V3(label, members, arm.keeper, arm.target, enemies > 0 and ownsAll)
	Check(id, v, t .. "; attacker P" .. Str(who) .. "; capitals: " .. table.concat(parts, "; "))
end

local function V4UI(arm, label, vals)
	local list = arm.v4 or {}
	if #list == 0 then
		Check(TXD.CheckId("V4", arm), "INFO", "no V4 entry yet (press V4 Boost (keeper))")
		return
	end
	for i, e in ipairs(list) do
		local idx = TechIndex(e.tech)
		local kB, tB = Boosted(arm.keeper, idx), Boosted(arm.target, idx)
		Check(TXD.CheckId("V4", arm), TXD.Verdict.V4(label, e.path, kB, tB, Str(e.tech) .. " (" .. Str(e.n) .. " " ..
			Str(e.unit) .. ", made turn " .. Str(e.turn) .. " at " .. Str(e.path) .. ")"))
		vals["v4k" .. i] = TXD.B01(kB)
		vals["v4t" .. i] = TXD.B01(tB)
	end
end

local function V5UI(arm, label, vals)
	if type(arm.v5) ~= "table" then
		Check(TXD.CheckId("V5", arm), "INFO", "no marker yet (press V5 Marker (keeper))")
		return
	end
	local x, y = arm.v5.x, arm.v5.y
	local kS, tS = Visible(arm.keeper, x, y), Visible(arm.target, x, y)
	local near = NearestAsset(arm.target, x, y)
	local v, t = TXD.Verdict.V5(label, kS, tS, near)
	Check(TXD.CheckId("V5", arm), v, t .. " (marker at " .. x .. "," .. y .. ")")
	vals.v5k, vals.v5t = TXD.B01(kS), TXD.B01(tS)
end

local function V7UI(arm, label, vals)
	local k, t = arm.keeper, arm.target
	local sKT, sTK = StateName(t, k), StateName(k, t)
	local obKT, obTK = HasOB(t, k), HasOB(k, t)
	local war = AtWar(k, t)
	Check(TXD.CheckId("V7", arm), "INFO", "keeper-target state(target view)=" .. Str(sKT) .. " state(keeper view)=" .. Str(sTK) ..
		" target has OB from keeper=" .. TXD.YN(obKT) .. " keeper has OB from target=" .. TXD.YN(obTK) ..
		" at war=" .. TXD.YN(war))
	vals.v7war = TXD.B01(war)
end

local function V9UI(arm, label, vals)
	local t, o = arm.target, arm.other
	local now = { ob12 = TXD.B01(HasOB(o, t)), ob21 = TXD.B01(HasOB(t, o)), gpt = GptFrom(t, o) }
	vals.v9ob12, vals.v9ob21, vals.v9gpt = now.ob12, now.ob21, now.gpt
	local base = nil
	if BaseUI(arm, "v9ob12") ~= nil then
		base = { ob12 = BaseUI(arm, "v9ob12"), ob21 = BaseUI(arm, "v9ob21"), gpt = BaseUI(arm, "v9gpt") }
	end
	Check(TXD.CheckId("V9", arm), TXD.Verdict.V9(label, base, now))
end

local function V10UI(arm, label, vals)
	local t, o = arm.target, arm.other
	local sTO, sOT = StateName(t, o), StateName(o, t)
	local ab, ba = nil, nil
	if sTO ~= nil then
		ab = sTO == FRIEND_STATE
	end
	if sOT ~= nil then
		ba = sOT == FRIEND_STATE
	end
	vals.v10f = TXD.B01(ab == true and ba == true)
	local v, txt = TXD.Verdict.V10(label, BaseUI(arm, "v10f"), ab, ba)
	Check(TXD.CheckId("V10", arm), v, txt .. " (states " .. Str(sTO) .. " / " .. Str(sOT) .. ")")
end

-- Returns the flat BASE values when the phase is BASE, else nil.
SnapshotUI = function(reason)
	local arm = ArmRead()
	if not IsArmed(arm) then
		if reason == "button" then
			Spike("SNAP", "not armed: press Arm BASE + snapshot first")
		end
		return nil
	end
	m_SnapTurn = TXD.Turn()
	local label = TXD.PhaseLabel(arm)
	local rows = Rows()
	local live, cfg = {}, {}
	for _, r in ipairs(rows) do
		live[#live + 1] = { pid = r.pid, team = r.team }
		cfg[#cfg + 1] = { pid = r.pid, team = r.cfg }
	end
	Spike("SNAP", label .. " reason=" .. Str(reason) .. " " .. Machine() .. " live teams=" .. TXD.GroupsText(TXD.TeamGroups(live)) ..
		" cfg teams=" .. TXD.GroupsText(TXD.TeamGroups(cfg)))
	local vals = {}
	local t, k = arm.target, arm.keeper
	Safe("V1", function()
		local tC, kC = CfgTeamOf(t), CfgTeamOf(k)
		local v, txt = TXD.Verdict.V1(label, TeamOf(t), TeamOf(k))
		Check(TXD.CheckId("V1", arm), v, txt .. "; cfg target=" .. Str(tC) .. " keeper=" .. Str(kC) ..
			"; #Teams[newTeam " .. Str(arm.newTeam) .. "]=" .. TeamsLen(arm.newTeam) ..
			"; target in Teams[origTeam " .. Str(arm.origTeam) .. "]=" .. TXD.YN(InTeam(arm.origTeam, t)))
		vals.v1cfgT, vals.v1cfgK = tC, kC
	end)
	Safe("V2", function()
		local tC = CfgTeamOf(t)
		local name = "?"
		pcall(function() name = Str(GameConfiguration.GetTeamName(tC)) end)
		Check(TXD.CheckId("V2", arm), "INFO", "LeaderIcon rule: #Teams[cfg team " .. Str(tC) .. "]=" .. TeamsLen(tC) ..
			" (team ribbon when > 1), GetTeamName=" .. name ..
			"; Leon: check World Rankings grouping, the ribbon team icon and the scoreboard")
	end)
	Safe("V3", function() V3UI(arm, label) end)
	Safe("V4", function() V4UI(arm, label, vals) end)
	Safe("V5", function() V5UI(arm, label, vals) end)
	Safe("V7", function() V7UI(arm, label, vals) end)
	Safe("V9", function() V9UI(arm, label, vals) end)
	Safe("V10", function() V10UI(arm, label, vals) end)
	if TXD.IsBase(label) then
		return vals
	end
	return nil
end

local function StoreUIBase(values)
	local arm = ArmRead()
	if not IsArmed(arm) or type(values) ~= "table" then
		return
	end
	local p = BaseParams("store_ui")
	p.armStamp = arm.armStamp
	local flat = TXD.Flatten("u_", values)
	for _, key in ipairs(TXD.SortedKeys(flat)) do
		p[key] = flat[key]
	end
	Send(p)
end

local function ArmBase()
	local p = BaseParams("arm")
	for _, r in ipairs(Rows()) do
		if r.cfg ~= nil then
			p["cfg_" .. r.pid] = r.cfg
		end
	end
	p.mp = NetMP()
	p.hotseat = Hotseat()
	SendAndWait(p, function()
		local values = SnapshotUI("arm")
		if values ~= nil then
			StoreUIBase(values)
		end
	end, "arm")
end

local function SnapshotNow()
	local p = BaseParams("snap")
	if IsArmed(ArmRead()) then
		SendAndWait(p, function() SnapshotUI("button") end, "arm")
	else
		Send(p)
		SnapshotUI("button")
	end
end

local function PickBoostUI()
	local _, keeper, _, _, _ = Roles()
	local target = CurrentTarget()
	local arm = ArmRead()
	if IsArmed(arm) then
		target = arm.target
	end
	local used = {}
	if arm ~= nil then
		for _, e in ipairs(arm.v4 or {}) do
			used[e.tech] = true
		end
	end
	local rows = {}
	for row in GameInfo.Boosts() do
		rows[#rows + 1] = row
	end
	local function usable(row)
		local idx = TechIndex(row.TechnologyType)
		if used[row.TechnologyType] then
			return false
		end
		for _, pid in ipairs({ keeper, target }) do
			if HasTech(pid, idx) ~= false or Boosted(pid, idx) ~= false then
				return false
			end
		end
		return true
	end
	local function isLand(unitType)
		local ok, d = pcall(function() return GameInfo.Units[unitType].Domain end)
		return ok and d == "DOMAIN_LAND"
	end
	local row = TXD.PickBoost(rows, usable, TechIndex, isLand)
	if row == nil then
		Spike("V4", "no usable own-units tech boost for P" .. Str(keeper) .. " and P" .. Str(target))
		return
	end
	Spike("V4", "picked " .. Str(row.TechnologyType) .. " (own " .. Str(row.NumItems) .. " " .. Str(row.Unit1Type) .. ")")
	local p = BaseParams("v4_boost")
	p.type = row.TechnologyType
	Send(p)
end

local function V8Info()
	local arm = ArmRead()
	local target, keeper = Roles()
	local r1 = TX_Probe("V8", DiploOf(keeper), nil, ":CanDeclareWarOn", target)
	local r2 = TX_Probe("V8", DiploOf(target), nil, ":CanDeclareWarOn", keeper)
	Check("V8-UI." .. TXD.PhaseLabel(arm), "INFO", "keeper P" .. Str(keeper) .. " may declare war on target P" .. Str(target) ..
		"=" .. TXD.Tok(r1) .. ", target on keeper=" .. TXD.Tok(r2) .. "; Leon: try it in the diplomacy screen")
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local function OnTurnActivated(pid)
	if pid ~= LocalID() or m_SnapTurn == TXD.Turn() then
		return
	end
	if IsArmed(ArmRead()) then
		SnapshotUI("turn")
	end
end

local function OnLoadDone()
	if IsArmed(ArmRead()) then
		SendAndWait(BaseParams("loaded"), function() SnapshotUI("loaded") end, "arm")
	end
end

local function OnTeamVictory(team, victory)
	local members = {}
	local list = TeamList(team)
	for _, pid in ipairs(list or {}) do
		members[#members + 1] = pid
	end
	m_Victory = { team = team, members = members }
	local arm = ArmRead()
	local text = "team victory team=" .. Str(team) .. " type=" .. Str(victory) .. " members=" .. table.concat(members, ",")
	if not IsArmed(arm) then
		Spike("V3", text .. " (not armed)")
		return
	end
	local v, t = TXD.Verdict.V3(TXD.PhaseLabel(arm), members, arm.keeper, arm.target, nil)
	Check(TXD.CheckId("V3", arm), v, text .. "; " .. t)
end

-- ---------------------------------------------------------------------------
-- Buttons (EFV table shape, EFV_Dev_Panel.lua:1480-1511)
-- ---------------------------------------------------------------------------
local UIFN = {
	S1DumpUI = S1DumpUI,
	S1MapUI = S1MapUI,
	S2ProbeUI = S2ProbeUI,
	S2CallSelected = S2CallSelected,
	S3SetTarget = function() S3Set("target") end,
	S3SetSelf = function() S3Set("self") end,
	S3Undo = S3Undo,
	ArmBase = ArmBase,
	SnapshotNow = SnapshotNow,
	PickBoostUI = PickBoostUI,
	V8Info = V8Info,
}

local BUTTONS = {
	{ header = "S1 API discovery" },
	{ label = "S1 Dump (UI)", ui = "S1DumpUI" },
	{ label = "S1 Dump (G)", cmd = "s1_dump" },
	{ label = "S1 Team map", ui = "S1MapUI" },
	{ header = "S2 engine setter" },
	{ label = "S2 Probe setters (no calls)", ui = "S2ProbeUI" },
	{ label = "S2 CALL selected setter (!)", ui = "S2CallSelected" },
	{ header = "S3 config change" },
	{ label = "S3 Set Target's team", ui = "S3SetTarget" },
	{ label = "S3 Set MY team", ui = "S3SetSelf" },
	{ label = "S3 Undo (Target)", ui = "S3Undo" },
	{ header = "Checklist" },
	{ label = "Arm BASE + snapshot", ui = "ArmBase" },
	{ label = "Snapshot now", ui = "SnapshotNow" },
	{ label = "V4 Boost (keeper)", ui = "PickBoostUI" },
	{ label = "V5 Marker (keeper)", cmd = "v5_marker" },
	{ label = "V6 Other declares war on keeper", cmd = "v6_war" },
	{ label = "V9 Deals target-other", cmd = "v9_deals" },
	{ label = "V10 Friends target-other", cmd = "v10_friend" },
	{ label = "V3 Domination: keeper", cmd = "v3_setup", who = "keeper" },
	{ label = "V3 Domination: target", cmd = "v3_setup", who = "target" },
	{ label = "V8 War allowed?", ui = "V8Info" },
	{ header = "Misc" },
	{ label = "Diplo matrix", cmd = "diplo" },
	{ label = "Clear spike state", cmd = "clear" },
}

local function OnButton(def)
	RebuildTargets()
	if def.ui ~= nil then
		local ok, err = pcall(UIFN[def.ui])
		if not ok then
			Spike("REQ", "ERROR " .. Str(def.label) .. " " .. Str(err))
		end
	else
		local p = BaseParams(def.cmd)
		if def.who ~= nil then
			p.who = def.who
		end
		Send(p)
	end
	local okR, errR = pcall(RefreshInfo)
	if not okR then
		Spike("REQ", "ERROR refresh " .. Str(errR))
	end
end

local function BuildButtons()
	m_ButtonIM:ResetInstances()
	m_HeaderIM:ResetInstances()
	for _, def in ipairs(BUTTONS) do
		if def.header ~= nil then
			local h = m_HeaderIM:GetInstance()
			h.HeaderLabel:SetText(def.header)
		else
			local b = m_ButtonIM:GetInstance()
			b.Button:SetText(def.label)
			b.Button:RegisterCallback(Mouse.eLClick, function() OnButton(def) end)
		end
	end
	Controls.ButtonStack:CalculateSize()
	Controls.ButtonScroll:CalculateInternalSize()
end

-- ---------------------------------------------------------------------------
-- Info lines and cycles
-- ---------------------------------------------------------------------------
RefreshInfo = function()
	local arm = ArmRead()
	local label = "not armed"
	if IsArmed(arm) then
		label = TXD.PhaseLabel(arm)
	end
	Controls.InfoLabel:SetText("local=P" .. Str(LocalID()) .. " host=" .. TXD.Tok(TX_Probe(false, "Network", nil, ".IsGameHost")) ..
		" hotseat=" .. Hotseat() .. " | turn " .. TXD.Turn() .. " | phase " .. label)
	local target, keeper, other, orig, new = Roles()
	Controls.RolesLabel:SetText("keeper=P" .. Str(keeper) .. " target=P" .. Str(target) .. " other=P" .. Str(other) ..
		" origTeam=" .. Str(orig) .. " newTeam=" .. Str(new))
	Controls.TargetLabel:SetText(PlayerName(CurrentTarget()))
	Controls.SuggestedLabel:SetText("Suggested: " .. Str(m_Suggested or "-"))
	Controls.SetterLabel:SetText(SetterLabelText())
end

-- RefreshInfo from handlers (input, update, buttons): never throws.
local function SafeRefresh()
	local ok, err = pcall(RefreshInfo)
	if not ok then
		Spike("REQ", "ERROR refresh " .. Str(err))
	end
end

local function OnTargetPrev()
	RebuildTargets()
	m_TargetIdx = m_TargetIdx - 1
	if m_TargetIdx < 1 then
		m_TargetIdx = #m_Targets
	end
	SafeRefresh()
end

local function OnTargetNext()
	RebuildTargets()
	m_TargetIdx = m_TargetIdx + 1
	if m_TargetIdx > #m_Targets then
		m_TargetIdx = 1
	end
	SafeRefresh()
end

local function OnSetterPrev()
	m_SetterIdx = m_SetterIdx - 1
	if m_SetterIdx < 1 then
		m_SetterIdx = math.max(#m_SetterList, 1)
	end
	SafeRefresh()
end

local function OnSetterNext()
	m_SetterIdx = m_SetterIdx + 1
	if m_SetterIdx > #m_SetterList then
		m_SetterIdx = 1
	end
	SafeRefresh()
end

-- ---------------------------------------------------------------------------
-- Update loop: WaitFor polling (EFV_Dev_Panel.lua:1299-1327)
-- ---------------------------------------------------------------------------
local function OnUpdate(dt)
	m_Clock = m_Clock + (tonumber(dt) or 0)
	if #m_Waits == 0 then
		return
	end
	local keep, due = {}, {}
	for _, w in ipairs(m_Waits) do
		if m_Clock >= w.nextAt then
			w.nextAt = m_Clock + POLL
			local okA, ans = pcall(Answered, w)
			if okA and ans then
				due[#due + 1] = { w = w, timeout = false }
			elseif m_Clock > w.untilAt then
				due[#due + 1] = { w = w, timeout = true }
			else
				keep[#keep + 1] = w
			end
		else
			keep[#keep + 1] = w
		end
	end
	m_Waits = keep
	for _, d in ipairs(due) do
		if d.timeout then
			Spike("REQ", "no answer from gameplay for " .. Str(d.w.what) .. " stamp=" .. Str(d.w.stamp) ..
				" within " .. WAIT_MAX .. " s")
		end
		local ok, err = pcall(d.w.fn)
		if not ok then
			Spike("REQ", "ERROR follow-up " .. Str(d.w.what) .. " " .. Str(err))
		end
	end
	if #due > 0 and m_Open then
		SafeRefresh()
	end
end

-- ---------------------------------------------------------------------------
-- Show / hide, hotkey, launch bar (EFV_Dev_Panel.lua:1516-1562)
-- ---------------------------------------------------------------------------
local function SetOpen(open)
	m_Open = open and true or false
	if ContextPtr:IsHidden() then
		ContextPtr:SetHide(false)
	end
	if m_Open then
		pcall(RebuildTargets)
		SafeRefresh()
	end
	Controls.Main:SetHide(not m_Open)
end

local function Toggle()
	SetOpen(not m_Open)
end

local function OnInput(pInput)
	if pInput:GetMessageType() == KeyEvents.KeyUp then
		local key = pInput:GetKey()
		if key == Keys.D and pInput:IsControlDown() and pInput:IsShiftDown() then
			Toggle()
			return true
		end
		if key == Keys.VK_ESCAPE and m_Open then
			SetOpen(false)
			return true
		end
	end
	return false
end

local function AttachLaunchButton()
	if m_LaunchDone then
		return
	end
	m_LaunchDone = true
	local ok, err = pcall(function()
		local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
		ContextPtr:BuildInstanceForControl("DevLaunchBarItem", m_LaunchInst, buttonStack)
		m_LaunchInst.LaunchItemButton:RegisterCallback(Mouse.eLClick, Toggle)
		ContextPtr:BuildInstanceForControl("DevLaunchBarPinInstance", {}, buttonStack)
		buttonStack:CalculateSize()
		local backing = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking")
		backing:SetSizeX(buttonStack:GetSizeX() + 116)
		local backingTile = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile")
		backingTile:SetSizeX(buttonStack:GetSizeX() - 20)
		LuaEvents.LaunchBar_Resize(buttonStack:GetSizeX())
	end)
	Spike("INIT", "launch bar button ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. " (Ctrl+Shift+D works regardless)")
end

local function OnLoadGameViewStateDone()
	AttachLaunchButton()
	OnLoadDone()
end

-- EFV_Dev_Panel.lua:1568-1578
local function Subscribe(label, getter, fn)
	local ok, err = pcall(function()
		local ev = getter()
		if ev == nil then
			error("event is nil")
		end
		ev.Add(function(...)
			local okH, errH = pcall(fn, ...)
			if not okH then
				Spike("REQ", "ERROR " .. label .. " listener " .. Str(errH))
			end
		end)
	end)
	if not ok then
		Spike("INIT", "subscribe FAILED " .. label .. ": " .. Str(err))
	end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)       -- contexts load hidden (PB 3)
	Controls.Main:SetHide(true)
	ContextPtr:SetInputHandler(OnInput, true)
	ContextPtr:SetUpdate(OnUpdate)
	Controls.CloseButton:RegisterCallback(Mouse.eLClick, function() SetOpen(false) end)
	Controls.RefreshButton:RegisterCallback(Mouse.eLClick, function() pcall(RebuildTargets); SafeRefresh() end)
	Controls.TargetPrev:RegisterCallback(Mouse.eLClick, OnTargetPrev)
	Controls.TargetNext:RegisterCallback(Mouse.eLClick, OnTargetNext)
	Controls.SetterPrev:RegisterCallback(Mouse.eLClick, OnSetterPrev)
	Controls.SetterNext:RegisterCallback(Mouse.eLClick, OnSetterNext)
	BuildButtons()
	Subscribe("Events.LoadGameViewStateDone", function() return Events.LoadGameViewStateDone end, OnLoadGameViewStateDone)
	Subscribe("Events.PlayerTurnActivated", function() return Events.PlayerTurnActivated end, OnTurnActivated)
	Subscribe("Events.TeamVictory", function() return Events.TeamVictory end, OnTeamVictory)
	RebuildTargets()
	Spike("INIT", "TX_Dev " .. TXD.VERSION .. " loaded (for TX " .. TXD.FOR_TX .. " spike) turn=" .. TXD.Turn() ..
		" armed=" .. Str(TXD.B01(IsArmed(ArmRead()))) .. " (Ctrl+Shift+D)")
end

Initialize()
