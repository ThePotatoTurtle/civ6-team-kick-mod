-- Tests of TX_Dev/Scripts/TX_Dev_Gameplay.lua (PLAN I.10): the real gameplay
-- script on the fake engine plus lib/fake_devworld.lua. Hotseat setup of
-- PLAN I.12: P0+P1 team 0, P2 (human) + P3 (AI) team 1, Free Cities, Barbarians.

local G = "TX_Dev/Scripts/TX_Dev_Gameplay.lua"
local GLOBALS = { "TXD", "TX_Probe" }

local function World(opts)
	opts = opts or {}
	H.world{
		teams = { [0] = 0, [1] = 0, [2] = 1, [3] = 1 },
		players = {
			{ id = 0, human = true }, { id = 1, human = true }, { id = 2, human = true }, { id = 3 },
			{ id = 62, kind = "FREE_CITIES" }, { id = 63, kind = "BARBARIAN" },
		},
	}
	FAKE.dofile("tests/offline/lib/fake_devworld.lua")
	FAKE_DEV.Install(opts)
	FAKE_DEV.AddCity(0, 3, 3)
	FAKE_DEV.AddCity(1, 6, 3)
	FAKE_DEV.AddCity(2, 18, 10)
	FAKE_DEV.AddCity(3, 20, 4)
	H.load(G)
end

local m_Stamp = 1000
local function Req(cmd, p, pid)
	p = p or {}
	p.OnStart = "TX_Dev"
	p.cmd = cmd
	if p.stamp == nil then
		m_Stamp = m_Stamp + 1
		p.stamp = m_Stamp
	end
	if p.ctx == nil then p.ctx = "UI" end
	H.request(pid or 0, p)
end

local function Arm(extra)
	local p = { target = 1, team = 2, mp = 0, hotseat = 1 }
	for i = 0, 3 do p["cfg_" .. i] = PlayerConfigurations[i]:GetTeam() end
	for k, v in pairs(extra or {}) do p[k] = v end
	Req("arm", p)
end

-- The S3 change as the panel makes it: config write in UI, then "changed".
local function S3Change(team)
	PlayerConfigurations[1]:SetTeam(team or 2)
	Req("changed", { path = "S3", target = 1, team = team or 2 })
end

local function NoErrors()
	for _, l in ipairs(H.lines()) do
		H.ok(not string.find(l, "] G ERROR ", 1, true) and not string.find(l, "] UI ERROR ", 1, true), "error line: " .. l)
	end
	H.clean()
end

