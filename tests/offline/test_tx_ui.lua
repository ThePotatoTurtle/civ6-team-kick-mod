-- Tests of the Team Kick UI, build chunk C of PLAN II.16 (II.14
-- "test_tx_ui.lua"; TP 2.7 phase 2): TX/UI/TX_UIShared.lua,
-- TX/UI/TX_TeamWindow.lua (launch-bar Team button, Team window, confirm
-- dialogs) and TX/UI/TX_VotePopup.lua, each in its own fake UI context
-- (FAKE_UI.LoadContext via FAKE_TX.LoadUI), with the real gameplay script
-- answering their requests (UI.RequestPlayerOperation is delivered to
-- GameEvents.TX_* as gameplay at once).
--
-- Standard world (FAKE_TX.World): P0, P1, P2 human on team 0; P3 human and P4
-- AI on team 1; P5 human solo (team 2); city-state 6; slots 7..61 empty;
-- Free Cities 62; Barbarians 63. First free team ID 6. Split team model
-- (PLAN II.0 F1 to F3): the UI's Players[i]:GetTeam() is stale until a load,
-- the config team is what gameplay reads.

local GAMEPLAY = "TX/Scripts/TX_Gameplay.lua"
local VOTE_N = "NOTIFICATION_TX_VOTE_REQUIRED"
local PASSED_N = "NOTIFICATION_TX_KICK_PASSED"
local FAILED_N = "NOTIFICATION_TX_REQUEST_FAILED"

local ENVS = nil

local function Setup(opts)
	opts = opts or {}
	FAKE.dofile("tests/offline/lib/fake_txworld.lua")
	FAKE_TX.World(opts)
	if opts.setup ~= nil then
		opts.setup()
	end
	FAKE_UI.Enable()
	FAKE.localPlayer = opts.localPlayer or 0
	FAKE_UI.AsGameplay(function() FAKE.dofile(GAMEPLAY) end)
	ENVS = FAKE_TX.LoadUI()
	H.markBody()
end

local function Win() return ENVS.TeamWindow end
local function Pop() return ENVS.VotePopup end

-- Texts and labels.
local function T(key, ...) return Locale.Lookup(key, ...) end
local function Label(pid)
	return "LOC_LEADER_FAKE_" .. pid .. "_NAME (LOC_CIVILIZATION_FAKE_" .. pid .. "_NAME)"
end
-- Kick mode words (kick modes): "soft kick" / "hard kick".
local function SoftS() return T("LOC_TX_MODE_SOFT_SHORT") end
local function HardS() return T("LOC_TX_MODE_HARD_SHORT") end
-- The kick confirm's mode lines between the kind text and the after text.
local function ModeLines(hard)
	local lines = { T("LOC_TX_MODE_LINE", T("LOC_TX_MODE_SOFT"), T("LOC_TX_MODE_SOFT_INFO")) }
	if hard ~= false then
		lines[2] = T("LOC_TX_MODE_LINE", T("LOC_TX_MODE_HARD"), T("LOC_TX_MODE_HARD_INFO"))
	end
	return "[NEWLINE][NEWLINE]" .. table.concat(lines, "[NEWLINE]") .. "[NEWLINE][NEWLINE]"
end
local function Has(s, sub) return type(s) == "string" and string.find(s, sub, 1, true) ~= nil end

-- Gameplay side (as the engine delivers EXECUTE_SCRIPT).
local function GPropose(pid, target, mode) H.request(pid, { OnStart = "TX_Propose", targetID = target, mode = mode or "SOFT" }) end
local function GVote(pid, id, v) H.request(pid, { OnStart = "TX_Vote", recordID = id, vote = v }) end
local function GTurn() FAKE_UI.AsGameplay(H.endTurn) end
local function Rec(id)
	local s = H.prop("TX_Store")
	return s and s.recs and s.recs["r" .. id]
end
local function Rev() return H.prop("TX_Rev") or 0 end

