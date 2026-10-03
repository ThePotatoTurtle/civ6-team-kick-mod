-- ===========================================================================
-- TX_Dev_Panel.lua  (TX_Dev 0.0.1.4, spike kit for Team Expulsion 0.0.1)
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
	DiplomacyActionTypes = function() return DiplomacyActionTypes end,
	WarTypes = function() return WarTypes end,
	DB = function() return DB end,
	-- R reload chain (0.0.1.4, research/RELOAD.md 2-3): reached only through TX_Probe
	UI = function() return UI end,
	Events = function() return Events end,
	LuaEvents = function() return LuaEvents end,
	SaveLocations = function() return SaveLocations end,
	SaveFileTypes = function() return SaveFileTypes end,
	SaveLocationOptions = function() return SaveLocationOptions end,
	ServerType = function() return ServerType end,
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
-- false until Events.LoadGameViewStateDone (EFV_Tracker.lua m_ViewReady pattern:
-- on load the engine replays events before that event, EFV Session A T21).
-- A turn snapshot before it would carry the label of the save (e.g. S3LIVE),
-- because gameplay has not counted the load yet.
local m_ViewReady = false
local m_S1Found = {}        -- setter-like keys of the UI dump { {obj, key} }
local m_UISetters = {}      -- S2 hits in UI
local m_SetterList = {}     -- UI + G hits, never-list names left out
local m_SetterIdx = 1
local m_Suggested = nil     -- S1 Team map's unused team
local m_Victory = nil       -- { team, members } of the last Events.TeamVictory

local SnapshotUI           -- forward
local RefreshInfo          -- forward
local CfgMembers           -- forward
local ALReadUI             -- forward
local VisReadUI            -- forward

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

-- true / false, nil when unreadable (AL8 / AL9: no verdict for an unmet pair).
local function Met(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():HasMet(b) end)
	if ok and type(v) == "boolean" then
		return v
	end
	return nil
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

-- As Visible, but nil when unreadable (the VIS verdict must not read an error as "does not see").
local function VisibleOrNil(pid, x, y)
	local ok, v = pcall(function() return PlayersVisibility[pid]:IsVisible(x, y) end)
	if ok and type(v) == "boolean" then
		return v
	end
	return nil
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

-- The S3 config write in UI: SetTeam on the config, then broadcast; logs the
-- S3-UI checks. Returns the live team before the write.
local function S3Write(t, team, arm)
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
	return liveBefore
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
	local liveBefore = S3Write(t, team, ArmRead())
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

-- S3n (0.0.1.4, research/RELOAD.md 3 "Probe first"): the S3 config write WITHOUT
-- Network.BroadcastPlayerInfo. Same immediate re-reads as S3 (UI getters and
-- Teams here, G getters through "changed" with path S3n). If gameplay still
-- switches and nothing fires PlayerInfoChanged, the ribbon may never break.
local function S3nSet()
	local t = CurrentTarget()
	local team = tonumber(EditText(Controls.TeamEdit))
	if team == nil then
		Spike("S3n", "set: type a New team first (S1 Team map suggests one)")
		return
	end
	local arm = ArmRead()
	local mach = Machine()
	local cfgBefore, liveBefore = CfgTeamOf(t), TeamOf(t)
	Spike("S3n", "about to set the config team of P" .. t .. " " .. Str(cfgBefore) .. " -> " .. team ..
		" WITHOUT a broadcast (a native crash loses the buffered log: write it in Result); machine " .. mach)
	local rSet = TX_Probe("S3n set", "PlayerConfigurations", t, ":SetTeam", team)
	local cfg, live = CfgTeamOf(t), TeamOf(t)
	local label = TXD.PhaseLabel({ path = "S3n", phase = "LIVE", mp = MpFlag(arm) })
	local verdict = "FAIL"
	if cfg == team then
		verdict = "PASS"
	end
	Check("S3n-UI." .. label, verdict, "config team of P" .. t .. " " .. Str(cfgBefore) .. " -> " .. Str(cfg) ..
		" (want " .. team .. "); live team " .. Str(liveBefore) .. " -> " .. Str(live) ..
		"; #Teams[" .. team .. "]=" .. TeamsLen(team) .. " #Teams[" .. Str(liveBefore) .. "]=" .. TeamsLen(liveBefore) ..
		" target in Teams[" .. Str(liveBefore) .. "]=" .. TXD.YN(InTeam(liveBefore, t)) ..
		" GetTeamPlayerCount(" .. team .. ")=" .. TeamCount(team) .. "; set " .. Res(rSet) .. ", no broadcast; machine " .. mach)
	local changedLive = "no"
	if live ~= liveBefore then
		changedLive = "yes"
	end
	Check("S3nLIVE-UI." .. label, "INFO", "Players[" .. t .. "]:GetTeam() changed live=" .. changedLive ..
		"; Leon: any new LeaderIcon.lua error, or a broken ribbon, right after this line?")
	local p = BaseParams("changed")
	p.path, p.target, p.team = "S3n", t, team
	if liveBefore ~= nil then
		p.orig = liveBefore
	end
	SendAndWait(p, function() SnapshotUI("changed") end, "arm")
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

