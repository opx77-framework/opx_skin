-- opx_skin client: the garment lists other resources show (client exports GetGarments / FindGarment) and
-- the outfits menu. It only lists and asks; the server decides what is worn and stored.

local Ui = assert(require('client.modules.ui'))

local SLOTS = { Head = true, Face = true, InnerChest = true, OuterChest = true, Legs = true, Feet = true, Outfit = true }
local PAGE = 256     -- records read per Open77.equipment.records call
local MAX_LIMIT = 60 -- items per GetGarments answer (an export result stays far under its limits)

local lists = {}    -- [family|slot] = { items = { { record, label } }, index = { [lower record] = position } }
local building = {} -- [family|slot] = true while a list is being built

-- Garment lists -------------------------------------------------------------------------------------

local function hidden(record)
	for _, pattern in ipairs(type(Config.hide) == 'table' and Config.hide or {}) do
		if type(pattern) == 'string' then
			local ok, found = pcall(string.find, record, pattern)
			if ok and found then return true end
		end
	end
	return false
end

local function usable(text)
	return type(text) == 'string' and text:find('%S') ~= nil and not text:find('^LocKey') and #text <= 96
end

-- The garment's name: the catalogue label, else the game's name in the player's language, else the
-- record made readable ("Items.Jacket_01_basic_01" -> "Jacket 01 basic 01").
local function label(row)
	if usable(row.label) then return row.label end
	local ok, info = pcall(Open77.data.item, row.record)
	if ok and type(info) == 'table' and usable(info.displayName) then return info.displayName end
	local text = row.record:gsub('^Items%.', ''):gsub('_', ' ')
	return (text:gsub('^%l', string.upper))
end

-- 'male' | 'female' | nil (no filter) for a family argument, else the local body's.
local function familyOf(value)
	if value == 'male' or value == 'female' then return value end
	local ok, family = pcall(Open77.equipment.family)
	if ok and (family == 'male' or family == 'female') then return family end
	return nil
end

-- Builds (once per family and slot) the sorted list. Yields between pages. list | nil, reason.
local function list(slot, family)
	local key = (family or 'any') .. '|' .. slot
	local deadline = GetGameTimer() + 20000
	while building[key] and GetGameTimer() < deadline do Wait(50) end
	if lists[key] then return lists[key] end
	building[key] = true
	local items, seen, offset = {}, {}, 0
	while true do
		local ok, records, reason = pcall(Open77.equipment.records, {
			slot = slot, family = family, restricted = false, limit = PAGE, offset = offset,
		})
		if not ok or type(records) ~= 'table' then
			building[key] = nil
			return nil, tostring(ok and reason or records)
		end
		for _, row in ipairs(records) do
			local record = type(row) == 'table' and row.record
			if type(record) == 'string' and #record <= 160 and (row.slot == nil or row.slot == slot)
				and row.nonvisual ~= true and not seen[record:lower()] and not hidden(record) then
				seen[record:lower()] = true
				items[#items + 1] = { record = record, label = label(row), sort = '' }
			end
		end
		if #records < PAGE or offset > 10000 then break end
		offset = offset + #records
		Wait(0)
	end
	for _, item in ipairs(items) do item.sort = item.label:lower() end
	table.sort(items, function(a, b)
		if a.sort ~= b.sort then return a.sort < b.sort end
		return a.record < b.record
	end)
	local index = {}
	for i, item in ipairs(items) do
		item.sort = nil
		index[item.record:lower()] = i
	end
	lists[key] = { items = items, index = index }
	building[key] = nil
	return lists[key]
end

-- ASYNC (the first call per slot and family builds the list): { total, items = { { record, label } } }
-- from position offset + 1, at most `limit` (<= 60) items. nil, reason.
exports('GetGarments', function(slot, offset, limit, family)
	if not SLOTS[slot] then return nil, 'invalid_slot' end
	if offset == nil then offset = 0 end
	if limit == nil then limit = MAX_LIMIT end
	offset = type(offset) == 'number' and math.tointeger(offset) or nil
	limit = type(limit) == 'number' and math.tointeger(limit) or nil
	if not offset or offset < 0 or not limit or limit < 1 then return nil, 'invalid_range' end
	limit = math.min(limit, MAX_LIMIT)
	local entry, reason = list(slot, familyOf(family))
	if not entry then return nil, reason end
	local out = {}
	for i = offset + 1, math.min(offset + limit, #entry.items) do
		local item = entry.items[i]
		out[#out + 1] = { record = item.record, label = item.label }
	end
	return { total = #entry.items, items = out }
end)

-- ASYNC: position (1-based, same order as GetGarments) of a record in a slot's list, or nil.
exports('FindGarment', function(slot, record, family)
	if not SLOTS[slot] or type(record) ~= 'string' then return nil end
	local entry = list(slot, familyOf(family))
	return entry and entry.index[record:lower()] or nil
end)

-- Outfits menu ---------------------------------------------------------------------------------------

RegisterNetEvent('opx_skin:outfits:open', function(data) Ui.open(data) end)
RegisterNetEvent('opx_skin:outfits:list', function(rows) Ui.setList(rows) end)
RegisterNetEvent('opx_skin:outfits:close', function() Ui.close(true) end)
