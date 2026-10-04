-- Tests of the apply seam UI, build chunk D of PLAN II.16 (II.14
-- "test_tx_apply.lua"): TX/UI/TX_ApplyBanner.lua end to end on the split team
-- model, with the real gameplay script answering its requests and the other
-- two contexts loaded (FAKE_TX.LoadUI). UI.RequestPlayerOperation reaches
-- GameEvents.TX_* as gameplay at once, or later with FAKE_UI.deferRequests.
--
-- Standard world (FAKE_TX.World): P0, P1, P2 human on team 0; P3 human and P4
-- AI on team 1; P5 human solo (team 2); city-state 6; slots 7..61 empty;
-- Free Cities 62; Barbarians 63. First free team ID 6. Split model (PLAN
-- II.0 F1 to F3): gameplay reads the config team at once, the UI's
-- Players[i]:GetTeam() only after FAKE_TX.Reload() (save and load, F4).

local GAMEPLAY = "TX/Scripts/TX_Gameplay.lua"
local BANNER = "TX/UI/TX_ApplyBanner.lua"
local VOTE_N = "NOTIFICATION_TX_VOTE_REQUIRED"
local PASSED_N = "NOTIFICATION_TX_KICK_PASSED"
local DONE_N = "NOTIFICATION_TX_KICK_DONE"
local FAILED_N = "NOTIFICATION_TX_REQUEST_FAILED"
local HUMANS = { 0, 1, 2, 3, 5 }

local ENVS = nil

local function Setup(opts)
	opts = opts or {}
	FAKE.dofile("tests/offline/lib/fake_txworld.lua")
	FAKE_TX.World(opts)
	FAKE_UI.Enable()
	FAKE.localPlayer = opts.localPlayer or 0
	FAKE_UI.AsGameplay(function() FAKE.dofile(GAMEPLAY) end)
	ENVS = FAKE_TX.LoadUI()
	H.markBody()
end

local function Ban() return ENVS.ApplyBanner end
local function Win() return ENVS.TeamWindow end
local function Pop() return ENVS.VotePopup end

local function T(key, ...) return Locale.Lookup(key, ...) end
local function Label(pid)
	return "LOC_LEADER_FAKE_" .. pid .. "_NAME (LOC_CIVILIZATION_FAKE_" .. pid .. "_NAME)"
end

-- Gameplay side (as the engine delivers EXECUTE_SCRIPT).
local function GPropose(pid, target) H.request(pid, { OnStart = "TX_Propose", targetID = target }) end
local function GVote(pid, id, v) H.request(pid, { OnStart = "TX_Vote", recordID = id, vote = v }) end
local function GTurn() FAKE_UI.AsGameplay(H.endTurn) end
local function Rec(id)
	local s = H.prop("TX_Store")
	return s and s.recs and s.recs["r" .. id]
end
local function Rev() return H.prop("TX_Rev") or 0 end

-- P0 proposes P1, P2 votes yes: record 1 PENDING_APPLY, newTeamID 6.
local function Pass()
	GPropose(0, 1)
	GVote(2, 1, "YES")
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.eq(Rec(1).newTeamID, 6)
end

-- One poll of the banner context (TX_Rev, turn, local player).
local function Poll() FAKE_UI.Update(Ban(), 0.6) end

local function BannerShown() return not Ban().Controls.Banner:IsHidden() end
local function BannerText() return Ban().Controls.BannerLabel.text end
local function ApplyShown() return not Ban().Controls.ApplyButton:IsHidden() end