-- Requests the UI sent.
local function Requests(onStart)
	local out = {}
	for _, r in ipairs(FAKE_UI.requests) do
		if onStart == nil or r.params.OnStart == onStart then
			out[#out + 1] = r
		end
	end
	return out
end

-- Built launch-bar instances (newest of that name) and instance managers.
local function Built(name)
	local hit = nil
	for _, b in ipairs(FAKE_UI.builtInstances or {}) do
		if b.name == name then hit = b end
	end
	return hit
end
local function Launch() return Built("TX_LaunchBarItem").inst end
local function Pin() return Built("TX_LaunchBarPin").inst.Pin end
local function IM(name)
	local hit = nil
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == name then hit = im end
	end
	return hit
end
local function Rows(name) return IM(name).list end
local function MemberRow(pid)
	for _, inst in ipairs(Rows("TX_MemberRow")) do
		if Has(inst.NameLabel.text, Label(pid)) then return inst end
	end
	return nil
end
local function VoterTexts()
	local out = {}
	for _, inst in ipairs(Rows("TX_VoterRow")) do out[#out + 1] = inst.VoterLabel.text end
	return out
end
local function History()
	local out = {}
	for _, inst in ipairs(Rows("TX_HistoryRow")) do
		out[#out + 1] = { text = inst.HistoryLabel.text, tip = inst.HistoryButton.tooltip }
	end
	return out
end

local function WindowOpen() return not Win().Controls.TeamPanel:IsHidden() end
local function OpenWindow()
	if not WindowOpen() then Launch().LaunchItemButton:Click() end
	H.ok(WindowOpen(), "the window opens")
end
local function PopupOpen()
	return not Pop().Controls.PopupRoot:IsHidden() and FAKE_UI.queued[Pop().ContextPtr] == true
end
local function LastDialog() return FAKE_UI.popups[#FAKE_UI.popups] end
local function DialogText(d) return table.concat(d.texts, "|") end

local function Kick(pid)
	local row = MemberRow(pid)
	H.notnil(row, "member row P" .. pid)
	local n = #FAKE_UI.popups
	row.KickButton:Click()
	H.eq(#FAKE_UI.popups, n + 1, "a confirm dialog opened")
	return LastDialog()
end

-- ===========================================================================
-- 1. Contexts
-- ===========================================================================
test("ui 1: each context un-hides itself; the window and the popup start hidden; no request at load", function()
	Setup()
	H.eq(Win().ContextPtr:IsHidden(), false, "TeamWindow ContextPtr:SetHide(false)")
	H.eq(Pop().ContextPtr:IsHidden(), false, "VotePopup ContextPtr:SetHide(false)")
	H.eq(Win().Controls.TeamPanel:IsHidden(), true, "TeamPanel hidden")
	H.eq(Win().Controls.VoteButton:IsHidden(), true, "VoteButton hidden")
	H.eq(Pop().Controls.PopupRoot:IsHidden(), true, "PopupRoot hidden")
	H.eq(FAKE_UI.queued[Pop().ContextPtr], nil, "popup not queued")
	H.len(H.lines("[UITeam] initialized", true), 1)
	H.len(H.lines("[UIVote] initialized", true), 1)
	H.len(FAKE_UI.requests, 0, "no request at load")
	H.notnil(FAKE_TX.ui.ApplyBanner, "chunk D context loaded")
	H.eq(FAKE_TX.ui.ApplyBanner.ContextPtr:IsHidden(), false, "ApplyBanner ContextPtr:SetHide(false)")
	H.eq(FAKE_TX.ui.ApplyBanner.Controls.Banner:IsHidden(), true, "Banner hidden without a passed kick")
	H.len(H.lines("[UIApply] initialized", true), 1)
	H.clean()
end)

-- ===========================================================================
-- 2. Team button
-- ===========================================================================
test("ui 2: Team button attached once on LoadGameViewStateDone; shown for P0 and P3, hidden for P5, -1 and after a hand-off", function()
	Setup()
	local resizes = {}
	LuaEvents.LaunchBar_Resize.Add(function(w) resizes[#resizes + 1] = w end)
	local item, pin = Built("TX_LaunchBarItem"), Built("TX_LaunchBarPin")
	H.notnil(item, "TX_LaunchBarItem built")
	H.notnil(pin, "TX_LaunchBarPin built")
	H.eq(item.parent, FAKE_UI.built["/InGame/LaunchBar/ButtonStack"], "built into the launch bar ButtonStack")
	H.eq(Launch().LaunchItemButton:IsHidden(), false, "shown for P0 (team of 3)")
	H.eq(Pin():IsHidden(), false)
	H.eq(Launch().AlertIndicator:IsHidden(), true, "no alert")
	H.eq(Launch().LaunchItemButton.tooltip, T("LOC_TX_LAUNCH_TT"))
	H.ok(FAKE_UI.built["/InGame/LaunchBar/LaunchBacking"].sizeX ~= 100, "backing resized")
	Events.LoadGameViewStateDone()
	local n = 0
	for _, b in ipairs(FAKE_UI.builtInstances) do
		if b.name == "TX_LaunchBarItem" then n = n + 1 end
	end
	H.eq(n, 1, "attached once")

	FAKE_TX.Hotseat(5)
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "hidden for P5 (solo)")
	H.eq(Pin():IsHidden(), true, "pin hidden with it")
	H.ok(#resizes >= 1, "LaunchBar_Resize after hiding")
	Launch().LaunchItemButton:Click()
	H.eq(WindowOpen(), false, "the window does not open for P5")
	FAKE_TX.Hotseat(3)
	H.eq(Launch().LaunchItemButton:IsHidden(), false, "shown for P3 (team with an AI)")
	FAKE_TX.Hotseat(-1)
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "hidden for local -1")
	FAKE_TX.Hotseat(0)
	H.eq(Launch().LaunchItemButton:IsHidden(), false, "shown again for P0")
	H.eq(Pin():IsHidden(), false)
	H.clean()
end)

test("ui 2b: button rule follows the config team and life: dead player, partner dead, the kicked target after the write", function()
	Setup({ localPlayer = 3 })
	H.eq(Launch().LaunchItemButton:IsHidden(), false, "P3 with P4")
	H.kill(4)
	Events.PlayerTurnActivated(3, true)
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "P3 alone once P4 is dead")
	FAKE_TX.Hotseat(1)
	H.eq(Launch().LaunchItemButton:IsHidden(), false, "P1 on team 0")
	PlayerConfigurations[1]:SetTeam(6)
	Events.PlayerTurnActivated(1, true)
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "P1 alone on its config team 6 (the value gameplay reads)")
	H.eq(Players[1]:GetTeam(), 0, "UI live team still old (F3)")
	H.clean()
end)

-- ===========================================================================
-- 3. Members
-- ===========================================================================
test("ui 3: members for P0: self first with (you) and no Kick; P1, P2 with enabled Kick buttons; portraits; P4 marked AI for P3", function()
	Setup()
	OpenWindow()
	local rows = Rows("TX_MemberRow")
	H.len(rows, 3, "three living majors on team 0")
	H.eq(rows[1].NameLabel.text, T("LOC_TX_MEMBER_YOU", Label(0)), "self first")
	H.eq(rows[1].KickButton:IsHidden(), true, "no Kick on self")
	H.eq(rows[2].NameLabel.text, Label(1))
	H.eq(rows[3].NameLabel.text, Label(2))
	for i = 2, 3 do
		H.eq(rows[i].KickButton:IsHidden(), false)
		H.eq(rows[i].KickButton:IsDisabled(), false, "Kick enabled")
		H.eq(rows[i].KickButton.tooltip, T("LOC_TX_KICK_TT", Label(i - 1)))
	end
	H.eq(rows[1].Portrait.icon, "ICON_LEADER_FAKE_0", "portrait from GetLeaderTypeName")
	H.eq(rows[3].Portrait.icon, "ICON_LEADER_FAKE_2")
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_NO_VOTE"))
	H.eq(Win().Controls.HistoryEmptyLabel:IsHidden(), false, "no history yet")

	Win().Controls.CloseButton:Click()
	FAKE_TX.Hotseat(3)
	OpenWindow()
	rows = Rows("TX_MemberRow")
	H.len(rows, 2)
	H.eq(rows[1].NameLabel.text, T("LOC_TX_MEMBER_YOU", Label(3)))
	H.eq(rows[2].NameLabel.text, T("LOC_TX_MEMBER_AI", Label(4)), "AI teammate")
	H.eq(rows[2].KickButton:IsDisabled(), false, "an AI teammate can be kicked")
	H.clean()
end)

-- ===========================================================================
-- 4. Kick and the confirm dialogs
-- ===========================================================================
test("ui 4: Kick confirm VOTE (team of 3): title, text with the label and 5 turns, the mode lines, the after text; Soft kick sends TX_Propose SOFT", function()
	Setup()
	FAKE.SetText("LOC_TX_CONFIRM_VOTE", "VOTE {1_Player}|{2_Num}")
	OpenWindow()
	local d = Kick(1)
	H.eq(d.title, T("LOC_TX_CONFIRM_TITLE"))
	H.eq(DialogText(d), "VOTE " .. Label(1) .. "|5" .. ModeLines() .. T("LOC_TX_CONFIRM_AFTER"))
	H.notnil(d.confirm, "Soft kick button")
	H.eq(d.confirmLabel, "Soft kick", "the default (confirm) button is Soft")
	H.len(d.buttons, 1, "one more choice")
	H.eq(d.buttons[1].label, "Hard kick")
	H.eq(d.cancelLabel, "Cancel")
	H.len(Requests(), 0, "nothing sent before a choice")
	d.confirm()
	local reqs = Requests("TX_Propose")
	H.len(reqs, 1)
	H.eq(reqs[1].pid, 0, "sent as the local player")
	H.deq(reqs[1].params, { OnStart = "TX_Propose", targetID = 1, mode = "SOFT" }, "flat params")
	H.ok(reqs[1].delivered, "delivered to gameplay")
	H.eq(Rec(1).state, "OPEN")
	H.eq(Rec(1).mode, "SOFT")
	H.ok(H.hasLine("[UIRequest] TX_Propose from P0 mode=SOFT targetID=1"), "request logged")
	H.clean()
end)

test("ui 4d: Hard kick button sends TX_Propose HARD; the mode shows in the vote line, the popup, the notification and the history", function()
	Setup()
	OpenWindow()
	local d = Kick(1)
	d.buttons[1].fn()
	local reqs = Requests("TX_Propose")
	H.len(reqs, 1)
	H.deq(reqs[1].params, { OnStart = "TX_Propose", targetID = 1, mode = "HARD" })
	H.eq(Rec(1).mode, "HARD")
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_VOTE_LINE", Label(0), Label(1), 5, HardS()))
	H.ok(Has(Win().Controls.VoteLabel.text, "(hard kick)"), "the proposer's window names the mode")
	-- the voter: notification text and popup
	local n = H.notifs(2, VOTE_N)
	H.ok(Has(n[#n].data[ParameterTypes.SUMMARY], "(hard kick)"), "VOTE_REQUIRED names the mode")
	FAKE_TX.Hotseat(2)
	FAKE_TX.Activate(2, VOTE_N)
	H.ok(PopupOpen(), "popup open")
	local body = Pop().Controls.BodyLabel.text
	H.ok(Has(body, T("LOC_TX_MODE_LINE", T("LOC_TX_MODE_HARD"), T("LOC_TX_MODE_HARD_INFO"))), "popup names the mode with its explanation")
	OpenWindow()
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_VOTE_LINE", Label(0), Label(1), 5, HardS()), "the voter's window too")
	-- a NO: the history row names the mode
	GVote(2, 1, "NO")
	FAKE_TX.Hotseat(0)
	OpenWindow()
	H.eq(History()[1].text, T("LOC_TX_HIST_FAILED", 1, Label(1), HardS()))
	-- a hard kick that passes: passed line with the mode
	GPropose(0, 1, "HARD")
	GVote(2, 2, "YES")
	H.eq(Rec(2).state, "PENDING_APPLY")
	FAKE_UI.Update(Win(), 1)
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_PASSED_LINE", Label(1), HardS()))
	H.clean()
end)

test("ui 4e: HARD_KICK_ENABLED = false: the dialog offers Soft only; gameplay refuses HARD with BAD_MODE", function()
	Setup()
	TX_Config.HARD_KICK_ENABLED = false
	OpenWindow()
	local d = Kick(1)
	H.eq(DialogText(d), T("LOC_TX_CONFIRM_VOTE", Label(1), 5) .. ModeLines(false) .. T("LOC_TX_CONFIRM_AFTER"))
	H.len(d.buttons, 0, "no Hard kick button")
	H.eq(d.confirmLabel, "Soft kick")
	GPropose(0, 1, "HARD")
	H.isnil(Rec(1), "HARD refused")
	H.eq(H.notifs(0, FAILED_N)[1].data[ParameterTypes.SUMMARY], T("LOC_TX_REASON_BAD_MODE"))
	d.confirm()
	H.eq(Rec(1).mode, "SOFT")
	H.clean()
end)

test("ui 4f: without PopupDialogInGame AddCustomButton the dialog still opens with Soft kick and Cancel; the probe logs the failure", function()
	Setup()
	PopupDialogInGame.AddCustomButton = nil
	OpenWindow()
	local d = Kick(1)
	H.len(d.buttons, 0, "no Hard kick button")
	H.ok(H.hasLine("[UIShared] PROBE UI PopupDialogInGame:AddCustomButton FAILED: "))
	d.confirm()
	H.eq(Rec(1).mode, "SOFT")
	H.clean()
end)

test("ui 4b: No sends nothing; DISSOLVE wording for a team of 2 (P3 kicks AI P4) passes at once", function()
	Setup({ localPlayer = 3 })
	OpenWindow()
	local d = Kick(4)
	H.eq(DialogText(d), T("LOC_TX_CONFIRM_DISSOLVE", Label(4)) .. ModeLines() .. T("LOC_TX_CONFIRM_AFTER"),
		"2-person wording")
	H.ok(d.cancel == nil, "the Cancel button just closes the dialog")
	H.len(Requests(), 0, "Cancel: nothing sent")
	d = Kick(4)
	d.confirm()
	H.len(Requests("TX_Propose"), 1)
	H.eq(Rec(1).state, "PENDING_APPLY", "dissolved at once")
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_PASSED_LINE", Label(4), SoftS()), "window shows the passed kick")
	H.clean()
end)

test("ui 4c: AI_ONLY wording ({P0 human, P1 AI, P2 target}) passes at once; a hand-off before Yes sends nothing", function()
	Setup({ setup = function() H.human(1, false) end })
	OpenWindow()
	H.eq(MemberRow(1).NameLabel.text, T("LOC_TX_MEMBER_AI", Label(1)))
	local d = Kick(2)
	H.eq(DialogText(d), T("LOC_TX_CONFIRM_AI_ONLY", Label(2)) .. ModeLines() .. T("LOC_TX_CONFIRM_AFTER"))
	-- hot seat: the machine changes hands while the dialog is open
	FAKE.localPlayer = 2
	d.confirm()
	H.len(Requests(), 0, "nothing sent for another player")
	H.ok(H.hasLine("[UITeam] kick P2 not sent: the local player changed from P0 to P2"))
	FAKE.localPlayer = 0
	d = Kick(2)
	d.confirm()
	H.eq(Rec(1).state, "PENDING_APPLY", "AI_ONLY passes at once")
	H.clean()
end)

-- ===========================================================================
-- 5, 6. Open vote per role
-- ===========================================================================
test("ui 5: open vote as P0 (proposer): who voted, never yes or no; Kick disabled with VOTE_OPEN", function()
	Setup()
	OpenWindow()
	Kick(1).confirm()
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_VOTE_LINE", Label(0), Label(1), 5, SoftS()))
	H.deq(VoterTexts(), { T("LOC_TX_VOTER_PROPOSER", Label(0)), T("LOC_TX_VOTER_PENDING", Label(2)) })
	H.eq(Win().Controls.VoteButton:IsHidden(), true, "the proposer has voted")
	for _, pid in ipairs({ 1, 2 }) do
		H.eq(MemberRow(pid).KickButton:IsDisabled(), true)
		H.eq(MemberRow(pid).KickButton.tooltip, T("LOC_TX_REASON_VOTE_OPEN"))
	end
	H.len(History(), 0, "an open vote is not history")
	H.clean()
end)

test("ui 5b: a voter who said yes reads 'voted' while the vote is open (P5 joins team 0: three voters)", function()
	Setup({ setup = function() H.team(5, 0) end })
	GPropose(0, 1)
	GVote(2, 1, "YES")
	H.eq(Rec(1).state, "OPEN", "P5 still to vote")
	OpenWindow()
	local texts = VoterTexts()
	H.deq(texts, { T("LOC_TX_VOTER_PROPOSER", Label(0)), T("LOC_TX_VOTER_VOTED", Label(2)),
		T("LOC_TX_VOTER_PENDING", Label(5)) })
	for _, s in ipairs(texts) do
		for _, pid in ipairs({ 0, 2, 5 }) do
			H.ne(s, T("LOC_TX_HIST_VOTE_YES", Label(pid)), "no yes value while open")
			H.ne(s, T("LOC_TX_HIST_VOTE_NO", Label(pid)), "no no value while open")
		end
		H.ok(string.sub(s, -5) ~= ": yes" and string.sub(s, -4) ~= ": no", "no vote value while open: " .. s)
	end
	H.clean()
end)

test("ui 6: P2 (pending voter) sees a Vote button and VOTE_OPEN on Kick; alert pip and tooltip line on the Team button", function()
	Setup()
	GPropose(0, 1)
	FAKE_TX.Hotseat(2)
	H.eq(Launch().AlertIndicator:IsHidden(), false, "alert for a pending voter")
	H.eq(Launch().LaunchItemButton.tooltip, T("LOC_TX_LAUNCH_TT") .. "[NEWLINE]" .. T("LOC_TX_LAUNCH_TT_VOTE"))
	OpenWindow()
	H.eq(Win().Controls.VoteButton:IsHidden(), false, "Vote button")
	H.eq(MemberRow(1).KickButton:IsDisabled(), true)
	H.eq(MemberRow(1).KickButton.tooltip, T("LOC_TX_REASON_VOTE_OPEN"))
	H.eq(MemberRow(0).KickButton.tooltip, T("LOC_TX_REASON_VOTE_OPEN"))
	FAKE_TX.Hotseat(0)
	H.eq(Launch().AlertIndicator:IsHidden(), true, "no alert for the proposer")
	H.clean()
end)

test("ui 5c: the target (P1) never sees the open vote: no vote, no history, TEAM_BUSY only, no alert, no popup", function()
	Setup()
	GPropose(0, 1)
	FAKE_TX.Hotseat(1)
	H.eq(Launch().AlertIndicator:IsHidden(), true, "no alert for the target")
	H.eq(Launch().LaunchItemButton.tooltip, T("LOC_TX_LAUNCH_TT"))
	OpenWindow()
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_NO_VOTE"))
	H.len(VoterTexts(), 0)
	H.eq(Win().Controls.VoteButton:IsHidden(), true)
	H.len(History(), 0)
	H.eq(Win().Controls.HistoryEmptyLabel:IsHidden(), false)
	for _, pid in ipairs({ 0, 2 }) do
		H.eq(MemberRow(pid).KickButton:IsDisabled(), true)
		H.eq(MemberRow(pid).KickButton.tooltip, T("LOC_TX_REASON_TEAM_BUSY"), "TEAM_BUSY wording only")
	end
	-- a Vote request for the record (e.g. a stale window event) opens no popup
	Win().Controls.CloseButton:Click()
	LuaEvents.TX_OpenVote(1)
	H.eq(PopupOpen(), false, "no popup for the target")
	H.eq(WindowOpen(), true, "the Team window instead")
	H.len(H.notifs(1), 0, "no TX notification for the target")
	H.clean()
end)

test("ui 5d: Kick reasons: APPLY_PENDING after a pass, VICTORY after a victory report", function()
	Setup()
	GPropose(0, 1)
	GVote(2, 1, "YES")
	OpenWindow()
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_PASSED_LINE", Label(1), SoftS()))
	H.eq(MemberRow(2).KickButton.tooltip, T("LOC_TX_REASON_APPLY_PENDING"))
	H.eq(Launch().AlertIndicator:IsHidden(), false, "alert while a kick waits")
	H.eq(Launch().LaunchItemButton.tooltip, T("LOC_TX_LAUNCH_TT") .. "[NEWLINE]" .. T("LOC_TX_PASSED_LINE", Label(1), SoftS()))
	H.request(0, { OnStart = "TX_Victory", team = 1 })
	FAKE_UI.Update(Win(), 0.6)
	H.eq(MemberRow(2).KickButton:IsDisabled(), true)
	H.eq(MemberRow(2).KickButton.tooltip, T("LOC_TX_REASON_VICTORY"), "the kick was cancelled by the victory")
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_NO_VOTE"))
	H.clean()
end)

-- ===========================================================================
-- 7 to 9. Vote popup
-- ===========================================================================
test("ui 7: popup from the notification: Activate(2, VOTE_REQUIRED) queues it with both labels; Yes sends TX_Vote and closes", function()
	Setup()
	FAKE.SetText("LOC_TX_POPUP_TEXT", "{1_Player}|{2_Player}|{3_Num}")
	GPropose(0, 1)
	FAKE_TX.Hotseat(2)
	H.notnil(FAKE_TX.Activate(2, VOTE_N), "P2 has the notification")
	H.ok(PopupOpen(), "popup queued and shown")
	H.eq(Pop().Controls.BodyLabel.text, Label(0) .. "|" .. Label(1) .. "|5")
	H.ok(H.hasLine("[UIShared] PROBE UI NotificationActivated NOTIFICATION_TX_VOTE_REQUIRED ok -> number 1"),
		"probe line for Session 4")
	Pop().Controls.YesButton:Click()
	local reqs = Requests("TX_Vote")
	H.len(reqs, 1)
	H.eq(reqs[1].pid, 2)
	H.deq(reqs[1].params, { OnStart = "TX_Vote", recordID = 1, vote = "YES" })
	H.eq(PopupOpen(), false, "closed")
	H.eq(Pop().Controls.PopupRoot:IsHidden(), true)
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.clean()
end)

test("ui 8: popup from the window: Vote fires LuaEvents.TX_OpenVote; No sends TX_Vote NO; Later sends nothing", function()
	Setup()
	GPropose(0, 1)
	FAKE_TX.Hotseat(2)
	OpenWindow()
	local opened = {}
	LuaEvents.TX_OpenVote.Add(function(id) opened[#opened + 1] = id end)
	Win().Controls.VoteButton:Click()
	H.deq(opened, { 1 }, "LuaEvents.TX_OpenVote(1)")
	H.ok(PopupOpen())
	Pop().Controls.LaterButton:Click()
	H.eq(PopupOpen(), false, "Later closes")
	H.len(Requests(), 0, "Later sends nothing")
	Win().Controls.VoteButton:Click()
	Pop().Controls.NoButton:Click()
	H.deq(Requests("TX_Vote")[1].params, { OnStart = "TX_Vote", recordID = 1, vote = "NO" })
	H.eq(Rec(1).state, "FAILED")
	FAKE_UI.Update(Win(), 0.6)
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_NO_VOTE"), "the window poll sees the failed vote")
	H.eq(Win().Controls.VoteButton:IsHidden(), true)
	H.clean()
end)

test("ui 9: hotseat: popup open for P2, Hotseat(0) closes it, no request; a stale voter at the click sends nothing", function()
	Setup()
	GPropose(0, 1)
	FAKE_TX.Hotseat(2)
	FAKE_TX.Activate(2, VOTE_N)
	H.ok(PopupOpen())
	FAKE_TX.Hotseat(0)
	H.eq(PopupOpen(), false, "closed on LocalPlayerChanged")
	Pop().Controls.YesButton:Click()
	H.len(Requests(), 0, "nothing sent")
	-- the voter is captured at open and re-checked at the click
	FAKE_TX.Hotseat(2)
	FAKE_TX.Activate(2, VOTE_N)
	H.ok(PopupOpen())
	FAKE.localPlayer = 0
	Pop().Controls.YesButton:Click()
	H.len(Requests(), 0, "a hand-off without the event: still nothing sent")
	H.eq(PopupOpen(), false)
	H.ok(H.hasLine("[UIVote] vote rec=1 not sent: the local player changed from P2 to P0"))
	H.eq(Rec(1).state, "OPEN")
	H.clean()
end)

test("ui 9b: activation for another player or another type is ignored; P0 (already voted) gets the Team window", function()
	Setup()
	GPropose(0, 1)
	-- P0 is local; P2's notification activated (pid ~= local): ignored
	local nid = H.notifs(2, VOTE_N)[1].id
	Events.NotificationActivated(2, nid, true)
	H.eq(PopupOpen(), false, "another player's activation")
	-- another type for the local player
	H.request(0, { OnStart = "TX_Vote", recordID = 9, vote = "YES" })
	H.notnil(FAKE_TX.Activate(0, FAILED_N), "P0 has a REQUEST_FAILED")
	H.eq(PopupOpen(), false, "another type")
	H.eq(WindowOpen(), false)
	-- the proposer has no vote to cast: the window opens instead
	LuaEvents.TX_OpenVote(1)
	H.eq(PopupOpen(), false)
	H.eq(WindowOpen(), true, "Team window instead")
	H.ok(H.hasLine("[UIVote] rec=1: P0 has no vote to cast (ALREADY_VOTED); Team window instead"))
	H.clean()
end)

test("ui 9c: the popup closes when the record leaves OPEN (rev poll): the target is eliminated", function()
	Setup()
	GPropose(0, 1)
	FAKE_TX.Hotseat(2)
	FAKE_TX.Activate(2, VOTE_N)
	H.ok(PopupOpen())
	H.kill(1)
	GTurn()
	H.eq(Rec(1).state, "CANCELLED", "the turn start cancels the vote")
	H.ok(PopupOpen(), "still open before the poll")
	FAKE_UI.Update(Pop(), 0.6)
	H.eq(PopupOpen(), false, "closed by the poll")
	H.len(Requests(), 0)
	H.clean()
end)

test("ui 9d: turns left at turn 2; the popup closes on LocalPlayerTurnEnd, ESC, the close button and the diplomacy screen", function()
	Setup()
	FAKE.SetText("LOC_TX_POPUP_TEXT", "{1_Player}|{2_Player}|{3_Num}")
	GPropose(0, 1)
	FAKE_TX.Hotseat(2)
	GTurn()
	FAKE_TX.Activate(2, VOTE_N)
	H.eq(Pop().Controls.BodyLabel.text, Label(0) .. "|" .. Label(1) .. "|4", "turns left at turn 2")
	Events.LocalPlayerTurnEnd()
	H.eq(PopupOpen(), false, "LocalPlayerTurnEnd")
	FAKE_TX.Activate(2, VOTE_N)
	H.ok(FAKE_UI.KeyTo(Pop(), Keys.VK_ESCAPE), "ESC consumed while open")
	H.eq(PopupOpen(), false, "ESC")
	H.eq(FAKE_UI.KeyTo(Pop(), Keys.VK_ESCAPE), false, "ESC passes through while closed")
	FAKE_TX.Activate(2, VOTE_N)
	Pop().Controls.CloseButton:Click()
	H.eq(PopupOpen(), false, "close button")
	FAKE_TX.Activate(2, VOTE_N)
	LuaEvents.DiplomacyActionView_HideIngameUI()
	H.eq(PopupOpen(), false, "diplomacy screen")
	H.len(Requests(), 0)
	H.clean()
end)

-- ===========================================================================
-- 10. Sweep
-- ===========================================================================
test("ui 10: sweep: two pending copies keep only the newest; after the vote every copy of P2 is dismissed", function()
	Setup()
	GPropose(0, 1)
	GTurn()
	local copies = H.notifs(2, VOTE_N)
	H.len(copies, 2, "re-sent at the turn start")
	FAKE_TX.Hotseat(2)
	Events.PlayerTurnActivated(2, true)
	H.eq(copies[1].dismissed, true, "older copy dismissed")
	H.ok(not copies[2].dismissed, "newest copy kept while pending")
	-- NotificationAdded of the type after view ready also sweeps
	GTurn()
	copies = H.notifs(2, VOTE_N)
	H.len(copies, 3)
	Events.NotificationAdded(2, copies[3].id)
	H.eq(copies[2].dismissed, true)
	H.ok(not copies[3].dismissed)
	-- P2 votes (here straight to gameplay): the next sweep clears every copy
	H.request(2, { OnStart = "TX_Vote", recordID = 1, vote = "YES" })
	FAKE_TX.Hotseat(0)
	FAKE_TX.Hotseat(2)
	FAKE_TX.Activate(2, VOTE_N)
	H.eq(PopupOpen(), false, "already voted: no popup")
	Events.PlayerTurnActivated(2, true)
	for _, n in ipairs(H.notifs(2, VOTE_N)) do
		H.eq(n.dismissed, true, "copy " .. n.id .. " dismissed once the vote closed")
	end
	H.clean()
end)

test("ui 10c: hotseat hand-off sweeps the new local player's copies (they piled up while another player had the seat)", function()
	Setup()
	GPropose(0, 1)
	GTurn()
	local copies = H.notifs(2, VOTE_N)
	H.len(copies, 2, "re-sent at the turn start while P0 is local")
	H.ok(not copies[1].dismissed and not copies[2].dismissed, "P0's turn sweeps nothing of P2")
	FAKE_TX.Hotseat(2)                       -- no PlayerTurnActivated, no new notification
	H.eq(copies[1].dismissed, true, "older copy dismissed on the hand-off")
	H.ok(not copies[2].dismissed, "newest copy kept while P2 still has to vote")
	-- the popup for the old player still closes on a hand-off
	FAKE_TX.Activate(2, VOTE_N)
	H.eq(PopupOpen(), true)
	FAKE_TX.Hotseat(0)
	H.eq(PopupOpen(), false)
	H.ok(not copies[2].dismissed, "P2's copy is not touched by P0's sweep")
	H.len(Requests("TX_Vote"), 0)
	H.clean()
end)

test("ui 10b: right after a vote from the popup the voter's copies go, before gameplay answers", function()
	Setup()
	GPropose(0, 1)
	FAKE_TX.Hotseat(2)
	FAKE_TX.Activate(2, VOTE_N)
	FAKE_UI.deferRequests = true
	Pop().Controls.YesButton:Click()
	H.eq(Rec(1).state, "OPEN", "gameplay has not answered yet")
	for _, n in ipairs(H.notifs(2, VOTE_N)) do
		H.eq(n.dismissed, true, "dismissed after the vote")
	end
	H.eq(FAKE_UI.DeliverRequests(), 1)
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.clean()
end)

-- ===========================================================================
-- 11. History
-- ===========================================================================
test("ui 11: history: FAILED shown to P0 and P2 with the votes, hidden from P1; DONE shown to all, newest first", function()
	Setup()
	GPropose(0, 1)
	GVote(2, 1, "NO")
	OpenWindow()
	local h = History()
	H.len(h, 1)
	H.eq(h[1].text, T("LOC_TX_HIST_FAILED", 1, Label(1), SoftS()))
	H.eq(h[1].tip, table.concat({ T("LOC_TX_HIST_STARTED_BY", Label(0)), T("LOC_TX_REASON_NO_VOTE"),
		T("LOC_TX_HIST_VOTE_YES", Label(0)), T("LOC_TX_HIST_VOTE_NO", Label(2)) }, "[NEWLINE]"), "votes shown once closed")
	H.eq(Win().Controls.HistoryEmptyLabel:IsHidden(), true)
	FAKE_TX.Hotseat(2)
	OpenWindow()
	H.len(History(), 1, "P2 sees it")
	FAKE_TX.Hotseat(1)
	OpenWindow()
	H.len(History(), 0, "hidden from the target")

	-- second vote passes; host applies; save and load; RELOADED -> DONE
	GPropose(0, 1)
	GVote(2, 2, "YES")
	FAKE_TX.Hotseat(0)
	OpenWindow()
	h = History()
	H.len(h, 2)
	H.eq(h[1].text, T("LOC_TX_HIST_PENDING_APPLY", 1, Label(1), SoftS()), "newest first")
	PlayerConfigurations[1]:SetTeam(Rec(2).newTeamID)
	H.request(0, { OnStart = "TX_ApplyDone", recordID = 2, step = "WRITTEN", team = Rec(2).newTeamID })
	ENVS = FAKE_TX.Reload()
	H.request(0, { OnStart = "TX_ApplyDone", recordID = 2, step = "RELOADED", team = Rec(2).newTeamID })
	H.eq(Rec(2).state, "DONE")
	OpenWindow()
	h = History()
	H.eq(h[1].text, T("LOC_TX_HIST_DONE", 1, Label(1), SoftS()))
	H.eq(h[2].text, T("LOC_TX_HIST_FAILED", 1, Label(1), SoftS()))
	H.len(Rows("TX_MemberRow"), 2, "P0 and P2 left")
	-- the target: alone, no Team button; once on a team of two it sees only the passed kick
	FAKE_TX.Hotseat(1)
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "the kicked player has no Team button")
	H.team(5, Rec(2).newTeamID)
	FAKE_TX.Hotseat(5)
	FAKE_TX.Hotseat(1)
	OpenWindow()
	h = History()
	H.len(h, 1, "the target sees the DONE record, not the failed one")
	H.eq(h[1].text, T("LOC_TX_HIST_DONE", 1, Label(1), SoftS()))
	H.clean()
end)

test("ui 11b: at most HISTORY_SHOWN rows", function()
	Setup()
	for i = 1, TX_Config.HISTORY_SHOWN + 2 do
		GPropose(0, 1)
		GVote(2, i, "NO")
	end
	OpenWindow()
	H.len(History(), TX_Config.HISTORY_SHOWN)
	H.eq(History()[1].text, T("LOC_TX_HIST_FAILED", 1, Label(1), SoftS()))
	H.clean()
end)

-- ===========================================================================
-- 12. Closing the window
-- ===========================================================================
test("ui 12: the window closes on LocalPlayerTurnEnd, ESC, the close button, a hand-off and the diplomacy screen", function()
	Setup()
	OpenWindow()
	Events.LocalPlayerTurnEnd()
	H.eq(WindowOpen(), false, "LocalPlayerTurnEnd")
	OpenWindow()
	H.ok(FAKE_UI.KeyTo(Win(), Keys.VK_ESCAPE), "ESC consumed")
	H.eq(WindowOpen(), false, "ESC")
	H.eq(FAKE_UI.KeyTo(Win(), Keys.VK_ESCAPE), false, "ESC passes through while closed")
	OpenWindow()
	Win().Controls.CloseButton:Click()
	H.eq(WindowOpen(), false, "close button")
	OpenWindow()
	FAKE_TX.Hotseat(2)
	H.eq(WindowOpen(), false, "hand-off")
	OpenWindow()
	LuaEvents.DiplomacyActionView_HideIngameUI()
	H.eq(WindowOpen(), false, "diplomacy screen")
	OpenWindow()
	Launch().LaunchItemButton:Click()
	H.eq(WindowOpen(), false, "the launch button toggles")
	LuaEvents.TX_OpenTeamWindow()
	H.eq(WindowOpen(), true, "LuaEvents.TX_OpenTeamWindow opens it")
	H.clean()
end)

test("ui 12b: the open window follows gameplay through the rev poll and shows the vote to the next hot seat player", function()
	Setup()
	OpenWindow()
	GPropose(0, 1)
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_NO_VOTE"), "not rebuilt before the poll")
	FAKE_UI.Update(Win(), 0.2)
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_NO_VOTE"), "poll interval not reached")
	FAKE_UI.Update(Win(), 0.4)
	H.eq(Win().Controls.VoteLabel.text, T("LOC_TX_VOTE_LINE", Label(0), Label(1), 5, SoftS()), "rebuilt on the TX_Rev change")
	H.clean()
end)

-- ===========================================================================
-- UI rules: read-only, flat requests, shared helpers
-- ===========================================================================
test("ui rules: viewing never writes a property; every request is flat; FAKE.forbidden stays empty", function()
	Setup()
	local writes = FAKE.DeepCopy(FAKE.propWrites)
	local rev = Rev()
	OpenWindow()
	FAKE_TX.Hotseat(1)
	OpenWindow()
	FAKE_TX.Hotseat(3)
	OpenWindow()
	Events.PlayerTurnActivated(3, true)
	H.deq(FAKE.propWrites, writes, "the UI wrote nothing")
	H.eq(Rev(), rev)
	FAKE_TX.Hotseat(0)
	OpenWindow()
	Kick(1).confirm()
	FAKE_TX.Hotseat(2)
	FAKE_TX.Activate(2, VOTE_N)
	Pop().Controls.NoButton:Click()
	H.len(FAKE_UI.requests, 2)
	for _, r in ipairs(FAKE_UI.requests) do
		H.eq(r.op, PlayerOperations.EXECUTE_SCRIPT)
		for k, v in pairs(r.params) do
			H.eq(type(k), "string")
			H.ok(type(v) == "number" or type(v) == "string", "flat value " .. tostring(k))
		end
	end
	H.len(FAKE.forbidden, 0)
	H.clean()
end)

test("ui shared: World uses the config team, LiveTeam the stale UI team; Label, PortraitIcon, ReasonText, Hash, IsHost, NetMP", function()
	Setup()
	PlayerConfigurations[1]:SetTeam(6)
	local w = TX_UI.World()
	H.eq(TX_Votes.TeamOf(w, 1), 6, "config team (what gameplay reads)")
	H.eq(TX_UI.LiveTeam(1), 0, "UI live team stale until a load (F3)")
	H.eq(TX_Votes.TeamOf(w, 9), -1, "empty slot")
	H.eq(#w.slots, 64)
	H.eq(TX_UI.Label(2), Label(2))
	H.eq(TX_UI.Label(-1), T("LOC_TX_PLAYER_GENERIC"))
	PlayerConfigurations[3].GetLeaderName = function() error("probe") end
	H.eq(TX_UI.Label(3), T("LOC_TX_PLAYER_GENERIC"), "fallback when a config read fails")
	H.eq(TX_UI.PortraitIcon(4), "ICON_LEADER_FAKE_4")
	H.eq(TX_UI.ReasonText({ "VOTE_OPEN", "VICTORY", "VOTE_OPEN" }),
		T("LOC_TX_REASON_VOTE_OPEN") .. "[NEWLINE]" .. T("LOC_TX_REASON_VICTORY"), "each code once")
	H.eq(TX_UI.ReasonText({}), "")
	H.eq(TX_UI.Hash(VOTE_N), GameInfo.Types[VOTE_N].Hash)
	H.isnil(TX_UI.Hash("NOTIFICATION_TX_NOPE"))
	H.eq(TX_UI.IsHost(), true)
	H.eq(TX_UI.NetMP(), false)
	FAKE_TX.netMP = true
	FAKE_TX.host = false
	H.eq(TX_UI.IsHost(), false)
	H.eq(TX_UI.NetMP(), true)
	H.clean()
end)

test("ui shared: Request flattens booleans, refuses without a local player; ReadStore caches on (TX_Rev, turn)", function()
	Setup()
	H.eq(TX_UI.Request("TX_Propose", { targetID = 1, mode = "SOFT", extra = true }), true)
	H.deq(Requests("TX_Propose")[1].params, { OnStart = "TX_Propose", targetID = 1, mode = "SOFT", extra = 1 })
	FAKE.localPlayer = -1
	H.eq(TX_UI.Request("TX_Propose", { targetID = 2 }), false)
	H.len(Requests("TX_Propose"), 1, "not sent without a local player")
	H.ok(H.hasLine("[UIRequest] ERROR TX_Propose not sent: no local player"))
	FAKE.localPlayer = 0
	local s1 = TX_UI.ReadStore()
	H.eq(TX_UI.ReadStore(), s1, "cached while TX_Rev and the turn stay")
	GVote(2, 1, "YES")
	H.ok(TX_UI.ReadStore() ~= s1, "re-read after a commit")
	H.eq(TX_Store.Get(TX_UI.ReadStore(), 1).state, "PENDING_APPLY")
end, { allowErrors = true })

test("ui shared: Sweep touches only its type with a record id, keeps the newest per record", function()
	Setup()
	GPropose(0, 1)
	GTurn()
	H.request(0, { OnStart = "TX_Propose", targetID = 9 })   -- REQUEST_FAILED for P0, no record id
	local kept = TX_UI.Sweep(2, PASSED_N, function() return false end)
	H.eq(kept, 0, "no copy of another type")
	H.eq(TX_UI.Sweep(-1, VOTE_N, function() return true end), 0)
	local n = TX_UI.Sweep(2, VOTE_N, function(rec) return rec.state == "OPEN" end)
	H.eq(n, 1, "one older copy")
	H.eq(TX_UI.Sweep(0, FAILED_N, function() return false end), 0, "a copy without TX_RecordID is never touched")
	H.len(H.notifs(0, FAILED_N), 1)
	H.ok(not H.notifs(0, FAILED_N)[1].dismissed)
	H.clean()
end)

test("ui xml: every instance control the Lua touches has an ID in the paired XML (the fake would auto-create it)", function()
	local pairsList = {
		{ lua = "TX/UI/TX_TeamWindow.lua", xml = "TX/UI/TX_TeamWindow.xml", vars = { "inst", "m_LaunchInst", "m_PinInst" } },
		{ lua = "TX/UI/TX_VotePopup.lua", xml = "TX/UI/TX_VotePopup.xml", vars = {} },
		{ lua = "TX/UI/TX_ApplyBanner.lua", xml = "TX/UI/TX_ApplyBanner.xml", vars = {} },
	}
	local checked = 0
	for _, p in ipairs(pairsList) do
		local src, xml = __py_read(p.lua), __py_read(p.xml)
		H.notnil(src, p.lua)
		H.notnil(xml, p.xml)
		for _, var in ipairs(p.vars) do
			for name in string.gmatch(src, "[^%w_]" .. var .. "%.([%a_][%w_]*)") do
				H.ok(string.find(xml, 'ID="' .. name .. '"', 1, true) ~= nil, p.lua .. ": " .. var .. "." .. name .. " has no ID in " .. p.xml)
				checked = checked + 1
			end
		end
		-- Controls.X is checked by tools/validate_data.py; repeat it here for the three contexts
		for name in string.gmatch(src, "Controls%.([%a_][%w_]*)") do
			H.ok(string.find(xml, 'ID="' .. name .. '"', 1, true) ~= nil, p.lua .. ": Controls." .. name)
			checked = checked + 1
		end
	end
	H.ok(checked > 20, "names checked: " .. checked)
end)