-- Players whose config team is team (Free Cities and Barbarians left out).
-- Live, the config team is what gameplay reads; UI Teams[] is stale until a reload.
CfgMembers = function(team)
	local out = {}
	for _, r in ipairs(Rows()) do
		if r.cfg == team and r.pid < 62 then
			out[#out + 1] = r.pid
		end
	end
	return out
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
	local members, cfgMembers = nil, nil
	local okW, team = pcall(function() return Game.GetWinningTeam() end)
	if okW and type(team) == "number" and team >= 0 then
		members = TeamList(team) or {}
		cfgMembers = CfgMembers(team)
	elseif m_Victory ~= nil then
		members = m_Victory.members
		cfgMembers = CfgMembers(m_Victory.team)
	end
	local v, t = TXD.Verdict.V3Both(label, members, cfgMembers, arm.keeper, arm.target, enemies > 0 and ownsAll)
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
	if reason == "turn" or reason == "loaded" then
		Safe("AL", function()
			if type(arm.al) == "table" and TXD.Turn() > (tonumber(arm.al.turn) or 0) then
				ALReadUI(arm, "AL" .. Str(arm.al.n), "turn", "turn " .. TXD.Turn() .. ", AL" .. Str(arm.al.n) .. " pressed on turn " ..
					Str(arm.al.turn))
			end
		end)
		Safe("VIS", function()
			if type(arm.vis) == "table" and TXD.Turn() > (tonumber(arm.vis.turn) or 0) then
				VisReadUI(arm, "VIS" .. Str(arm.vis.n), "turn", "turn " .. TXD.Turn() .. ", VIS" .. Str(arm.vis.n) ..
					" pressed on turn " .. Str(arm.vis.turn))
			end
		end)
		Safe("K", function()
			if type(arm.k) == "table" and TXD.Turn() > (tonumber(arm.k.turn) or 0) then
				local note = "turn " .. TXD.Turn() .. ", K pressed on turn " .. Str(arm.k.turn)
				ALReadUI(arm, "K", "turn", note)
				VisReadUI(arm, "Kvis", "turn", note)
			end
		end)
	end
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
-- AL: the leftover ALLIED state (research/ALLIANCE.md 5). UI half.
-- ---------------------------------------------------------------------------
-- The other's intact teammate: does it see the other's capital (team vision)?
local function IntactVision(arm)
	local o = arm.other
	local oTeam, mate = nil, nil
	for _, r in ipairs(arm.teamsBase or {}) do
		if r.pid == o then
			oTeam = r.team
		end
	end
	for _, r in ipairs(arm.teamsBase or {}) do
		if mate == nil and oTeam ~= nil and r.team == oTeam and r.pid ~= o and r.pid < 62 then
			mate = r.pid
		end
	end
	if mate == nil then
		return "intact team: no teammate of the other"
	end
	for _, c in ipairs(arm.caps or {}) do
		if c.pid == o then
			return "intact team: P" .. mate .. " sees P" .. o .. "'s capital=" .. TXD.YN(Visible(mate, c.x, c.y)) ..
				" (nearest P" .. mate .. " asset " .. Str(NearestAsset(mate, c.x, c.y)) .. ")"
		end
	end
	return "intact team: no capital of P" .. Str(o)
end

-- Side effects of war then peace (Session 3: AL3, AL3b; AL0 for the baseline). UI reads only, all probes:
-- GetGrievancesAgainst (DiplomacyActionView_AllianceRow.lua:46, XP2); the DOW warmonger
-- points and level (DeclareWarPopup.lua:113,130: ComputeDOWWarmongerPoints(defender,
-- warType), GetWarmongerLevel(-points)); GetAtWarChangeTurn, CanMakePeaceWith,
-- CanDeclareWarOn (CityStates.lua:1496-1516); GetMinPeaceDuration (CityStates.lua:74);
-- era score (EraProgressPanel.lua:68, XP2). Open borders and the deal count are
-- verified UI reads (R D).
local FX_ITEMS = { AL0 = true, AL3 = true, AL3b = true }

local function ALFxUI(arm, item, stage)
	local k, t = arm.keeper, arm.target
	local dk, dt = DiploOf(k), DiploOf(t)
	local function Both(member)
		return " k->t=" .. TXD.Tok(TX_Probe(false, dk, nil, member, t)) .. " t->k=" .. TXD.Tok(TX_Probe(false, dt, nil, member, k))
	end
	local warmonger
	local rf = TX_Probe(false, "WarTypes", nil, "=FORMAL_WAR")
	if rf.ok and rf.rets[1] ~= nil then
		local rp = TX_Probe(false, dk, nil, ":ComputeDOWWarmongerPoints", t, rf.rets[1])
		warmonger = TXD.Tok(rp)
		if rp.ok and type(rp.rets[1]) == "number" then
			warmonger = warmonger .. " level=" .. TXD.Tok(TX_Probe(false, dk, nil, ":GetWarmongerLevel", -rp.rets[1]))
		end
	else
		warmonger = "FORMAL_WAR=" .. TXD.Tok(rf)
	end
	local minPeace
	local rg = TX_Probe(false, "Game", nil, ".GetGameDiplomacy")
	if rg.ok and rg.rets[1] ~= nil then
		minPeace = TXD.Tok(TX_Probe(false, rg.rets[1], nil, ":GetMinPeaceDuration"))
	else
		minPeace = TXD.Tok(rg)
	end
	local era
	local re = TX_Probe(false, "Game", nil, ".GetEras")
	if re.ok and re.rets[1] ~= nil then
		era = "k=" .. TXD.Tok(TX_Probe(false, re.rets[1], nil, ":GetPlayerCurrentScore", k)) ..
			" t=" .. TXD.Tok(TX_Probe(false, re.rets[1], nil, ":GetPlayerCurrentScore", t))
	else
		era = TXD.Tok(re)
	end
	local okD, nDeals = pcall(function()
		local deals = DealManager.GetPlayerDeals(k, t)
		if deals == nil then
			return 0
		end
		return #deals
	end)
	if not okD then
		nDeals = "ERR"
	end
	local head = ""
	if stage ~= nil then
		head = stage .. ": "
	end
	Check(TXD.StepId(item .. "fx", arm, stage), "INFO", head .. "keeper P" .. Str(k) .. " target P" .. Str(t) ..
		"; grievances" .. Both(":GetGrievancesAgainst") .. "; DOW warmonger points k->t=" .. warmonger ..
		"; AtWarChangeTurn" .. Both(":GetAtWarChangeTurn") .. "; CanMakePeaceWith" .. Both(":CanMakePeaceWith") ..
		"; CanDeclareWarOn" .. Both(":CanDeclareWarOn") .. "; MinPeaceDuration=" .. minPeace ..
		"; open borders target from keeper=" .. TXD.YN(HasOB(t, k)) .. " keeper from target=" .. TXD.YN(HasOB(k, t)) ..
		"; deals=" .. Str(nDeals) .. "; era score " .. era ..
		"; Leon: notifications, historic moments, grievances in the diplomacy screen")
end

-- The UI read-out. item: AL0 (always INFO), AL1..AL7, AL3b, AL7off, K; stage:
-- before | after | turn | nil. AL0, AL3 and AL3b also log the <item>fx line.
ALReadUI = function(arm, item, stage, note)
	local k, t = arm.keeper, arm.target
	local sTK, sKT = StateName(t, k), StateName(k, t)
	local d = DiploOf(k)
	local at = TX_Probe(false, d, nil, ":GetAllianceType", t)
	local ae = TX_Probe(false, d, nil, ":GetAllianceTurnsUntilExpiration", t)
	local ft = TX_Probe(false, d, nil, ":GetDeclaredFriendshipTurn", t)
	local cw = TX_Probe(false, d, nil, ":CanDeclareWarOn", t)
	local share = TX_Probe(false, "GameConfiguration", nil, ".GetValue", "GAME_ALLIES_SHARE_VISIBILITY")
	local vis = "-"
	if type(arm.v5) == "table" then
		vis = TXD.YN(Visible(t, arm.v5.x, arm.v5.y)) .. " at " .. arm.v5.x .. "," .. arm.v5.y
	end
	local facts = "GetAllianceType=" .. TXD.Tok(at) .. " TurnsUntilExpiration=" .. TXD.Tok(ae) ..
		" DeclaredFriendshipTurn=" .. TXD.Tok(ft) .. " CanDeclareWarOn k->t=" .. TXD.Tok(cw) .. " at war=" .. TXD.YN(AtWar(k, t)) ..
		" target sees marker=" .. vis .. "; " .. IntactVision(arm) .. "; GAME_ALLIES_SHARE_VISIBILITY=" .. TXD.Tok(share)
	local metKT, metTK = Met(k, t), Met(t, k)
	facts = facts .. "; met k->t=" .. TXD.YN(metKT) .. " t->k=" .. TXD.YN(metTK)
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
	if FX_ITEMS[item] then
		ALFxUI(arm, item, stage)
	end
end

-- ---------------------------------------------------------------------------
-- VIS: the leftover shared vision (Session 2). UI half of the read-out.
-- ---------------------------------------------------------------------------
-- Cities and units of pid as { {x, y} } (the gameplay Assets twin).
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

local function PlotDist(x1, y1, x2, y2)
	local ok, d = pcall(function() return Map.GetPlotDistance(x1, y1, x2, y2) end)
	if ok and type(d) == "number" then
		return d
	end
	return 999
end

-- The keeper city farthest from every target asset: { x, y, near } or nil.
local function FarCity(k, t)
	local cands = {}
	pcall(function()
		for _, c in Players[k]:GetCities():Members() do
			cands[#cands + 1] = { x = c:GetX(), y = c:GetY(), idx = c:GetID() }
		end
	end)
	local best, d = TXD.FarthestPlot(cands, Assets(t), PlotDist)
	if best == nil then
		return nil
	end
	return { x = best.x, y = best.y, near = d }
end

-- a's active diplomatic visibility sources on b (DiplomacyActionView.lua:996-997), a probe.
local function VisSources(a, b)
	local d = DiploOf(a)
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
	return TXD.Tok(TX_Probe(false, DiploOf(a), nil, ":GetVisibilityOn", b))
end

-- The UI VIS read-out (IsVisible is verified in UI). item: VIS0 (always INFO), VIS1..VIS3, Kvis.
VisReadUI = function(arm, item, stage, note)
	local k, t = arm.keeper, arm.target
	local m, c = { has = false }, { has = false }
	local where = {}
	if type(arm.v5) == "table" then
		local x, y = arm.v5.x, arm.v5.y
		m = { has = true, k = VisibleOrNil(k, x, y), t = VisibleOrNil(t, x, y), near = NearestAsset(t, x, y) }
		where[#where + 1] = "marker at " .. Str(x) .. "," .. Str(y)
	end
	local city = FarCity(k, t)
	if city ~= nil then
		c = { has = true, k = VisibleOrNil(k, city.x, city.y), t = VisibleOrNil(t, city.x, city.y), near = city.near }
		where[#where + 1] = "city at " .. city.x .. "," .. city.y
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
		(#where > 0 and table.concat(where, ", ") or "no marker, no keeper city") .. "; GetVisibilityOn k->t=" ..
		VisOnTok(k, t) .. " t->k=" .. VisOnTok(t, k) .. "; sources k->t=" .. VisSources(k, t) .. " t->k=" .. VisSources(t, k) ..
		(note and ("; " .. note) or ""))
end

-- The arm for an AL read: the armed record, or the roles from the panel Target.
local function ALRoles()
	local arm = ArmRead()
	if IsArmed(arm) then
		return arm
	end
	local target, keeper, other = Roles()
	local a = { target = target, keeper = keeper, other = other }
	if arm ~= nil then
		a.v5 = arm.v5
	end
	return a
end

-- AL0: the AL and VIS read-outs (UI), then the G half.
local function ALRead()
	local arm = ALRoles()
	ALReadUI(arm, "AL0")
	VisReadUI(arm, "VIS0")
	Send(BaseParams("al_read"))
end

-- A destructive AL or VIS step: UI read before, the G command, UI read after
-- the answer. Refused unarmed and at BASE (gameplay refuses too).
local function Step(section, cmd, extra, read)
	local arm = ArmRead()
	if not IsArmed(arm) or arm.phase == "BASE" then
		Spike(section, "refused: arm BASE and split the team first (or load TX3_split)")
		return
	end
	read(arm, "before")
	local p = BaseParams(cmd)
	extra = extra or {}
	for _, key in ipairs(TXD.SortedKeys(extra)) do
		p[key] = extra[key]
	end
	SendAndWait(p, function()
		local now = ArmRead()
		if IsArmed(now) then
			read(now, "after")
		end
	end, "arm")
end

local function ALStep(n, cmd, extra)
	local item = "AL" .. n
	Step(item, cmd, extra, function(a, stage) ALReadUI(a, item, stage) end)
end

local function VISStep(n)
	local item = "VIS" .. n
	Step(item, "vis_step", { n = n }, function(a, stage) VisReadUI(a, item, stage) end)
end

-- K: the full kick, a rehearsal of the real mod action. The S3 config write and
-- broadcast here, then one gameplay request (k_kick) that records the change and
-- runs VIS1. No war (Leon: war then peace is the last resort). Refused unless
-- armed at BASE. Uses the armed target and the New team box (else the armed newTeam).
local function KFullKick()
	local arm = ArmRead()
	if not IsArmed(arm) or arm.phase ~= "BASE" then
		Spike("K", "refused: K starts at BASE (load TX3_base, or press Arm BASE first)")
		return
	end
	local t = arm.target
	local team = tonumber(EditText(Controls.TeamEdit)) or tonumber(arm.newTeam)
	if team == nil then
		Spike("K", "refused: no New team (S1 Team map suggests one)")
		return
	end
	if CurrentTarget() ~= t then
		Spike("K", "the panel Target is P" .. Str(CurrentTarget()) .. "; K kicks the armed target P" .. Str(t))
	end
	ALReadUI(arm, "K", "before")
	VisReadUI(arm, "Kvis", "before")
	local liveBefore = S3Write(t, team, arm)
	local p = BaseParams("k_kick")
	p.path, p.target, p.team = "S3", t, team
	if liveBefore ~= nil then
		p.orig = liveBefore
	end
	SendAndWait(p, function()
		local now = ArmRead()
		-- arm.k is written only by a k_kick that ran to the end (the wait also ends on a timeout).
		if not IsArmed(now) or now.phase == "BASE" or type(now.k) ~= "table" then
			Spike("K", "WARNING gameplay did not finish K (refused, error or no answer): do NOT save TX3_kick. " ..
				"Read the G lines, then load TX3_base.")
			return
		end
		SnapshotUI("changed")
		ALReadUI(now, "K", "after")
		VisReadUI(now, "Kvis", "after")
		Spike("K", "done. NOW save the game as TX3_kick and load TX3_kick (the base UI is stale until a load).")
	end, "arm")
end

-- ---------------------------------------------------------------------------
-- P-Teams (0.0.1.4, research/RELOAD.md 1 "Mitigations"). Teams is an engine
-- global; each UI context has its own binding. Whether the ribbon's binding is
-- the same table object is unknown, so the write may change only this panel's copy.
-- ---------------------------------------------------------------------------
local PTW_LABEL_TEXT = "P-Teams WRITE panel copy (!)"

-- target, live (UI) team, config team
local function PTeamsRoles()
	local arm = ArmRead()
	local t = CurrentTarget()
	if IsArmed(arm) then
		t = arm.target
	end
	return t, TeamOf(t), CfgTeamOf(t)
end

local function PTeamsText(t, orig, new)
	local tbl = "nil"
	pcall(function() tbl = tostring(Teams) end)
	return "tostring(Teams)=" .. tbl .. " #Teams[orig " .. Str(orig) .. "]=" .. TeamsLen(orig) ..
		" Teams[new " .. Str(new) .. "] exists=" .. TXD.YN(TeamList(new) ~= nil) .. " #Teams[new]=" .. TeamsLen(new) ..
		" target P" .. Str(t) .. " in Teams[orig]=" .. TXD.YN(InTeam(orig, t)) .. " in Teams[new]=" .. TXD.YN(InTeam(new, t))
end

local function PTeamsRead()
	local t, orig, new = PTeamsRoles()
	Check("PTeams-UI." .. TXD.PhaseLabel(ArmRead()), "INFO", "read: live team " .. Str(orig) .. ", config team " .. Str(new) ..
		"; " .. PTeamsText(t, orig, new))
end

-- The gated write: only from its own button (def.label). Needs the S3 config
-- write first (config team ~= UI live team). Then a broadcast re-runs the ribbon.
local function PTeamsWrite(def)
	if type(def) ~= "table" or def.label ~= PTW_LABEL_TEXT then
		Spike("PTeams", "REFUSED: the Teams write runs only from its own button '" .. PTW_LABEL_TEXT .. "'")
		return
	end
	local t, orig, new = PTeamsRoles()
	local label = TXD.PhaseLabel(ArmRead())
	if orig == nil or new == nil or orig == new then
		Spike("PTeams", "refused: P" .. Str(t) .. " config team " .. Str(new) .. " = live team " .. Str(orig) ..
			": press S3 Set Target's team first")
		return
	end
	local before = PTeamsText(t, orig, new)
	local tblBefore = "nil"
	pcall(function() tblBefore = tostring(Teams) end)
	local ok, res = pcall(function() return TXD.PatchTeams(Teams, orig, new, t) end)
	local after = PTeamsText(t, orig, new)
	local tblAfter = "nil"
	pcall(function() tblAfter = tostring(Teams) end)
	local changed = "no"
	if InTeam(new, t) == true and InTeam(orig, t) ~= true then
		changed = "yes"
	elseif InTeam(new, t) == true or InTeam(orig, t) ~= true then
		changed = "partly"
	end
	local verdict = "INFO"
	if not ok then
		verdict = "FAIL"
	end
	Check("PTeams-UI." .. label .. ".write", verdict, "write ok=" .. tostring(ok) .. " " .. Str(res) ..
		"; Teams in this context changed=" .. changed .. " (same table object " .. TXD.YN(tblBefore == tblAfter) ..
		"); before: " .. before .. "; after: " .. after ..
		"; only this panel's copy is known to change (RELOAD.md 1)")
	local rCast = TX_Probe("PTeams broadcast", "Network", nil, ".BroadcastPlayerInfo", t)
	Spike("PTeams", "ribbon refresh: BroadcastPlayerInfo(" .. t .. ") " .. Res(rCast) ..
		". Leon: a NEW LeaderIcon.lua:143 error after this line means the ribbon does not see this write. Then click P" ..
		t .. "'s portrait.")
end

-- ---------------------------------------------------------------------------
-- R: apply + save + reload in one click (0.0.1.4, research/RELOAD.md 3, hotseat).
-- Each call copies a shipped shape (RELOAD.md 2): the S3 write; Network.SaveGame
-- (SaveGameMenu.lua:52-66, InGame.lua:189-201); Events.SaveComplete
-- (Automation_StandardTests.lua:37); UI.QuerySaveGameList + LuaEvents.FileListQueryResults
-- (LoadSaveMenu_Shared.lua:1041-1073); Network.LeaveGame + Network.LoadGame(entry,
-- SERVER_TYPE_NONE) (LoadGameMenu.lua:96-114, InGameTopOptionsMenu.lua:204-209).
-- Running the chain from a mod context is unverified: every call is a probe,
-- every step has a timeout (OnUpdate clock), every failure logs
-- <kind>-UI.<phase> FAIL and what Leon must do by hand.
-- Only armed at BASE (as K): one change, one save, no stale LIVE state saved twice.
-- RK = K's gameplay step (k_kick: record + VIS1) instead of "changed".
-- ---------------------------------------------------------------------------
-- Each run saves under its own name (R_SAVE_<local date_time>, os.date as
-- TopPanel.lua:283): the file list match can never pick a file left by an
-- earlier run (e.g. step 5's save while step 6 waits on a stray or failed save).
local R_SAVE = "TX_autoreload"
local R_SAVE_MAX = 10     -- s for Events.SaveComplete
local R_QUERY_MAX = 10    -- s for LuaEvents.FileListQueryResults
local R_LOAD_MAX = 15     -- s: this context should be gone after Network.LoadGame
local m_R = nil           -- the running chain
local m_RSubSave = false  -- listeners added in this Lua state
local m_RSubList = false

local function RId(phase)
	local kind = "R"
	if m_R ~= nil then
		kind = m_R.kind
	end
	return kind .. "-UI." .. phase
end

local function RManual(r)
	local name = R_SAVE .. "_<time>"
	if r ~= nil and r.e ~= nil and r.e.saveName ~= nil then
		name = r.e.saveName
	end
	if r == nil or not r.applied then
		Spike("R", "nothing changed: R stopped before the team write. Nothing to load.")
	elseif not r.recorded then
		Spike("R", "MANUAL: gameplay did not record the change. Do NOT save. Load TX3b_base (Menu > Load Game) and read the G lines.")
	else
		Spike("R", "MANUAL: open Menu > Load Game and load '" .. name .. "' by hand now (if it is missing, " ..
			"first save as '" .. name .. "'). Don't click leader portraits until then.")
	end
end

local function RFail(phase, reason)
	local r = m_R
	Check(RId(phase), "FAIL", reason)
	m_R = nil
	if r ~= nil and r.queryId ~= nil and not r.closed then
		TX_Probe(false, "UI", nil, ".CloseFileListQuery", r.queryId)
	end
	RManual(r)
end

local function ArgsText(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = Str((select(i, ...)))
	end
	return table.concat(parts, ",")
end

local function ROnSaveComplete(...)
	local args = { n = select("#", ...), ... }
	local ok, err = pcall(function()
		if m_R ~= nil and m_R.phase == "save" then
			m_R.saved = true
			m_R.saveArgs = ArgsText(unpack(args, 1, args.n))
		end
	end)
	if not ok then
		Spike("R", "ERROR SaveComplete listener " .. Str(err))
	end
end

-- Results are filed by id; RTick picks ours (the id may come after the results).
local function ROnFileList(fileList, id)
	local ok, err = pcall(function()
		if m_R ~= nil and m_R.phase == "query" then
			m_R.lists[Str(id)] = fileList or {}
		end
	end)
	if not ok then
		Spike("R", "ERROR FileListQueryResults listener " .. Str(err))
	end
end

-- Adds a listener through the probe (the events are not verified). nil or the error.
local function RSub(rootName, evName, fn)
	local re = TX_Probe(false, rootName, nil, "=" .. evName)
	if not re.ok or re.rets[1] == nil then
		return rootName .. "." .. evName .. "=" .. TXD.Tok(re)
	end
	local ra = TX_Probe("R sub", re.rets[1], nil, ".Add", fn)
	if not ra.ok then
		return rootName .. "." .. evName .. ".Add " .. TXD.Tok(ra)
	end
	return nil
end

-- Enums and the save type, read before anything changes. e or nil, error.
local function RPrep()
	local e, bad = {}, {}
	local function Enum(key, root, name)
		local r = TX_Probe(false, root, nil, "=" .. name)
		if r.ok and r.rets[1] ~= nil then
			e[key] = r.rets[1]
		else
			bad[#bad + 1] = root .. "." .. name .. "=" .. TXD.Tok(r)
		end
	end
	Enum("loc", "SaveLocations", "LOCAL_STORAGE")
	Enum("gameState", "SaveFileTypes", "GAME_STATE")
	Enum("optNormal", "SaveLocationOptions", "NORMAL")
	Enum("optQuick", "SaveLocationOptions", "QUICKSAVE")
	Enum("optMeta", "SaveLocationOptions", "LOAD_METADATA")
	Enum("serverNone", "ServerType", "SERVER_TYPE_NONE")
	local st = TX_Probe(false, "Network", nil, ".GetGameConfigurationSaveType")
	if st.ok and st.rets[1] ~= nil then
		e.saveType = st.rets[1]
	else
		bad[#bad + 1] = "Network.GetGameConfigurationSaveType()=" .. TXD.Tok(st)
	end
	local okN, stampText = pcall(function() return os.date("%Y%m%d_%H%M%S") end)
	if okN and type(stampText) == "string" and stampText ~= "" then
		e.saveName = R_SAVE .. "_" .. stampText
	else
		bad[#bad + 1] = "os.date for a unique save name " .. Str(stampText)
	end
	for _, k in ipairs({ "QuerySaveGameList", "CloseFileListQuery" }) do
		if TX_Probe(false, "UI", nil, "?" .. k).exists ~= "function" then
			bad[#bad + 1] = "UI." .. k .. " missing"
		end
	end
	for _, k in ipairs({ "SaveGame", "LeaveGame", "LoadGame" }) do
		if TX_Probe(false, "Network", nil, "?" .. k).exists ~= "function" then
			bad[#bad + 1] = "Network." .. k .. " missing"
		end
	end
	if #bad == 0 then
		local okO, opts = pcall(function() return e.optNormal + e.optQuick + e.optMeta end)
		if okO then
			e.opts = opts
		else
			bad[#bad + 1] = "SaveLocationOptions sum " .. Str(opts)
		end
	end
	if #bad == 0 and not m_RSubSave then
		local err = RSub("Events", "SaveComplete", ROnSaveComplete)
		if err == nil then
			m_RSubSave = true
		else
			bad[#bad + 1] = err
		end
	end
	if #bad == 0 and not m_RSubList then
		local err = RSub("LuaEvents", "FileListQueryResults", ROnFileList)
		if err == nil then
			m_RSubList = true
		else
			bad[#bad + 1] = err
		end
	end
	if #bad > 0 then
		return nil, table.concat(bad, "; ")
	end
	return e, nil
end

local function RLoad(list)
	local r = m_R
	local name = r.e.saveName
	local entry, seen = TXD.FindSave(list, name)
	TX_Probe(false, "UI", nil, ".CloseFileListQuery", r.queryId)
	r.closed = true
	local names = {}
	for i = 1, math.min(#seen, 12) do
		names[i] = seen[i]
	end
	if entry == nil then
		RFail("query", "no entry named " .. name .. " among " .. #seen .. " files: " .. table.concat(names, ", "))
		return
	end
	Check(RId("query"), "PASS", "found " .. name .. " (Name=" .. Str(entry.Name) .. ") among " .. #seen .. " files")
	r.phase = "load"
	r.untilAt = m_Clock + R_LOAD_MAX
	Spike("R", "leaving the session and loading " .. name .. " (LoadGameMenu.lua:96-114). The game should reload now.")
	local rl = TX_Probe("R leave", "Network", nil, ".LeaveGame")
	if not rl.ok then
		RFail("load", "Network.LeaveGame " .. TXD.Tok(rl))
		return
	end
	local rd = TX_Probe("R load", "Network", nil, ".LoadGame", entry, r.e.serverNone)
	if not rd.ok then
		RFail("load", "Network.LoadGame " .. TXD.Tok(rd))
		return
	end
	Check(RId("load"), "INFO", "Network.LoadGame(" .. name .. ", SERVER_TYPE_NONE) requested; expect the load screen, then " ..
		"phase S3RELOAD1 and V1 PASS")
end

local function RQuery()
	local r, e = m_R, m_R.e
	Check(RId("save"), "PASS", "Events.SaveComplete args=(" .. Str(r.saveArgs) .. ")")
	r.phase = "query"
	r.untilAt = m_Clock + R_QUERY_MAX
	local q = TX_Probe("R query", "UI", nil, ".QuerySaveGameList", e.loc, e.saveType, e.opts, e.gameState, "")
	if not q.ok or q.rets[1] == nil then
		RFail("query", "UI.QuerySaveGameList " .. TXD.Tok(q))
		return
	end
	r.queryId = q.rets[1]
	Check(RId("query"), "INFO", "UI.QuerySaveGameList id=" .. Str(r.queryId) .. "; waiting for LuaEvents.FileListQueryResults (" ..
		R_QUERY_MAX .. " s)")
end

local function RSave()
	local r, e = m_R, m_R.e
	local file = { Name = e.saveName, Location = e.loc, Type = e.saveType, FileType = e.gameState, IsAutosave = false,
		IsQuicksave = false }
	r.phase = "save"
	r.saved = false
	r.untilAt = m_Clock + R_SAVE_MAX
	local s = TX_Probe("R save", "Network", nil, ".SaveGame", file)
	if not s.ok then
		RFail("save", "Network.SaveGame " .. TXD.Tok(s))
		return
	end
	Check(RId("save"), "INFO", "Network.SaveGame{Name=" .. e.saveName .. ", Location=" .. Str(e.loc) .. ", Type=" .. Str(e.saveType) ..
		", FileType=" .. Str(e.gameState) .. "} sent; waiting for Events.SaveComplete (" .. R_SAVE_MAX .. " s)")
end

-- The OnUpdate step of the chain: save -> query -> load, each with a timeout.
local function RTick()
	local r = m_R
	if r == nil then
		return
	end
	if r.phase == "save" then
		if r.saved then
			RQuery()
		elseif m_Clock > r.untilAt then
			RFail("save", "no Events.SaveComplete within " .. R_SAVE_MAX .. " s")
		end
	elseif r.phase == "query" then
		local list = r.lists[Str(r.queryId)]
		if list ~= nil then
			RLoad(list)
		elseif m_Clock > r.untilAt then
			RFail("query", "no LuaEvents.FileListQueryResults for id " .. Str(r.queryId) .. " within " .. R_QUERY_MAX .. " s")
		end
	elseif r.phase == "load" then
		if m_Clock > r.untilAt then
			RFail("load", "this game still runs " .. R_LOAD_MAX .. " s after Network.LoadGame")
		end
	end
end

-- Runs fn; an error stops the chain with a FAIL (never a chain stuck in a phase).
local function RGuard(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		Spike("R", "ERROR " .. Str(err))
		if m_R ~= nil then
			RFail(Str(m_R.phase), "ERROR " .. Str(err))
		end
	end
end

-- The gameplay answer to "changed" / "k_kick": the change must be recorded before the save.
local function RAfterApply(stamp)
	local r = m_R
	if r == nil or r.phase ~= "apply" then
		return
	end
	local now = ArmRead()
	if not IsArmed(now) or now.phase ~= "LIVE" or now.stamp ~= stamp or (r.kind == "RK" and type(now.k) ~= "table") then
		RFail("apply", "gameplay did not record the change (refused, error or no answer within " .. WAIT_MAX ..
			" s); phase " .. TXD.PhaseLabel(now))
		return
	end
	r.recorded = true
	Check(RId("apply"), "PASS", "config team of P" .. r.t .. " = " .. Str(CfgTeamOf(r.t)) .. ", gameplay phase " ..
		TXD.PhaseLabel(now))
	SnapshotUI("changed")
	if r.kind == "RK" then
		ALReadUI(now, "K", "after")
		VisReadUI(now, "Kvis", "after")
	end
	RSave()
end

-- The button. kind "R" (changed) or "RK" (k_kick). Every refusal comes before any change.
local function RStart(kind)
	if m_R ~= nil then
		Spike("R", "refused: an R chain is already running (phase " .. Str(m_R.phase) .. ")")
		return
	end
	local arm = ArmRead()
	if not IsArmed(arm) or arm.phase ~= "BASE" then
		Spike("R", "refused: " .. kind .. " starts at BASE (load TX3b_base, or press Arm BASE first)")
		return
	end
	if NetMP() == 1 then
		Spike("R", "refused: network multiplayer. The host loads from the front end, clients rejoin (RELOAD.md 2)")
		return
	end
	local me = LocalID()
	local act = TX_Probe(false, "Players", me, ":IsTurnActive")
	if act.ok and act.rets[1] ~= true then
		Spike("R", "refused: not P" .. Str(me) .. "'s active turn (save and load need it, LocalPlayerActionSupport.lua:6-44)")
		return
	end
	local feats = {}
	for _, f in ipairs({ "Saving", "Loading" }) do
		local rf = TX_Probe(false, "UI", nil, ".HasFeature", f)
		if rf.ok and rf.rets[1] == false then
			Spike("R", "refused: UI.HasFeature(\"" .. f .. "\") is false")
			return
		end
		feats[#feats + 1] = f .. "=" .. TXD.Tok(rf)
	end
	local t = arm.target
	local team = tonumber(EditText(Controls.TeamEdit)) or tonumber(arm.newTeam)
	if team == nil then
		Spike("R", "refused: no New team (S1 Team map suggests one)")
		return
	end
	if CurrentTarget() ~= t then
		Spike("R", "the panel Target is P" .. Str(CurrentTarget()) .. "; " .. kind .. " uses the armed target P" .. Str(t))
	end
	m_R = { kind = kind, phase = "prep", t = t, team = team, lists = {}, applied = false, recorded = false }
	local e, err = RPrep()
	if e == nil then
		RFail("prep", Str(err))
		return
	end
	m_R.e = e
	Check(RId("prep"), "INFO", "P" .. t .. " -> team " .. team .. "; save '" .. e.saveName .. "' type " .. Str(e.saveType) ..
		"; turn active=" .. TXD.Tok(act) .. " " .. table.concat(feats, " ") .. "; " .. Machine())
	if kind == "RK" then
		ALReadUI(arm, "K", "before")
		VisReadUI(arm, "Kvis", "before")
	end
	m_R.phase = "apply"
	m_R.applied = true
	local liveBefore = S3Write(t, team, arm)
	if CfgTeamOf(t) ~= team then
		RFail("apply", "config team of P" .. t .. " is " .. Str(CfgTeamOf(t)) .. ", want " .. team)
		return
	end
	local p = BaseParams("changed")
	if kind == "RK" then
		p = BaseParams("k_kick")
	end
	p.path, p.target, p.team = "S3", t, team
	if liveBefore ~= nil then
		p.orig = liveBefore
	end
	if not Send(p) then
		RFail("apply", "request " .. p.cmd .. " not sent")
		return
	end
	WaitFor(p.stamp, function() RGuard(RAfterApply, p.stamp) end, "arm", p.cmd)
end

-- AL2 UI half: existence only (no calls), then the G half.
local function AL2Exist()
	local arm = ALRoles()
	local names = {}
	local function Ex(label, root, sel, member)
		names[#names + 1] = label .. "=" .. TXD.Tok(TX_Probe("AL2 exist", root, sel, member))
	end
	for _, m in ipairs({ "SendAction", "AddCommand", "TestAction", "RequestSession" }) do
		Ex("DiplomacyManager." .. m, "DiplomacyManager", nil, "?" .. m)
	end
	Ex("DiplomacyActionTypes.ALLY", "DiplomacyActionTypes", nil, "=ALLY")
	local d = DiploOf(arm.keeper)
	for _, m in ipairs({ "GetAllianceType", "GetAllianceTurnsUntilExpiration", "IsDiplomaticActionValid",
		"GetDeclaredFriendshipTurn", "CanDeclareWarOn" }) do
		Ex("Diplomacy:" .. m, d, nil, "?" .. m)
	end
	Ex("DB.MakeHash", "DB", nil, "?MakeHash")
	Check(TXD.ALId("2", arm), "INFO", "exist: " .. table.concat(names, " "))
	Send(BaseParams("al2_exist"))
end

-- AL4 / AL4L UI half: the alliance value hash (DB.MakeHash, DiplomacyActionView_Expansion1.lua:165), then G.
local function AL4Deal(n, cmd)
	local r = TX_Probe("AL" .. n .. " hash", "DB", nil, ".MakeHash", "ALLIANCE_RESEARCH")
	local extra = {}
	if r.ok and type(r.rets[1]) == "number" then
		extra.hash = r.rets[1]
	end
	ALStep(n, cmd, extra)
end

-- AL6: read-only refusal checks for war and denounce. IsDiplomaticActionValid:
-- DiplomacyStatementSupport.lua:167; TestAction: DeclareWarPopup.lua:109-111.
local function AL6Valid()
	local arm = ALRoles()
	local k, t = arm.keeper, arm.target
	local d = DiploOf(k)
	local parts = {}
	local function Add(label, r)
		parts[#parts + 1] = label .. "=" .. TXD.Rets(r)
	end
	Add("CanDeclareWarOn k->t", TX_Probe("AL6 valid", d, nil, ":CanDeclareWarOn", t))
	Add("CanDeclareWarOn t->k", TX_Probe("AL6 valid", DiploOf(t), nil, ":CanDeclareWarOn", k))
	for _, a in ipairs({ "DIPLOACTION_DECLARE_FORMAL_WAR", "DIPLOACTION_DECLARE_SURPRISE_WAR", "DIPLOACTION_DENOUNCE",
		"DIPLOACTION_ALLIANCE_RESEARCH" }) do
		Add(a, TX_Probe("AL6 valid", d, nil, ":IsDiplomaticActionValid", a, t, true))
	end
	local rw = TX_Probe(false, "WarTypes", nil, "=SURPRISE_WAR")
	local ra = TX_Probe(false, "DiplomacyActionTypes", nil, "=SET_WAR_STATE")
	if rw.rets[1] ~= nil and ra.rets[1] ~= nil then
		Add("TestAction SET_WAR_STATE", TX_Probe("AL6 valid", "DiplomacyManager", nil, ".TestAction", k, t, ra.rets[1],
			{ WarState = rw.rets[1] }))
	else
		parts[#parts + 1] = "TestAction=skipped (WarTypes.SURPRISE_WAR=" .. TXD.Tok(rw) .. " SET_WAR_STATE=" .. TXD.Tok(ra) .. ")"
	end
	Check(TXD.ALId("6", arm), "INFO", "keeper P" .. Str(k) .. " on target P" .. Str(t) .. ": " .. table.concat(parts, "; "))
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local function OnTurnActivated(pid)
	if not m_ViewReady or pid ~= LocalID() or m_SnapTurn == TXD.Turn() then
		return
	end
	if IsArmed(ArmRead()) then
		SnapshotUI("turn")
	end
end

local function OnLoadDone()
	m_ViewReady = true
	if IsArmed(ArmRead()) then
		-- the "loaded" follow-up is this turn's UI snapshot (with the RELOAD label)
		m_SnapTurn = TXD.Turn()
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
	local v, t = TXD.Verdict.V3Both(TXD.PhaseLabel(arm), members, CfgMembers(team), arm.keeper, arm.target, nil)
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
	ALRead = ALRead,
	AL1 = function() ALStep("1", "al1_friend_off") end,
	AL2 = AL2Exist,
	AL3 = function() ALStep("3", "al3_war_peace") end,
	AL3b = function() ALStep("3b", "al3b_war_peace") end,
	AL4 = function() AL4Deal("4", "al4_alliance") end,
	AL4L = function() AL4Deal("4L", "al4l_alliance_long") end,
	AL8 = function() ALStep("8", "al8_unmeet") end,
	AL9 = function() ALStep("9", "al9_remeet") end,
	AL5 = function() ALStep("5", "al5_allied_toggle") end,
	AL6 = AL6Valid,
	AL7Off = function() ALStep("7off", "al7_vis", { on = 0 }) end,
	AL7On = function() ALStep("7on", "al7_vis", { on = 1 }) end,
	VIS1 = function() VISStep(1) end,
	VIS2 = function() VISStep(2) end,
	VIS3 = function() VISStep(3) end,
	KFull = KFullKick,
	S3n = S3nSet,
	PTeamsRead = PTeamsRead,
	PTeamsWrite = PTeamsWrite,
	RApply = function() RGuard(RStart, "R") end,
	RKApply = function() RGuard(RStart, "RK") end,
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
	{ label = "Q Setup Session 2", cmd = "q_setup2", tip = "V10 friends, V9 deals, V5 marker in one press (no V4)" },
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
	{ header = "AL alliance tests (load TX3_split before each !)" },
	{ label = "AL0 Read state (UI+G)", ui = "ALRead", tip = "read only: diplo state both ways, HasAllied, friendship, war, vision" },
	{ label = "AL1 Friendship off (!)", ui = "AL1", tip = "SetHasDeclaredFriendship false, keeper and target, both ways" },
	{ label = "AL2 Probe APIs (no calls)", ui = "AL2", tip = "existence only of the alliance and peace calls" },
	{ label = "AL3 War then peace (!)", ui = "AL3", tip = "keeper declares war on target, then makes peace" },
	{ label = "AL3b War(false) then peace (!)", ui = "AL3b", tip = "as AL3, with DeclareWarOn third argument false" },
	{ label = "AL4 Alliance deal 1 turn (!)", ui = "AL4", tip = "research alliance keeper-target, duration 1 turn" },
	{ label = "AL4L Alliance, friends off (!)", ui = "AL4L",
		tip = "AL4, then AL1 friendship off. End turns past the expiry: every turn start reads the state" },
	{ label = "AL5 SetHasAllied toggle (!)", ui = "AL5", tip = "SetHasAllied true both ways, then false. May stick for good." },
	{ label = "AL6 War/denounce valid? (UI)", ui = "AL6", tip = "read only: may keeper declare war on or denounce target?" },
	{ label = "AL7 Vision OFF (all teams!)", ui = "AL7Off",
		tip = "GLOBAL: switches team vision off for EVERY team, the intact one too. Press AL7 Vision ON after." },
	{ label = "AL7 Vision ON (restore)", ui = "AL7On", tip = "GLOBAL: switches team vision back on for every team" },
	{ label = "AL8 Unmeet both ways (!)", ui = "AL8", tip = "clean break probe: SetHasMet(other, false), keeper and target" },
	{ label = "AL9 Unmeet then meet (!)", ui = "AL9", tip = "clean break probe: SetHasMet(false) both ways, then SetHasMet again" },
	{ header = "VIS vision tests (load TX3_split, V5 Marker, end turn)" },
	{ label = "VIS1 Remove outgoing vis (!)", ui = "VIS1", tip = "RemoveOutgoingVisibility keeper->target and target->keeper" },
	{ label = "VIS2 Recheck visibility (!)", ui = "VIS2", tip = "RecheckVisibilityOnAll and RecheckVisibilityOn, keeper and target" },
	{ label = "VIS3 SetVisibilityOn 0 (!)", ui = "VIS3", tip = "diplomatic visibility level 0, both ways (GetVisibilityOn logged)" },
	{ header = "K full kick (load TX3_base, armed at BASE)" },
	{ label = "K Full kick (S3+VIS1) (!)", ui = "KFull",
		tip = "S3 set + broadcast, then RemoveOutgoingVisibility both ways (no war). Then save TX3_kick and load it." },
	{ header = "Session 3b: S3n, P-Teams, R reload (hotseat)" },
	{ label = "S3n Set team, no broadcast (!)", ui = "S3n",
		tip = "config team of the Target = New team, WITHOUT Network.BroadcastPlayerInfo. Leon: watch the ribbon" },
	{ label = "P-Teams read", ui = "PTeamsRead", tip = "read only: this panel's Teams table, #Teams[orig], Teams[new]" },
	{ label = PTW_LABEL_TEXT, ui = "PTeamsWrite",
		tip = "after S3: Teams[new] = {target}, target out of Teams[orig], in THIS panel's context only; then a broadcast" },
	{ label = "R Apply + reload (hotseat) (!)", ui = "RApply",
		tip = "at BASE: S3 set + broadcast, save TX_autoreload_<date_time>, then load it by itself. Hotseat, your turn only" },
	{ label = "RK Kick + VIS1 + reload (!)", ui = "RKApply",
		tip = "at BASE: K (S3 + VIS1), then save TX_autoreload_<date_time> and load it by itself" },
	{ header = "Misc" },
	{ label = "Diplo matrix", cmd = "diplo" },
	{ label = "Clear spike state", cmd = "clear" },
}

local function OnButton(def)
	RebuildTargets()
	if def.ui ~= nil then
		-- def goes along: the P-Teams write checks its own button label
		local ok, err = pcall(UIFN[def.ui], def)
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
			if def.tip ~= nil then
				b.Button:SetToolTipString(def.tip)
			end
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
	if m_R ~= nil then
		RGuard(RTick)
	end
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
