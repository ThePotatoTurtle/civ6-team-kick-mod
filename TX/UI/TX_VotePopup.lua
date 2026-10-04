-- ===========================================================================
-- TX_VotePopup.lua  (Team Expulsion 0.1.0)
-- TX:CONTEXT UI
--
-- Context of TX_VotePopup.xml (AddUserInterfaces, Context InGame; PLAN
-- II.11b). Controls: PopupRoot, PopupWindow, PopupTitle, CloseButton,
-- BodyLabel, ButtonStack, YesButton, NoButton, LaterButton.
--
-- The one voting UI (PLAN II.18 item 6). Modal: UIManager:QueuePopup(
-- ContextPtr, PopupPriority.Medium) (EFV_DestinationPicker.lua:111-127,
-- 265-297).
--   * Open(recID): only when the local player has a vote to cast in that
--     OPEN record (TX_Votes.VoteReasons empty). Remembers the voter
--     (m_Voter) and the record (m_RecID); LOC_TX_POPUP_TEXT {proposer,
--     target, turns left}. Otherwise LuaEvents.TX_OpenTeamWindow() instead.
--   * Yes / No: if TX_UI.Local() is no longer m_Voter (hotseat hand-off),
--     close and send nothing; else TX_Vote { recordID, vote = YES | NO }
--     and close. Later: close.
--   * Entry points: Events.NotificationActivated(pid, nid, byUser) for the
--     local player and a NOTIFICATION_TX_VOTE_REQUIRED (XP2-20
--     GovernorPanel.lua:414-426; HistoricMoments.lua:136-150; PROBE for a
--     custom type, see TX_UI.ActivatedRecord), and LuaEvents.TX_OpenVote(recID)
--     from the Team window's Vote button.
--   * Closes when the record leaves OPEN or the local player no longer has a
--     vote (TX_Rev poll), on ESC, the close button, LocalPlayerTurnEnd,
--     LocalPlayerChanged (hotseat) and DiplomacyActionView_HideIngameUI
--     (EFV_DestinationPicker.lua:319-343).
--   * Sweeps the local player's VOTE_REQUIRED copies (keep the newest per
--     record while it is OPEN and the local player still has to vote; PLAN
--     II.7 persistence) on LoadGameViewStateDone, the local
--     PlayerTurnActivated, LocalPlayerChanged (hotseat hand-off: copies pile
--     up while another player has the seat), NotificationAdded of that type
--     after the view is ready, and right after a vote.
-- The UI only sends flat requests; gameplay re-validates the vote (TP 2.5).
-- ===========================================================================

include("TX_UIShared")

local LOG_TAG = "UIVote"
local POLL_SECONDS = 0.5            -- TX_Rev poll while open (EFV_Tracker.lua:70)

local ST, V = TX_Config.ST, TX_Config.V
local L = TX_UI.L
local Str = TX_Util.Str
local VOTE_TYPE = TX_Config.NOTIF.VOTE_REQUIRED

local m_Voter = nil                 -- local player the popup was opened for (nil: closed)
local m_RecID = nil                 -- record voted on
local m_ViewReady = false           -- set on LoadGameViewStateDone (EFV_Tracker.lua:93-97)
local m_PollElapsed = 0
local m_LastRev = -1

local function Log(level, fmt, ...)
	TX_Util.Log(level, LOG_TAG, fmt, ...)
end

-- Codes that stop pid from voting in recID now (empty: may vote).
local function VoteCodes(pid, recID)
	return TX_Votes.VoteReasons(TX_UI.ReadStore(), TX_UI.World(), pid, recID, V.YES)
end

-- ---------------------------------------------------------------------------
-- Sweep: VOTE_REQUIRED copies of the local player (TX_UI.Sweep). skipID: a
-- record just voted on (its copies go at once, before gameplay answers).
-- ---------------------------------------------------------------------------
local function SweepVotes(skipID)
	local me = TX_UI.Local()
	if me < 0 then
		return 0
	end
	local n = TX_UI.Sweep(me, VOTE_TYPE, function(rec)
		if rec.id == skipID or rec.state ~= ST.OPEN then
			return false
		end
		local e = TX_Votes.VoterEntry(rec, me)
		return e ~= nil and e.v == V.PENDING
	end)
	if n > 0 then
		Log(3, "swept %d vote notification(s) of P%d", n, me)
	end
	return n
end

-- ---------------------------------------------------------------------------
-- Close() (EFV_DestinationPicker.lua:111-127): dequeue, hide, forget the
-- voter. Safe when already closed.
-- ---------------------------------------------------------------------------
local function Close()
	local wasOpen = (m_Voter ~= nil)
	m_Voter = nil
	m_RecID = nil
	ContextPtr:ClearUpdate()
	pcall(function()
		if UIManager:IsInPopupQueue(ContextPtr) then
			UIManager:DequeuePopup(ContextPtr)
			UI.PlaySound("UI_Screen_Close")
		end
	end)
	Controls.PopupRoot:SetHide(true)
	if wasOpen then
		Log(3, "closed")
	end
end

-- TX_Rev poll while open: close once the record left OPEN or the voter has
-- no vote any more (voted elsewhere, eliminated, victory).
local function OnUpdate(fDTime)
	m_PollElapsed = m_PollElapsed + (tonumber(fDTime) or 0)
	if m_PollElapsed < POLL_SECONDS then
		return
	end
	m_PollElapsed = 0
	if m_Voter == nil then
		return
	end
	local rev = TX_UI.Rev()
	if rev == m_LastRev then
		return
	end
	m_LastRev = rev
	if TX_UI.Local() ~= m_Voter or #VoteCodes(m_Voter, m_RecID) > 0 then
		Log(3, "rec=%s no longer open for P%s: closing", Str(m_RecID), Str(m_Voter))
		Close()
	end
