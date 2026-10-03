-- TX_Spike.lua (fixture): the probe convention. A probe names an engine call by string and runs it
-- under pcall, so api_audit does not audit its arguments; the calls are listed as INFO instead.
function TX_Probe(label, objName, index, method, ...)
	local obj = _G[objName]
	if obj ~= nil and index ~= nil then
		obj = obj[index]
	end
	local fn = obj and obj[method]
	if type(fn) ~= "function" then
		TX_Log("Spike", label .. ": " .. objName .. "." .. method .. " = nil")
		return false
	end
	local ok, res = pcall(fn, obj, ...)
	TX_Log("Spike", label .. ": ok=" .. tostring(ok) .. " result=" .. tostring(res))
	return ok, res
end

function TX_RunSpike()
	TX_Probe("S3 config team", "PlayerConfigurations", 1, "GetTeam")
	TX_Probe("S3 set team", "PlayerConfigurations", 1, "SetTeam", 5)
	TX_Probe("S1 team setter", "Players", 1, "SetTeam", 5)
end
