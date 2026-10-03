-- Tests of TX_Dev/UI/TX_Dev_Panel.lua (PLAN I.10): the real panel in a fake
-- UI context, with the real gameplay script answering its requests.

local G = "TX_Dev/Scripts/TX_Dev_Gameplay.lua"
local PANEL = "TX_Dev/UI/TX_Dev_Panel.lua"
local ENV = nil

local function Setup(opts)
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
	FAKE_UI.Enable()
	FAKE.localPlayer = opts.localPlayer or 0
	FAKE_UI.AsGameplay(function() FAKE.dofile(G) end)
	ENV = FAKE_UI.LoadContext(PANEL)
	H.markBody()
end

local function Click(label)
	local b = FAKE_UI.FindButton(label)
	H.notnil(b, "button " .. label)
	b:Click()
end

local function Frames(n)
	for _ = 1, n or 1 do FAKE_UI.Update(ENV, 0.3) end
end

local function SetTeamEdit(v)
	ENV.Controls.TeamEdit:SetText(tostring(v))
end

local function LastRequest(cmd)
	for i = #FAKE_UI.requests, 1, -1 do
		local r = FAKE_UI.requests[i]
		if cmd == nil or r.params.cmd == cmd then return r end
	end
	return nil
end

local function ArmNow()
	SetTeamEdit(2)
	Click("Arm BASE + snapshot")
	Frames(1)
end

local function EndTurn()
	FAKE_UI.AsGameplay(H.endTurn)
end

local function NoErrors()
	for _, l in ipairs(H.lines()) do
		H.ok(not string.find(l, "] G ERROR ", 1, true) and not string.find(l, "] UI ERROR ", 1, true), "error line: " .. l)
	end
	H.clean()
end

local LABELS = {
	"S1 Dump (UI)", "S1 Dump (G)", "S1 Team map", "S2 Probe setters (no calls)", "S2 CALL selected setter (!)",
	"S3 Set Target's team", "S3 Set MY team", "S3 Undo (Target)", "Arm BASE + snapshot", "Snapshot now",
	"V4 Boost (keeper)", "V5 Marker (keeper)", "V6 Other declares war on keeper", "V9 Deals target-other",
	"V10 Friends target-other", "V3 Domination: keeper", "V3 Domination: target", "V8 War allowed?",
	"Diplo matrix", "Clear spike state", "Q Setup Session 2", "AL0 Read state (UI+G)", "AL1 Friendship off (!)",
	"AL2 Probe APIs (no calls)", "AL3 War then peace (!)", "AL4 Alliance deal 1 turn (!)", "AL5 SetHasAllied toggle (!)",
	"AL6 War/denounce valid? (UI)", "AL7 Vision OFF (all teams!)", "AL7 Vision ON (restore)",
	"AL3b War(false) then peace (!)", "VIS1 Remove outgoing vis (!)", "VIS2 Recheck visibility (!)",
	"VIS3 SetVisibilityOn 0 (!)", "K Full kick (S3+VIS1) (!)", "AL4L Alliance, friends off (!)",
	"AL8 Unmeet both ways (!)", "AL9 Unmeet then meet (!)",
}

