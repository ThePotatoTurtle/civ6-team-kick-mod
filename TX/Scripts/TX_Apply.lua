-- ===========================================================================
-- TX_Apply.lua  (Team Kick 0.1.0)
-- TX:CONTEXT G
--
-- Gameplay only: include("TX_Apply") from TX_Gameplay.lua. The gameplay hook
-- of the apply seam (PLAN II.9, II.12), provisional Mode B, and the HARD kick
-- (DEC 2026-10-04 "two kick modes"; PLAN Part II notes "Kick modes").
--
-- TX_Apply.AfterReload(rec, world) runs once per record, from the synced
-- TX_ApplyDone RELOADED handler, right after the record became DONE and the
-- store was committed (so a second RELOADED, from another UI or after another
-- load, finds DONE and never gets here). A GameEvents handler runs the same
-- on every machine, so the diplomacy calls here are MP safe and deterministic:
-- keepers in ascending pid order, one attempt per step, no retries.
--
--   SOFT: nothing. The ex-teammates stay in the timeless alliance (SEAM O1
--         stays open for soft kicks; Session 3 found no clean break and no
--         alliance that truly expires).
--   HARD: the KICKED player declares war on each remaining living member of
--         its old team (ascending pids), then makes peace with each one it is
--         still at war with: Players[t]:GetDiplomacy():DeclareWarOn(k,
--         WarTypes.FORMAL_WAR, true), then :MakePeaceWith(k, true). The
--         keepers then hold the grievances against the kicked player (AL3:
--         the target held 100 against the declarer). The third DeclareWarOn
--         argument must be true to declare on an ally (AL3b).
--         VERIFIED in TX_Dev Session 3c (2026-10-07): the kicked player's
--         war on one keeper is a war on the whole team and one peace ends it
--         for every keeper; the keepers hold the grievances; an AI target
--         stays at peace. The loop handles both answers: a keeper already at
--         war gets no new declaration, a keeper no longer at war gets no
--         peace call. TX_Config.HARD_KICK_ENABLED = false switches it off.
--
-- SEAM O2 (shared vision): no fix exists (Session 3 VIS1 to VIS3); known
-- limitation for both modes.
-- Engine calls (PLAN Appendix B): Players[i]:GetDiplomacy() (G:C),
-- :IsAtWarWith (G:C), :DeclareWarOn(b, WarTypes.FORMAL_WAR, true) (G, VER:
-- V6, AL3), :MakePeaceWith(b, true) (G, VER: AL3, LOG:2748), WarTypes.FORMAL_WAR.
-- ===========================================================================

if TX_Apply ~= nil and TX_Apply.LOADED == 1 then
	return
end

include("TX_Config")
include("TX_Util")
include("TX_Votes")

TX_Apply = {}

-- AfterReload results.
TX_Apply.SOFT = "SOFT"         -- soft kick: nothing to do
TX_Apply.OFF = "OFF"           -- HARD record while HARD_KICK_ENABLED is false: nothing done
TX_Apply.SKIP = "SKIP"         -- HARD record that already has hardDone: nothing done
TX_Apply.OK = "OK"             -- HARD: every keeper saw war, none is at war at the end
TX_Apply.FAILED = "FAILED"     -- HARD: a step failed (ERROR lines name it); left as it is

local function Log(level, fmt, ...)
	TX_Util.Log(level, "Apply", fmt, ...)
end

local function YN(v)
	if v == true then
		return "yes"
	elseif v == false then
		return "no"
	end
	return "unreadable"
end

-- true / false, or nil when the read fails (G:C, EFV A36).
local function AtWar(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():IsAtWarWith(b) end)
	if ok and type(v) == "boolean" then
		return v
	end
	return nil
end

