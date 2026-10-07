-- ===========================================================================
-- TX_ApplyBanner.lua  (Team Kick 1.0.0)
-- TX:CONTEXT UI
--
-- Context of TX_ApplyBanner.xml (AddUserInterfaces, Context InGame; PLAN
-- II.9, II.11c). Controls: Banner, BannerButton, BannerLabel, ApplyButton.
-- The UI half of the apply seam (provisional Mode B, DEC 2026-10-04): the
-- host's UI writes the target's config team and broadcasts it, gameplay
-- confirms, the host's UI saves the game under a clear name (DEC
-- 2026-10-07), and everyone loads that save from the main menu.
--
--   * Banner for the local machine, first match over the PENDING_APPLY
--     records (ascending id):
--       1. written, not reloaded (the target's config team is newTeamID or
--          gameplay confirmed it, and its UI live team is not, F3):
--          LOC_TX_BANNER_SAVING while the kick save runs, LOC_TX_BANNER_SAVED
--          {name} once it is saved (this Lua state only), else
--          LOC_TX_BANNER_RELOAD, on every machine and for every local player;
--       2. applied = 0, the host (F7), no victory, and network apply allowed
--          (SEAM O4): LOC_TX_BANNER_HOST plus the Apply button;
--       3. applied = 0 otherwise: LOC_TX_BANNER_WAIT.
--     Hotseat: the machine is the host, so whoever has the turn may apply,
--     the target too (PLAN II.18 item 3).
--   * Apply (the button, or a KICK_PASSED click on the host):
--       1. re-check (ApplyCodes); a taken newTeamID gives
--          LOC_TX_APPLY_CONFLICT_TEXT (gameplay picks a new ID at the next
--          turn start);
--       2. confirm LOC_TX_APPLY_CONFIRM (+ _HARD for a hard kick, + _NETMP in network MP);
--       3. yes: re-check, then PlayerConfigurations[t]:SetTeam(newTeamID) and
--          Network.BroadcastPlayerInfo(t), the S3 call shapes proven in
--          Sessions 1 and 2 (TX_Dev_Panel.lua:639-660 S3Write; SR:133,
--          LOG:1151). The config team is read back; wrong: undo;
--       4. TX_ApplyDone { recordID, step = WRITTEN, team, attempt }, then a
--          wait in the update handler every WAIT_POLL s, up to WAIT_MAX s,
--          for applied = 1 (TX_Dev_Panel.lua:435-447, 2134-2172). attempt:
--          a new number per try, above this Lua state's last one and the
--          record's undoneAttempt;
--       5. answered: banner 1 from now on, and the kick save (StartSave,
--          host only): Network.SaveGame as TeamKick_<target>_T<turn>_<HHMM>,
--          then on Events.SaveComplete the blocking LOC_TX_SAVED_TITLE /
--          _TEXT_HOTSEAT / _NETMP / _LOCAL dialog with the name. A failed save
--          call or no SaveComplete within SAVE_MAX s: the manual
--          LOC_TX_RELOAD_TITLE / _TEXT dialog ("save and reload now");
--       6. no answer, a REQUEST_FAILED for the record (NOT_SEEN), or the
--          record left PENDING_APPLY: undo with SetTeam(old team) + broadcast
--          (TX_Dev S3 Undo, TX_Dev_Panel.lua:684-711) and
--          LOC_TX_APPLY_FAILED_TITLE / _TEXT. When WRITTEN was sent and the
--          record is still PENDING_APPLY, TX_ApplyDone { recordID, step =
--          UNDONE, attempt } follows: gameplay sets applied back to 0 (a slow
--          WRITTEN may have been accepted after the timeout) and refuses that
--          attempt's WRITTEN if it comes later, so both sides agree.
--   * Reload report: on LoadGameViewStateDone and the local
--     PlayerTurnActivated, every PENDING_APPLY record whose target's UI live
--     team is newTeamID (true only after a load, F3, F4) and not reported in
--     this Lua state: TX_ApplyDone { recordID, step = RELOADED, team }.
--     Gameplay checks its own read again and marks DONE (PLAN II.8).
--   * Victory report: Events.TeamVictory(team, victory, eventID)
--     (EndGameMenu.lua:1039, 1345) -> TX_Victory { team }, once per Lua
--     state (gameplay has no verified victory read, PLAN II.8).
--   * KICK_PASSED click: the host with an unapplied kick gets Apply, everybody
--     else the Team window. Sweeps KICK_PASSED copies (keep the newest per
--     record while it waits).
-- Refresh: LoadGameViewStateDone, the local PlayerTurnActivated,
-- LocalPlayerChanged, NotificationAdded for the local player, and a
-- (TX_Rev, turn, local player) poll in the update handler.
--
-- MP: SetTeam and BroadcastPlayerInfo run only here, only on the host, only
-- for a PENDING_APPLY record with applied 0 and no victory, and always lead to
-- the kick save, the reload dialog or the undo. The save runs only here, only
-- on the host, only after gameplay confirmed WRITTEN. No load, leave,
-- diplomacy or visibility call (PLAN II.12; why no load: "Kick save" below).
-- Gameplay re-validates every request (TP 2.5).
-- Engine calls (PLAN Appendix B, UI): PlayerConfigurations[t]:SetTeam,
-- :GetTeam, Network.BroadcastPlayerInfo (C, hotseat), Network.SaveGame,
-- Network.GetGameConfigurationSaveType, SaveLocations.LOCAL_STORAGE,
-- SaveFileTypes.GAME_STATE, Events.SaveComplete (C, TX_Dev R / RK save,
-- Session 3b, all through TX_UI.TryProbe), os.date (C, the same runs),
-- :GetCivilizationShortDescription (C), Events.TeamVictory
-- (VERIFIED-BY-SOURCE), Events.NotificationActivated (PROBE for a custom type,
-- through TX_UI.ActivatedRecord), NotificationManager.GetList / Find /
-- :GetType / :GetValue (C), PopupDialogInGame (C), ContextPtr SetUpdate (C),
-- plus the TX_UIShared ones.
-- ===========================================================================

