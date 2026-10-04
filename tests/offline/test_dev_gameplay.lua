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
	H.ok(#H.lines("[TX][SPIKE][INIT] G TX_Dev 0.0.1.5 loaded (for TX 0.0.1 spike) turn=1 armed=0", true) == 1)
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

test("q_setup2: V10 friends, V9 deals, V5 marker in that order", function()
	World()
	Req("q_setup2", { target = 1 })
	local function At(prefix)
		for i, l in ipairs(H.lines()) do
			if string.find(l, prefix, 1, true) == 1 then return i end
		end
		return nil
	end
	local a, b, c = At("[TX][SPIKE][V10] G friends=yes/yes"), At("[TX][SPIKE][V9] G ob12=1 ob21=1"), At("[TX][SPIKE][V5] G marker P0")
	H.ok(a ~= nil and b ~= nil and c ~= nil and a < b and b < c, H.Ser({ a, b, c }))
	local arm = H.prop("TX_DEV_ARM")
	H.ok(arm.v5 ~= nil and arm.v9 ~= nil and arm.v10 ~= nil, H.Ser(arm))
	H.isnil(arm.v4, "no V4")
	NoErrors()
end)

-- ---------------------------------------------------------------------------
-- AL buttons (research/ALLIANCE.md 5). The split, then the leftover ALLIED state.
-- ---------------------------------------------------------------------------
local ALLIED = "DIPLO_STATE_ALLIED"

-- The leftover state after a split (Session 2): ALLIED both ways, friends, and
-- shared vision (LinkVision) whatever the teams. P0 has a second city far from P1.
local function Split()
	World()
	FAKE.teamModel = "live"
	FAKE_DEV.AddCity(0, 3, 12)
	FAKE_DEV.LinkVision(0, 1)
	Req("v5_marker", { target = 1 })
	Arm()
	S3Change(2)
	FAKE_DEV.SetState(0, 1, ALLIED)
	FAKE_DEV.SetState(1, 0, ALLIED)
	H.friend(0, 1, true)
	H.clean()
end

test("AL: destructive steps refused at BASE; AL0 read works unarmed and armed", function()
	World()
	Req("al_read", { target = 1 })
	H.ok(H.hasLine("[TX][CHECK] AL0-G.BASE INFO T1 G state now target->keeper=DIPLO_STATE_NEUTRAL"))
	Arm()
	for _, c in ipairs({ "al1_friend_off", "al3_war_peace", "al4_alliance", "al5_allied_toggle", "al7_vis" }) do
		Req(c)
	end
	H.eq(#H.lines("refused: arm BASE and split the team first"), 5)
	H.isnil(H.prop("TX_DEV_ARM").al)
	H.len(FAKE_DEV.visFlag, 0)
	NoErrors()
end)

test("AL0 read after the split: INFO with the G state, HasAllied, friendship, marker", function()
	Split()
	Req("al_read")
	local l = H.lines("[TX][CHECK] AL0-G.S3LIVE INFO T1 G state now target->keeper=DIPLO_STATE_ALLIED keeper->target=DIPLO_STATE_ALLIED: still ALLIED")[1]
	H.notnil(l, H.Ser(H.lines("AL0")))
	H.ok(string.find(l, "HasAllied k->t=no t->k=no friends k->t=yes t->k=yes met k->t=yes t->k=yes", 1, true), l)
	H.ok(string.find(l, "CanDeclareWarOn k->t=false target sees marker=", 1, true), l)
	NoErrors()
end)

test("AL3 war then peace: before, war, after PASS (UNFRIENDLY), next turn read", function()
	Split()
	Req("al3_war_peace")
	H.ok(H.hasLine("[TX][CHECK] AL3-G.S3LIVE.before INFO T1 G before: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.ok(H.hasLine("[TX][SPIKE][AL3] G P0 declares war on P1 at war=true"))
	H.ok(H.hasLine("[TX][CHECK] AL3-G.S3LIVE.war INFO T1 G war: state now target->keeper=DIPLO_STATE_WAR"))
	H.len(H.lines("WARNING peace failed"), 0)
	H.ok(H.hasLine("[TX][SPIKE][AL3] G PROBE AL3 peace <table>:MakePeaceWith(1,true) exists=function ok=true"))
	H.eq(#FAKE_DEV.peace, 1, "the first peace call ended the war")
	H.ok(H.hasLine("[TX][CHECK] AL3-G.S3LIVE.after PASS T1 G after: state now target->keeper=DIPLO_STATE_UNFRIENDLY " ..
		"keeper->target=DIPLO_STATE_UNFRIENDLY: no longer ALLIED"))
	H.deq(H.prop("TX_DEV_ARM").al, { n = "3", turn = 1 })
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] AL3-G.S3LIVE.turn PASS T2 G turn: state now target->keeper=DIPLO_STATE_UNFRIENDLY"))
	H.ok(H.hasLine("turn 2, AL3 pressed on turn 1"))
	NoErrors()
end)

test("AL3 peace fails: still at war is INFO with a WARNING, never PASS", function()
	Split()
	for pid = 0, 1 do
		rawset(FAKE.players[pid].diplomacy, "MakePeaceWith", function() end)
	end
	Req("al3_war_peace")
	H.ok(H.hasLine("[TX][SPIKE][AL3] G peace: at war now=yes"))
	H.ok(H.hasLine("[TX][SPIKE][AL3] G WARNING peace failed or unreadable: P0 and P1 may still be at war. Load TX3_split."))
	H.ok(H.hasLine("[TX][CHECK] AL3-G.S3LIVE.after INFO T1 G after: state now target->keeper=DIPLO_STATE_WAR " ..
		"keeper->target=DIPLO_STATE_WAR: at war (no exit until peace)"))
	H.len(H.lines("AL3-G.S3LIVE.after PASS"), 0)
	NoErrors()
end)

test("AL4 alliance deal: civics, every step a probe, the UI hash, HasAllied after", function()
	Split()
	Req("al4_alliance", { hash = 4242 })
	H.ok(H.hasLine("[TX][SPIKE][AL4] G civic P0 CIVIC_CIVIL_SERVICE ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL4] G PROBE AL4 deal DealAgreementTypes=ALLIANCE exists=number ok=true ret=(9)"))
	H.ok(H.hasLine("[TX][SPIKE][AL4] G PROBE AL4 deal <table>:SetValueType(4242) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL4] G PROBE AL4 deal <table>:SetDuration(1) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL4] G PROBE AL4 deal DealManager.EnactWorkingDeal(0,1) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL4] G alliance deal P0->P1 (ALLIANCE_RESEARCH, 1 turn) enact ok=true hash=4242 HasAllied k->t=yes t->k=yes"))
	H.ok(H.hasLine("[TX][CHECK] AL4-G.S3LIVE.after INFO T1 G after: state now target->keeper=DIPLO_STATE_ALLIED"))
	-- no UI hash: gameplay probes DB.MakeHash itself
	H.clean()
	Req("al4_alliance")
	H.ok(H.hasLine("[TX][SPIKE][AL4] G PROBE AL4 deal DB.MakeHash(\"ALLIANCE_RESEARCH\") exists=function ok=true"))
	NoErrors()
end)

test("AL5 SetHasAllied toggle: gated calls run from AL5, false is a no-op in the fake", function()
	Split()
	Req("al5_allied_toggle")
	H.ok(H.hasLine("[TX][SPIKE][AL5] G PROBE AL5 allied <table>:SetHasAllied(1,true) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL5] G PROBE AL5 allied <table>:SetHasAllied(0,false) exists=function ok=true"))
	H.ok(H.hasLine("[TX][CHECK] AL5-G.S3LIVE.set INFO"))
	local l = H.lines("[TX][CHECK] AL5-G.S3LIVE.after INFO")[1]
	H.ok(l ~= nil and string.find(l, "HasAllied k->t=yes t->k=yes", 1, true), l)
	H.len(H.lines("REFUSED"), 0)
	NoErrors()
end)

test("AL1 friendship off and AL7 vision off/on (gated, global)", function()
	Split()
	Req("al1_friend_off")
	H.ok(H.hasLine("[TX][SPIKE][AL1] G friendship off P0<->P1 ok=true now k->t=no t->k=no"))
	H.ok(H.hasLine("[TX][CHECK] AL1-G.S3LIVE.after INFO T1 G after: state now target->keeper=DIPLO_STATE_ALLIED"))
	Req("al7_vis", { on = 0 })
	H.ok(H.hasLine("[TX][SPIKE][AL7] G SetAlliesShareVisFlag(false) ok=true (global: every team)"))
	H.ok(H.hasLine("[TX][CHECK] AL7off-G.S3LIVE.after"))
	Req("al7_vis", { on = 1 })
	H.ok(H.hasLine("[TX][CHECK] AL7on-G.S3LIVE.after"))
	H.deq(FAKE_DEV.visFlag, { false, true })
	H.eq(H.prop("TX_DEV_ARM").al.n, "7on")
	NoErrors()
end)

test("AL2 existence only: no diplomacy call, AL2-G line", function()
	Split()
	local before = #FAKE_DEV.peace
	Req("al2_exist")
	local l = H.lines("[TX][CHECK] AL2-G.S3LIVE INFO T1 G exist:")[1]
	H.notnil(l)
	H.ok(string.find(l, "Diplomacy:SetHasAllied=function Diplomacy:MakePeaceWith=function", 1, true), l)
	H.ok(string.find(l, "Diplomacy:SetPermanentAlliance=nil", 1, true), l)
	H.ok(string.find(l, "GameDiplomacy:SetAlliesShareVisFlag=function DealAgreementTypes.ALLIANCE=9 DB.MakeHash=function", 1, true), l)
	H.eq(#FAKE_DEV.peace, before)
	H.len(FAKE_DEV.visFlag, 0)
	H.isnil(H.prop("TX_DEV_ARM").al, "existence checks are no AL step")
	NoErrors()
end)

test("AL3b: DeclareWarOn third arg false (a probe), then peace; AL3 keeps true", function()
	Split()
	Req("al3b_war_peace")
	H.ok(H.hasLine("[TX][CHECK] AL3b-G.S3LIVE.before INFO T1 G before: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.ok(H.hasLine("[TX][SPIKE][AL3b] G PROBE AL3b war <table>:DeclareWarOn(1,1,false) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL3b] G P0 declares war on P1 (DeclareWarOn third arg false) at war=true"))
	H.ok(H.hasLine("[TX][CHECK] AL3b-G.S3LIVE.war INFO T1 G war: state now target->keeper=DIPLO_STATE_WAR"))
	H.ok(H.hasLine("[TX][SPIKE][AL3b] G PROBE AL3b peace <table>:MakePeaceWith(1,true) exists=function ok=true"))
	H.ok(H.hasLine("[TX][CHECK] AL3b-G.S3LIVE.after PASS T1 G after: state now target->keeper=DIPLO_STATE_UNFRIENDLY"))
	H.deq(FAKE_DEV.dows, { { a = 0, b = 1, warType = 1, flag = false } })
	H.deq(H.prop("TX_DEV_ARM").al, { n = "3b", turn = 1 })
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] AL3b-G.S3LIVE.turn PASS T2 G turn:"))
	H.ok(H.hasLine("turn 2, AL3b pressed on turn 1"))
	NoErrors()
end)

test("AL3 keeps the verified V6 DeclareWarOn shape (third arg true)", function()
	Split()
	Req("al3_war_peace")
	H.deq(FAKE_DEV.dows, { { a = 0, b = 1, warType = 1, flag = true } })
	NoErrors()
end)

-- ---------------------------------------------------------------------------
-- VIS steps and the K full kick (TX_Dev 0.0.1.3)
-- ---------------------------------------------------------------------------
test("VIS: refused at BASE; AL0 logs VIS0-G (always INFO)", function()
	World()
	FAKE_DEV.LinkVision(0, 1)
	Req("v5_marker", { target = 1 })
	Arm()
	for n = 1, 3 do
		Req("vis_step", { n = n })
		H.ok(H.hasLine("[TX][SPIKE][VIS" .. n .. "] G refused: arm BASE and split the team first (or load TX3_split)"))
	end
	H.len(FAKE_DEV.visCalls, 0)
	H.isnil(H.prop("TX_DEV_ARM").vis)
	Req("al_read")
	H.ok(H.hasLine("[TX][CHECK] VIS0-G.BASE INFO T1 G marker keeper sees=yes target sees=yes"))
	Req("vis_step", { n = 7 })
	H.ok(H.hasLine("[TX][SPIKE][VIS] G unknown VIS step 7"))
	NoErrors()
end)

test("VIS1 cuts the leftover vision: before INFO shared, after PASS, next turn PASS", function()
	Split()
	Req("vis_step", { n = 1 })
	local before = H.lines("[TX][CHECK] VIS1-G.S3LIVE.before INFO T1 G before: marker keeper sees=yes target sees=yes")[1]
	H.notnil(before, H.Ser(H.lines("VIS1")))
	H.ok(string.find(before, "city keeper sees=yes target sees=yes nearest target asset=9", 1, true), before)
	H.ok(string.find(before, ": vision still shared (target sees the keeper's marker and city)", 1, true), before)
	H.ok(string.find(before, "city at 3,12", 1, true), before)
	H.ok(string.find(before, "G IsVisible marker k=true t=true city k=true t=true", 1, true), before)
	H.ok(string.find(before, "GetVisibilityOn k->t=2 t->k=2; sources k->t=SOURCE_ALLY t->k=SOURCE_ALLY", 1, true), before)
	H.ok(H.hasLine("[TX][SPIKE][VIS1] G PROBE VIS1 remove PlayersVisibility[0]:RemoveOutgoingVisibility(1) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][VIS1] G PROBE VIS1 remove PlayersVisibility[1]:RemoveOutgoingVisibility(0) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][VIS1] G RemoveOutgoingVisibility P0->P1 and P1->P0 ok=true"))
	H.ok(H.hasLine("[TX][CHECK] VIS1-G.S3LIVE.after PASS T1 G after: marker keeper sees=yes target sees=no"))
	H.deq(FAKE_DEV.visCalls, { "RemoveOutgoingVisibility 0,1", "RemoveOutgoingVisibility 1,0" })
	H.deq(H.prop("TX_DEV_ARM").vis, { n = 1, turn = 1 })
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] VIS1-G.S3LIVE.turn PASS T2 G turn: marker"))
	H.ok(H.hasLine("turn 2, VIS1 pressed on turn 1"))
	H.len(H.lines("REFUSED"), 0)
	NoErrors()
end)

test("VIS2 and VIS3: the calls run (gated), no map change in the fake; VIS3 logs GetVisibilityOn", function()
	Split()
	Req("vis_step", { n = 2 })
	H.deq(FAKE_DEV.visCalls, { "RecheckVisibilityOnAll 0", "RecheckVisibilityOn 0,1", "RecheckVisibilityOnAll 1",
		"RecheckVisibilityOn 1,0" })
	H.ok(H.hasLine("[TX][SPIKE][VIS2] G PROBE VIS2 recheck <table>:RecheckVisibilityOnAll() exists=function ok=true"))
	H.ok(H.hasLine("[TX][CHECK] VIS2-G.S3LIVE.after INFO T1 G after: marker keeper sees=yes target sees=yes"))
	Req("vis_step", { n = 3 })
	H.ok(H.hasLine("[TX][SPIKE][VIS3] G PROBE VIS3 set <table>:SetVisibilityOn(1,0) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][VIS3] G GetVisibilityOn before k->t=2 t->k=2, after k->t=0 t->k=0"))
	local after = H.lines("[TX][CHECK] VIS3-G.S3LIVE.after INFO")[1]
	H.ok(after ~= nil and string.find(after, "GetVisibilityOn k->t=0 t->k=0", 1, true), after)
	H.eq(H.prop("TX_DEV_ARM").vis.n, 3)
	H.len(H.lines("REFUSED"), 0)
	NoErrors()
end)

local function KWorld(model)
	World()
	FAKE.teamModel = model or "live"
	FAKE_DEV.AddCity(0, 3, 12)
	FAKE_DEV.LinkVision(0, 1)
	FAKE.PairSet(FAKE.diplo.met, 0, 1, true)   -- ex-teammates have met (Session 2 V7)
	FAKE.PairSet(FAKE.diplo.met, 1, 0, true)
	Req("v5_marker", { target = 1 })
end

test("K full kick: refused unarmed and after the change; from BASE: change, VIS1 (no war), save line", function()
	KWorld()
	Req("k_kick", { path = "S3", target = 1, team = 2 })
	H.ok(H.hasLine("[TX][SPIKE][K] G refused: K starts at BASE (load TX3_base, or press Arm BASE first)"))
	Arm()
	FAKE_DEV.SetState(0, 1, ALLIED)
	FAKE_DEV.SetState(1, 0, ALLIED)
	H.friend(0, 1, true)
	Req("k_kick", { path = "S3", target = 2, team = 2 })
	H.ok(H.hasLine("[TX][SPIKE][K] G refused: target P2 is not the armed target P1"))
	H.eq(H.prop("TX_DEV_ARM").phase, "BASE")
	H.clean()
	PlayerConfigurations[1]:SetTeam(2)   -- the UI writes the config team first
	Req("k_kick", { path = "S3", target = 1, team = 2 })
	H.ok(H.hasLine("[TX][CHECK] V1-G.S3LIVE PASS"))
	H.ok(H.hasLine("[TX][SPIKE][K] G full kick of P1 (config team 0 -> 2): gameplay reads target team 2, keeper team 0"))
	H.ok(H.hasLine("[TX][CHECK] K-G.S3LIVE.before INFO T1 G before: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.ok(H.hasLine("[TX][CHECK] Kvis-G.S3LIVE.before INFO T1 G before: marker keeper sees=yes target sees=yes"))
	H.ok(H.hasLine("[TX][SPIKE][K] G PROBE K vis PlayersVisibility[0]:RemoveOutgoingVisibility(1) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][K] G RemoveOutgoingVisibility P0->P1 and P1->P0 ok=true"))
	H.ok(H.hasLine("[TX][CHECK] K-G.S3LIVE.after INFO T1 G after: state now target->keeper=DIPLO_STATE_ALLIED"),
		"no war: the leftover ALLIED state stays")
	H.ok(H.hasLine("[TX][CHECK] Kvis-G.S3LIVE.after PASS T1 G after: marker keeper sees=yes target sees=no"))
	local last = H.lines()[#H.lines()]
	H.ok(string.find(last, "[TX][SPIKE][K] G done. NOW save the game as TX3_kick and load TX3_kick", 1, true), last)
	H.len(FAKE_DEV.dows, 0, "no war in K")
	H.len(FAKE_DEV.peace, 0)
	H.len(H.lines("[TX][CHECK] K-G.S3LIVE.war"), 0)
	local a = H.prop("TX_DEV_ARM")
	H.eq(a.path, "S3")
	H.eq(a.phase, "LIVE")
	H.eq(a.newTeam, 2)
	H.deq(a.k, { n = 1, turn = 1 })
	H.isnil(a.al)
	H.len(H.lines("REFUSED"), 0)
	Req("k_kick", { path = "S3", target = 1, team = 2 })
	H.ok(H.hasLine("[TX][SPIKE][K] G refused: K starts at BASE"), "a second K is refused")
	-- save TX3_kick and load it, V6, end turn: separate teams, not at war, no shared vision (still ALLIED)
	H.reload(G, GLOBALS, { applyConfigTeams = true })
	Req("loaded")
	H.ok(H.hasLine("[TX][CHECK] V1-G.S3RELOAD1 PASS"))
	Req("v6_war")
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] V6-G.S3RELOAD1 PASS T2 G other at war with keeper=yes, with target=no"))
	H.ok(H.hasLine("[TX][CHECK] K-G.S3RELOAD1.turn INFO T2 G turn: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.ok(H.hasLine("[TX][CHECK] Kvis-G.S3RELOAD1.turn PASS T2 G turn:"))
	H.ok(H.hasLine("turn 2, K pressed on turn 1"))
	NoErrors()
end)

test("K full kick: gameplay still reads one team (config model): vision step skipped", function()
	KWorld("config")
	Arm()
	FAKE_DEV.SetState(0, 1, ALLIED)
	FAKE_DEV.SetState(1, 0, ALLIED)
	PlayerConfigurations[1]:SetTeam(2)
	Req("k_kick", { path = "S3", target = 1, team = 2 })
	H.ok(H.hasLine("[TX][SPIKE][K] G WARNING gameplay still reads one team: vision step skipped."))
	H.len(FAKE_DEV.visCalls, 0)
	H.ok(H.hasLine("[TX][CHECK] K-G.S3LIVE.after INFO T1 G after: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.ok(H.hasLine("[TX][SPIKE][K] G done. NOW save the game as TX3_kick"))
	NoErrors()
end)

-- ---------------------------------------------------------------------------
-- Clean-break probes (AL8, AL9) and the alliance-expiry long run (AL4L)
-- ---------------------------------------------------------------------------
test("AL8 unmeet: gated SetHasMet(false) both ways, HasMet logged, turn read", function()
	Split()
	Req("al8_unmeet")
	H.ok(H.hasLine("[TX][CHECK] AL8-G.S3LIVE.before INFO T1 G before: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.ok(H.hasLine("[TX][SPIKE][AL8] G PROBE AL8 unmeet <table>:SetHasMet(1,false) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL8] G PROBE AL8 unmeet <table>:SetHasMet(0,false) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL8] G SetHasMet(false) P0<->P1: met k->t=no t->k=no"))
	local l = H.lines("[TX][CHECK] AL8-G.S3LIVE.after INFO")[1]
	H.ok(l ~= nil and string.find(l, "met k->t=no t->k=no", 1, true), l)
	H.deq(H.prop("TX_DEV_ARM").al, { n = "8", turn = 1 })
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] AL8-G.S3LIVE.turn INFO T2 G turn:"))
	H.len(H.lines("REFUSED"), 0)
	NoErrors()
end)

test("AL8 / AL9: a non-ALLIED state while unmet is INCONCLUSIVE, never PASS; met again it decides", function()
	Split()
	FAKE_DEV.SetState(0, 1, "DIPLO_STATE_NEUTRAL")   -- what the engine might report for an unmet pair
	FAKE_DEV.SetState(1, 0, "DIPLO_STATE_NEUTRAL")
	Req("al8_unmeet")
	H.ok(H.hasLine("[TX][CHECK] AL8-G.S3LIVE.before PASS"))
	H.ok(H.hasLine("[TX][CHECK] AL8-G.S3LIVE.after INFO T1 G after: INCONCLUSIVE: not met (k->t=no t->k=no), no verdict;"))
	H.len(H.lines("AL8-G.S3LIVE.after PASS"), 0)
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] AL8-G.S3LIVE.turn INFO T2 G turn: INCONCLUSIVE: not met"))
	H.clean()
	Req("al9_remeet")
	H.ok(H.hasLine("[TX][CHECK] AL9-G.S3LIVE.unmet INFO T2 G unmet: INCONCLUSIVE: not met"))
	H.ok(H.hasLine("[TX][CHECK] AL9-G.S3LIVE.after PASS T2 G after: state now target->keeper=DIPLO_STATE_NEUTRAL"))
	NoErrors()
end)

test("AL9 unmeet then meet: unmet stage, then met again (MeetPair)", function()
	Split()
	Req("al9_remeet")
	H.ok(H.hasLine("[TX][SPIKE][AL9] G SetHasMet(false) P0<->P1: met k->t=no t->k=no"))
	H.ok(H.hasLine("[TX][CHECK] AL9-G.S3LIVE.unmet INFO"))
	H.ok(H.hasLine("[TX][SPIKE][AL9] G SetHasMet P0<->P1 again: met k->t=yes t->k=yes"))
	local l = H.lines("[TX][CHECK] AL9-G.S3LIVE.after INFO")[1]
	H.ok(l ~= nil and string.find(l, "met k->t=yes t->k=yes", 1, true), l)
	H.eq(H.prop("TX_DEV_ARM").al.n, "9")
	NoErrors()
end)

test("AL8 / AL9 refused at BASE", function()
	World()
	Players[0]:GetDiplomacy():SetHasMet(1)
	Players[1]:GetDiplomacy():SetHasMet(0)
	Arm()
	Req("al8_unmeet")
	Req("al9_remeet")
	H.eq(#H.lines("refused: arm BASE and split the team first (or load TX3_split)"), 2)
	H.ok(Players[0]:GetDiplomacy():HasMet(1), "no unmeet at BASE")
	NoErrors()
end)

test("AL4L: the alliance deal, then friendship off; turn reads every turn start", function()
	Split()
	Req("al4l_alliance_long", { hash = 4242 })
	H.ok(H.hasLine("[TX][CHECK] AL4L-G.S3LIVE.before INFO"))
	H.ok(H.hasLine("[TX][SPIKE][AL4L] G civic P0 CIVIC_CIVIL_SERVICE ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL4L] G PROBE AL4L deal <table>:SetDuration(1) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL4L] G alliance deal P0->P1 (ALLIANCE_RESEARCH, 1 turn) enact ok=true hash=4242 HasAllied k->t=yes t->k=yes"))
	H.ok(H.hasLine("[TX][CHECK] AL4L-G.S3LIVE.deal INFO"))
	H.ok(H.hasLine("[TX][SPIKE][AL4L] G friendship off P0<->P1 ok=true now k->t=no t->k=no"))
	local l = H.lines("[TX][CHECK] AL4L-G.S3LIVE.after INFO")[1]
	H.ok(l ~= nil and string.find(l, "HasAllied k->t=yes t->k=yes friends k->t=no t->k=no", 1, true), l)
	H.deq(H.prop("TX_DEV_ARM").al, { n = "4L", turn = 1 })
	H.endTurn()
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] AL4L-G.S3LIVE.turn INFO T2 G turn:"))
	H.ok(H.hasLine("[TX][CHECK] AL4L-G.S3LIVE.turn INFO T3 G turn:"))
	-- the alliance ends (modelled): the next turn read gives the verdict
	FAKE.PairSet(FAKE.diplo.allied, 0, 1, false)
	FAKE.PairSet(FAKE.diplo.allied, 1, 0, false)
	FAKE_DEV.SetState(0, 1, "DIPLO_STATE_FRIENDLY")
	FAKE_DEV.SetState(1, 0, "DIPLO_STATE_FRIENDLY")
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] AL4L-G.S3LIVE.turn PASS T4 G turn: state now target->keeper=DIPLO_STATE_FRIENDLY"))
	NoErrors()
end)

-- ---------------------------------------------------------------------------
-- TX_Dev 0.0.1.5: AL3T, the HARD kick's war step (target declares, then peace)
-- ---------------------------------------------------------------------------
-- Session 3c b): P0, P1, P2 human on team 0, P3 AI on team 1. Target P2 split to
-- team 2 (live), leftover ALLIED both ways with P0 and P1, all met.
local function Split3(opts)
	opts = opts or {}
	H.world{
		teams = { [0] = 0, [1] = 0, [2] = 0, [3] = 1 },
		players = {
			{ id = 0, human = true }, { id = 1, human = true, alive = opts.p1Alive ~= false }, { id = 2, human = true }, { id = 3 },
			{ id = 62, kind = "FREE_CITIES" }, { id = 63, kind = "BARBARIAN" },
		},
	}
	FAKE.dofile("tests/offline/lib/fake_devworld.lua")
	FAKE_DEV.Install()
	FAKE_DEV.AddCity(0, 3, 3)
	FAKE_DEV.AddCity(1, 6, 3)
	FAKE_DEV.AddCity(2, 18, 10)
	FAKE_DEV.AddCity(3, 20, 4)
	H.load(G)
	FAKE.teamModel = "live"
	if opts.teamWars ~= nil then
		FAKE.teamWars = opts.teamWars
	end
	local p = { target = 2, team = 2, mp = 0, hotseat = 1 }
	for i = 0, 3 do p["cfg_" .. i] = PlayerConfigurations[i]:GetTeam() end
	Req("arm", p)
	PlayerConfigurations[2]:SetTeam(2)
	Req("changed", { path = "S3", target = 2, team = 2 })
	for _, k in ipairs({ 0, 1 }) do
		FAKE_DEV.SetState(2, k, ALLIED)
		FAKE_DEV.SetState(k, 2, ALLIED)
		H.meet(2, k)
	end
	H.meet(0, 1)
	H.clean()
end

test("AL3T refused unarmed, at BASE and without a keeper; nothing declared", function()
	World()
	Req("al3t_war_peace")
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G refused: arm BASE and split the team first (or load TX3_split)"))
	Arm()
	Req("al3t_war_peace")
	H.eq(#H.lines("[TX][SPIKE][AL3T] G refused: arm BASE and split the team first"), 2)
	H.len(FAKE_DEV.dows, 0)
	H.isnil(H.prop("TX_DEV_ARM").al)
	-- split, then the only teammate dies: no keeper left
	S3Change(2)
	FAKE.players[0].alive = false
	Req("al3t_war_peace")
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G refused: the target P1 has no living teammate left from its original team (arm record)"))
	H.len(FAKE_DEV.dows, 0)
	H.isnil(H.prop("TX_DEV_ARM").al)
	NoErrors()
end)

test("AL3T, 2-person team: P1 declares on P0 (third arg true), peace, PASS, grievances on the target, turn read", function()
	Split()
	Req("al3t_war_peace")
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G target P1 declares war on P0, then makes peace"))
	H.ok(H.hasLine("[TX][CHECK] AL3T-G.S3LIVE.before INFO T1 G before: 0/1 pairs clear (not ALLIED, not at war); P0: state now " ..
		"target->keeper=DIPLO_STATE_ALLIED keeper->target=DIPLO_STATE_ALLIED: still ALLIED; target P1 keepers P0;"))
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G P1 declares war on P0 (DeclareWarOn(0,FORMAL_WAR,true)) ok=true at war=yes"))
	H.deq(FAKE_DEV.dows, { { a = 1, b = 0, warType = 1, flag = true } })
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G war matrix after P0: P0-P1=yes"))
	H.ok(H.hasLine("[TX][CHECK] AL3T-G.S3LIVE.war INFO T1 G war: 0/1 pairs clear"))
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G PROBE AL3T peace <table>:MakePeaceWith(0,true) exists=function ok=true"))
	H.deq(FAKE_DEV.peace, { { a = 1, b = 0 } }, "the target made peace")
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G peace P1 with P0: at war now=no; war matrix P0-P1=no"))
	H.len(H.lines("WARNING peace failed"), 0)
	local l = H.lines("[TX][CHECK] AL3T-G.S3LIVE.after PASS T1 G after: 1/1 pairs clear (not ALLIED, not at war); P0: state now " ..
		"target->keeper=DIPLO_STATE_UNFRIENDLY keeper->target=DIPLO_STATE_UNFRIENDLY: no longer ALLIED")[1]
	H.notnil(l, H.Ser(H.lines("AL3T-G")))
	H.ok(string.find(l, "P1<->P0 G state(target view)=DIPLO_STATE_UNFRIENDLY (keeper view)=DIPLO_STATE_UNFRIENDLY war=no", 1, true), l)
	H.ok(string.find(l, "; war matrix P0-P1=no", 1, true), l)
	-- the fake gives the defender 100 grievances against the declarer: the keeper holds them
	H.eq(FAKE_DEV.grievances["0,1"], 100)
	H.isnil(FAKE_DEV.grievances["1,0"])
	H.deq(H.prop("TX_DEV_ARM").al, { n = "3T", turn = 1 })
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] AL3T-G.S3LIVE.turn PASS T2 G turn: 1/1 pairs clear"))
	H.ok(H.hasLine("turn 2, AL3T pressed on turn 1"))
	H.len(H.lines("[TX][CHECK] AL3T-G.S3LIVE.turn INFO"), 0)
	NoErrors()
end)

test("AL3T, 2 keepers, separate wars: the target declares on and makes peace with each, PASS for both pairs", function()
	Split3({ teamWars = false })
	Req("al3t_war_peace")
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G target P2 declares war on P0,P1, then makes peace"))
	H.deq(FAKE_DEV.dows, { { a = 2, b = 0, warType = 1, flag = true }, { a = 2, b = 1, warType = 1, flag = true } })
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G war matrix after P0: P0-P1=no P0-P2=yes P1-P2=no"))
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G war matrix after P1: P0-P1=no P0-P2=yes P1-P2=yes"))
	local w = H.lines("[TX][CHECK] AL3T-G.S3LIVE.war INFO T1 G war: 0/2 pairs clear")[1]
	H.notnil(w, H.Ser(H.lines("AL3T-G")))
	H.ok(string.find(w, "P0: state now target->keeper=DIPLO_STATE_WAR keeper->target=DIPLO_STATE_WAR: at war", 1, true), w)
	H.ok(string.find(w, "target P2 keepers P0,P1", 1, true), w)
	H.deq(FAKE_DEV.peace, { { a = 2, b = 0 }, { a = 2, b = 1 } }, "peace with each keeper, by the target")
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G peace P2 with P0: at war now=no"))
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G peace P2 with P1: at war now=no"))
	local l = H.lines("[TX][CHECK] AL3T-G.S3LIVE.after PASS T1 G after: 2/2 pairs clear (not ALLIED, not at war)")[1]
	H.notnil(l, H.Ser(H.lines("AL3T-G")))
	H.ok(string.find(l, "P0: state now target->keeper=DIPLO_STATE_UNFRIENDLY keeper->target=DIPLO_STATE_UNFRIENDLY: no longer ALLIED | " ..
		"P1: state now target->keeper=DIPLO_STATE_UNFRIENDLY", 1, true), l)
	H.ok(string.find(l, "P2<->P0 G state(target view)=DIPLO_STATE_UNFRIENDLY", 1, true), l)
	H.ok(string.find(l, "P2<->P1 G state(target view)=DIPLO_STATE_UNFRIENDLY", 1, true), l)
	H.eq(FAKE_DEV.grievances["0,2"], 100)
	H.eq(FAKE_DEV.grievances["1,2"], 100)
	H.eq(PlayerConfigurations[0]:GetTeam(), PlayerConfigurations[1]:GetTeam(), "the keepers stay one team")
	H.endTurn()
	H.ok(H.hasLine("[TX][CHECK] AL3T-G.S3LIVE.turn PASS T2 G turn: 2/2 pairs clear"))
	NoErrors()
end)

test("AL3T, 2 keepers, team war (fake model): one declaration, peace with P0 only, P1 left ALLIED is INFO", function()
	Split3({ teamWars = true })
	Req("al3t_war_peace")
	H.deq(FAKE_DEV.dows, { { a = 2, b = 0, warType = 1, flag = true } })
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G P2 already at war with P1 (a war on a teammate?): no declaration"))
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G war matrix after P1: P0-P1=no P0-P2=yes P1-P2=yes"))
	H.deq(FAKE_DEV.peace, { { a = 2, b = 0 } })
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G P2 not at war with P1: no peace call"))
	local l = H.lines("[TX][CHECK] AL3T-G.S3LIVE.after INFO T1 G after: 1/2 pairs clear")[1]
	H.notnil(l, H.Ser(H.lines("AL3T-G")))
	H.ok(string.find(l, "P1: state now target->keeper=DIPLO_STATE_ALLIED keeper->target=DIPLO_STATE_ALLIED: still ALLIED", 1, true), l)
	H.len(H.lines("AL3T-G.S3LIVE.after PASS"), 0)
	NoErrors()
end)

test("AL3T: a dead keeper is skipped; peace that fails is INFO with a WARNING", function()
	Split3({ teamWars = false, p1Alive = false })
	for pid = 0, 2 do
		rawset(FAKE.players[pid].diplomacy, "MakePeaceWith", function() end)
	end
	Req("al3t_war_peace")
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G target P2 declares war on P0, then makes peace"))
	H.deq(FAKE_DEV.dows, { { a = 2, b = 0, warType = 1, flag = true } })
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G PROBE AL3T peace <table>:MakePeaceWith(0) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G PROBE AL3T peace <table>:MakePeaceWith(2,true) exists=function ok=true"))
	H.ok(H.hasLine("[TX][SPIKE][AL3T] G WARNING peace failed or unreadable: P2 may still be at war with P0."))
	H.ok(H.hasLine("[TX][CHECK] AL3T-G.S3LIVE.after INFO T1 G after: 0/1 pairs clear"))
	H.len(H.lines("AL3T-G.S3LIVE.after PASS"), 0)
	NoErrors()
end)
