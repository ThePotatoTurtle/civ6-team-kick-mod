-- ===========================================================================
-- TX_Apply.lua  (Team Expulsion 0.1.0)
-- TX:CONTEXT G
--
-- Gameplay only: include("TX_Apply") from TX_Gameplay.lua. The gameplay hook
-- of the apply seam (PLAN II.9, II.12), provisional Mode B.
--
-- TX_Apply.AfterReload(rec, world) runs once per record, from the synced
-- TX_ApplyDone RELOADED handler, right after the record became DONE and the
-- store was committed. Diplomacy and visibility calls made here later would
-- be MP safe (a GameEvents handler, the same on every machine).
--
-- SEAM O1 (leftover DIPLO_STATE_ALLIED) and SEAM O2 (shared vision): no
-- cleanup in 0.1.0. Session 3 decides (AL8 / AL9 clean break, AL4L expiring
-- alliance, AL3 / AL3b war then peace; VIS1 to VIS3, K), DEC 2026-10-03.
-- If Session 3 shows that vision must be cut before the save, add a
-- TX_Apply.AfterWrite called from the WRITTEN step then; not now.
-- No diplomacy, visibility, save or load call appears in TX/ in 0.1.0
-- (PLAN II.12).
-- ===========================================================================

if TX_Apply ~= nil and TX_Apply.LOADED == 1 then
	return
end

include("TX_Config")
include("TX_Util")

TX_Apply = {}

-- ---------------------------------------------------------------------------
-- TX_Apply.AfterReload(rec, world)
-- SEAM O1, O2: logs the hook and does nothing else in 0.1.0.
-- ---------------------------------------------------------------------------
function TX_Apply.AfterReload(rec, world)
	TX_Util.Log(2, "Apply", "AfterReload rec=%s target=P%s: no cleanup in 0.1.0 (O1 alliance, O2 vision)",
		TX_Util.Str(rec and rec.id), TX_Util.Str(rec and rec.targetID))
end

TX_Apply.LOADED = 1