include("PopupDialog")
include("TX_UIShared")

local LOG_TAG = "UIApply"
local POLL_SECONDS = 0.5            -- (TX_Rev, turn, local) poll (EFV_Tracker.lua:70)

local ST = TX_Config.ST
local L = TX_UI.L
local Str = TX_Util.Str
local PASSED_TYPE = TX_Config.NOTIF.KICK_PASSED
local FAILED_TYPE = TX_Config.NOTIF.REQUEST_FAILED

local KIND_RELOAD, KIND_HOST, KIND_WAIT = "RELOAD", "HOST", "WAIT"

local m_ViewReady = false           -- set on LoadGameViewStateDone (EFV_Tracker.lua:93-97)
local m_SentReloaded = {}           -- [recID] = true: RELOADED sent in this Lua state
local m_SentVictory = false         -- TX_Victory sent in this Lua state
local m_Wait = nil                  -- the apply in flight (at most one)
local m_Save = nil                  -- the kick save in flight (at most one)
local m_SaveListening = false       -- Events.SaveComplete listener added in this Lua state
local m_SavedName = {}              -- [recID] = save name, saved in this Lua state
local m_UsedNames = {}              -- [name] = true: save names requested in this Lua state
local m_Attempts = {}               -- [recID] = last apply attempt number sent in this Lua state
local m_BannerRecID = nil           -- record the Apply button applies
local m_BannerKey = nil             -- "<kind>:<id>" shown now (nil: hidden)
local m_PollElapsed = 0
local m_LastKey = nil               -- "<rev>|<turn>|<local>" of the last poll refresh

local function Log(level, fmt, ...)
	TX_Util.Log(level, LOG_TAG, fmt, ...)
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
-- The config team of pid (what gameplay reads, F1, F2), or nil.
local function ConfigTeam(pid)
	local ok, t = pcall(function() return PlayerConfigurations[pid]:GetTeam() end)
	if ok and type(t) == "number" then
		return t
	end
	return nil
end

-- This machine may apply: the host (F7), and network apply allowed or not a
-- network game (SEAM O4: TX_Config.ALLOW_NETWORK_APPLY).
local function CanApplyHere()
	if not TX_UI.IsHost() then
		return false
	end
	return TX_Config.ALLOW_NETWORK_APPLY == true or not TX_UI.NetMP()
end

local function Won(store)
	return store.victoryTurn ~= nil
end

-- Written but not reloaded yet: the config reads newTeamID (or gameplay
-- already confirmed it, applied = 1), the UI's live team does not (F3).
-- applied = 1 also counts so a network client whose config read lags the
-- host's broadcast still gets the reload banner (SEAM O4).
local function WrittenNotReloaded(rec)
	if TX_UI.LiveTeam(rec.targetID) == rec.newTeamID then
		return false
	end
	return rec.applied == 1 or ConfigTeam(rec.targetID) == rec.newTeamID
end

