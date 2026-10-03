-- TX_Util.lua (BROKEN fixture: shared file with an unclosed region marker)
TX_Util = {}

function TX_Util.Log(msg)
	print(msg)
end

-- TX:G-ONLY begin
function TX_Util.Mutate()
	Game:SetProperty("TX_X", 1)
end
