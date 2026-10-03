-- TX_Rules.lua (fixture; shared, context adapters with region markers)
TX_Rules = {}

TX_Rules.ALL_REASON_CODES = {
	"NOT_HUMAN",
	"NOT_TEAMMATE",
}

function TX_Rules.ProposeReasons(proposerID, targetID)
	local reasons = {}
	local pP = Players[proposerID]
	local pT = Players[targetID]
	if pP == nil or pT == nil then
		return reasons
	end
	if not pP:IsHuman() then
		reasons[#reasons + 1] = "NOT_HUMAN"
	end
	if pP:GetTeam() ~= pT:GetTeam() then
		reasons[#reasons + 1] = "NOT_TEAMMATE"
	end
	return reasons
end

function TX_Rules.Relation(a, b)
	if TX_IsGameplay() then
		-- TX:G-ONLY begin
		if Players[a]:GetDiplomacy():HasAllied(b) then
			return "ALLIANCE"
		end
		-- TX:G-ONLY end
	else
		-- TX:UI-ONLY begin
		local idx = Players[b]:GetDiplomaticAI():GetDiplomaticStateIndex(a)
		local row = GameInfo.DiplomaticStates[idx]
		if row ~= nil and row.StateType == "DIPLO_STATE_ALLIED" then
			return "ALLIANCE"
		end
		-- TX:UI-ONLY end
	end
	return nil
end