test("init: context shown, Main hidden, hotkey and Esc, every button", function()
	Setup()
	H.eq(ENV.ContextPtr:IsHidden(), false, "ContextPtr:SetHide(false) in init")
	H.eq(ENV.Controls.Main:IsHidden(), true)
	H.ok(#H.lines("[TX][SPIKE][INIT] UI TX_Dev 0.0.1.3 loaded (for TX 0.0.1 spike)", true) == 1)
	FAKE_UI.KeyTo(ENV, Keys.D, { ctrl = true, shift = true })
	H.eq(ENV.Controls.Main:IsHidden(), false, "Ctrl+Shift+D opens")
	H.ok(string.find(ENV.Controls.RolesLabel:GetText(), "keeper=P0 target=P1 other=P2", 1, true), ENV.Controls.RolesLabel:GetText())
	FAKE_UI.KeyTo(ENV, Keys.D, { ctrl = true })
	H.eq(ENV.Controls.Main:IsHidden(), false, "Ctrl+D alone does nothing")
	FAKE_UI.KeyTo(ENV, Keys.VK_ESCAPE)
	H.eq(ENV.Controls.Main:IsHidden(), true, "Esc closes")
	for _, l in ipairs(LABELS) do
		H.notnil(FAKE_UI.FindButton(l), "button " .. l)
	end
	Events.LoadGameViewStateDone()
	H.ok(H.hasLine("[TX][SPIKE][INIT] UI launch bar button ok=true"))
	NoErrors()
end)

test("S3 Set Target's team: config write, broadcast, S3-UI PASS, changed reaches G", function()
	Setup()
	SetTeamEdit(2)
	Click("S3 Set Target's team")
	H.deq(FAKE.teamSets[1], { pid = 1, team = 2, turn = 1, context = "UI" })
	H.eq(FAKE.broadcasts[1].pid, 1)
	H.eq(FAKE.broadcasts[1].context, "UI")
	H.ok(H.hasLine("[TX][CHECK] S3-UI.S3LIVE PASS T1 UI config team of P1 0 -> 2 (want 2); live team 0 -> 0"))
	H.ok(H.hasLine("[TX][CHECK] S3LIVE-UI.S3LIVE INFO T1 UI Players[1]:GetTeam() changed live=no"))
	H.ok(H.hasLine("[TX][SPIKE][S3] UI PROBE S3 set PlayerConfigurations[1]:SetTeam(2) exists=function ok=true"))
	local r = LastRequest("changed")
	H.notnil(r)
	H.ok(r.delivered)
	H.eq(r.params.path, "S3")
	H.eq(r.params.target, 1)
	H.ok(H.hasLine("[TX][SPIKE][S4] G changed path=S3 but not armed"))
	NoErrors()
end)

test("S3 Set MY team targets the local player", function()
	Setup({ localPlayer = 2 })
	SetTeamEdit(5)
	Click("S3 Set MY team")
	H.eq(FAKE.teamSets[1].pid, 2)
	H.eq(FAKE.teamSets[1].team, 5)
	H.eq(FAKE.broadcasts[1].pid, 2)
	H.eq(LastRequest("changed").params.target, 2)
	NoErrors()
end)

test("S1 Team map fills New team with the unused ID", function()
	Setup()
	Click("S1 Team map")
	H.eq(ENV.Controls.TeamEdit:GetText(), "2")
	H.ok(H.hasLine("[TX][SPIKE][S1] UI unused team: 2"))
	H.ok(H.hasLine("[TX][SPIKE][S1] UI slot 1 team=0 alive=1 major=1 human=1 cfgTeam=0 cfgHuman=yes slotStatus=MISSING #Teams[0]=2"))
	H.ok(H.hasLine("[TX][CHECK] S1TEAM-UI INFO"))
	H.ok(H.hasLine("[TX][SPIKE][S1] G unused team: 2"), "s1_map sent to gameplay")
	SetTeamEdit(7)
	Click("S1 Team map")
	H.eq(ENV.Controls.TeamEdit:GetText(), "7", "a typed value is kept")
	NoErrors()
end)

test("S1 Dump (UI) logs the targets", function()
	Setup()
	Click("S1 Dump (UI)")
	H.ok(H.hasLine("[TX][SPIKE][S1] UI Players[0] team:"))
	H.ok(H.hasLine("[TX][SPIKE][S1] UI Teams[t] all("))
	H.ok(H.hasLine("[TX][CHECK] S1-UI INFO"))
	NoErrors()
end)

test("S2 list merges UI and G hits and drops never-list names", function()
	Setup()
	Players[1].SetTeam = function(self, t) self.team = t end
	FAKE_UI.deferRequests = true
	Click("S2 Probe setters (no calls)")
	H.ok(H.hasLine("[TX][SPIKE][S2] UI PlayerConfigurations:SetTeam exists in UI"))
	H.eq(FAKE_UI.DeliverRequests(), 1)
	local s2 = Game:GetProperty("TX_DEV_S2")
	s2.hits[#s2.hits + 1] = { ctx = "G", root = "Game", name = "SetWinningTeam", style = ".", args = "player,team" }
	FAKE_UI.AsGameplay(function() Game:SetProperty("TX_DEV_S2", s2) end)
	Frames(1)
	local line = H.lines("[TX][SPIKE][S2] UI setter list (UI+G):")[1]
	H.notnil(line)
	H.ok(string.find(line, "UI:Players[target]:SetTeam(team)", 1, true), line)
	H.ok(string.find(line, "G:Players[target]:SetTeam(team)", 1, true), line)
	H.ok(not string.find(line, "SetWinningTeam", 1, true), line)
	H.ok(string.find(ENV.Controls.SetterLabel:GetText(), "UI Players[target]:SetTeam(team)", 1, true), ENV.Controls.SetterLabel:GetText())
	-- CALL the selected UI setter: one call on the Target with the New team, then "changed" path S2
	FAKE_UI.deferRequests = false
	ArmNow()
	Click("S2 CALL selected setter (!)")
	H.eq(Players[1]:GetTeam(), 2)
	H.ok(H.hasLine("[TX][SPIKE][S2] UI PROBE S2 CALL Players[1]:SetTeam(2) exists=function ok=true"))
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] V1-G.S2LIVE PASS"))
	H.ok(H.hasLine("[TX][CHECK] V1-UI.S2LIVE PASS"))
	NoErrors()
end)

test("S1 Dump (UI) + S2 Probe never offer Network.JoinGame / LeaveGame", function()
	Setup()
	local called = {}
	Network.LeaveGame = function() called[#called + 1] = "LeaveGame" end
	Network.JoinGame = function() called[#called + 1] = "JoinGame" end
	Network.JoinGameByJoinCode = function() called[#called + 1] = "JoinGameByJoinCode" end
	Click("S1 Dump (UI)")
	H.ok(not H.hasLine("[TX][SPIKE][S1] UI Network setters:"), "no Network setters line")
	local s1 = H.lines("[TX][CHECK] S1-UI INFO")[1]
	H.ok(s1 ~= nil and not string.find(s1, "Network", 1, true), s1)
	Click("S2 Probe setters (no calls)")
	Frames(1)
	local line = H.lines("[TX][SPIKE][S2] UI setter list (UI+G):")[1]
	H.notnil(line)
	H.ok(not string.find(line, "Network", 1, true), line)
	H.len(called, 0)
	NoErrors()
end)

test("Arm BASE waits for the stamp, then sends store_ui with u_ values", function()
	Setup()
	FAKE_UI.deferRequests = true
	SetTeamEdit(2)
	Click("Arm BASE + snapshot")
	local armReq = LastRequest("arm")
	H.eq(armReq.params.cfg_1, 0)
	H.eq(armReq.params.hotseat, 1)
	H.eq(armReq.params.mp, 0)
	Frames(2)
	H.isnil(LastRequest("store_ui"), "no answer yet")
	FAKE_UI.DeliverRequests()
	Frames(1)
	H.ok(H.hasLine("[TX][SPIKE][SNAP] UI BASE reason=arm local=P0"))
	H.ok(H.hasLine("[TX][CHECK] V1-UI.BASE INFO"))
	local st = LastRequest("store_ui")
	H.notnil(st)
	H.eq(st.params.armStamp, armReq.params.stamp)
	H.eq(st.params.u_v1cfgT, 0)
	FAKE_UI.DeliverRequests()
	H.ok(H.hasLine("[TX][SPIKE][SNAP] G stored"))
	H.eq(Game:GetProperty("TX_DEV_ARM").ui.v1cfgK, 0)
	NoErrors()
end)

test("WaitFor times out without an answer", function()
	Setup()
	FAKE_UI.deferRequests = true
	ArmNow()
	Frames(20)
	H.ok(H.hasLine("[TX][SPIKE][REQ] UI no answer from gameplay for arm"))
	NoErrors()
end)

test("S3 Undo restores the BASE config team", function()
	Setup()
	ArmNow()
	SetTeamEdit(2)
	Click("S3 Set Target's team")
	H.eq(PlayerConfigurations[1]:GetTeam(), 2)
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] V1-UI.S3LIVE FAIL"), "config model: live team unchanged")
	Click("S3 Undo (Target)")
	H.eq(PlayerConfigurations[1]:GetTeam(), 0)
	H.ok(H.hasLine("[TX][SPIKE][S3] UI S3 undo P1 config team 2 -> 0 (BASE cfg 0)"))
	H.eq(FAKE.broadcasts[#FAKE.broadcasts].pid, 1)
	H.eq(Game:GetProperty("TX_DEV_ARM").phase, "LIVE", "undo leaves the phase")
	NoErrors()
end)

test("OnLoadDone with an armed property sends loaded", function()
	Setup()
	ArmNow()
	Events.LoadGameViewStateDone()
	local r = LastRequest("loaded")
	H.notnil(r)
	H.ok(r.delivered)
	Frames(1)
	H.ok(H.hasLine("[TX][SPIKE][SNAP] UI BASE reason=loaded"))
	NoErrors()
end)

test("Events.TeamVictory: stale Teams[] vs config INCONCLUSIVE, {0} PASS, {0,1} FAIL", function()
	Setup()
	ArmNow()
	SetTeamEdit(2)
	Click("S3 Set Target's team")
	-- config model = the measured live state: config team 2, Teams[0] still {0,1}
	Events.TeamVictory(0, "VICTORY_DEFAULT", 1)
	H.ok(H.hasLine("[TX][CHECK] V3-UI.S3LIVE INFO T1 UI team victory team=0 type=VICTORY_DEFAULT members=0,1; " ..
		"INCONCLUSIVE: Teams[] says FAIL, config teams say PASS"))
	H.ok(H.hasLine("cfg members={0}; Leon: whose name is on the victory screen?"))
	H.team(1, 2)
	Events.TeamVictory(0, "VICTORY_DEFAULT", 2)
	H.ok(H.hasLine("[TX][CHECK] V3-UI.S3LIVE PASS T1 UI team victory team=0 type=VICTORY_DEFAULT members=0; " ..
		"victory members={0} keeper=P0 target=P1: only one of them won; cfg members={0}"))
	H.team(1, 0)
	Events.TeamVictory(0, "VICTORY_DEFAULT", 3)
	H.ok(H.hasLine("[TX][CHECK] V3-UI.S3LIVE FAIL T1 UI team victory team=0 type=VICTORY_DEFAULT members=0,1; " ..
		"victory members={0,1} keeper=P0 target=P1: victory still shared; cfg members={0,1}"))
	NoErrors()
end)

test("reload: no UI turn snapshot before LoadGameViewStateDone, the loaded snapshot has the RELOAD label", function()
	Setup()
	Events.LoadGameViewStateDone()   -- new game
	ArmNow()
	SetTeamEdit(2)
	Click("S3 Set Target's team")
	Frames(1)
	-- save and reload: fresh Lua states for gameplay and the panel
	FAKE_UI.AsGameplay(function() H.reload(G, { "TXD", "TX_Probe" }, { applyConfigTeams = true }) end)
	ENV = FAKE_UI.LoadContext(PANEL)
	H.markBody()
	Events.PlayerTurnActivated(0, false)   -- replayed before the view is ready
	H.len(H.lines("reason=turn"), 0, "no turn snapshot with the old S3LIVE label")
	Events.LoadGameViewStateDone()
	Frames(1)
	H.ok(H.hasLine("[TX][SPIKE][SNAP] UI S3RELOAD1 reason=loaded"))
	H.ok(H.hasLine("[TX][CHECK] V1-UI.S3RELOAD1 PASS"))
	Events.PlayerTurnActivated(0, true)
	H.len(H.lines("reason=turn"), 0, "the loaded snapshot covers this turn")
	H.len(H.lines("UI S3LIVE"), 0)
	EndTurn()
	Events.PlayerTurnActivated(0, true)
	H.ok(H.hasLine("[TX][SPIKE][SNAP] UI S3RELOAD1 reason=turn"))
	NoErrors()
end)

test("checklist flow: setups, arm, live split, turn snapshot verdicts in UI", function()
	Setup()
	Events.LoadGameViewStateDone()   -- new game: the view is ready before any turn snapshot
	FAKE.teamModel = "live"
	Click("V10 Friends target-other")
	Click("V9 Deals target-other")
	Click("V5 Marker (keeper)")
	Click("V4 Boost (keeper)")
	H.ok(H.hasLine("[TX][SPIKE][V4] UI picked TECH_MACHINERY (own 3 UNIT_ARCHER)"))
	H.ok(H.hasLine("[TX][SPIKE][V4] G spawned 3 UNIT_ARCHER for P0"))
	ArmNow()
	H.ok(H.hasLine("[TX][CHECK] V4-UI.BASE INFO T1 UI control, made before the change: TECH_MACHINERY"))
	H.ok(H.hasLine("[TX][CHECK] V5-UI.BASE INFO T1 UI keeper sees=yes target sees=yes"))
	H.ok(H.hasLine("[TX][CHECK] V9-UI.BASE INFO"))
	H.ok(H.hasLine("[TX][CHECK] V10-UI.BASE INFO"))
	SetTeamEdit(2)
	Click("S3 Set Target's team")
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] V1-UI.S3LIVE PASS"))
	H.ok(H.hasLine("[TX][CHECK] V5-UI.S3LIVE PASS"))
	H.ok(H.hasLine("[TX][CHECK] V9-UI.S3LIVE PASS"))
	H.ok(H.hasLine("[TX][CHECK] V10-UI.S3LIVE PASS"))
	Click("V4 Boost (keeper)")
	H.ok(H.hasLine("[TX][SPIKE][V4] UI picked TECH_METAL_CASTING"))
	Click("V6 Other declares war on keeper")
	Click("V8 War allowed?")
	H.ok(H.hasLine("[TX][CHECK] V8-UI.S3LIVE INFO"))
	EndTurn()
	Events.PlayerTurnActivated(0, true)
	H.ok(H.hasLine("[TX][CHECK] V6-G.S3LIVE PASS T2"))
	H.ok(H.hasLine("[TX][CHECK] V4-UI.S3LIVE PASS T2 UI TECH_METAL_CASTING"))
	H.ok(H.hasLine("[TX][SPIKE][SNAP] UI S3LIVE reason=turn"))
	Events.PlayerTurnActivated(0, true)
	H.eq(#H.lines("reason=turn local="), 1, "one UI snapshot per turn per Lua state")
	Click("V3 Domination: keeper")
	H.ok(H.hasLine("[TX][SPIKE][V3] G P0: capital of P2 at 18,10"))
	Click("Snapshot now")
	Frames(1)
	H.ok(H.hasLine("[TX][SPIKE][SNAP] UI S3LIVE reason=button"))
	Click("Diplo matrix")
	Click("Clear spike state")
	H.ok(H.hasLine("[TX][SPIKE][SNAP] G cleared"))
	NoErrors()
end)

test("Session 2 live: Q Setup, split, no reload; V6 and V3 verdicts at the next turn starts (S3LIVE)", function()
	Setup()
	Events.LoadGameViewStateDone()   -- new game
	FAKE.teamModel = "live"
	Click("Q Setup Session 2")
	H.ok(H.hasLine("[TX][SPIKE][V10] G friends=yes/yes"))
	H.ok(H.hasLine("[TX][SPIKE][V9] G ob12=1 ob21=1"))
	H.ok(H.hasLine("[TX][SPIKE][V5] G marker P0 Warrior"))
	EndTurn()
	ArmNow()
	SetTeamEdit(2)
	Click("S3 Set Target's team")
	Frames(1)
	Click("V6 Other declares war on keeper")
	H.ok(H.hasLine("[TX][SPIKE][V6] G P2 declares war on P0 ok=true"))
	EndTurn()
	Events.PlayerTurnActivated(0, true)
	H.ok(H.hasLine("[TX][CHECK] V6-G.S3LIVE PASS T3 G other at war with keeper=yes, with target=no"))
	H.ok(H.hasLine("[TX][SPIKE][SNAP] UI S3LIVE reason=turn"))
	Click("V3 Domination: keeper")
	-- the keeper takes both enemy capitals
	FAKE_DEV.CityAt(18, 10).owner = 0
	FAKE_DEV.CityAt(20, 4).owner = 0
	EndTurn()
	Events.PlayerTurnActivated(0, true)
	H.ok(H.hasLine("[TX][CHECK] V3-UI.S3LIVE PASS T4 UI no victory; attacker holds every enemy original capital=yes " ..
		"and no victory fired (the target is now a rival)"))
	H.ok(H.hasLine("[TX][CHECK] V3-G.S3LIVE INFO T4 G original capitals: P0@3,3 owner=0"))
	H.len(H.lines("RELOAD"), 0, "no reload in this flow")
	NoErrors()
end)

-- The leftover state after a split (Session 2): ALLIED both ways and shared
-- vision (LinkVision) whatever the teams. P0 has a second city far from P1.
-- Ex-teammates have met (Session 2 V7: met=1); the fake world starts unmet.
local function MeetTeammates()
	FAKE.PairSet(FAKE.diplo.met, 0, 1, true)
	FAKE.PairSet(FAKE.diplo.met, 1, 0, true)
end

local function SplitPanel()
	Setup()
	Events.LoadGameViewStateDone()
	FAKE.teamModel = "live"
	FAKE_DEV.AddCity(0, 3, 12)
	FAKE_DEV.LinkVision(0, 1)
	MeetTeammates()
	Click("V5 Marker (keeper)")
	ArmNow()
	SetTeamEdit(2)
	Click("S3 Set Target's team")
	Frames(1)
	FAKE_DEV.SetState(0, 1, "DIPLO_STATE_ALLIED")
	FAKE_DEV.SetState(1, 0, "DIPLO_STATE_ALLIED")
	H.clean()
end

test("AL buttons: refused before the split; AL0 logs AL0-UI and AL0-G", function()
	Setup()
	Click("AL3 War then peace (!)")
	H.ok(H.hasLine("[TX][SPIKE][AL3] UI refused: arm BASE and split the team first"))
	H.isnil(LastRequest("al3_war_peace"), "nothing sent")
	for _, label in ipairs({ "AL3b War(false) then peace (!)", "VIS1 Remove outgoing vis (!)", "VIS2 Recheck visibility (!)",
		"VIS3 SetVisibilityOn 0 (!)" }) do
		Click(label)
	end
	H.ok(H.hasLine("[TX][SPIKE][AL3b] UI refused: arm BASE and split the team first (or load TX3_split)"))
	for n = 1, 3 do
		H.ok(H.hasLine("[TX][SPIKE][VIS" .. n .. "] UI refused: arm BASE and split the team first"))
	end
	H.isnil(LastRequest("vis_step"), "nothing sent")
	Click("AL0 Read state (UI+G)")
	H.ok(H.hasLine("[TX][CHECK] AL0-UI.BASE INFO T1 UI state now target->keeper=DIPLO_STATE_NEUTRAL"))
	H.ok(H.hasLine("[TX][CHECK] AL0-G.BASE INFO T1 G state now"))
	local b = FAKE_UI.FindButton("AL7 Vision OFF (all teams!)")
	H.ok(string.find(b.tooltip or "", "GLOBAL", 1, true), b.tooltip)
	NoErrors()
end)

test("AL3 from the panel: UI before and after, G steps, UI and G turn reads", function()
	SplitPanel()
	Click("AL0 Read state (UI+G)")
	local l = H.lines("[TX][CHECK] AL0-UI.S3LIVE INFO")[1]
	H.ok(l ~= nil and string.find(l, "still ALLIED", 1, true), l)
	H.ok(string.find(l, "target sees marker=", 1, true) and string.find(l, "intact team: P3 sees P2's capital=", 1, true), l)
	Click("AL3 War then peace (!)")
	H.ok(H.hasLine("[TX][CHECK] AL3-UI.S3LIVE.before INFO T1 UI before: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.ok(H.hasLine("[TX][CHECK] AL3-G.S3LIVE.after PASS"))
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] AL3-UI.S3LIVE.after PASS T1 UI after: state now target->keeper=DIPLO_STATE_UNFRIENDLY"))
	EndTurn()
	Events.PlayerTurnActivated(0, true)
	H.ok(H.hasLine("[TX][CHECK] AL3-G.S3LIVE.turn PASS T2"))
	H.ok(H.hasLine("[TX][CHECK] AL3-UI.S3LIVE.turn PASS T2 UI turn:"))
	NoErrors()
end)

test("AL2, AL4, AL6, AL7 from the panel", function()
	SplitPanel()
	Click("AL2 Probe APIs (no calls)")
	local l = H.lines("[TX][CHECK] AL2-UI.S3LIVE INFO")[1]
	H.ok(l ~= nil and string.find(l, "DiplomacyActionTypes.ALLY=5", 1, true) and string.find(l, "DB.MakeHash=function", 1, true), l)
	H.ok(H.hasLine("[TX][CHECK] AL2-G.S3LIVE INFO"))
	Click("AL4 Alliance deal 1 turn (!)")
	local hash = string.len("ALLIANCE_RESEARCH") * 1000 + 7
	H.eq(LastRequest("al4_alliance").params.hash, hash)
	H.ok(H.hasLine("[TX][SPIKE][AL4] G alliance deal P0->P1 (ALLIANCE_RESEARCH, 1 turn) enact ok=true hash=" .. hash))
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] AL4-UI.S3LIVE.after INFO"))
	Click("AL6 War/denounce valid? (UI)")
	l = H.lines("[TX][CHECK] AL6-UI.S3LIVE INFO")[1]
	H.ok(l ~= nil and string.find(l, "CanDeclareWarOn k->t=", 1, true) and string.find(l, "DIPLOACTION_DENOUNCE=MISSING", 1, true), l)
	H.ok(string.find(l, "TestAction SET_WAR_STATE=MISSING", 1, true), l)
	Click("AL7 Vision OFF (all teams!)")
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] AL7off-UI.S3LIVE.after"))
	Click("AL7 Vision ON (restore)")
	Frames(1)
	H.deq(FAKE_DEV.visFlag, { false, true })
	H.len(H.lines("REFUSED"), 0)
	NoErrors()
end)

-- ---------------------------------------------------------------------------
-- TX_Dev 0.0.1.3: AL0 side effects, AL3b, VIS buttons, K full kick
-- ---------------------------------------------------------------------------
test("AL0 logs VIS0 (UI and G) and the AL0fx side-effect line", function()
	SplitPanel()
	Click("AL0 Read state (UI+G)")
	local v = H.lines("[TX][CHECK] VIS0-UI.S3LIVE INFO T1 UI marker keeper sees=yes target sees=yes")[1]
	H.notnil(v, H.Ser(H.lines("VIS0")))
	H.ok(string.find(v, ": vision still shared (target sees the keeper's marker and city)", 1, true), v)
	H.ok(string.find(v, "city at 3,12; GetVisibilityOn k->t=2 t->k=2; sources k->t=SOURCE_ALLY t->k=SOURCE_ALLY", 1, true), v)
	H.ok(H.hasLine("[TX][CHECK] VIS0-G.S3LIVE INFO T1 G marker keeper sees=yes target sees=yes"))
	local fx = H.lines("[TX][CHECK] AL0fx-UI.S3LIVE INFO T1 UI keeper P0 target P1; grievances k->t=0 t->k=0")[1]
	H.notnil(fx, H.Ser(H.lines("AL0fx")))
	for _, part in ipairs({ "DOW warmonger points k->t=50 level=LOC_FAKE_WARMONGER_-50", "AtWarChangeTurn k->t=-1 t->k=-1",
		"CanMakePeaceWith k->t=false t->k=false", "MinPeaceDuration=10", "open borders target from keeper=no keeper from target=no",
		"deals=0", "era score k=0 t=0", "Leon: notifications, historic moments" }) do
		H.ok(string.find(fx, part, 1, true), part .. " in " .. fx)
	end
	NoErrors()
end)

test("AL3b from the panel: UI before and after with the fx lines (grievances after the war)", function()
	SplitPanel()
	Click("AL3b War(false) then peace (!)")
	H.ok(H.hasLine("[TX][CHECK] AL3b-UI.S3LIVE.before INFO T1 UI before: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.ok(H.hasLine("[TX][CHECK] AL3bfx-UI.S3LIVE.before INFO T1 UI before: keeper P0 target P1; grievances k->t=0 t->k=0"))
	H.ok(H.hasLine("[TX][SPIKE][AL3b] G PROBE AL3b war <table>:DeclareWarOn(1,1,false) exists=function ok=true"))
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] AL3b-UI.S3LIVE.after PASS T1 UI after: state now target->keeper=DIPLO_STATE_UNFRIENDLY"))
	local fx = H.lines("[TX][CHECK] AL3bfx-UI.S3LIVE.after INFO")[1]
	H.ok(fx ~= nil and string.find(fx, "grievances k->t=0 t->k=100; ", 1, true), fx)
	H.ok(string.find(fx, "AtWarChangeTurn k->t=1 t->k=1", 1, true), fx)
	EndTurn()
	Events.PlayerTurnActivated(0, true)
	H.ok(H.hasLine("[TX][CHECK] AL3b-UI.S3LIVE.turn PASS T2 UI turn:"))
	H.ok(H.hasLine("[TX][CHECK] AL3bfx-UI.S3LIVE.turn INFO T2 UI turn:"))
	NoErrors()
end)

test("VIS buttons from the panel: VIS1 before/after in UI and G, VIS2, VIS3, next turn read", function()
	SplitPanel()
	Click("VIS1 Remove outgoing vis (!)")
	H.ok(H.hasLine("[TX][CHECK] VIS1-UI.S3LIVE.before INFO T1 UI before: marker keeper sees=yes target sees=yes"))
	H.eq(LastRequest("vis_step").params.n, 1)
	H.ok(H.hasLine("[TX][CHECK] VIS1-G.S3LIVE.after PASS"))
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] VIS1-UI.S3LIVE.after PASS T1 UI after: marker keeper sees=yes target sees=no"))
	Click("VIS2 Recheck visibility (!)")
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] VIS2-UI.S3LIVE.after"))
	Click("VIS3 SetVisibilityOn 0 (!)")
	Frames(1)
	local l = H.lines("[TX][CHECK] VIS3-UI.S3LIVE.after")[1]
	H.ok(l ~= nil and string.find(l, "GetVisibilityOn k->t=0 t->k=0", 1, true), l)
	H.eq(Game:GetProperty("TX_DEV_ARM").vis.n, 3)
	EndTurn()
	Events.PlayerTurnActivated(0, true)
	H.ok(H.hasLine("[TX][CHECK] VIS3-UI.S3LIVE.turn PASS T2 UI turn:"))
	H.ok(H.hasLine("[TX][CHECK] VIS3-G.S3LIVE.turn PASS T2 G turn:"))
	H.len(H.lines("REFUSED"), 0)
	NoErrors()
end)

test("K Full kick from the panel: refused unarmed; from BASE: S3 write, k_kick (no war), UI reads, save line, turn reads", function()
	Setup()
	Events.LoadGameViewStateDone()
	FAKE.teamModel = "live"
	FAKE_DEV.AddCity(0, 3, 12)
	FAKE_DEV.LinkVision(0, 1)
	MeetTeammates()
	Click("K Full kick (S3+VIS1) (!)")
	H.ok(H.hasLine("[TX][SPIKE][K] UI refused: K starts at BASE (load TX3_base, or press Arm BASE first)"))
	H.isnil(LastRequest("k_kick"))
	H.len(FAKE.teamSets, 0)
	Click("V5 Marker (keeper)")
	ArmNow()
	FAKE_DEV.SetState(0, 1, "DIPLO_STATE_ALLIED")
	FAKE_DEV.SetState(1, 0, "DIPLO_STATE_ALLIED")
	H.clean()
	ENV.Controls.TeamEdit:SetText("")   -- after loading TX3_base the box is empty: K uses the armed newTeam
	Click("K Full kick (S3+VIS1) (!)")
	H.ok(H.hasLine("[TX][CHECK] K-UI.BASE.before INFO T1 UI before: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.len(H.lines("Kfx-"), 0, "no war, no side-effect line")
	H.ok(H.hasLine("[TX][CHECK] Kvis-UI.BASE.before INFO"))
	H.deq(FAKE.teamSets[1], { pid = 1, team = 2, turn = 1, context = "UI" })
	H.eq(FAKE.broadcasts[#FAKE.broadcasts].pid, 1)
	H.ok(H.hasLine("[TX][CHECK] S3-UI.S3LIVE PASS T1 UI config team of P1 0 -> 2 (want 2)"))
	local r = LastRequest("k_kick")
	H.notnil(r)
	H.eq(r.params.target, 1)
	H.eq(r.params.team, 2)
	H.eq(r.params.path, "S3")
	H.isnil(LastRequest("changed"), "k_kick records the change itself")
	H.ok(H.hasLine("[TX][CHECK] K-G.S3LIVE.after INFO"))
	H.ok(H.hasLine("[TX][CHECK] Kvis-G.S3LIVE.after PASS"))
	Frames(1)
	H.ok(H.hasLine("[TX][SPIKE][SNAP] UI S3LIVE reason=changed"))
	H.ok(H.hasLine("[TX][CHECK] K-UI.S3LIVE.after INFO T1 UI after: state now target->keeper=DIPLO_STATE_ALLIED"))
	H.ok(H.hasLine("[TX][CHECK] Kvis-UI.S3LIVE.after PASS T1 UI after: marker keeper sees=yes target sees=no"))
	H.len(FAKE_DEV.dows, 0, "no war in K")
	local last = H.lines()[#H.lines()]
	H.ok(string.find(last, "[TX][SPIKE][K] UI done. NOW save the game as TX3_kick and load TX3_kick", 1, true), last)
	Click("K Full kick (S3+VIS1) (!)")
	H.ok(H.hasLine("[TX][SPIKE][K] UI refused: K starts at BASE"), "a second K is refused")
	EndTurn()
	Events.PlayerTurnActivated(0, true)
	H.ok(H.hasLine("[TX][CHECK] K-UI.S3LIVE.turn INFO T2 UI turn:"))
	H.ok(H.hasLine("[TX][CHECK] Kvis-UI.S3LIVE.turn PASS T2 UI turn:"))
	H.ok(H.hasLine("[TX][CHECK] K-G.S3LIVE.turn INFO T2"))
	H.ok(H.hasLine("[TX][CHECK] Kvis-G.S3LIVE.turn PASS T2"))
	H.len(H.lines("REFUSED"), 0)
	NoErrors()
end)

test("K Full kick: no gameplay answer (or a refusal): WARNING, no save line", function()
	Setup()
	Events.LoadGameViewStateDone()
	FAKE.teamModel = "live"
	MeetTeammates()
	Click("V5 Marker (keeper)")
	ArmNow()
	H.clean()
	FAKE_UI.deferRequests = true   -- the k_kick request never reaches gameplay
	Click("K Full kick (S3+VIS1) (!)")
	H.notnil(LastRequest("k_kick"))
	Frames(25)
	H.ok(H.hasLine("[TX][SPIKE][K] UI WARNING gameplay did not finish K (refused, error or no answer): do NOT save TX3_kick."))
	H.len(H.lines("NOW save the game as TX3_kick"), 0)
	H.len(H.lines("K-UI.BASE.after"), 0)
	FAKE_UI.deferRequests = false
	FAKE_UI.pending = {}
	H.clean()
end)

test("AL8 from the panel: the UI line logs met and is INCONCLUSIVE while unmet", function()
	SplitPanel()
	FAKE_DEV.SetState(0, 1, "DIPLO_STATE_NEUTRAL")
	FAKE_DEV.SetState(1, 0, "DIPLO_STATE_NEUTRAL")
	Click("AL8 Unmeet both ways (!)")
	Frames(1)
	local l = H.lines("[TX][CHECK] AL8-UI.S3LIVE.after INFO T1 UI after: INCONCLUSIVE: not met (k->t=no t->k=no)")[1]
	H.notnil(l, H.Ser(H.lines("AL8-UI")))
	H.ok(string.find(l, "; met k->t=no t->k=no", 1, true), l)
	H.len(H.lines("AL8-UI.S3LIVE.after PASS"), 0)
	NoErrors()
end)

test("AL4L, AL8, AL9 from the panel: UI before/after, the hash for AL4L, UI turn reads with the alliance timer", function()
	SplitPanel()
	Click("AL4L Alliance, friends off (!)")
	H.eq(LastRequest("al4l_alliance_long").params.hash, string.len("ALLIANCE_RESEARCH") * 1000 + 7)
	H.ok(H.hasLine("[TX][CHECK] AL4L-UI.S3LIVE.before INFO"))
	Frames(1)
	local l = H.lines("[TX][CHECK] AL4L-UI.S3LIVE.after INFO")[1]
	H.ok(l ~= nil and string.find(l, "GetAllianceType=", 1, true) and string.find(l, "TurnsUntilExpiration=", 1, true), l)
	EndTurn()
	Events.PlayerTurnActivated(0, true)
	H.ok(H.hasLine("[TX][CHECK] AL4L-UI.S3LIVE.turn INFO T2 UI turn:"))
	Click("AL8 Unmeet both ways (!)")
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] AL8-UI.S3LIVE.after"))
	H.ok(H.hasLine("[TX][SPIKE][AL8] G SetHasMet(false) P0<->P1: met k->t=no t->k=no"))
	Click("AL9 Unmeet then meet (!)")
	Frames(1)
	H.ok(H.hasLine("[TX][CHECK] AL9-UI.S3LIVE.after"))
	H.len(H.lines("REFUSED"), 0)
	NoErrors()
end)
