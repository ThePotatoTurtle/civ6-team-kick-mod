-- TX_UIShared.lua (fixture; UI include)
include("TX_Util")
include("TX_Rules")

function TX_UI_Request(onStart, params)
	params.OnStart = onStart
	UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT, params)
end

function TX_UI_ReadStore()
	return Game:GetProperty("TX_Proposals")
end
