-- TX_Syntax.lua (BROKEN fixture: missing 'end')
function TX_Broken(a)
	if a then
		print("never closed")
end
