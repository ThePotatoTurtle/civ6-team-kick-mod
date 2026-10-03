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
	"Diplo matrix", "Clear spike state",
}

test("init: context shown, Main hidden, hotkey and Esc, every button", function()
	Setup()
	H.eq(ENV.ContextPtr:IsHidden(), false, "ContextPtr:SetHide(false) in init")
	H.eq(ENV.Controls.Main:IsHidden(), true)
	H.ok(#H.lines("[TX][SPIKE][INIT] UI TX_Dev 0.0.1.1 loaded (for TX 0.0.1 spike)", true) == 1)
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

test("Events.TeamVictory: members {0,1} FAIL, {0} PASS", function()
	Setup()
	ArmNow()
	SetTeamEdit(2)
	Click("S3 Set Target's team")
	Events.TeamVictory(0, "VICTORY_DEFAULT", 1)
	H.ok(H.hasLine("[TX][CHECK] V3-UI.S3LIVE FAIL T1 UI team victory team=0 type=VICTORY_DEFAULT members=0,1"))
	H.team(1, 2)
	Events.TeamVictory(0, "VICTORY_DEFAULT", 2)
	H.ok(H.hasLine("[TX][CHECK] V3-UI.S3LIVE PASS T1 UI team victory team=0 type=VICTORY_DEFAULT members=0"))
	NoErrors()
end)

test("checklist flow: setups, arm, live split, turn snapshot verdicts in UI", function()
	Setup()
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