local function Requests(onStart, step)
	local out = {}
	for _, r in ipairs(FAKE_UI.requests) do
		if (onStart == nil or r.params.OnStart == onStart) and (step == nil or r.params.step == step) then
			out[#out + 1] = r
		end
	end
	return out
end

local function LastDialog() return FAKE_UI.popups[#FAKE_UI.popups] end
local function DialogText(d) return table.concat(d.texts, "|") end

-- Apply button -> confirm dialog (returned, not answered yet).
local function ClickApply()
	local n = #FAKE_UI.popups
	Ban().Controls.ApplyButton:Click()
	H.eq(#FAKE_UI.popups, n + 1, "a dialog opened")
	return LastDialog()
end

local function Pids(list)
	local out = {}
	for _, n in ipairs(list) do out[#out + 1] = n.pid end
	table.sort(out)
	return out
end

local function UISets()
	local out = {}
	for _, s in ipairs(FAKE.teamSets) do
		out[#out + 1] = { pid = s.pid, team = s.team, context = s.context }
	end
	return out
end

local function UICasts()
	local out = {}
	for _, b in ipairs(FAKE.broadcasts) do out[#out + 1] = b.pid .. ":" .. b.context end
	return out
end

-- Built launch-bar instance (newest).
local function Launch()
	local hit = nil
	for _, b in ipairs(FAKE_UI.builtInstances or {}) do
		if b.name == "TX_LaunchBarItem" then hit = b end
	end
	return hit.inst
end

local function OpenNotifs(pid, typeName)
	local out = {}
	for _, n in ipairs(H.notifs(pid, typeName)) do
		if not n.dismissed then out[#out + 1] = n end
	end
	return out
end

-- Apply rec 1 through the banner and confirm it.
local function ApplyNow()
	local d = ClickApply()
	H.eq(d.id, "TX_ConfirmApply")
	d.confirm()
	return d
end

-- ===========================================================================
-- 1. Banner after a pass; non-host
-- ===========================================================================
test("apply 1: no banner before a pass; after it the host sees the banner with Apply, for every local player", function()
	Setup()
	H.eq(BannerShown(), false)
	GPropose(0, 1)
	Poll()
	H.eq(BannerShown(), false, "an open vote has no banner")
	GVote(2, 1, "YES")
	Poll()
	H.eq(BannerShown(), true)
	H.eq(BannerText(), T("LOC_TX_BANNER_HOST", Label(1)))
	H.eq(ApplyShown(), true)
	-- hotseat: the machine is the host, so every player sees Apply (II.18 item 3)
	for _, pid in ipairs({ 1, 3, 5 }) do
		FAKE_TX.Hotseat(pid)
		H.eq(BannerShown(), true, "P" .. pid)
		H.eq(ApplyShown(), true, "P" .. pid)
	end
	H.len(FAKE.teamSets, 0, "nothing written by showing the banner")
	H.clean()
end)

test("apply 1b: not the host: the wait banner, no Apply; Apply and the KICK_PASSED click change nothing", function()
	Setup({ host = false })
	Pass()
	Poll()
	H.eq(BannerShown(), true)
	H.eq(BannerText(), T("LOC_TX_BANNER_WAIT", Label(1)))
	H.eq(ApplyShown(), false)
	local n = #FAKE_UI.popups
	Ban().Controls.ApplyButton:Click()   -- even a click on the hidden button
	H.eq(#FAKE_UI.popups, n, "no confirm dialog")
	H.ok(H.hasLine("[UIApply] apply rec=1 at click refused: NOT_HOST"))
	FAKE_TX.Activate(0, PASSED_N)
	H.eq(#FAKE_UI.popups, n, "the notification click opens no dialog")
	H.eq(Win().Controls.TeamPanel:IsHidden(), false, "the Team window instead")
	H.len(FAKE.teamSets, 0)
	H.len(FAKE.broadcasts, 0)
	H.len(Requests("TX_ApplyDone"), 0)
	H.clean()
end)

-- ===========================================================================
-- 2. Apply
-- ===========================================================================
test("apply 2: Apply, confirm: config write + broadcast, WRITTEN, applied 1, reload dialog, reload banner, no KICK_DONE", function()
	Setup()
	Pass()
	Poll()
	local d = ClickApply()
	H.eq(d.id, "TX_ConfirmApply")
	H.eq(d.title, T("LOC_TX_APPLY_TITLE"))
	H.eq(DialogText(d), T("LOC_TX_APPLY_CONFIRM", Label(1)), "no network MP warning in hotseat")
	H.len(FAKE.teamSets, 0, "nothing written before yes")
	d.confirm()
	H.deq(UISets(), { { pid = 1, team = 6, context = "UI" } })
	H.deq(UICasts(), { "1:UI" })
	H.eq(PlayerConfigurations[1]:GetTeam(), 6)
	local w = Requests("TX_ApplyDone", "WRITTEN")
	H.len(w, 1)
	H.deq(w[1].params, { OnStart = "TX_ApplyDone", recordID = 1, step = "WRITTEN", team = 6 })
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.eq(Rec(1).applied, 1)
	H.eq(Rec(1).appliedBy, 0)
	local r = LastDialog()
	H.eq(r.id, "TX_ReloadNow")
	H.eq(r.title, T("LOC_TX_RELOAD_TITLE"))
	H.eq(DialogText(r), T("LOC_TX_RELOAD_TEXT"))
	H.ok(r.confirm == nil and r.cancel == nil, "one OK button that only closes it")
	H.eq(BannerText(), T("LOC_TX_BANNER_RELOAD"))
	H.eq(ApplyShown(), false)
	H.len(H.notifs(nil, DONE_N), 0, "no KICK_DONE before the reload")
	H.ok(H.hasLine("[UIApply] apply rec=1: about to set the config team of P1 0 -> 6 and broadcast"))
	H.ok(H.hasLine("[UIApply] apply rec=1: set ok broadcast ok; config team of P1 now 6"))
	H.ok(H.hasLine("[UIApply] apply rec=1 confirmed by gameplay: P1 reads team 6; save and reload now"))
	-- every local player now sees the reload banner
	FAKE_TX.Hotseat(3)
	H.eq(BannerText(), T("LOC_TX_BANNER_RELOAD"))
	H.eq(ApplyShown(), false)
	-- the kicked player's Team button goes right after the write (TeamWindow chunk C)
	FAKE_TX.Hotseat(1)
	H.eq(Launch().LaunchItemButton:IsHidden(), true)
	H.clean()
end)

test("apply 2b: the wait polls: an answer that comes later ends it; a second Apply meanwhile is refused", function()
	Setup()
	Pass()
	Poll()
	FAKE_UI.deferRequests = true
	ApplyNow()
	H.eq(Rec(1).applied, 0, "not delivered yet")
	H.eq(ApplyShown(), false, "no Apply while one is in flight")
	local n = #FAKE_UI.popups
	Ban().Controls.ApplyButton:Click()
	H.eq(#FAKE_UI.popups, n, "BUSY: no second dialog")
	H.ok(H.hasLine("[UIApply] apply rec=1 at click refused: BUSY"))
	FAKE_UI.Update(Ban(), 0.3)
	FAKE_UI.Update(Ban(), 0.3)
	H.eq(#FAKE_UI.popups, n, "still waiting")
	H.eq(FAKE_UI.DeliverRequests(), 1)
	FAKE_UI.Update(Ban(), 0.3)
	H.eq(LastDialog().id, "TX_ReloadNow")
	H.len(FAKE.teamSets, 1, "no undo")
	H.eq(BannerText(), T("LOC_TX_BANNER_RELOAD"))
	H.clean()
end)

-- ===========================================================================
-- 3, 4, 5. Reload detection
-- ===========================================================================
test("apply 3: before the reload no RELOADED is sent, also not after a turn", function()
	Setup()
	Pass()
	Poll()
	ApplyNow()
	Events.PlayerTurnActivated(0, true)
	H.len(Requests("TX_ApplyDone", "RELOADED"), 0)
	GTurn()
	Events.PlayerTurnActivated(0, true)
	Poll()
	H.len(Requests("TX_ApplyDone", "RELOADED"), 0, "the UI live team is still old (F3)")
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.eq(BannerText(), T("LOC_TX_BANNER_RELOAD"))
	H.clean()
end)

test("apply 4: after the load: RELOADED once, DONE, KICK_DONE to every living human, AfterReload, banner gone, KICK_PASSED swept, Team buttons", function()
	Setup()
	Pass()
	GTurn()                                  -- a second KICK_PASSED copy for everyone
	Poll()
	ApplyNow()
	H.len(H.notifs(0, PASSED_N), 2, "P0 got two copies")
	H.len(OpenNotifs(0, PASSED_N), 1, "the poll kept only the newest while the kick waits")
	ENVS = FAKE_TX.Reload()                  -- save and load (F4)
	local rel = Requests("TX_ApplyDone", "RELOADED")
	H.len(rel, 1)
	H.deq(rel[1].params, { OnStart = "TX_ApplyDone", recordID = 1, step = "RELOADED", team = 6 })
	H.eq(rel[1].pid, 0)
	H.eq(Rec(1).state, "DONE")
	H.eq(Rec(1).doneTurn, 2)
	H.deq(Pids(H.notifs(nil, DONE_N)), HUMANS, "KICK_DONE to every living human")
	H.eq(H.notifs(0, DONE_N)[1].data[ParameterTypes.SUMMARY], Label(1) .. " now plays alone.")
	H.len(H.lines("[Apply] AfterReload rec=1 target=P1: no cleanup in 0.1.0 (O1 alliance, O2 vision)"), 1)
	H.eq(BannerShown(), false)
	H.len(OpenNotifs(0, PASSED_N), 0, "P0's KICK_PASSED copies swept")
	H.eq(Launch().LaunchItemButton:IsHidden(), false, "P0 keeps the Team button")
	FAKE_TX.Hotseat(1)
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "the kicked player has no Team button")
	H.len(OpenNotifs(1, PASSED_N), 0, "P1's copies swept on the hand-off")
	FAKE_TX.Hotseat(2)
	H.eq(Launch().LaunchItemButton:IsHidden(), false, "P2 keeps it (team of 2 now)")
	-- later turns: nothing new (no RELOADED, no KICK_PASSED for a DONE record)
	local passed = #H.notifs(nil, PASSED_N)
	Events.PlayerTurnActivated(2, true)
	GTurn()
	Events.PlayerTurnActivated(2, true)
	H.len(Requests("TX_ApplyDone", "RELOADED"), 1)
	H.len(H.notifs(nil, PASSED_N), passed)
	H.clean()
end)

test("apply 5: two UIs report RELOADED after the load: DONE once, KICK_DONE once per human, the hook once", function()
	Setup()
	Pass()
	Poll()
	ApplyNow()
	FAKE_UI.deferRequests = true
	ENVS = FAKE_TX.Reload()
	FAKE_UI.LoadContext(BANNER)              -- the UI of a second machine
	Events.LoadGameViewStateDone()
	H.len(FAKE_UI.pending, 2, "both report")
	local rev = Rev()
	H.eq(FAKE_UI.DeliverRequests(), 2)
	H.eq(Rec(1).state, "DONE")
	H.eq(Rev(), rev + 1, "one commit")
	H.deq(Pids(H.notifs(nil, DONE_N)), HUMANS)
	H.len(H.lines("AfterReload rec=1"), 1)
	-- the first UI does not report again in this Lua state
	Events.PlayerTurnActivated(0, true)
	H.len(FAKE_UI.pending, 0)
	H.clean()
end)

-- ===========================================================================
-- 6. Failure: the write is not seen, or no answer
-- ===========================================================================
test("apply 6: gameplay does not see the write (NOT_SEEN): the UI undoes it, the failed dialog opens, applied stays 0", function()
	Setup({ split = false })
	Pass()
	Poll()
	ApplyNow()
	H.deq(UISets(), { { pid = 1, team = 6, context = "UI" }, { pid = 1, team = 0, context = "UI" } }, "write, then undo")
	H.deq(UICasts(), { "1:UI", "1:UI" })
	H.eq(PlayerConfigurations[1]:GetTeam(), 0)
	local d = LastDialog()
	H.eq(d.id, "TX_ApplyFailed")
	H.eq(d.title, T("LOC_TX_APPLY_FAILED_TITLE"))
	H.eq(DialogText(d), T("LOC_TX_APPLY_FAILED_TEXT"))
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.eq(Rec(1).applied, 0)
	H.eq(H.notifs(0, FAILED_N)[1].data.TX_RecordID, 1)
	H.ok(H.hasLine("[UIApply] ERROR apply rec=1 not confirmed (REQUEST_FAILED): undoing the write of P1"))
	H.ok(H.hasLine("[UIApply] undo rec=1: set ok broadcast ok; config team of P1 now 0"))
	H.ok(H.hasLine("(NOT_SEEN)"), "gameplay's ERROR line")
	-- the banner offers Apply again
	H.eq(BannerText(), T("LOC_TX_BANNER_HOST", Label(1)))
	H.eq(ApplyShown(), true)
	H.len(H.notifs(nil, DONE_N), 0)
end, { allowErrors = true })

test("apply 6b: no answer within WAIT_MAX: undo and the failed dialog; the late WRITTEN is refused by gameplay", function()
	Setup()
	Pass()
	Poll()
	FAKE_UI.deferRequests = true
	ApplyNow()
	local n = #FAKE_UI.popups
	for _ = 1, 16 do
		FAKE_UI.Update(Ban(), 0.3)        -- 4.8 s
	end
	H.eq(#FAKE_UI.popups, n, "still waiting at 4.8 s")
	FAKE_UI.Update(Ban(), 0.3)
	FAKE_UI.Update(Ban(), 0.3)
	H.eq(LastDialog().id, "TX_ApplyFailed")
	H.eq(PlayerConfigurations[1]:GetTeam(), 0, "undone")
	H.ok(H.hasLine("not confirmed (no answer within 5 s)"))
	FAKE_UI.deferRequests = false
	FAKE_UI.DeliverRequests()
	H.eq(Rec(1).applied, 0, "gameplay reads the old team again: NOT_SEEN")
	H.eq(ApplyShown(), true)
end, { allowErrors = true })

test("apply 6c: the record left PENDING_APPLY during the wait (victory): undo", function()
	Setup()
	Pass()
	Poll()
	FAKE_UI.deferRequests = true
	ApplyNow()
	H.request(3, { OnStart = "TX_Victory", team = 1 })   -- reaches gameplay first
	FAKE_UI.Update(Ban(), 0.3)
	H.eq(Rec(1).state, "CANCELLED")
	H.eq(PlayerConfigurations[1]:GetTeam(), 0, "undone")
	H.eq(LastDialog().id, "TX_ApplyFailed")
	H.eq(BannerShown(), false)
end, { allowErrors = true })

-- ===========================================================================
-- 7. Conflict
-- ===========================================================================
test("apply 7: newTeamID taken in the UI world: no write, the conflict dialog; the next turn start picks a new ID", function()
	Setup()
	Pass()
	Poll()
	H.team(5, 6)                              -- P5 now uses team 6
	local d = ClickApply()
	H.eq(d.id, "TX_ApplyConflict")
	H.eq(d.title, T("LOC_TX_APPLY_TITLE"))
	H.eq(DialogText(d), T("LOC_TX_APPLY_CONFLICT_TEXT"))
	H.len(FAKE.teamSets, 0)
	H.len(Requests("TX_ApplyDone"), 0)
	GTurn()
	H.eq(Rec(1).newTeamID, 2, "team 2 is free now")
	Events.PlayerTurnActivated(0, true)
	ApplyNow()
	H.deq(UISets(), { { pid = 1, team = 2, context = "UI" } })
	H.eq(Rec(1).applied, 1)
	H.clean()
end)

test("apply 7b: the target died before the click: no write", function()
	Setup()
	Pass()
	Poll()
	H.kill(1)
	local n = #FAKE_UI.popups
	Ban().Controls.ApplyButton:Click()
	H.eq(#FAKE_UI.popups, n)
	H.ok(H.hasLine("refused: TARGET_GONE"))
	H.len(FAKE.teamSets, 0)
	H.clean()
end)

-- ===========================================================================
-- 8. Victory
-- ===========================================================================
test("apply 8: Events.TeamVictory sends TX_Victory once; the unapplied kick is cancelled; banner and Apply gone", function()
	Setup()
	Pass()
	Poll()
	H.eq(ApplyShown(), true)
	Events.TeamVictory(1, 3, 77)
	local v = Requests("TX_Victory")
	H.len(v, 1)
	H.deq(v[1].params, { OnStart = "TX_Victory", team = 1 })
	H.eq(Rec(1).state, "CANCELLED")
	H.eq(Rec(1).reason, "VICTORY")
	H.eq(BannerShown(), false)
	Events.TeamVictory(1, 3, 77)
	H.len(Requests("TX_Victory"), 1, "once per Lua state")
	-- a KICK_PASSED click now opens the Team window, never Apply
	local n = #FAKE_UI.popups
	FAKE_TX.Activate(0, PASSED_N)
	H.eq(#FAKE_UI.popups, n)
	-- after a load the store already has the victory: no new report
	ENVS = FAKE_TX.Reload()
	Events.TeamVictory(1, 3, 77)
	H.len(Requests("TX_Victory"), 1)
	H.len(FAKE.teamSets, 0)
	H.clean()
end)

test("apply 8c: two TeamVictory events before gameplay answers: still one TX_Victory", function()
	Setup()
	FAKE_UI.deferRequests = true
	Events.TeamVictory(1, 3, 77)
	Events.TeamVictory(1, 3, 78)
	H.len(FAKE_UI.pending, 1)
	FAKE_UI.DeliverRequests()
	H.eq(H.prop("TX_Store").victoryTeam, 1)
	H.clean()
end)

test("apply 8b: an applied kick is not cancelled by a victory and still gets the reload banner", function()
	Setup()
	Pass()
	Poll()
	ApplyNow()
	Events.TeamVictory(0, 3, 1)
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.eq(BannerText(), T("LOC_TX_BANNER_RELOAD"))
	ENVS = FAKE_TX.Reload()
	H.eq(Rec(1).state, "DONE")
	H.clean()
end)

-- ===========================================================================
-- 9. Network MP (SEAM O4)
-- ===========================================================================
test("apply 9: network MP adds the untested warning; ALLOW_NETWORK_APPLY = false: no Apply, the wait banner", function()
	Setup({ netMP = true })
	Pass()
	Poll()
	H.eq(ApplyShown(), true)
	local d = ClickApply()
	H.eq(DialogText(d), T("LOC_TX_APPLY_CONFIRM", Label(1)) .. T("LOC_TX_APPLY_CONFIRM_NETMP"))
	TX_Config.ALLOW_NETWORK_APPLY = false
	Events.PlayerTurnActivated(0, true)
	H.eq(ApplyShown(), false)
	H.eq(BannerText(), T("LOC_TX_BANNER_WAIT", Label(1)))
	d.confirm()                                -- the dialog was open before the switch
	H.len(FAKE.teamSets, 0, "refused at yes")
	H.ok(H.hasLine("refused: NETWORK_OFF"))
	H.clean()
end)

-- ===========================================================================
-- 10. SEAM O3: no save or load call
-- ===========================================================================
test("apply 10: AUTO_RELOAD false (and the unported true): no save or load call is ever touched", function()
	Setup()
	local touched = {}
	local function Trap(root, name)
		setmetatable(root, { __index = function(_, k)
			touched[#touched + 1] = name .. "." .. tostring(k)
			return nil
		end })
	end
	Trap(Network, "Network")
	Trap(UI, "UI")
	H.eq(TX_Config.AUTO_RELOAD, false)
	Pass()
	Poll()
	ApplyNow()
	H.eq(LastDialog().id, "TX_ReloadNow")
	-- the hook itself, switched on: it only logs (the R chain is not ported)
	TX_Config.AUTO_RELOAD = true
	GPropose(3, 4)
	Poll()
	Events.PlayerTurnActivated(0, true)
	H.eq(Rec(2).state, "PENDING_APPLY")
	-- record 2 is P4's kick; record 1 already shows the reload banner, so apply it from its notification
	FAKE_TX.Hotseat(3)
	FAKE_TX.Activate(3, PASSED_N)
	LastDialog().confirm()
	H.ok(H.hasLine("[UIApply] AutoReload rec=2: AUTO_RELOAD is on but the R chain is not ported yet; save and load by hand"))
	H.deq(touched, {}, "no Network / UI member outside the fake's set was read")
	-- and no save, load or leave call anywhere in TX/ code (comments aside)
	for _, rel in ipairs({ "TX/UI/TX_ApplyBanner.lua", "TX/UI/TX_UIShared.lua", "TX/UI/TX_TeamWindow.lua",
			"TX/UI/TX_VotePopup.lua", "TX/Scripts/TX_Gameplay.lua", "TX/Scripts/TX_Apply.lua" }) do
		local src = __py_read(rel)
		for line in string.gmatch(src, "[^\n]*") do
			local code = string.gsub(line, "%-%-.*$", "")
			for _, bad in ipairs({ "Network.SaveGame", "Network.LoadGame", "Network.LeaveGame", "UI.QuerySaveGameList",
					"Events.SaveComplete", "FileListQueryResults" }) do
				H.ok(string.find(code, bad, 1, true) == nil, rel .. ": " .. bad .. " in code: " .. line)
			end
		end
	end
	H.clean()
end)

-- ===========================================================================
-- End to end through the UI, and the review rules
-- ===========================================================================
test("apply e2e: kick from the window, vote from the notification, the target applies (hotseat), reload, DONE", function()
	Setup()
	-- P0 kicks P1 from the Team window
	Launch().LaunchItemButton:Click()
	local row = nil
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "TX_MemberRow" then
			for _, inst in ipairs(im.list) do
				if string.find(inst.NameLabel.text, Label(1), 1, true) then row = inst end
			end
		end
	end
	row.KickButton:Click()
	LastDialog().confirm()
	H.eq(Rec(1).state, "OPEN")
	H.len(H.notifs(1), 0, "the target gets nothing")
	-- P2 votes yes from the notification popup
	FAKE_TX.Hotseat(2)
	FAKE_TX.Activate(2, VOTE_N)
	Pop().Controls.YesButton:Click()
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.deq(Pids(H.notifs(nil, PASSED_N)), HUMANS, "KICK_PASSED to every living human")
	-- the target itself has the turn and applies from its KICK_PASSED notification
	FAKE_TX.Hotseat(1)
	H.eq(BannerText(), T("LOC_TX_BANNER_HOST", Label(1)))
	FAKE_TX.Activate(1, PASSED_N)
	H.ok(H.hasLine("PROBE UI NotificationActivated NOTIFICATION_TX_KICK_PASSED ok -> number 1"))
	H.eq(LastDialog().id, "TX_ConfirmApply")
	LastDialog().confirm()
	H.eq(Rec(1).appliedBy, 1)
	H.eq(LastDialog().id, "TX_ReloadNow")
	-- save and load
	ENVS = FAKE_TX.Reload()
	H.eq(Rec(1).state, "DONE")
	H.deq(Pids(H.notifs(nil, DONE_N)), HUMANS)
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "P1 (local) has no Team button")
	FAKE_TX.Hotseat(0)
	H.eq(Launch().LaunchItemButton:IsHidden(), false)
	Launch().LaunchItemButton:Click()
	local hist = nil
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "TX_HistoryRow" and #im.list > 0 then hist = im.list[1].HistoryLabel.text end
	end
	H.eq(hist, T("LOC_TX_HIST_DONE", 1, Label(1)))
	H.clean()
end)

test("apply e2e 2: team of two: P3 kicks P4 (AI): dissolve wording, passes at once, apply, reload, no Team button for P3", function()
	Setup({ localPlayer = 3 })
	Launch().LaunchItemButton:Click()
	local row = nil
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "TX_MemberRow" then
			for _, inst in ipairs(im.list) do
				if string.find(inst.NameLabel.text, Label(4), 1, true) then row = inst end
			end
		end
	end
	row.KickButton:Click()
	H.ok(string.find(DialogText(LastDialog()), T("LOC_TX_CONFIRM_DISSOLVE", Label(4)), 1, true) ~= nil)
	LastDialog().confirm()
	H.eq(Rec(1).state, "PENDING_APPLY")
	Poll()
	H.eq(BannerText(), T("LOC_TX_BANNER_HOST", Label(4)))
	ApplyNow()
	H.deq(UISets(), { { pid = 4, team = 6, context = "UI" } })
	FAKE_UI.Update(Win(), 0.6)
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "the open window's poll hides it right after the write")
	H.eq(Win().Controls.TeamPanel:IsHidden(), true, "and closes the window")
	ENVS = FAKE_TX.Reload()
	H.eq(Rec(1).state, "DONE")
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "P3 is alone now")
	H.clean()
end)

test("apply rules: the banner writes no property; requests are flat; SetTeam and BroadcastPlayerInfo only in TX_ApplyBanner", function()
	Setup()
	Pass()
	local writes = FAKE.DeepCopy(FAKE.propWrites)
	Poll()
	FAKE_TX.Hotseat(3)
	Events.PlayerTurnActivated(3, true)
	H.deq(FAKE.propWrites, writes, "showing the banner wrote nothing")
	FAKE_TX.Hotseat(0)
	ApplyNow()
	ENVS = FAKE_TX.Reload()
	for _, r in ipairs(FAKE_UI.requests) do
		H.eq(r.op, PlayerOperations.EXECUTE_SCRIPT)
		for k, v in pairs(r.params) do
			H.eq(type(k), "string")
			H.ok(type(v) == "number" or type(v) == "string", "flat value " .. tostring(k))
		end
	end
	H.len(FAKE.forbidden, 0)
	for _, s in ipairs(FAKE.teamSets) do
		H.eq(s.context, "UI")
	end
	for _, rel in ipairs({ "TX/UI/TX_UIShared.lua", "TX/UI/TX_TeamWindow.lua", "TX/UI/TX_VotePopup.lua",
			"TX/Scripts/TX_Gameplay.lua", "TX/Scripts/TX_Apply.lua", "TX/Scripts/TX_Notify.lua",
			"TX/Scripts/TX_Votes.lua", "TX/Scripts/TX_Store.lua", "TX/Scripts/TX_Util.lua", "TX/Scripts/TX_Config.lua" }) do
		local src = __py_read(rel)
		for line in string.gmatch(src, "[^\n]*") do
			local code = string.gsub(line, "%-%-.*$", "")
			H.ok(string.find(code, ":SetTeam(", 1, true) == nil, rel .. ": SetTeam outside the apply path")
			H.ok(string.find(code, "BroadcastPlayerInfo", 1, true) == nil, rel .. ": BroadcastPlayerInfo outside the apply path")
		end
	end
	H.clean()
end)

test("apply xml: every Controls.X of the banner has an ID in its XML; the modinfo lists both files", function()
	local src, xml = __py_read(BANNER), __py_read("TX/UI/TX_ApplyBanner.xml")
	local n = 0
	for name in string.gmatch(src, "Controls%.([%a_][%w_]*)") do
		H.ok(string.find(xml, 'ID="' .. name .. '"', 1, true) ~= nil, "Controls." .. name)
		n = n + 1
	end
	H.ok(n >= 4)
	local mi = __py_read("TX/TX.modinfo")
	H.ok(string.find(mi, "<File>UI/TX_ApplyBanner.xml</File>", 1, true) ~= nil)
	H.ok(string.find(mi, "<File>UI/TX_ApplyBanner.lua</File>", 1, true) ~= nil)
end)
