-- ===========================================================================
-- TX_TeamWindow.lua  (Team Kick 1.0.0)
-- TX:CONTEXT UI
--
-- Context of TX_TeamWindow.xml (AddUserInterfaces, Context InGame; PLAN
-- II.11a). Controls: TeamPanel (TeamWindowFrame, WindowTitle, CloseButton,
-- MainStack, MembersHeader, MembersStack, VoteHeader, VoteSection, VoteLabel,
-- VoterStack, VoteButton, HistoryHeader, HistoryArea, HistoryScroll,
-- HistoryStack, HistoryEmptyLabel); instances TX_MemberRow (MemberRoot,
-- Portrait, NameLabel, KickButton), TX_VoterRow (VoterRoot, VoterLabel),
-- TX_HistoryRow (HistoryButton, HistoryLabel), TX_LaunchBarItem
-- (LaunchItemButton, LaunchItemLabel, AlertIndicator), TX_LaunchBarPin (Pin).
--
-- For the LOCAL player, read at the moment of use (TX_UI.Local(); hotseat):
--   * launch-bar "Team" button (attached once on LoadGameViewStateDone,
--     EFV_Tracker.lua:209-229; TX_Dev_Panel.lua:2208-2226), shown only while
--     TX_Votes.CanSeeTeamButton (human living major on a team of 2+, TP 2.3);
--     hidden with SetHide on the button and its pin, then the backing resize
--     (EFV_Tracker.lua:182-195; base LaunchBar.lua:302-327, 498-518). Alert
--     pip and a tooltip line while the local player has a vote to cast or the
--     team has a passed kick waiting;
--   * the window (EFV_Tracker.lua:465-494 open / close / toggle):
--       1. members: the local player first "(you)", then ascending, ", AI"
--          for AI; a Kick button on every other member, enabled iff
--          TX_Votes.ProposeReasons is empty, else the reason texts as the
--          tooltip (the target of an open vote sees TEAM_BUSY only);
--       2. the open vote, only when TX_Votes.VisibleTo (never for its
--          target, DEC 2): who started it, who voted, who has not (never yes
--          or no while open, TP 2.3); a Vote button for a pending local voter
--          (LuaEvents.TX_OpenVote -> TX_VotePopup). A passed kick: passed /
--          applied line; every line names the kick mode;
--       3. history: VisibleTo records of the team, newest first, at most
--          TX_Config.HISTORY_SHOWN; tooltip: who started it, the reason, each
--          vote (the records are closed by then).
--   * Kick -> PopupDialogInGame confirm (EFV_UnitActions.lua:260-268) with the
--     TX_Votes.ConfirmKind text (VOTE / DISSOLVE for a team of 2 / AI_ONLY),
--     one line per kick mode (LOC_TX_MODE_LINE) and LOC_TX_CONFIRM_AFTER.
--     Buttons (DEC 2026-10-04 kick modes): Soft kick (the confirm button, the
--     default), Hard kick (PopupDialogInGame:AddCustomButton, only while
--     TX_Config.HARD_KICK_ENABLED), Cancel. A mode button sends TX_Propose
--     { targetID, mode } only if the local player is still the one who
--     clicked (hotseat hand-off). The open vote, the passed / applied line
--     and the history rows name the record's mode.
-- Refresh: LoadGameViewStateDone, the local PlayerTurnActivated,
-- LocalPlayerChanged, NotificationAdded for the local player, and a
-- (TX_Rev, turn, local) poll while the window is open (EFV_Tracker.lua:444-455).
-- Closes on ESC, the close button, LocalPlayerTurnEnd, LocalPlayerChanged and
-- DiplomacyActionView_HideIngameUI (EFV_DestinationPicker.lua:333-343).
-- LuaEvents.TX_OpenTeamWindow() opens it (the vote popup's fallback).
--
-- The UI only displays and sends flat requests; gameplay re-validates
-- everything (TP 2.5). Engine calls: PLAN Appendix B (launch bar,
-- PopupDialogInGame, InstanceManager, ContextPtr, controls, UI.PlaySound,
-- Image:SetIcon on Leaders45) plus the TX_UIShared ones.
-- ===========================================================================

include("InstanceManager")
include("PopupDialog")
include("TX_UIShared")

local LOG_TAG = "UITeam"
local POLL_SECONDS = 0.5            -- (TX_Rev, turn, local) poll while open (EFV_Tracker.lua:70)

local ST, V = TX_Config.ST, TX_Config.V
local L = TX_UI.L
local Str = TX_Util.Str

-- Instance managers (EFV_Tracker.lua:73).
local m_MemberIM = InstanceManager:new("TX_MemberRow", "MemberRoot", Controls.MembersStack)
local m_VoterIM = InstanceManager:new("TX_VoterRow", "VoterRoot", Controls.VoterStack)
local m_HistoryIM = InstanceManager:new("TX_HistoryRow", "HistoryButton", Controls.HistoryStack)

local m_Open = false                -- window open flag (never ContextPtr:IsHidden, EFV_Tracker.lua:79)
local m_ViewReady = false           -- set on LoadGameViewStateDone (EFV_Tracker.lua:93-97)
local m_LaunchAttached = false      -- double-attach guard (EFV_Tracker.lua:74)
local m_LaunchInst = nil            -- TX_LaunchBarItem instance
local m_PinInst = nil               -- TX_LaunchBarPin instance
local m_ButtonShown = nil           -- last visibility given to the button (nil: not yet)
local m_Last = { rev = -1, turn = -1, localID = -2 }   -- key of the last window rebuild
local m_PollElapsed = 0
local m_VoteRecID = nil             -- record the Vote button opens

local function Log(level, fmt, ...)
	TX_Util.Log(level, LOG_TAG, fmt, ...)
end

local function PlaySound(name)
	pcall(function() UI.PlaySound(name) end)
end

-- ---------------------------------------------------------------------------
-- View helpers (pure over the store, the world and the local player)
-- ---------------------------------------------------------------------------
-- The team's active record when the viewer may see it (TX_Votes.VisibleTo:
-- an OPEN vote is never shown to its target, DEC 2), else nil.
local function VisibleActive(store, me, team)
	local rec = TX_Votes.Active(store, team)
	if rec ~= nil and TX_Votes.VisibleTo(rec, me, team) then
		return rec
	end
	return nil