-- TX_Apply.Keepers(rec, world) -> ascending pids of the living majors still
-- on the record's old team (the kicked player is on newTeamID by now).
function TX_Apply.Keepers(rec, world)
	local out = {}
	for _, pid in ipairs(TX_Votes.Members(world, rec.teamID)) do
		if pid ~= rec.targetID then
			out[#out + 1] = pid
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- TX_Apply.HardKick(rec, world) -> true when the alliance was ended
-- War then peace, the kicked player as the declarer. Every step is logged; a
-- failed step is an ERROR line and is left as it is (one attempt, no retry,
-- so nothing can loop). The peace pass runs whatever the war pass did, so a
-- war that did start is always offered its peace.
-- ---------------------------------------------------------------------------
function TX_Apply.HardKick(rec, world)
	local t = rec.targetID
	local keepers = TX_Apply.Keepers(rec, world)
	local names = {}
	for i, k in ipairs(keepers) do
		names[i] = "P" .. k
	end
	Log(2, "HARD rec=%d: P%d ends the alliance with its old team %d: keepers [%s]", rec.id, t, rec.teamID,
		table.concat(names, ","))
	if #keepers == 0 then
		Log(2, "HARD rec=%d: no living member left on team %d; nothing to end", rec.id, rec.teamID)
		return true
	end
	local ok = true
	local warSeen = {}

	-- 1. War: P<t> declares on each keeper (verified, Session 3c).
	for _, k in ipairs(keepers) do
		local before = AtWar(t, k)
		if before == true then
			-- A war declared on an earlier keeper may already cover this one
			-- (team wide war, verified in Session 3c).
			warSeen[k] = true
			Log(2, "HARD rec=%d war P%d->P%d: already at war, no declaration", rec.id, t, k)
		else
			local okCall, err = pcall(function()
				Players[t]:GetDiplomacy():DeclareWarOn(k, WarTypes.FORMAL_WAR, true)
			end)
			local now = AtWar(t, k)
			if not okCall then
				ok = false
				Log(1, "HARD rec=%d war P%d->P%d: DeclareWarOn failed: %s (at war=%s)", rec.id, t, k, TX_Util.Str(err), YN(now))
			elseif now ~= true then
				ok = false
				Log(1, "HARD rec=%d war P%d->P%d: DeclareWarOn ran but at war=%s", rec.id, t, k, YN(now))
			else
				warSeen[k] = true
				Log(2, "HARD rec=%d war P%d->P%d: declared, at war=yes", rec.id, t, k)
			end
		end
	end

	-- 2. Peace with every keeper still at war (one call each).
	for _, k in ipairs(keepers) do
		local w = AtWar(t, k)
		if w == true then
			local okCall, err = pcall(function()
				Players[t]:GetDiplomacy():MakePeaceWith(k, true)
			end)
			local now = AtWar(t, k)
			if not okCall then
				ok = false
				Log(1, "HARD rec=%d peace P%d->P%d: MakePeaceWith failed: %s (at war=%s)", rec.id, t, k, TX_Util.Str(err), YN(now))
			elseif now ~= false then
				ok = false
				Log(1, "HARD rec=%d peace P%d->P%d: MakePeaceWith ran but at war=%s", rec.id, t, k, YN(now))
			else
				Log(2, "HARD rec=%d peace P%d->P%d: made, at war=no", rec.id, t, k)
			end
		elseif w == false then
			Log(2, "HARD rec=%d peace P%d->P%d: not at war, no call", rec.id, t, k)
		else
			ok = false
			Log(1, "HARD rec=%d peace P%d->P%d: the war state is unreadable", rec.id, t, k)
		end
	end

	-- 3. Final state, one line per keeper.
	for _, k in ipairs(keepers) do
		local w = AtWar(t, k)
		Log(2, "HARD rec=%d final P%d vs P%d: war step=%s at war=%s", rec.id, t, k, YN(warSeen[k] == true), YN(w))
		if warSeen[k] ~= true or w ~= false then
			ok = false
		end
	end
	if ok then
		Log(2, "HARD rec=%d done: the alliance of P%d with team %d is ended (war then peace)", rec.id, t, rec.teamID)
	else
		Log(1, "HARD rec=%d FAILED: P%d may still be allied with or at war with team %d; left as it is (no retry)",
			rec.id, t, rec.teamID)
	end
	return ok
end

-- ---------------------------------------------------------------------------
-- TX_Apply.AfterReload(rec, world) -> TX_Apply.SOFT | OFF | SKIP | OK | FAILED
-- Gameplay stores the HARD outcome as rec.hardDone (OK: 1, FAILED: 0) and
-- picks the notification from the result.
-- ---------------------------------------------------------------------------
function TX_Apply.AfterReload(rec, world)
	local mode = TX_Votes.RecMode(rec)
	if mode ~= TX_Config.MODE.HARD then
		Log(2, "AfterReload rec=%s target=P%s mode=%s: no war step, the ex-teammates stay allied (O2 vision: known limitation)",
			TX_Util.Str(rec.id), TX_Util.Str(rec.targetID), mode)
		return TX_Apply.SOFT
	end
	if TX_Config.HARD_KICK_ENABLED ~= true then
		Log(2, "AfterReload rec=%s target=P%s mode=HARD: HARD_KICK_ENABLED is false; nothing done, they stay allied",
			TX_Util.Str(rec.id), TX_Util.Str(rec.targetID))
		return TX_Apply.OFF
	end
	if rec.hardDone ~= nil then
		Log(2, "AfterReload rec=%s target=P%s mode=HARD: already ran (hardDone=%s); nothing done",
			TX_Util.Str(rec.id), TX_Util.Str(rec.targetID), TX_Util.Str(rec.hardDone))
		return TX_Apply.SKIP
	end
	Log(2, "AfterReload rec=%s target=P%s mode=HARD: war then peace",
		TX_Util.Str(rec.id), TX_Util.Str(rec.targetID))
	if TX_Apply.HardKick(rec, world) then
		return TX_Apply.OK
	end
	return TX_Apply.FAILED
end

TX_Apply.LOADED = 1