local function Last(prefix)
	local l = H.lines(prefix)
	return l[#l]
end

test("init line and the handler", function()
	World()
	H.ok(#H.lines("[TX][SPIKE][INIT] G TX_Dev 0.0.1.1 loaded (for TX 0.0.1 spike) turn=1 armed=0", true) == 1)
	H.eq(GameEvents.TX_Dev.Count(), 1)
	H.eq(GameEvents.OnGameTurnStarted.Count(), 1)
	NoErrors()
end)

test("unknown cmd is logged and does not throw", function()
	World()
	Req("nope")
	H.ok(H.hasLine("[TX][SPIKE][REQ] G unknown cmd nope"))
	H.request(0, { OnStart = "TX_Dev" })
	H.ok(H.hasLine("unknown cmd nil"))
	NoErrors()
end)

test("s1_map: every slot, the unused team, S1TEAM-G", function()
	World()
	Req("s1_map")
	for _, i in ipairs({ 0, 1, 2, 3, 62, 63 }) do
		H.ok(H.hasLine("[TX][SPIKE][S1] G slot " .. i .. " team="), "slot " .. i)
	end
	H.ok(H.hasLine("[TX][SPIKE][S1] G slot 1 team=0 alive=1 major=1 human=1 cfgTeam=0"))
	H.ok(H.hasLine("[TX][SPIKE][S1] G teams: 0={0,1} 1={2,3} 62={62} 63={63}"))
	H.ok(H.hasLine("[TX][SPIKE][S1] G unused team: 2 (lowest non-negative ID"))
	H.ok(H.hasLine("[TX][CHECK] S1TEAM-G INFO T1 G solo team==pid 0/0; unused=2; cfg readable in G=yes"))
	NoErrors()
end)

test("s1_dump: targets, setter keys stored", function()
	World()
	Players[0].SetTeam = function() end
	Req("s1_dump", { stamp = 77 })
	-- own keys first (the fake player table), then the metatable's methods
	H.ok(H.hasLine("[TX][SPIKE][S1] G Players[0] team: SetTeam(f) configTeam(n) team(n) GetTeam(f)"), H.Ser(H.lines("Players[0] team")))
	H.ok(H.hasLine("[TX][SPIKE][S1] G DiplomacyManager = MISSING"))
	H.ok(H.hasLine("[TX][CHECK] S1-G INFO"))
	local s1 = H.prop("TX_DEV_S1")
	H.eq(s1.stamp, 77)
	local found = false
	for _, k in ipairs(s1.keys or {}) do
		if k.obj == "Players[0]" and k.key == "SetTeam" then found = true end
	end
	H.ok(found, H.Ser(s1))
	NoErrors()
end)

test("arm: roles, teamsBase, caps survive the property round trip", function()
	World()
	Arm()
	local a = H.prop("TX_DEV_ARM")
	H.eq(a.keeper, 0)
	H.eq(a.target, 1)
	H.eq(a.other, 2)
	H.eq(a.origTeam, 0)
	H.eq(a.newTeam, 2)
	H.eq(a.path, "BASE")
	H.eq(a.phase, "BASE")
	H.eq(a.hotseat, 1)
	local pids = {}
	for i, r in ipairs(a.teamsBase) do pids[i] = r.pid end
	H.deq(pids, { 0, 1, 2, 3, 62, 63 })
	H.eq(a.teamsBase[2].cfg, 0)
	H.isnil(a.teamsBase[5].cfg, "no cfg param for 62")
	H.eq(#a.caps, 4)
	H.deq(a.caps[3], { pid = 2, x = 18, y = 10 })
	H.ok(type(a.g) == "table", "BASE values recorded")
	H.ok(H.hasLine("[TX][SPIKE][SNAP] G armed roles keeper=P0 target=P1 other=P2 origTeam=0 newTeam=2"))
	H.ok(H.hasLine("[TX][CHECK] V1-G.BASE INFO"))
	H.len(FAKE.propViolations, 0)
	NoErrors()
end)

test("S3 config model: S3LIVE FAIL, RELOAD1 PASS, second loaded ignored, RELOAD2", function()
	World()
	Arm()
	S3Change(2)
	H.ok(H.hasLine("[TX][CHECK] V1-G.S3LIVE FAIL"), "config-only change: live team unchanged")
	H.ok(H.hasLine("[TX][CHECK] S4-G.S3LIVE INFO T1 G gameplay reads Players[1]:GetTeam()=0 (want 2), cfg via probe=2"))
	H.reload(G, GLOBALS, { applyConfigTeams = true })
	Req("loaded")
	local a = H.prop("TX_DEV_ARM")
	H.eq(a.loads, 1)
	H.eq(a.phase, "RELOAD")
	H.ok(H.hasLine("[TX][SPIKE][SNAP] G load counted loads=1 phase=S3RELOAD1"))
	H.ok(H.hasLine("[TX][CHECK] V1-G.S3RELOAD1 PASS"))
	Req("loaded")
	H.eq(H.prop("TX_DEV_ARM").loads, 1, "a second loaded in the same state is not counted")
	H.ok(H.hasLine("loaded: no load to count"))
	H.reload(G, GLOBALS)
	Req("loaded")
	H.eq(H.prop("TX_DEV_ARM").loads, 2)
	H.ok(H.hasLine("[TX][CHECK] V1-G.S3RELOAD2 PASS"))
	NoErrors()
end)

test("S3 live model: S3LIVE PASS", function()
	World()
	FAKE.teamModel = "live"
	Arm()
	S3Change(2)
	H.ok(H.hasLine("[TX][CHECK] V1-G.S3LIVE PASS"))
	NoErrors()
end)

test("reload at BASE keeps BASE; a lobby change is detected as S3b", function()
	World()
	Arm()
	H.reload(G, GLOBALS)
	Req("snap")
	H.ok(H.hasLine("load counted loads=1 phase=BASE (armed at BASE, reloaded 1)"))
	H.eq(H.prop("TX_DEV_ARM").path, "BASE")
	H.reload(G, GLOBALS)
	H.team(1, 2)
	Req("loaded")
	H.ok(H.hasLine("[TX][SPIKE][S3b] G team changed outside the panel (lobby?): P1 team 0 -> 2"))
	H.ok(H.hasLine("[TX][CHECK] V1-G.S3bRELOAD1 PASS"))
	NoErrors()
end)

test("v6_war: refused at BASE, FAIL while the team is shared", function()
	World()
	Arm()
	Req("v6_war")
	H.ok(H.hasLine("[TX][SPIKE][V6] G refused before the change"))
	H.isnil(H.prop("TX_DEV_ARM").v6)
	S3Change(2)
	Req("v6_war")
	H.ok(H.hasLine("[TX][SPIKE][V6] G P2 declares war on P0 ok=true"))
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] V6-G.S3LIVE FAIL T2 G other at war with keeper=yes, with target=yes"))
	NoErrors()
end)

test("v6_war: PASS with a split team", function()
	World()
	FAKE.teamModel = "live"
	Arm()
	S3Change(2)
	Req("v6_war")
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] V6-G.S3LIVE PASS T2 G other at war with keeper=yes, with target=no"))
	NoErrors()
end)

test("V9 and V10: BASE stores the deals and friendship, PASS after, FAIL when gone", function()
	World()
	FAKE.teamModel = "live"
	Req("v10_friend", { target = 1 })
	H.ok(H.hasLine("[TX][SPIKE][V10] G friends=yes/yes (P1 and P2)"))
	Req("v9_deals", { target = 1 })
	H.ok(H.hasLine("[TX][SPIKE][V9] G ob12=1 ob21=1 gpt=1 deals=3"), H.Ser(H.lines("[TX][SPIKE][V9]")))
	H.ok(H.hasLine("PROBE V9 gpt DealManager.EnactWorkingDeal(1,2)"))
	Arm()
	local a = H.prop("TX_DEV_ARM")
	H.eq(a.g.v10, 1)
	H.eq(a.g.v9ob12, 1)
	H.eq(a.g.v9gpt, 1)
	H.eq(a.v9.ob21, 1, "the setup record made before arming stays")
	S3Change(2)
	H.ok(H.hasLine("[TX][CHECK] V9-G.S3LIVE PASS"))
	H.ok(H.hasLine("[TX][CHECK] V10-G.S3LIVE PASS"))
	H.friend(1, 2, false)
	FAKE_DEV.RemoveDeals(1, 2)
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] V10-G.S3LIVE FAIL T2"))
	H.ok(H.hasLine("[TX][CHECK] V9-G.S3LIVE FAIL T2"))
	NoErrors()
end)