end

-- ---------------------------------------------------------------------------
-- Open(recID) (EFV_DestinationPicker.lua:265-297)
-- ---------------------------------------------------------------------------
local function Open(recID)
	local me = TX_UI.Local()
	if type(recID) ~= "number" then
		Log(2, "open ignored: no record id; Team window instead")
		LuaEvents.TX_OpenTeamWindow()
		return
	end
	local codes = VoteCodes(me, recID)
	if #codes > 0 then
		Log(2, "rec=%d: P%d has no vote to cast (%s); Team window instead", recID, me, table.concat(codes, ","))
		if m_Voter ~= nil then
			Close()
		end
		LuaEvents.TX_OpenTeamWindow()
		return
	end
	local rec = TX_Store.Get(TX_UI.ReadStore(), recID)
	m_Voter = me
	m_RecID = recID
	m_LastRev = TX_UI.Rev()
	Controls.BodyLabel:SetText(L("LOC_TX_POPUP_TEXT", TX_UI.Label(rec.proposerID), TX_UI.Label(rec.targetID),
		TX_Votes.TurnsLeft(rec, TX_UI.Turn())))
	ContextPtr:SetHide(false)
	Controls.PopupRoot:SetHide(false)
	if not UIManager:IsInPopupQueue(ContextPtr) then
		UIManager:QueuePopup(ContextPtr, PopupPriority.Medium)
		pcall(function() UI.PlaySound("UI_Screen_Open") end)
	end
	m_PollElapsed = 0
	ContextPtr:SetUpdate(OnUpdate)
	Log(2, "opened rec=%d for P%d", recID, me)
end

-- ---------------------------------------------------------------------------
-- Yes / No / Later
-- ---------------------------------------------------------------------------
local function SendVote(vote)
	local voter, recID = m_Voter, m_RecID
	if voter == nil then
		return
	end
	local now = TX_UI.Local()
	if now ~= voter then
		Log(2, "vote rec=%s not sent: the local player changed from P%d to P%d", Str(recID), voter, now)
		Close()
		return
	end
	Close()
	TX_UI.Request(TX_Config.REQ_VOTE, { recordID = recID, vote = vote })
	SweepVotes(recID)
end

local function OnYes()
	SendVote(V.YES)
end

local function OnNo()
	SendVote(V.NO)
end

local function OnLater()
	Close()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
-- A click on a VOTE_REQUIRED notification of the local player.
local function OnNotificationActivated(pid, nid, byUser)
	if pid ~= TX_UI.Local() then
		return
	end
	local matched, recID = TX_UI.ActivatedRecord(pid, nid, VOTE_TYPE)
	if not matched then
		return
	end
	Log(2, "vote notification %s activated by P%d rec=%s", Str(nid), pid, Str(recID))
	Open(recID)
end

local function OnNotificationAdded(pid, nid)
	if not m_ViewReady or pid ~= TX_UI.Local() then
		return
	end
	local ok, t = pcall(function()
		local p = NotificationManager.Find(pid, nid)
		if p == nil then
			return nil
		end
		return p:GetType()
	end)
	if ok and t ~= nil and t == TX_UI.Hash(VOTE_TYPE) then
		SweepVotes(nil)
	end
end

local function OnPlayerTurnActivated(pid)
	if m_ViewReady and pid == TX_UI.Local() then
		SweepVotes(nil)
	end
end

local function OnLoadGameViewStateDone()
	m_ViewReady = true
	SweepVotes(nil)
end

local function OnCloseTrigger()
	if m_Voter ~= nil then
		Close()
	end
end

-- Hotseat hand-off: the popup belongs to the previous player (close), and the
-- new local player's copies sent while another player had the seat are swept.
local function OnLocalPlayerChanged()
	OnCloseTrigger()
	if m_ViewReady then
		SweepVotes(nil)
	end
end

-- ESC closes the popup (EFV_DestinationPicker.lua:308-317).
local function OnInput(pInput)
	if m_Voter == nil then
		return false
	end
	if pInput:GetMessageType() == KeyEvents.KeyUp and pInput:GetKey() == Keys.VK_ESCAPE then
		Close()
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Initialize() (EFV_DestinationPicker.lua:333-343): contexts load HIDDEN
-- (PB 3), so the context is shown here; the open state is PopupRoot plus
-- m_Voter, never ContextPtr:IsHidden().
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)
	Controls.PopupRoot:SetHide(true)
	ContextPtr:SetInputHandler(OnInput, true)
	Controls.CloseButton:RegisterCallback(Mouse.eLClick, OnCloseTrigger)
	Controls.YesButton:RegisterCallback(Mouse.eLClick, OnYes)
	Controls.NoButton:RegisterCallback(Mouse.eLClick, OnNo)
	Controls.LaterButton:RegisterCallback(Mouse.eLClick, OnLater)
	Events.NotificationActivated.Add(OnNotificationActivated)
	Events.NotificationAdded.Add(OnNotificationAdded)
	Events.PlayerTurnActivated.Add(OnPlayerTurnActivated)
	Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
	Events.LocalPlayerTurnEnd.Add(OnCloseTrigger)
	Events.LocalPlayerChanged.Add(OnLocalPlayerChanged)
	LuaEvents.DiplomacyActionView_HideIngameUI.Add(OnCloseTrigger)
	LuaEvents.TX_OpenVote.Add(Open)
	Log(2, "initialized")
end

Initialize()