end

-- True when me has a vote to cast in the team's open vote.
local function IsPendingVoter(store, world, me, rec)
	if rec == nil or rec.state ~= ST.OPEN then
		return false
	end
	return #TX_Votes.VoteReasons(store, world, me, rec.id, V.YES) == 0
end

-- Member order: the local player first, then ascending (PLAN II.11a item 1).
local function MemberOrder(world, team, me)
	local out = {}
	local members = TX_Votes.Members(world, team)
	for _, pid in ipairs(members) do
		if pid == me then
			out[#out + 1] = pid
		end
	end
	for _, pid in ipairs(members) do
		if pid ~= me then
			out[#out + 1] = pid
		end
	end
	return out
end

local function MemberText(world, pid, me)
	local label = TX_UI.Label(pid)
	if pid == me then
		return L("LOC_TX_MEMBER_YOU", label)
	end
	local s = TX_Votes.Slot(world, pid)
	if s ~= nil and s.human ~= 1 then
		return L("LOC_TX_MEMBER_AI", label)
	end
	return label
end

-- Voter row text of an OPEN record: started / voted / not voted yet /
-- eliminated. Never the yes or no value while the vote is open (TP 2.3).
local function VoterText(rec, e)
	local label = TX_UI.Label(e.pid)
	if e.pid == rec.proposerID then
		return L("LOC_TX_VOTER_PROPOSER", label)
	end
	if e.v == V.GONE then
		return L("LOC_TX_VOTER_GONE", label)
	end
	if e.v == V.PENDING then
		return L("LOC_TX_VOTER_PENDING", label)
	end
	return L("LOC_TX_VOTER_VOTED", label)
end

-- History row key per state (PASSED is the short step before PENDING_APPLY).
local HIST_KEY = {
	DONE = "LOC_TX_HIST_DONE",
	PENDING_APPLY = "LOC_TX_HIST_PENDING_APPLY",
	PASSED = "LOC_TX_HIST_PENDING_APPLY",
	FAILED = "LOC_TX_HIST_FAILED",
	EXPIRED = "LOC_TX_HIST_EXPIRED",
	CANCELLED = "LOC_TX_HIST_CANCELLED",
}

local function HistoryTurn(rec)
	if rec.state == ST.DONE and type(rec.doneTurn) == "number" then
		return rec.doneTurn
	end
	if type(rec.closedTurn) == "number" then
		return rec.closedTurn
	end
	return rec.openedTurn or 0
end

-- Tooltip of a history row: who started it, the reason (FAILED, CANCELLED)
-- and each vote. History rows are never OPEN, so the votes may show (TP 2.3).
local function HistoryTooltip(rec)
	local lines = { L("LOC_TX_HIST_STARTED_BY", TX_UI.Label(rec.proposerID)) }
	if type(rec.reason) == "string" and rec.reason ~= "" then
		lines[#lines + 1] = L("LOC_TX_REASON_" .. rec.reason)
	end
	for _, e in ipairs(rec.voters or {}) do
		local label = TX_UI.Label(e.pid)
		if e.v == V.YES then
			lines[#lines + 1] = L("LOC_TX_HIST_VOTE_YES", label)
		elseif e.v == V.NO then
			lines[#lines + 1] = L("LOC_TX_HIST_VOTE_NO", label)
		else
			lines[#lines + 1] = L("LOC_TX_HIST_VOTE_NONE", label)
		end
	end
	return table.concat(lines, "[NEWLINE]")
end

-- History records for the viewer, newest first, at most HISTORY_SHOWN.
local function HistoryRecords(store, me, team)
	local out = {}
	local recs = TX_Store.Records(store)
	for i = #recs, 1, -1 do
		local rec = recs[i]
		if rec.state ~= ST.OPEN and HIST_KEY[rec.state] ~= nil and TX_Votes.VisibleTo(rec, me, team) then
			out[#out + 1] = rec
			if #out >= TX_Config.HISTORY_SHOWN then
				break
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Launch-bar button
-- ---------------------------------------------------------------------------
-- RealizeLaunchBacking(): ButtonStack:CalculateSize(); LaunchBacking w + 116;
-- LaunchBackingTile w - 20; LuaEvents.LaunchBar_Resize(w)
-- (EFV_Tracker.lua:182-195; LaunchBar.lua:498-517 math).
local function RealizeLaunchBacking()
	local ok, err = pcall(function()
		local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
		buttonStack:CalculateSize()
		local w = buttonStack:GetSizeX()
		ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking"):SetSizeX(w + 116)
		ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile"):SetSizeX(w - 20)
		LuaEvents.LaunchBar_Resize(w)
	end)
	if not ok then
		Log(1, "launch bar resize failed: %s", Str(err))
	end
	return ok
end

local Toggle -- forward
local Close  -- forward

-- AttachLaunchButton(): once; TX_LaunchBarItem and TX_LaunchBarPin built into
-- /InGame/LaunchBar/ButtonStack (EFV_Tracker.lua:209-229;
-- TX_Dev_Panel.lua:2208-2226). A failure is logged once; LuaEvents
-- .TX_OpenTeamWindow (vote popup fallback) still opens the window.
local function AttachLaunchButton()
	if m_LaunchAttached then
		return
	end
	m_LaunchAttached = true
	local inst, pin = {}, {}
	local ok, err = pcall(function()
		local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
		ContextPtr:BuildInstanceForControl("TX_LaunchBarItem", inst, buttonStack)
		inst.LaunchItemButton:RegisterCallback(Mouse.eLClick, function() Toggle() end)
		ContextPtr:BuildInstanceForControl("TX_LaunchBarPin", pin, buttonStack)
	end)
	if ok then
		m_LaunchInst = inst
		m_PinInst = pin
		m_ButtonShown = nil
		Log(2, "launch bar button attached")
	else
		Log(1, "launch bar button attach failed: %s", Str(err))
	end
end

-- RefreshButton(): show the button iff TX_Votes.CanSeeTeamButton for the
-- local player now; alert pip and tooltip line for a pending local voter or
-- a passed kick of the team. Closes the window when the button goes away.
local function RefreshButton()
	local me = TX_UI.Local()
	local world = TX_UI.World()
	local show = TX_Votes.CanSeeTeamButton(world, me)
	if not show and m_Open then
		Close()
	end
	if m_LaunchInst == nil then
		return show
	end
	local ok, err = pcall(function()
		m_LaunchInst.LaunchItemButton:SetHide(not show)
		if m_PinInst ~= nil and m_PinInst.Pin ~= nil then
			m_PinInst.Pin:SetHide(not show)
		end
		local alert = false
		local lines = { L("LOC_TX_LAUNCH_TT") }
		if show then
			local store = TX_UI.ReadStore()
			local team = TX_Votes.TeamOf(world, me)
			local rec = VisibleActive(store, me, team)
			if IsPendingVoter(store, world, me, rec) then
				alert = true
				lines[#lines + 1] = L("LOC_TX_LAUNCH_TT_VOTE")
			elseif rec ~= nil and rec.state == ST.PENDING_APPLY then
				alert = true
				if rec.applied == 1 then
					lines[#lines + 1] = L("LOC_TX_APPLIED_LINE", TX_UI.Label(rec.targetID), TX_UI.ModeShort(rec))
				else
					lines[#lines + 1] = L("LOC_TX_PASSED_LINE", TX_UI.Label(rec.targetID), TX_UI.ModeShort(rec))
				end
			end
		end
		m_LaunchInst.AlertIndicator:SetHide(not alert)
		m_LaunchInst.LaunchItemButton:SetToolTipString(table.concat(lines, "[NEWLINE]"))
	end)
	if not ok then
		Log(1, "launch button refresh failed: %s", Str(err))
	end
	if m_ButtonShown ~= show then
		m_ButtonShown = show
		RealizeLaunchBacking()
		Log(3, "launch button %s for P%d", show and "shown" or "hidden", me)
	end
	return show
end

-- ---------------------------------------------------------------------------
-- Kick: confirm, then TX_Propose
-- ---------------------------------------------------------------------------
local RefreshWindow -- forward

-- ConfirmText(world, me, targetID) -> confirm text for TX_Votes.ConfirmKind
-- (TP 2.3 wording), one LOC_TX_MODE_LINE per offered mode (TX_Votes.Modes),
-- then LOC_TX_CONFIRM_AFTER.
local function ConfirmText(world, me, targetID)
	local kind = TX_Votes.ConfirmKind(world, me, targetID)
	local label = TX_UI.Label(targetID)
	local text
	if kind == TX_Votes.KIND_DISSOLVE then
		text = L("LOC_TX_CONFIRM_DISSOLVE", label)
	elseif kind == TX_Votes.KIND_AI_ONLY then
		text = L("LOC_TX_CONFIRM_AI_ONLY", label)
	else
		text = L("LOC_TX_CONFIRM_VOTE", label, TX_Config.VOTE_TURNS)
	end
	local modes = {}
	for _, mode in ipairs(TX_Votes.Modes()) do
		modes[#modes + 1] = TX_UI.ModeLine(mode)
	end
	return text .. "[NEWLINE][NEWLINE]" .. table.concat(modes, "[NEWLINE][NEWLINE]") .. "[NEWLINE][NEWLINE]" .. L("LOC_TX_CONFIRM_AFTER"), kind
end

-- OnKickClicked(targetID): re-check for the display, then PopupDialogInGame
-- (EFV_UnitActions.lua:260-268). Soft kick (confirm button, the default) or
-- Hard kick (AddCustomButton, BASE24 Popups/PopupDialog.lua:497-499): TX_Propose
-- { targetID, mode }, only while the local player is still the one who
-- clicked (hotseat hand-off between the click and the answer sends nothing).
-- Cancel sends nothing.
local function OnKickClicked(targetID)
	local clicker = TX_UI.Local()
	local world = TX_UI.World()
	local store = TX_UI.ReadStore()
	local codes = TX_Votes.ProposeReasons(store, world, clicker, targetID)
	if #codes > 0 then
		Log(2, "kick P%s by P%d not offered: %s", Str(targetID), clicker, table.concat(codes, ","))
		RefreshWindow(true)
		return
	end
	local text, kind = ConfirmText(world, clicker, targetID)
	Log(2, "kick P%s by P%d: confirm %s", Str(targetID), clicker, kind)
	local popup = PopupDialogInGame:new("TX_ConfirmKick")
	popup:AddTitle(L("LOC_TX_CONFIRM_TITLE"))
	popup:AddText(text)
	local function Send(mode)
		local now = TX_UI.Local()
		if now ~= clicker then
			Log(2, "kick P%s not sent: the local player changed from P%d to P%d", Str(targetID), clicker, now)
			return
		end
		TX_UI.Request(TX_Config.REQ_PROPOSE, { targetID = targetID, mode = mode })
		RefreshWindow(true)
		RefreshButton()
	end
	popup:AddConfirmButton(L("LOC_TX_MODE_SOFT"), function() Send(TX_Config.MODE.SOFT) end)
	if TX_Config.HARD_KICK_ENABLED == true then
		-- Session 4 step 3: PopupDialogInGame has no AddButton (that is PopupDialog), so the
		-- Hard kick button never showed. PopupDialogInGame:AddCustomButton(label, callback)
		-- is its click-only button (BASE24 Popups/PopupDialog.lua:497-499). Still a probe.
		TX_UI.TryProbe("UI PopupDialogInGame:AddCustomButton", function()
			popup:AddCustomButton(L("LOC_TX_MODE_HARD"), function() Send(TX_Config.MODE.HARD) end)
		end)
	end
	-- Session 4: three buttons in one row ran past the dialog. Base PopupDialog puts
	-- buttons that follow each other in one row and starts a new row after a text
	-- (PopupDialog.lua:159, 183-190), so an empty text puts Cancel on its own row.
	popup:AddText("")
	popup:AddCancelButton(L("LOC_TX_CANCEL"), nil)
	popup:Open()
end

local function OnVoteClicked()
	local id = m_VoteRecID
	if id == nil then
		return
	end
	Log(2, "vote button rec=%d P%d", id, TX_UI.Local())
	LuaEvents.TX_OpenVote(id)
end

-- ---------------------------------------------------------------------------
-- Window content
-- ---------------------------------------------------------------------------
local function FillMembers(store, world, me, team)
	m_MemberIM:ResetInstances()
	for _, pid in ipairs(MemberOrder(world, team, me)) do
		local inst = m_MemberIM:GetInstance()
		local icon = TX_UI.PortraitIcon(pid)
		if icon ~= nil then
			pcall(function() inst.Portrait:SetIcon(icon) end)
		end
		inst.NameLabel:SetText(MemberText(world, pid, me))
		if pid == me then
			inst.KickButton:SetHide(true)
		else
			local label = TX_UI.Label(pid)
			local codes = TX_Votes.ProposeReasons(store, world, me, pid)
			inst.KickButton:SetHide(false)
			inst.KickButton:SetDisabled(#codes > 0)
			if #codes > 0 then
				inst.KickButton:SetToolTipString(TX_UI.ReasonText(codes))
			else
				inst.KickButton:SetToolTipString(L("LOC_TX_KICK_TT", label))
			end
			local target = pid
			inst.KickButton:RegisterCallback(Mouse.eLClick, function() OnKickClicked(target) end)
		end
	end
	Controls.MembersStack:CalculateSize()
end

local function FillVote(store, world, me, team)
	m_VoterIM:ResetInstances()
	m_VoteRecID = nil
	local rec = VisibleActive(store, me, team)
	local showButton = false
	if rec == nil then
		Controls.VoteLabel:SetText(L("LOC_TX_NO_VOTE"))
	elseif rec.state == ST.OPEN then
		Controls.VoteLabel:SetText(L("LOC_TX_VOTE_LINE", TX_UI.Label(rec.proposerID), TX_UI.Label(rec.targetID),
			TX_Votes.TurnsLeft(rec, TX_UI.Turn()), TX_UI.ModeShort(rec)))
		for _, e in ipairs(rec.voters or {}) do
			local inst = m_VoterIM:GetInstance()
			inst.VoterLabel:SetText(VoterText(rec, e))
		end
		if IsPendingVoter(store, world, me, rec) then
			showButton = true
			m_VoteRecID = rec.id
		end
	elseif rec.applied == 1 then
		Controls.VoteLabel:SetText(L("LOC_TX_APPLIED_LINE", TX_UI.Label(rec.targetID), TX_UI.ModeShort(rec)))
	else
		Controls.VoteLabel:SetText(L("LOC_TX_PASSED_LINE", TX_UI.Label(rec.targetID), TX_UI.ModeShort(rec)))
	end
	Controls.VoteButton:SetHide(not showButton)
	Controls.VoterStack:CalculateSize()
	Controls.VoteSection:CalculateSize()
end

local function FillHistory(store, me, team)
	m_HistoryIM:ResetInstances()
	local recs = HistoryRecords(store, me, team)
	for _, rec in ipairs(recs) do
		local inst = m_HistoryIM:GetInstance()
		inst.HistoryLabel:SetText(L(HIST_KEY[rec.state], HistoryTurn(rec), TX_UI.Label(rec.targetID), TX_UI.ModeShort(rec)))
		inst.HistoryButton:SetToolTipString(HistoryTooltip(rec))
	end
	Controls.HistoryEmptyLabel:SetHide(#recs > 0)
	Controls.HistoryStack:CalculateSize()
	Controls.HistoryScroll:CalculateSize()
	return #recs
end

-- RefreshWindow(force): rebuild while open when forced or when (TX_Rev,
-- turn, local player) changed (EFV_Tracker.lua:330-369). Closes the window
-- when the local player may no longer see the Team button.
RefreshWindow = function(force)
	if not m_Open then
		return
	end
	local me = TX_UI.Local()
	local rev, turn = TX_UI.Rev(), TX_UI.Turn()
	if not force and rev == m_Last.rev and turn == m_Last.turn and me == m_Last.localID then
		return
	end
	m_Last = { rev = rev, turn = turn, localID = me }
	local world = TX_UI.World()
	if not TX_Votes.CanSeeTeamButton(world, me) then
		Close()
		return
	end
	local store = TX_UI.ReadStore()
	local team = TX_Votes.TeamOf(world, me)
	FillMembers(store, world, me, team)
	FillVote(store, world, me, team)
	local n = FillHistory(store, me, team)
	Controls.MainStack:CalculateSize()
	Log(3, "window P%d team=%d rev=%d turn=%d history=%d", me, team, rev, turn, n)
end

-- ---------------------------------------------------------------------------
-- Open / close / toggle (EFV_Tracker.lua:465-494)
-- ---------------------------------------------------------------------------
local function OnUpdate(fDTime)
	m_PollElapsed = m_PollElapsed + (tonumber(fDTime) or 0)
	if m_PollElapsed < POLL_SECONDS then
		return
	end
	m_PollElapsed = 0
	local rev = m_Last.rev
	RefreshWindow(false)
	if m_Last.rev ~= rev then
		RefreshButton()
	end
end

local function Open()
	local me = TX_UI.Local()
	if not TX_Votes.CanSeeTeamButton(TX_UI.World(), me) then
		Log(3, "open ignored: P%d has no team to show", me)
		return
	end
	ContextPtr:SetHide(false)
	m_Open = true
	Controls.TeamPanel:SetHide(false)
	PlaySound("UI_Screen_Open")
	RefreshWindow(true)
	RefreshButton()
	m_PollElapsed = 0
	ContextPtr:SetUpdate(OnUpdate)
	Log(3, "opened for P%d", me)
end

Close = function()
	if not m_Open then
		return
	end
	m_Open = false
	ContextPtr:ClearUpdate()
	Controls.TeamPanel:SetHide(true)
	PlaySound("UI_Screen_Close")
	Log(3, "closed")
end

Toggle = function()
	if m_Open then
		Close()
	else
		Open()
	end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
-- ESC closes the window; input passes through while it is closed
-- (EFV_Tracker.lua:697-706).
local function OnInput(pInput)
	if not m_Open then
		return false
	end
	if pInput:GetMessageType() == KeyEvents.KeyUp and pInput:GetKey() == Keys.VK_ESCAPE then
		Close()
		return true
	end
	return false
end

local function OnLoadGameViewStateDone()
	m_ViewReady = true
	AttachLaunchButton()
	RefreshButton()
end

local function OnPlayerTurnActivated(pid)
	if pid ~= TX_UI.Local() then
		return
	end
	RefreshButton()
	RefreshWindow(false)
end

-- Hotseat hand-off: the window belongs to the player who opened it.
local function OnLocalPlayerChanged()
	Close()
	RefreshButton()
end

-- A TX notification for the local player can change the alert pip. Replays
-- before LoadGameViewStateDone are ignored (EFV_Tracker.lua:635-644).
local function OnNotificationAdded(pid)
	if not m_ViewReady or pid ~= TX_UI.Local() then
		return
	end
	RefreshButton()
	RefreshWindow(false)
end

local function OnCloseTrigger()
	Close()
end

-- ---------------------------------------------------------------------------
-- Initialize(): event wiring. AddUserInterfaces contexts load HIDDEN (PB 3;
-- EFV_Tracker.lua:708-744): the context is shown here and the open state is
-- the TeamPanel control plus the m_Open flag.
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)
	Controls.TeamPanel:SetHide(true)
	Controls.VoteButton:SetHide(true)
	ContextPtr:SetInputHandler(OnInput, true)
	Controls.CloseButton:RegisterCallback(Mouse.eLClick, OnCloseTrigger)
	Controls.VoteButton:RegisterCallback(Mouse.eLClick, OnVoteClicked)
	Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
	Events.PlayerTurnActivated.Add(OnPlayerTurnActivated)
	Events.LocalPlayerChanged.Add(OnLocalPlayerChanged)
	Events.LocalPlayerTurnEnd.Add(OnCloseTrigger)
	Events.NotificationAdded.Add(OnNotificationAdded)
	LuaEvents.DiplomacyActionView_HideIngameUI.Add(OnCloseTrigger)
	LuaEvents.TX_OpenTeamWindow.Add(Open)
	Log(2, "initialized")
end

Initialize()