local function PendingRecords(store)
	local out = {}
	for _, rec in ipairs(TX_Store.Records(store)) do
		if rec.state == ST.PENDING_APPLY then
			out[#out + 1] = rec
		end
	end
	return out
end

-- ApplyCodes(store, world, rec) -> codes that stop the apply now (empty: ok).
-- Display and click checks only; gameplay re-validates WRITTEN (ApplyReasons).
-- TEAM_TAKEN: another slot already uses newTeamID (gameplay picks a new ID at
-- the next turn start, TX_Votes.TurnStart TEAM_ID).
local function ApplyCodes(store, world, rec)
	local codes = {}
	if rec == nil or rec.state ~= ST.PENDING_APPLY then
		codes[#codes + 1] = "NOT_PENDING"
		return codes
	end
	if rec.applied == 1 then
		codes[#codes + 1] = "APPLIED"
	end
	if not TX_UI.IsHost() then
		codes[#codes + 1] = "NOT_HOST"
	elseif not CanApplyHere() then
		codes[#codes + 1] = "NETWORK_OFF"
	end
	if Won(store) then
		codes[#codes + 1] = "VICTORY"
	end
	if m_Wait ~= nil or m_Save ~= nil then
		codes[#codes + 1] = "BUSY"
	end
	if not TX_Votes.IsLivingMajor(world, rec.targetID) then
		codes[#codes + 1] = "TARGET_GONE"
	elseif TX_Votes.TeamUsed(world, rec.newTeamID, rec.targetID) then
		codes[#codes + 1] = "TEAM_TAKEN"
	end
	return codes
end

local function HasCode(codes, code)
	for _, c in ipairs(codes) do
		if c == code then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Banner (PLAN II.11c, first match)
-- ---------------------------------------------------------------------------
local function BannerFor(store)
	local pending = PendingRecords(store)
	for _, rec in ipairs(pending) do
		if WrittenNotReloaded(rec) then
			return KIND_RELOAD, rec
		end
	end
	if Won(store) then
		return nil, nil
	end
	for _, rec in ipairs(pending) do
		if rec.applied ~= 1 then
			if CanApplyHere() then
				return KIND_HOST, rec
			end
			return KIND_WAIT, rec
		end
	end
	return nil, nil
end

local function RefreshBanner()
	if not m_ViewReady then
		return
	end
	local store = TX_UI.ReadStore()
	local kind, rec = BannerFor(store)
	local key = nil
	if kind ~= nil then
		key = kind .. ":" .. rec.id
	end
	local ok, err = pcall(function()
		if kind == nil then
			m_BannerRecID = nil
			Controls.ApplyButton:SetHide(true)
			Controls.Banner:SetHide(true)
			return
		end
		local label = TX_UI.Label(rec.targetID)
		if kind == KIND_RELOAD then
			if m_Save ~= nil and m_Save.recID == rec.id then
				Controls.BannerLabel:SetText(L("LOC_TX_BANNER_SAVING"))
			elseif m_SavedName[rec.id] ~= nil then
				Controls.BannerLabel:SetText(L("LOC_TX_BANNER_SAVED", m_SavedName[rec.id]))
			else
				Controls.BannerLabel:SetText(L("LOC_TX_BANNER_RELOAD"))
			end
		elseif kind == KIND_HOST then
			Controls.BannerLabel:SetText(L("LOC_TX_BANNER_HOST", label))
		else
			Controls.BannerLabel:SetText(L("LOC_TX_BANNER_WAIT", label))
		end
		m_BannerRecID = rec.id
		Controls.ApplyButton:SetHide(kind ~= KIND_HOST or m_Wait ~= nil or m_Save ~= nil)
		Controls.Banner:SetHide(false)
	end)
	if not ok then
		Log(1, "banner refresh failed: %s", Str(err))
	end
	if key ~= m_BannerKey then
		m_BannerKey = key
		Log(2, "banner %s for P%d", Str(key or "hidden"), TX_UI.Local())
	end
end

-- ---------------------------------------------------------------------------
-- Dialogs (PopupDialogInGame, EFV_UnitActions.lua:260-268)
-- ---------------------------------------------------------------------------
-- One OK button: the saved and reload instructions, the failed and the conflict notes.
local function Notice(id, titleKey, text)
	local popup = PopupDialogInGame:new(id)
	popup:AddTitle(L(titleKey))
	popup:AddText(text)
	popup:AddConfirmButton(L("LOC_TX_OK"), nil)
	popup:Open()
end

-- The manual fallback: no kick save was made (or it was not confirmed).
local function ReloadDialog()
	local key = "LOC_TX_RELOAD_TEXT_LOCAL"
	if TX_UI.NetMP() then
		key = "LOC_TX_RELOAD_TEXT_NETMP"
	elseif TX_UI.Hotseat() then
		key = "LOC_TX_RELOAD_TEXT"
	end
	Notice("TX_ReloadNow", "LOC_TX_RELOAD_TITLE", L(key))
end

-- The kick save is done: how everyone loads it (hotseat, network MP, single machine).
local function SavedDialog(name)
	local text
	if TX_UI.NetMP() then
		text = L("LOC_TX_SAVED_TEXT_NETMP", name)
	elseif TX_UI.Hotseat() then
		text = L("LOC_TX_SAVED_TEXT_HOTSEAT", name)
	else
		text = L("LOC_TX_SAVED_TEXT_LOCAL", name)
	end
	Notice("TX_KickSaved", "LOC_TX_SAVED_TITLE", text)
end

local function FailedDialog()
	Notice("TX_ApplyFailed", "LOC_TX_APPLY_FAILED_TITLE", L("LOC_TX_APPLY_FAILED_TEXT"))
end

local function ConflictDialog()
	Notice("TX_ApplyConflict", "LOC_TX_APPLY_TITLE", L("LOC_TX_APPLY_CONFLICT_TEXT"))
end

-- ---------------------------------------------------------------------------
-- Kick save (DEC 2026-10-07; replaces the SEAM O3 one-click reload).
-- After gameplay confirms WRITTEN, the host's UI saves the game under a clear
-- name and, on Events.SaveComplete, tells everyone to load that save.
--
-- The mod never loads a game. TX_Dev Session 3b (SPIKE_RESULTS.md) tried the
-- R chain's in-game load of a hotseat game: Network.LeaveGame +
-- Network.LoadGame(entry, SERVER_TYPE_NONE) reloads it, but as a single
-- player game (the other humans' turns are skipped); SERVER_TYPE_HOTSEAT
-- drops to the main menu (the hotseat load only works from the front-end
-- lobby). Network MP clients have to rejoin by hand in any case. So the
-- players load the save from the main menu, and TX has no load or leave call
-- (test_tx_apply.lua asserts it).
--
-- Calls, all through TX_UI.TryProbe (PLAN Appendix B; VERIFIED-IN-GAME by the
-- TX_Dev R / RK save step, Session 3b, three PASS): Network.SaveGame{Name,
-- Location = SaveLocations.LOCAL_STORAGE, Type =
-- Network.GetGameConfigurationSaveType(), FileType = SaveFileTypes.GAME_STATE,
-- IsAutosave = false, IsQuicksave = false} (SaveGameMenu.lua:52-66), then
-- Events.SaveComplete (Automation_StandardTests.lua:37; in game its arguments
-- were (0,3,0,0): no file name).
-- Guard: one SaveComplete is taken, only while a kick save waits, and only
-- when the turn and the local player are still those of the request, so an
-- autosave at a turn change cannot pass for ours. A failed call or no
-- SaveComplete within TX_Config.SAVE_MAX s: the manual reload dialog.
-- ---------------------------------------------------------------------------
local NAME_PART_MAX = 20            -- characters of the target part of the name

-- Letters, digits and underscores only (no spaces or accents in a file name).
local function SafePart(text)
	if type(text) ~= "string" then
		return ""
	end
	local out = string.gsub(text, "[^A-Za-z0-9_]", "")
	return string.sub(out, 1, NAME_PART_MAX)
end

-- The target's civ short name (e.g. "Rome"), else its leader, else P<id>.
local function TargetPart(pid)
	local ok, key = pcall(function() return PlayerConfigurations[pid]:GetCivilizationShortDescription() end)
	local part = ""
	if ok then
		part = SafePart(L(key))
	end
	if part == "" then
		ok, key = pcall(function() return PlayerConfigurations[pid]:GetLeaderName() end)
		if ok then
			part = SafePart(L(key))
		end
	end
	if part == "" then
		part = "P" .. tostring(pid)
	end
	return part
end

-- TeamKick_<target>_T<turn>_<HHMM> (local time, os.date as TX_Dev R and
-- TopPanel.lua:283), plus _2, _3 when this Lua state already used the name.
local function SaveName(rec)
	local base = TX_Config.SAVE_PREFIX .. "_" .. TargetPart(rec.targetID) .. "_T" .. tostring(TX_UI.Turn())
	local ok, stamp = pcall(function() return os.date("%H%M") end)
	if ok and type(stamp) == "string" and string.match(stamp, "^%d%d%d%d$") ~= nil then
		base = base .. "_" .. stamp
	end
	local name, n = base, 1
	while m_UsedNames[name] do
		n = n + 1
		name = base .. "_" .. n
	end
	m_UsedNames[name] = true
	return name
end

local function ArgsText(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = Str((select(i, ...)))
	end
	return table.concat(parts, ",")
end

-- The save did not happen or is not confirmed: log it, the manual dialog.
local function SaveFailed(s, why)
	Log(1, "kick save rec=%d %s: %s; asking for a manual save and reload", s.recID, s.name, why)
	ReloadDialog()
	RefreshBanner()
end

-- Events.SaveComplete(...): ours only while a kick save waits (see the guard).
local function OnSaveComplete(...)
	local args = ArgsText(...)
	local s = m_Save
	if s == nil then
		Log(3, "Events.SaveComplete (%s): no kick save waits, ignored", args)
		return
	end
	m_Save = nil
	if TX_UI.Turn() ~= s.turn or TX_UI.Local() ~= s.localID then
		SaveFailed(s, "Events.SaveComplete (" .. args .. ") came after a turn or player change, so it may not be ours")
		return
	end
	m_SavedName[s.recID] = s.name
	Log(2, "kick save rec=%d: saved as %s (Events.SaveComplete %s)", s.recID, s.name, args)
	SavedDialog(s.name)
	RefreshBanner()
end

-- StartSave(rec) -> true when the save was requested (the dialog follows on
-- SaveComplete or the timeout); false: nothing saved, the caller shows the
-- manual reload dialog.
local function StartSave(rec)
	if not TX_UI.IsHost() then
		Log(2, "kick save rec=%d: not the host, no save here", rec.id)
		return false
	end
	if m_Save ~= nil then
		Log(1, "kick save rec=%d: the save of rec=%d still runs", rec.id, m_Save.recID)
		return false
	end
	if not m_SaveListening then
		Log(1, "kick save rec=%d: no Events.SaveComplete listener; asking for a manual save and reload", rec.id)
		return false
	end
	local name = SaveName(rec)
	local okFile, file = TX_UI.TryProbe("UI kick save file", function()
		return { Name = name, Location = SaveLocations.LOCAL_STORAGE, Type = Network.GetGameConfigurationSaveType(),
			FileType = SaveFileTypes.GAME_STATE, IsAutosave = false, IsQuicksave = false }
	end)
	if not okFile or type(file) ~= "table" or file.Location == nil or file.Type == nil or file.FileType == nil then
		Log(1, "kick save rec=%d %s: no save file shape (%s); asking for a manual save and reload", rec.id, name, Str(file))
		return false
	end
	-- Set before the call: a SaveComplete fired from inside it still finds the wait.
	m_Save = { recID = rec.id, name = name, elapsed = 0, turn = TX_UI.Turn(), localID = TX_UI.Local() }
	Log(2, "kick save rec=%d: Network.SaveGame{Name=%s, Location=%s, Type=%s, FileType=%s}; waiting for Events.SaveComplete (%s s)",
		rec.id, name, Str(file.Location), Str(file.Type), Str(file.FileType), Str(TX_Config.SAVE_MAX))
	local okSave = TX_UI.TryProbe("UI Network.SaveGame", function() Network.SaveGame(file) end)
	if not okSave then
		m_Save = nil
		Log(1, "kick save rec=%d %s: Network.SaveGame failed; asking for a manual save and reload", rec.id, name)
		return false
	end
	return true
end

local function TickSave(dt)
	local s = m_Save
	if s == nil then
		return
	end
	s.elapsed = s.elapsed + dt
	if s.elapsed > TX_Config.SAVE_MAX then
		m_Save = nil
		SaveFailed(s, "no Events.SaveComplete within " .. tostring(TX_Config.SAVE_MAX) .. " s")
	end
end

-- ---------------------------------------------------------------------------
-- The config write and its undo (the S3 call shapes, TX_Dev_Panel.lua:639-711)
-- ---------------------------------------------------------------------------
-- Write(t, team) -> config team read back after SetTeam + broadcast.
local function Write(what, recID, t, team)
	local before = ConfigTeam(t)
	Log(2, "%s rec=%d: about to set the config team of P%d %s -> %d and broadcast", what, recID, t, Str(before), team)
	local okSet, errSet = pcall(function() PlayerConfigurations[t]:SetTeam(team) end)
	local okCast, errCast = pcall(function() Network.BroadcastPlayerInfo(t) end)
	local now = ConfigTeam(t)
	Log(2, "%s rec=%d: set %s broadcast %s; config team of P%d now %s", what, recID,
		okSet and "ok" or ("FAILED " .. Str(errSet)), okCast and "ok" or ("FAILED " .. Str(errCast)), t, Str(now))
	return now
end

-- Undo(w, why): back to the team before the write, broadcast, failed dialog.
local function Undo(w, why)
	m_Wait = nil
	Log(1, "apply rec=%d not confirmed (%s): undoing the write of P%d", w.recID, why, w.target)
	local now = Write("undo", w.recID, w.target, w.undoTeam)
	if now ~= w.undoTeam then
		Log(1, "undo rec=%d: config team of P%d is %s, want %d", w.recID, w.target, Str(now), w.undoTeam)
	end
	-- Tell gameplay, so a WRITTEN it accepts late cannot leave applied = 1
	-- with the write undone (the reload banner forever, no Apply button).
	local rec = TX_Store.Get(TX_UI.ReadStore(), w.recID)
	if w.sent and rec ~= nil and rec.state == ST.PENDING_APPLY then
		Log(2, "apply rec=%d: reporting UNDONE attempt %d", w.recID, w.attempt)
		TX_UI.Request(TX_Config.REQ_APPLY_DONE, { recordID = w.recID, step = TX_Config.STEP_UNDONE, attempt = w.attempt })
	end
	FailedDialog()
	RefreshBanner()
end

-- ---------------------------------------------------------------------------
-- The wait for gameplay (TX_Dev WaitFor, TX_Dev_Panel.lua:435-447, 2134-2172)
-- ---------------------------------------------------------------------------
-- IDs of the REQUEST_FAILED notifications of pid that carry recID.
local function FailedNotifications(pid, recID)
	local out = {}
	local want = TX_UI.Hash(FAILED_TYPE)
	if want == nil or type(pid) ~= "number" or pid < 0 then
		return out
	end
	local okList, list = pcall(function() return NotificationManager.GetList(pid) end)
	if not okList or type(list) ~= "table" then
		return out
	end
	for _, nid in ipairs(list) do
		pcall(function()
			local p = NotificationManager.Find(pid, nid)
			if p ~= nil and p:GetType() == want and p:GetValue(TX_Config.NKEY_RECORD) == recID then
				out[#out + 1] = nid
			end
		end)
	end
	return out
end

local function Answered(w)
	m_Wait = nil
	local rec = TX_Store.Get(TX_UI.ReadStore(), w.recID)
	Log(2, "apply rec=%d confirmed by gameplay: P%d reads team %d; saving the game", w.recID, w.target, w.newTeam)
	if rec == nil or not StartSave(rec) then
		ReloadDialog()
	end
	RefreshBanner()
end

-- CheckWait(timedOut) -> true when the wait ended.
local function CheckWait(timedOut)
	local w = m_Wait
	if w == nil then
		return true
	end
	local rec = TX_Store.Get(TX_UI.ReadStore(), w.recID)
	if rec ~= nil and rec.applied == 1 and (rec.state == ST.PENDING_APPLY or rec.state == ST.DONE) then
		Answered(w)
		return true
	end
	for _, nid in ipairs(FailedNotifications(w.sender, w.recID)) do
		if not w.failedBefore[nid] then
			Undo(w, "REQUEST_FAILED")
			return true
		end
	end
	if rec == nil or rec.state ~= ST.PENDING_APPLY then
		Undo(w, "record " .. Str(rec and rec.state or "missing"))
		return true
	end
	if timedOut then
		Undo(w, "no answer within " .. tostring(TX_Config.WAIT_MAX) .. " s")
		return true
	end
	return false
end

local function TickWait(dt)
	local w = m_Wait
	if w == nil then
		return
	end
	w.elapsed = w.elapsed + dt
	w.sincePoll = w.sincePoll + dt
	if w.sincePoll < TX_Config.WAIT_POLL and w.elapsed <= TX_Config.WAIT_MAX then
		return
	end
	w.sincePoll = 0
	CheckWait(w.elapsed > TX_Config.WAIT_MAX)
end

-- ---------------------------------------------------------------------------
-- Apply (PLAN II.11c steps 1 to 6)
-- ---------------------------------------------------------------------------
-- Logs the codes; a taken team ID gets the conflict dialog. Returns true when
-- the apply may go on.
local function ApplyAllowed(recID, step)
	local store = TX_UI.ReadStore()
	local rec = TX_Store.Get(store, recID)
	local codes = ApplyCodes(store, TX_UI.World(), rec)
	if #codes == 0 then
		return true, rec
	end
	Log(2, "apply rec=%s %s refused: %s", Str(recID), step, table.concat(codes, ","))
	if HasCode(codes, "TEAM_TAKEN") and not HasCode(codes, "BUSY") then
		ConflictDialog()
	end
	RefreshBanner()
	return false, rec
end

-- Step 3 onwards: the confirm dialog's yes.
local function DoApply(recID)
	local ok, rec = ApplyAllowed(recID, "at yes")
	if not ok then
		return
	end
	local t, team = rec.targetID, rec.newTeamID
	local before = ConfigTeam(t)
	local undoTeam = rec.teamID
	if type(before) == "number" and before >= 0 then
		undoTeam = before
	end
	local attempt = math.max(m_Attempts[recID] or 0, rec.undoneAttempt or 0, rec.appliedAttempt or 0) + 1
	m_Attempts[recID] = attempt
	local w = { recID = recID, target = t, newTeam = team, undoTeam = undoTeam, sender = TX_UI.Local(),
		attempt = attempt, sent = false, elapsed = 0, sincePoll = 0, failedBefore = {} }
	for _, nid in ipairs(FailedNotifications(w.sender, recID)) do
		w.failedBefore[nid] = true
	end
	m_Wait = w
	local now = Write("apply", recID, t, team)
	if now ~= team then
		Undo(w, "config team read back " .. Str(now))
		return
	end
	if not TX_UI.Request(TX_Config.REQ_APPLY_DONE, { recordID = recID, step = TX_Config.STEP_WRITTEN, team = team,
			attempt = attempt }) then
		Undo(w, "WRITTEN not sent")
		return
	end
	w.sent = true
	RefreshBanner()
	-- A synchronous answer ends the wait at once; otherwise the update handler polls.
	CheckWait(false)
end

-- Steps 1 and 2: re-check, then the confirm dialog.
local function OnApply(recID)
	local ok, rec = ApplyAllowed(recID, "at click")
	if not ok then
		return
	end
	local text = L("LOC_TX_APPLY_CONFIRM", TX_UI.Label(rec.targetID))
	if TX_Votes.RecMode(rec) == TX_Config.MODE.HARD and TX_Config.HARD_KICK_ENABLED == true then
		text = text .. L("LOC_TX_APPLY_CONFIRM_HARD")   -- the war then peace runs after the reload
	end
	if TX_UI.NetMP() then
		text = text .. L("LOC_TX_APPLY_CONFIRM_NETMP")   -- SEAM O4: untested warning
	end
	Log(2, "apply rec=%d: confirm for P%d (target P%d newTeam=%d)", recID, TX_UI.Local(), rec.targetID, rec.newTeamID)
	local popup = PopupDialogInGame:new("TX_ConfirmApply")
	popup:AddTitle(L("LOC_TX_APPLY_TITLE"))
	popup:AddText(text)
	popup:AddConfirmButton(L("LOC_YES"), function() DoApply(recID) end)
	popup:AddCancelButton(L("LOC_NO"), nil)
	popup:Open()
end

local function OnApplyClicked()
	if m_BannerRecID ~= nil then
		OnApply(m_BannerRecID)
	end
end

local function OnBannerClicked()
	LuaEvents.TX_OpenTeamWindow()
end

-- ---------------------------------------------------------------------------
-- Reports to gameplay
-- ---------------------------------------------------------------------------
-- RELOADED for every PENDING_APPLY record whose target the UI already reads
-- on newTeamID: before a load it never does (F3), after one it does (F4).
local function ReportReloads()
	local store = TX_UI.ReadStore()
	for _, rec in ipairs(PendingRecords(store)) do
		if not m_SentReloaded[rec.id] and TX_UI.LiveTeam(rec.targetID) == rec.newTeamID then
			Log(2, "rec=%d: the UI reads team %d for P%d after a load; reporting RELOADED", rec.id, rec.newTeamID, rec.targetID)
			if TX_UI.Request(TX_Config.REQ_APPLY_DONE, { recordID = rec.id, step = TX_Config.STEP_RELOADED, team = rec.newTeamID }) then
				m_SentReloaded[rec.id] = true
			end
		end
	end
end

-- Events.TeamVictory(team, victory, eventID) (EndGameMenu.lua:1039, 1345):
-- TX_Victory once per Lua state; nothing when the store already has it.
local function OnTeamVictory(team, victory, eventID)
	if m_SentVictory then
		return
	end
	if Won(TX_UI.ReadStore()) then
		m_SentVictory = true
		Log(3, "victory team=%s: already recorded", Str(team))
		RefreshBanner()
		return
	end
	local params = {}
	if type(team) == "number" then
		params.team = team
	end
	Log(2, "victory team=%s type=%s: reporting", Str(team), Str(victory))
	if TX_UI.Request(TX_Config.REQ_VICTORY, params) then
		m_SentVictory = true
	end
	RefreshBanner()
end

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------
-- KICK_PASSED copies of the local player: the newest per record stays while
-- the kick waits (PLAN II.7 persistence, TX_UI.Sweep).
local function SweepPassed()
	local me = TX_UI.Local()
	if me < 0 then
		return
	end
	local n = TX_UI.Sweep(me, PASSED_TYPE, function(rec)
		return rec.state == ST.PENDING_APPLY or rec.state == ST.PASSED
	end)
	if n > 0 then
		Log(3, "swept %d kick notification(s) of P%d", n, me)
	end
end

-- A click on a KICK_PASSED notification of the local player.
local function OnNotificationActivated(pid, nid, byUser)
	if pid ~= TX_UI.Local() then
		return
	end
	local matched, recID = TX_UI.ActivatedRecord(pid, nid, PASSED_TYPE)
	if not matched then
		return
	end
	local rec = nil
	if recID ~= nil then
		rec = TX_Store.Get(TX_UI.ReadStore(), recID)
	end
	Log(2, "kick notification %s activated by P%d rec=%s", Str(nid), pid, Str(recID))
	if rec ~= nil and rec.state == ST.PENDING_APPLY and rec.applied ~= 1 and CanApplyHere() then
		OnApply(recID)
	else
		LuaEvents.TX_OpenTeamWindow()
	end
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
	if ok and t ~= nil and t == TX_UI.Hash(PASSED_TYPE) then
		SweepPassed()
	end
	if m_Wait ~= nil then
		CheckWait(false)
	end
	RefreshBanner()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local function PollKey()
	return tostring(TX_UI.Rev()) .. "|" .. tostring(TX_UI.Turn()) .. "|" .. tostring(TX_UI.Local())
end

local function OnUpdate(fDTime)
	local dt = tonumber(fDTime) or 0
	TickWait(dt)
	TickSave(dt)
	m_PollElapsed = m_PollElapsed + dt
	if m_PollElapsed < POLL_SECONDS or not m_ViewReady then
		return
	end
	m_PollElapsed = 0
	local key = PollKey()
	if key ~= m_LastKey then
		m_LastKey = key
		SweepPassed()
		RefreshBanner()
	end
end

local function OnLoadGameViewStateDone()
	m_ViewReady = true
	ReportReloads()
	SweepPassed()
	m_LastKey = PollKey()
	RefreshBanner()
end

local function OnPlayerTurnActivated(pid)
	if not m_ViewReady or pid ~= TX_UI.Local() then
		return
	end
	ReportReloads()
	SweepPassed()
	RefreshBanner()
end

-- Hotseat hand-off: the banner is per machine; the new local player's
-- KICK_PASSED copies get swept.
local function OnLocalPlayerChanged()
	if not m_ViewReady then
		return
	end
	SweepPassed()
	RefreshBanner()
end

-- ---------------------------------------------------------------------------
-- Initialize(): contexts load HIDDEN (PB 3), so the context is shown here;
-- the banner state is the Banner control. The update handler runs the wait,
-- the kick save timeout and the poll (one handler per context).
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)
	Controls.Banner:SetHide(true)
	Controls.ApplyButton:SetHide(true)
	Controls.ApplyButton:RegisterCallback(Mouse.eLClick, OnApplyClicked)
	Controls.BannerButton:RegisterCallback(Mouse.eLClick, OnBannerClicked)
	ContextPtr:SetUpdate(OnUpdate)
	m_SaveListening = TX_UI.TryProbe("UI Events.SaveComplete.Add", function() Events.SaveComplete.Add(OnSaveComplete) end)
	Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
	Events.PlayerTurnActivated.Add(OnPlayerTurnActivated)
	Events.LocalPlayerChanged.Add(OnLocalPlayerChanged)
	Events.NotificationAdded.Add(OnNotificationAdded)
	Events.NotificationActivated.Add(OnNotificationActivated)
	Events.TeamVictory.Add(OnTeamVictory)
	Log(2, "initialized")
end

Initialize()
