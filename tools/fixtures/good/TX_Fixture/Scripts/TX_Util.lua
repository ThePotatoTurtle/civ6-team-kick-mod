-- TX_Util.lua (fixture; shared G + UI via ImportFiles)
TX_Util = {}

function TX_IsGameplay()
	return UI == nil
end

function TX_Log(tag, msg)
	print("[TX][T" .. tostring(Game.GetCurrentGameTurn()) .. "][" .. tag .. "] " .. msg)
end

-- The only sanctioned pairs(): keys come back sorted.
function TX_SortedKeys(t)
	local keys = {}
	for k, _ in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

function TX_Util.SortedAlivePlayers()
	local ids = {}
	for _, id in ipairs(PlayerManager.GetAliveIDs()) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end
