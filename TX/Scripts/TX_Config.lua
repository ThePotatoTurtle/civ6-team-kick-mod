-- ===========================================================================
-- TX_Config.lua  (Team Kick 0.1.0)
-- TX:CONTEXT both
--
-- Constants and shared names (PLAN II.3). Included by gameplay and UI with
-- include("TX_Config") (modinfo ImportFiles TX_Imports).
-- No engine calls. Loading the file only defines TX_Config.
-- Pattern: EFV/Scripts/EFV_Config.lua:24-33 (load-once guard, version),
-- :110-160 (property keys, request names, notification names).
-- ===========================================================================

-- Load-once guard: include() re-runs a file each time it is called
-- (EFV_Config.lua:24-26).
if TX_Config ~= nil and TX_Config.LOADED == 1 then
	return
end

TX_Config = {}

-- Keep equal to LOC_TX_MOD_TITLE / LOC_TX_MOD_DESCRIPTION in TX.modinfo.
-- TX_Gameplay logs it at load, so a Lua.log names the installed build.
TX_Config.VERSION = "0.1.0"
TX_Config.SCHEMA = 1                -- TX_Store schema

TX_Config.VOTE_TURNS = 5            -- TP 2.1, DEC 3: expiry after 5 turns
TX_Config.HISTORY_MAX = 50          -- closed records kept in the store
TX_Config.HISTORY_SHOWN = 20        -- rows in the window
TX_Config.MAX_TEAM_ID = 63          -- team ribbons ICON_TEAM_RIBBON_0..63 (RIB 2)
TX_Config.LOG_LEVEL = 2             -- 1 errors, 2 events, 3 verbose

-- Game properties (written by gameplay only).
TX_Config.PROP_STORE = "TX_Store"
TX_Config.PROP_REV = "TX_Rev"

-- Request names: params.OnStart values and GameEvents.<name>. Top-level
-- REQ_X = "TX_..." so the audit's OnStart cross-check resolves them
-- (tools/api_audit.py cross_checks).
TX_Config.REQ_PROPOSE = "TX_Propose"
TX_Config.REQ_VOTE = "TX_Vote"
TX_Config.REQ_APPLY_DONE = "TX_ApplyDone"
TX_Config.REQ_VICTORY = "TX_Victory"

-- Record states (PLAN II.6).
TX_Config.ST = {
	OPEN = "OPEN",
	PASSED = "PASSED",
	FAILED = "FAILED",
	EXPIRED = "EXPIRED",
	CANCELLED = "CANCELLED",
	PENDING_APPLY = "PENDING_APPLY",
	DONE = "DONE",
}

-- Vote values of a voter entry.
TX_Config.V = { PENDING = "PENDING", YES = "YES", NO = "NO", GONE = "GONE" }

-- Steps of the TX_ApplyDone request (apply seam, PLAN II.9).
TX_Config.STEP_WRITTEN = "WRITTEN"
TX_Config.STEP_RELOADED = "RELOADED"
-- The host's UI undid its write after the wait (timeout or refusal); carries
-- the same attempt number as its WRITTEN (review fix, PLAN Part II notes).
TX_Config.STEP_UNDONE = "UNDONE"

-- Notification types. Must match Data/TX_Notifications.sql. Text keys are
-- "LOC_" .. type .. "_MESSAGE" / "_SUMMARY".
TX_Config.NOTIF = {
	VOTE_REQUIRED = "NOTIFICATION_TX_VOTE_REQUIRED",
	KICK_PASSED = "NOTIFICATION_TX_KICK_PASSED",
	KICK_DONE = "NOTIFICATION_TX_KICK_DONE",
	REQUEST_FAILED = "NOTIFICATION_TX_REQUEST_FAILED",
	HARD_KICK_DONE = "NOTIFICATION_TX_HARD_KICK_DONE",
}
-- Custom notification data keys (EFV_Notify.lua:170-180).
TX_Config.NKEY_RECORD = "TX_RecordID"
TX_Config.NKEY_TURN = "TX_Turn"

-- Kick modes (DEC 2026-10-04 "two kick modes"). The proposer picks one; it is
-- the flat param mode of TX_Propose and the record's mode field.
--   SOFT: team split only; the ex-teammates stay in the timeless alliance.
--   HARD: team split, then after the reload the KICKED player declares war on
--         each remaining member of its old team and makes peace at once
--         (TX_Apply.AfterReload), so the grievances fall on the kicked player.
-- A record without a mode (saved before kick modes) loads as MODE_DEFAULT.
TX_Config.MODE = { SOFT = "SOFT", HARD = "HARD" }
TX_Config.MODE_DEFAULT = "SOFT"         -- the dialog's default and the mode of old records
-- The kicked-player-declares war step was verified in TX_Dev Session 3c. false: the dialog offers Soft only, gameplay refuses HARD
-- (BAD_MODE) and a stored HARD record gets no war step (it ends as a soft kick).
TX_Config.HARD_KICK_ENABLED = true

-- UI wait for gameplay after a request, in seconds (TX_Dev_Panel.lua:55-56).
TX_Config.WAIT_POLL = 0.3
TX_Config.WAIT_MAX = 5

-- Seams (PLAN II.12). No final behaviour in 0.1.0.
TX_Config.ALLOW_NETWORK_APPLY = true    -- SEAM O4: the host may apply in network MP (untested warning)
-- Kick save (DEC 2026-10-07, replaces SEAM O3): after gameplay confirms the
-- apply, the host's UI saves as <SAVE_PREFIX>_<target>_T<turn>_<HHMM> and
-- waits up to SAVE_MAX s for Events.SaveComplete. The mod never loads a game
-- (TX_ApplyBanner.lua "Kick save" says why).
TX_Config.SAVE_PREFIX = "TeamKick"
TX_Config.SAVE_MAX = 10

TX_Config.LOADED = 1