test("s2_probe lists a stub setter, s2_call refuses a never-list name", function()
	World()
	Players[1].SetTeam = function() end
	Req("s2_probe", { target = 1, stamp = 55 })
	local s2 = H.prop("TX_DEV_S2")
	H.eq(s2.stamp, 55)
	local found = false
	for _, h in ipairs(s2.hits or {}) do
		if h.root == "Players" and h.name == "SetTeam" and h.ctx == "G" and h.sel == "target" then found = true end
	end
	H.ok(found, H.Ser(s2))
	H.ok(H.hasLine("[TX][SPIKE][S2] G PROBE S2 exist Players[1]?SetTeam exists=function"))
	H.ok(H.hasLine("[TX][CHECK] S2-G INFO T1 G exist:"))
	Req("s2_call", { root = "Game", name = "SetWinningTeam", style = ".", args = "player,team", target = 1, team = 2 })
	H.ok(H.hasLine("[TX][SPIKE][S2] G REFUSED never-call Game.SetWinningTeam"))
	NoErrors()
end)

test("s2_call calls the setter, then V1 and the S2 phase", function()
	World()
	local got = {}
	Players[1].SetTeam = function(self, t) got[#got + 1] = t; self.team = t end
	Arm()
	Req("s2_call", { root = "Players", sel = "target", name = "SetTeam", style = ":", args = "team", target = 1, team = 2 })
	H.deq(got, { 2 })
	H.ok(H.hasLine("[TX][SPIKE][S2] G about to call Players[target]:SetTeam(team) target=P1 team=2"))
	H.ok(H.hasLine("[TX][CHECK] S2-G INFO T1 G call ok=true ret=nil target team now 2"))
	H.ok(H.hasLine("[TX][CHECK] V1-G.S2LIVE PASS"))
	H.eq(H.prop("TX_DEV_ARM").path, "S2")
	NoErrors()
end)

test("turn snapshot only when armed", function()
	World()
	H.endTurn()
	H.eq(#H.lines("[TX][SPIKE][SNAP] G"), 0)
	Arm()
	H.endTurn()
	H.ok(H.hasLine("[TX][SPIKE][SNAP] G BASE reason=turn teams: 0={0,1} 1={2,3} 62={62} 63={63}"))
	H.ok(H.hasLine("[TX][CHECK] V12-G.BASE INFO T3 G fp="))
	NoErrors()
end)

test("v4_boost and v5_marker before arming, recorded in the arm", function()
	World()
	Req("v4_boost", { target = 1, type = "TECH_MACHINERY" })
	H.ok(H.hasLine("[TX][SPIKE][V4] G spawned 3 UNIT_ARCHER for P0 (TECH_MACHINERY boost: own 3)"))
	local mach = GameInfo.Technologies.TECH_MACHINERY.Index
	H.ok(FAKE_DEV.boosts[1][mach], "boost shared with P1 in the fake team model")
	Req("v5_marker", { target = 1 })
	local a = H.prop("TX_DEV_ARM")
	H.eq(a.v4[1].tech, "TECH_MACHINERY")
	H.eq(a.v4[1].n, 3)
	H.eq(a.v4[1].path, "BASE")
	H.ok(a.v5 ~= nil and a.v5.x ~= nil, H.Ser(a))
	H.ok(Players[0]:GetUnits() ~= nil)
	H.ok(H.hasLine("[TX][SPIKE][V5] G marker P0 Warrior at"))
	-- the marker is far from P1's city at 6,3
	H.ok(math.max(math.abs(a.v5.x - 6), math.abs(a.v5.y - 3)) > 3)
	Arm()
	a = H.prop("TX_DEV_ARM")
	H.eq(a.v4[1].tech, "TECH_MACHINERY", "kept by arm")
	H.ok(H.hasLine("[TX][CHECK] V5-G.BASE INFO T1 G visibility read in gameplay (probe): target sees marker=true"))
	H.len(FAKE.propViolations, 0)
	NoErrors()
end)

test("v3_setup: refused before V6, then tanks next to the enemy capitals", function()
	World()
	FAKE.teamModel = "live"
	Arm()
	Req("v3_setup", { who = "keeper" })
	H.ok(H.hasLine("[TX][SPIKE][V3] G refused"))
	S3Change(2)
	Req("v6_war")
	Req("v3_setup", { who = "keeper" })
	H.ok(H.hasLine("[TX][SPIKE][V3] G P0: capital of P2 at 18,10 weakened=true (city HP 1/200, walls 0/100), 3 Tanks at"))
	H.ok(H.hasLine("[TX][SPIKE][V3] G P0: capital of P3 at 20,4 weakened=true"))
	H.eq(#H.lines("capital of P1"), 0, "the target is not an enemy of the keeper's base team")
	H.eq(H.prop("TX_DEV_ARM").v3.who, 0)
	H.ok(#FAKE_DEV.visCount > 0)
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] V3-G.S3LIVE INFO T2 G original capitals: P0@3,3 owner=0 orig=0 isOrigCap=true"))
	NoErrors()
end)

test("diplo matrix and clear", function()
	World()
	H.war(0, 2)
	Req("diplo")
	H.ok(H.hasLine("[TX][SPIKE][DIPLO] G P0 team 0 -> 1:T 2:WM 3:W"), H.Ser(H.lines("DIPLO")))
	Arm()
	Req("clear")
	local a = H.prop("TX_DEV_ARM")
	H.isnil(a.armedTurn)
	H.eq(a.cleared, 1)
	H.eq(H.prop("TX_DEV_S1").n, 0)
	H.ok(H.hasLine("[TX][SPIKE][SNAP] G cleared"))
	NoErrors()
end)

test("store_ui keeps UI base values only for the arm stamp at BASE", function()
	World()
	Arm({ stamp = 4242 })
	Req("store_ui", { armStamp = 1, u_v9ob12 = 1 })
	H.ok(H.hasLine("store_ui ignored"))
	Req("store_ui", { armStamp = 4242, u_v9ob12 = 1, u_v1cfgT = 0 })
	H.ok(H.hasLine("[TX][SPIKE][SNAP] G stored 2 UI base values"))
	H.deq(H.prop("TX_DEV_ARM").ui, { v9ob12 = 1, v1cfgT = 0 })
	NoErrors()
end)

test("no Game.GetLocalPlayer and no math.random in gameplay", function()
	World()
	Arm()
	S3Change(2)
	Req("s1_map")
	Req("s1_dump")
	Req("s2_probe", { target = 1 })
	Req("diplo")
	H.endTurn()
	H.len(FAKE.forbidden, 0)
	NoErrors()
end)
